#!/bin/bash
# The shaper, `trafficctl shape` (trafficctl.shape), and the shapes half of
# `trafficctl restore`, against a stateful tc (tests/lib/tc-htb.sh): what the
# router holds afterwards, not only which commands ran. The cases moved here
# from the tests of the shell shaper (test_regressions, test_subnet_limits)
# keep their reasons; the direction and asymmetric cases are in
# test_direction and test_asymmetric_limits, the readers' lookups in
# test_shape_lookup.

PASS=0
FAIL=0

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/shape_env.sh
. "$UC_TESTLIB/shape_env.sh"

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}

lt_cfg 0
st_net br-lan lan1 lan2
cid_of() { sed -n "s/.*\"ip\":\"$1\",\"rate_kbit\":[0-9]*,\"classid\":\"\(1:[0-9a-f]*\)\".*/\1/p" "$SHAPES"; }
# The filters on dev, as "<dir> <ip> flowid <cid>".
filters_of() { st_dump | awk -v d="$1" '$1 == "dev" { on = ($2 == d); next } on && $1 == "filter" { print $4, $5, $6, $7 }'; }

# ════════════════════════════════════════════════════════════════════════════
# Every shape keeps its filters when another is added or removed
# ════════════════════════════════════════════════════════════════════════════
#
# A u32 `filter del` without a handle removes the whole prio: up to v1.30.x
# each add (which first detaches the address) and each remove took the
# filters of every other shaped device on the same device with it, so only
# the shape applied last was in force while all of them read as applied.

st_reset
st_run add 192.168.1.50 5000 >/dev/null
st_run add 192.168.1.51 3000 >/dev/null
assert_eq "two shapes: both download filters are on the LAN device" \
    "$(printf 'dst 192.168.1.50/32 flowid 1:2\ndst 192.168.1.51/32 flowid 1:3')" "$(filters_of br-lan)"
assert_eq "two shapes: both upload filters are on the IFB" \
    "$(printf 'src 192.168.1.50/32 flowid 1:2\nsrc 192.168.1.51/32 flowid 1:3')" "$(filters_of tctl-ifb0)"
st_run add 192.168.1.50 8000 >/dev/null
assert_eq "re-applying one shape keeps the other's filters" \
    "$(printf 'dst 192.168.1.50/32 flowid 1:2\ndst 192.168.1.51/32 flowid 1:3')" "$(filters_of br-lan)"
assert_contains "and the re-applied class has the new rate" "class 1:2 1:1 8000kbit" "$(st_dump)"
st_run remove 192.168.1.50 >/dev/null
assert_eq "removing one shape leaves the other's download filter" \
    "dst 192.168.1.51/32 flowid 1:3" "$(filters_of br-lan)"
assert_eq "and its upload filter" "src 192.168.1.51/32 flowid 1:3" "$(filters_of tctl-ifb0)"
assert_not_contains "and the removed class is gone" "class 1:2 " "$(st_dump)"

# .1 is a prefix of .10 as text, in the records and in the filter keys.
st_reset
st_run add 192.168.1.1 5000 >/dev/null
st_run add 192.168.1.10 3000 >/dev/null
st_run remove 192.168.1.1 >/dev/null
assert_eq ".1 removed: .10's download filter stays" "dst 192.168.1.10/32 flowid 1:3" "$(filters_of br-lan)"
assert_eq ".1 removed: and its upload filter" "src 192.168.1.10/32 flowid 1:3" "$(filters_of tctl-ifb0)"
assert_contains ".1 removed: and its class" "class 1:3 1:1 3000kbit" "$(st_dump)"
st_run add 192.168.1.1 5000 >/dev/null
st_run remove 192.168.1.10 >/dev/null
assert_eq ".10 removed: .1's download filter stays" "dst 192.168.1.1/32 flowid 1:2" "$(filters_of br-lan)"
assert_eq ".10 removed: and its upload filter" "src 192.168.1.1/32 flowid 1:2" "$(filters_of tctl-ifb0)"
assert_eq ".10 removed: .1's record stays" '[{"ip":"192.168.1.1","rate_kbit":5000,"classid":"1:2"}]' "$(cat "$SHAPES")"

# Concurrent adds (the DHCP hook's, the UI's, the bot's) each get their own
# minor: the pick and the save are under one lock.
st_reset
# (Waits on these three only: the ubus mock runs in the background too.)
st_run add 192.168.1.41 5000 > "$STATE/c1" & p1=$!
st_run add 192.168.1.42 5000 > "$STATE/c2" & p2=$!
st_run add 192.168.1.43 5000 > "$STATE/c3" & p3=$!
wait "$p1" "$p2" "$p3"
assert_eq "concurrent adds: three distinct minors" "1:2 1:3 1:4" \
    "$(for i in 41 42 43; do cid_of 192.168.1.$i; echo; done | sort | paste -sd " " -)"
assert_eq "concurrent adds: three download filters" "3" "$(filters_of br-lan | wc -l)"
assert_eq "concurrent adds: each its own class" "3" "$(filters_of br-lan | awk '{ print $4 }' | sort -u | wc -l)"
assert_eq "concurrent adds: all replied ok" "3" "$(cat "$STATE/c1" "$STATE/c2" "$STATE/c3" | grep -c '"ok":true')"

# ════════════════════════════════════════════════════════════════════════════
# Classids are allocated, not derived from the address
# ════════════════════════════════════════════════════════════════════════════

# 192.168.0.1 must NOT land on 1:1 (the reserved root class): the old
# derivation used the last two octets (0*256+1=1).
st_reset
st_run add 192.168.0.1 5000 >/dev/null
assert_eq "192.168.0.1 gets an allocated minor, not the root class 1:1" "1:2" "$(cid_of 192.168.0.1)"
# x.x.255.254 must NOT land on 1:fffe (the default class): 255*256+254.
st_reset
st_run add 10.0.255.254 5000 >/dev/null
assert_eq "x.x.255.254 gets an allocated minor, not the default class 1:fffe" "1:2" "$(cid_of 10.0.255.254)"
assert_contains "and the default class is still the root's" "class 1:fffe 1:1 1000mbit" "$(st_dump)"

# Two addresses sharing their last two octets across subnets get DIFFERENT
# minors: the old derivation collided them.
st_reset
st_run add 192.168.1.50 5000 >/dev/null
st_run add 10.0.1.50 5000 >/dev/null
assert_eq "cross-subnet addresses with the same last octets get different minors" \
    "1:2 1:3" "$(cid_of 192.168.1.50) $(cid_of 10.0.1.50)"
# A minor held only by a live class (a crash between tc and the record) is
# not handed out again.
sh "$UC_TESTLIB/tc-htb.sh" tc class add dev br-lan parent 1:1 classid 1:4 htb rate 1kbit ceil 1kbit burst 1600b cburst 1600b
st_run add 10.0.2.50 5000 >/dev/null
assert_eq "a minor in use by a live class is skipped" "1:5" "$(cid_of 10.0.2.50)"

# Re-shaping an existing address reuses its recorded minor.
st_reset
st_run add 192.168.1.77 5000 >/dev/null
first=$(cid_of 192.168.1.77)
st_run add 192.168.1.77 8000 >/dev/null
assert_eq "re-shaping the same address reuses its minor" "$first" "$(cid_of 192.168.1.77)"

# A shape recorded before classids were allocated (no classid field) is
# still removable, through the class derived from the address: 1*256+77.
st_reset
printf '[{"ip":"192.168.1.77","rate_kbit":5000}]' > "$SHAPES"
T() { sh "$UC_TESTLIB/tc-htb.sh" tc "$@"; }
T qdisc del dev br-lan root 2>/dev/null
T qdisc add dev br-lan root handle 1: htb default fffe r2q 10
T class add dev br-lan parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit burst 125000b cburst 125000b
T class add dev br-lan parent 1:1 classid 1:14d htb rate 5000kbit ceil 5000kbit burst 6250b cburst 6250b
T filter add dev br-lan parent 1:0 prio 10 protocol ip u32 match ip dst 192.168.1.77/32 flowid 1:14d
OUT=$(st_run remove 192.168.1.77)
assert_contains "a pre-allocation record is removable" '"ok":true' "$OUT"
assert_eq "its derived class and filter are gone" "" "$(st_dump | grep -E '1:14d')"
assert_eq "and the record with it" "[]" "$(cat "$SHAPES")"

# An address with no record has no class to remove: its derived minor
# (192.168.0.4 -> 1:4) may be allocated to another device, whose filters,
# class and qdisc the remove would tear down (the bot and rpcd pass any
# address).
st_reset
printf '[{"ip":"192.168.0.50","rate_kbit":5000,"classid":"1:4"}]' > "$SHAPES"
st_run add 192.168.0.50 5000 >/dev/null
before=$(st_dump)
OUT=$(st_run remove 192.168.0.4)
assert_contains "remove, no record: still ok" '"ok":true' "$OUT"
assert_eq "remove, no record: another device's shape on the derived minor is untouched" "$before" "$(st_dump)"
assert_eq "remove, no record: and its record" '[{"ip":"192.168.0.50","rate_kbit":5000,"classid":"1:4"}]' "$(cat "$SHAPES")"

# ════════════════════════════════════════════════════════════════════════════
# A foreign root qdisc (SQM's cake) is declined, never torn down
# ════════════════════════════════════════════════════════════════════════════
#
# The requester in #64 runs SQM. Refusing to replace a root qdisc it does not
# recognise is what stops this app destroying an SQM setup, but the refusal
# used to read "tc setup failed", which looks like a bug. The limiter is a
# policer, owns no qdisc, and is the answer on such a router.

TC_ROOT_br_lan=cake st_reset
OUT=$(st_run add 192.168.1.90 5000)
assert_contains "SQM: declines rather than claiming success" '"ok":false' "$OUT"
assert_contains "SQM: names the root qdisc as the reason" "root qdisc" "$OUT"
assert_contains "SQM: points at the limiter, which coexists with SQM" "limiter" "$OUT"
assert_not_contains "SQM: never deletes the foreign root qdisc" "qdisc del dev br-lan root" "$(cat "$TC_LOG")"
assert_contains "SQM: cake is still the root" "dev br-lan root cake" "$(st_dump)"
assert_eq "SQM: nothing is recorded" "" "$(cat "$SHAPES" 2>/dev/null)"

# A qdisc the kernel or OpenWrt put there carries nothing worth keeping.
TC_ROOT_br_lan=fq_codel st_reset
OUT=$(st_run add 192.168.1.90 5000)
assert_not_contains "a default root qdisc is not reported as somebody's QoS" "will not be torn down" "$OUT"
assert_contains "and is replaced by the HTB tree" "dev br-lan root htb" "$(st_dump)"

# ════════════════════════════════════════════════════════════════════════════
# Without kmod-ifb: download only, and said so
# ════════════════════════════════════════════════════════════════════════════

st_reset
OUT=$(TC_NO_IFB=1 st_run add 192.168.1.60 5000)
assert_contains "no IFB: still applied" '"ok":true' "$OUT"
assert_contains "no IFB: says download only and what to install" \
    "(download only — upload needs kmod-ifb: opkg/apk install kmod-ifb kmod-sched)" "$OUT"
assert_eq "no IFB: the download half is in place" "dst 192.168.1.60/32 flowid 1:2" "$(filters_of br-lan)"
OUT=$(TC_NO_IFB=1 st_run add 192.168.1.61 5000 x 1000)
assert_contains "no IFB, asymmetric: the upload ceiling is named as NOT applied" \
    "shape 5000 kbit/s applied to 192.168.1.61 for download only — the 1000 kbit/s upload ceiling was NOT applied" "$OUT"
assert_contains "no IFB: the record still carries the upload rate" \
    '{"ip":"192.168.1.61","rate_kbit":5000,"classid":"1:3","rate_kbit_up":1000}' "$(cat "$SHAPES")"

# ════════════════════════════════════════════════════════════════════════════
# The reply is the only output, and a failure is one
# ════════════════════════════════════════════════════════════════════════════
#
# The shell shaper printed tc's error text ahead of its JSON, which a caller
# parsing stdout could not read.

st_reset
OUT=$(PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" TC_FAIL='class add dev br-lan parent 1:1 classid 1:2' \
    tctl shape add 192.168.1.70 5000 2>/dev/null)
rc=$?
assert_eq "tc failure: the reply" '{"ok":false,"msg":"tc setup failed for 192.168.1.70 on br-lan"}' "$OUT"
assert_eq "tc failure: exit status 1" "1" "$rc"
assert_eq "tc failure: nothing is recorded" "" "$(cat "$SHAPES" 2>/dev/null)"

# A record that cannot be written: the shape is in force, the reply says
# the restore will not know it.
st_reset
mkdir -p "$SHAPES"
OUT=$(st_run add 192.168.1.71 5000)
assert_contains "save fails: the shape is still applied" '"ok":true' "$OUT"
assert_contains "save fails: and the reply says it is not saved" "shapes.json could not be written" "$OUT"
OUT=$(st_run remove 192.168.1.71)
assert_contains "save fails on remove: says the shape comes back" "comes back on the next ifup lan" "$OUT"
rmdir "$SHAPES"

# ════════════════════════════════════════════════════════════════════════════
# Arguments
# ════════════════════════════════════════════════════════════════════════════

st_reset
assert_eq "no action: usage" '{"ok":false,"msg":"usage: trafficctl-shape.sh <add|remove|status> <ip> [rate_kbit] [label]"}' "$(st_run)"
assert_eq "add without a rate" '{"ok":false,"msg":"usage: trafficctl-shape.sh add <ip> <rate_kbit> [label]"}' "$(st_run add 192.168.1.5)"
assert_eq "remove without an address" '{"ok":false,"msg":"usage: trafficctl-shape.sh remove <ip>"}' "$(st_run remove)"
assert_eq "an invalid address" '{"ok":false,"msg":"invalid IP address"}' "$(st_run add '192.168.1.5;reboot' 5000)"
assert_eq "a subnet is not a shaper target" '{"ok":false,"msg":"invalid IP address"}' "$(st_run add 192.168.1.0/24 5000)"
assert_eq "rate 0 is refused, not a total block" \
    '{"ok":false,"msg":"invalid rate: expected whole kbit/s, 1 to 100000000"}' "$(st_run add 192.168.1.5 0)"
assert_eq "an invalid upload rate" \
    '{"ok":false,"msg":"invalid upload rate: expected whole kbit/s, 1 to 100000000"}' "$(st_run add 192.168.1.5 5000 x 010)"
assert_eq "nothing reached tc" "" "$(grep -v ' show ' "$TC_LOG")"

# ════════════════════════════════════════════════════════════════════════════
# status
# ════════════════════════════════════════════════════════════════════════════

st_reset
st_run add 192.168.1.80 5000 >/dev/null
assert_eq "status: the class and its rate as tc lists it" \
    '{"ok":true,"ip":"192.168.1.80","classid":"1:2","info":"5Mbit"}' "$(st_run status 192.168.1.80)"
assert_eq "status: an address with no shape" \
    '{"ok":true,"ip":"192.168.1.81","classid":"","info":"no shape active"}' "$(st_run status 192.168.1.81)"

# ════════════════════════════════════════════════════════════════════════════
# shapes.json: the bytes every release reads, and the lock they share
# ════════════════════════════════════════════════════════════════════════════

st_reset
printf '[{"ip":"192.168.1.9","rate_kbit":1000,"classid":"1:9"},{"ip":"192.168.1.10","rate_kbit":2000,"classid":"1:a","rate_kbit_up":500}]' > "$SHAPES"
st_run add 192.168.1.1 4000 >/dev/null
st_run add 192.168.1.2 4000 x 400 >/dev/null
assert_eq "records: others kept byte for byte, rate_kbit_up only when it differs" \
    '[{"ip":"192.168.1.9","rate_kbit":1000,"classid":"1:9"},{"ip":"192.168.1.10","rate_kbit":2000,"classid":"1:a","rate_kbit_up":500},{"ip":"192.168.1.1","rate_kbit":4000,"classid":"1:2"},{"ip":"192.168.1.2","rate_kbit":4000,"classid":"1:3","rate_kbit_up":400}]' \
    "$(cat "$SHAPES")"
st_run remove 192.168.1.1 >/dev/null
assert_eq "records: removing .1 keeps .10 (a prefix of it as text)" \
    '[{"ip":"192.168.1.9","rate_kbit":1000,"classid":"1:9"},{"ip":"192.168.1.10","rate_kbit":2000,"classid":"1:a","rate_kbit_up":500},{"ip":"192.168.1.2","rate_kbit":4000,"classid":"1:3","rate_kbit_up":400}]' \
    "$(cat "$SHAPES")"
assert_eq "records: mode 644" "644" "$(stat -c %a "$SHAPES")"
assert_eq "records: the lock is released" "no" "$([ -e "$ROOT/tmp/trafficctl_shapes.lock.d" ] && echo yes || echo no)"

# The shell shaper of an older release, or a writer killed mid-save, leaves
# the bare mkdir lock: taken over once it is 5 s old, as the shell did.
mkdir -p "$ROOT/tmp/trafficctl_shapes.lock.d"
touch -d '1 minute ago' "$ROOT/tmp/trafficctl_shapes.lock.d"
OUT=$(st_run add 192.168.1.3 1000)
assert_contains "lock: a stale lock is taken over" '"ok":true' "$OUT"
assert_contains "lock: and the record written" '"ip":"192.168.1.3"' "$(cat "$SHAPES")"
assert_eq "lock: and released" "no" "$([ -e "$ROOT/tmp/trafficctl_shapes.lock.d" ] && echo yes || echo no)"

# ════════════════════════════════════════════════════════════════════════════
# trafficctl restore: every record, quietly
# ════════════════════════════════════════════════════════════════════════════
#
# The ifup lan hook ran its own loop over shapes.json; `trafficctl restore`
# does it now, after the blocks and the limits. A shape is always saved
# (persist_rules is the blocks' and limits' switch), so it always comes back.

st_reset
lt_reset
printf "config trafficctl 'main'\n\toption persist_rules '0'\n\nconfig logging 'logging'\n\toption enabled '1'\n" > "$ROOT/etc/config/trafficctl"
rm -f "$ROOT/tmp/trafficctl/activity.log"
printf '[{"ip":"192.168.1.20","rate_kbit":5000,"classid":"1:7"},{"ip":"192.168.1.21","rate_kbit":8000,"classid":"1:3","rate_kbit_up":800},{"ip":"192.168.1.22","rate_kbit":"abc","classid":"1:4"},{"ip":"192.168.1.23","rate_kbit":0,"classid":"1:5"},{"ip":"","rate_kbit":1000},{"ip":"192.168.1.24","rate_kbit":1000}]' > "$SHAPES"
OUT=$(lt_run restore)
assert_eq "restore: counted with the blocks and limits" '{"ok":false,"restored":3,"failed":1}' "$OUT"
D=$(st_dump)
assert_contains "restore: a record keeps its recorded minor" "class 1:7 1:1 5000kbit" "$D"
assert_contains "restore: an asymmetric record's upload class" "class 1:3 1:1 800kbit" "$D"
assert_contains "restore: a pre-allocation record gets a minor now" '{"ip":"192.168.1.24","rate_kbit":1000,"classid":"1:2"}' "$(cat "$SHAPES")"
assert_contains "restore: a record it cannot apply is in syslog" \
    'Failed to restore shape for 192.168.1.22 (abckbit)' "$(cat "$LOGGER_LOG")"
assert_not_contains "restore: a zero-rate record is skipped, not a failure" '192.168.1.23' "$(cat "$LOGGER_LOG")"
assert_not_contains "restore: nothing goes to the activity log" 'shape' "$(cat "$ROOT/tmp/trafficctl/activity.log" 2>/dev/null)"

# The first save dropped the records the pattern does not match (a rate that
# is no number, an empty address), as every release's save did.
assert_not_contains "restore: the unreadable record is gone from the file" '192.168.1.22' "$(cat "$SHAPES")"

# An ifup without a reboot: the classes are there already and are replaced,
# not stacked or lost.
before=$(st_dump)
OUT=$(lt_run restore)
assert_eq "restore again: the same shapes back" '{"ok":true,"restored":3,"failed":0}' "$OUT"
assert_eq "restore again: the same tc state" "$before" "$(st_dump)"

# A shapes.json that is no JSON array restores nothing, and says so.
st_reset
printf '[{"ip":"192.168.1.20","rate_kbit":5000,' > "$SHAPES"
assert_eq "restore: a corrupt shapes.json" '{"ok":true,"restored":0,"failed":0}' "$(lt_run restore)"
assert_contains "restore: and it is in syslog" "shapes.json is not a JSON array" "$(cat "$LOGGER_LOG")"

# No shapes.json at all is no failure.
st_reset
assert_eq "restore: no shapes.json" '{"ok":true,"restored":0,"failed":0}' "$(lt_run restore)"
assert_eq "restore: and touches no tc" "" "$(grep -v ' show ' "$TC_LOG")"

# The hook leaves the shapes to `trafficctl restore`.
HOOK="$UC_REPO/trafficctl/files/etc/hotplug.d/iface/99-trafficctl-shapes"
assert_eq "hook: no shape loop of its own" "0" "$(grep -c 'trafficctl-shape\.sh\|SHAPES_FILE\|jsonfilter -i "\$SHAPES' "$HOOK")"
assert_contains "hook: runs trafficctl restore" "/usr/sbin/trafficctl restore" "$(cat "$HOOK")"

# ════════════════════════════════════════════════════════════════════════════
# Qualcomm NSS: installed and inert, and said so (#81)
# ════════════════════════════════════════════════════════════════════════════

st_reset
ECM="$ROOT/sys/kernel/debug/ecm"
mkdir -p "$ECM/ecm_db"
: > "$ECM/ecm_db/defunct_all"
OUT=$(st_run add 192.168.1.30 5000)
assert_contains "NSS: the reply carries the status" '"nss":"active"' "$OUT"
assert_contains "NSS: and the verdict" "NOT ENFORCED" "$OUT"
assert_eq "NSS: accelerated flows are defuncted" "1" "$(tr -d '\n' < "$ECM/ecm_db/defunct_all")"
rm -rf "$ROOT/sys/kernel"
OUT=$(st_run add 192.168.1.30 5000)
assert_contains "no NSS: absent" '"nss":"absent"' "$OUT"
assert_not_contains "no NSS: no verdict" "NOT ENFORCED" "$OUT"

# ════════════════════════════════════════════════════════════════════════════

echo
echo "test_shape: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
