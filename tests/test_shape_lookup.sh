#!/bin/bash
# Readers of shapes.json must find a device's HTB class by LOOKUP.
#
# Minors are allocated (lowest free, see trafficctl-shape.sh), not derived from
# the address. Two readers had not caught up:
#
#   * trafficctl-summary.sh derived 1:<hex(o3*256+o4)> per device, so the first
#     shaped device's rate (class 1:2) was shown on 192.168.x.2, and the device
#     actually shaped read 0 — the Telegram bot builds its shape flag and its
#     "Shape — Remove" button from that field.
#   * trafficctl-shape-stats.sh only matched records that END at the classid,
#     so every shape with its own upload ceiling (rate_kbit_up) was missing
#     from its output, and with it from tctl_has_limit.

PASS=0
FAIL=0


# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
TMPDIR="$UC_TMP/t"
mkdir -p "$TMPDIR/root/etc/trafficctl"
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"

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
        printf "FAIL: %s\n  expected to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    fi
}

# Under TCTL_ROOT, where every reader and the shaper find it.
SHAPES="$TMPDIR/root/etc/trafficctl/shapes.json"

# .100 symmetric, allocated 1:2 — the minor the old derivation gives 192.168.0.2.
# .101 with its own upload ceiling, allocated 1:3.
# .5   persisted before allocation: no classid, so its class is the derived 1:105.
cat > "$SHAPES" <<'JSON'
[{"ip":"192.168.1.100","rate_kbit":10000,"classid":"1:2"},{"ip":"192.168.1.101","rate_kbit":5000,"classid":"1:3","rate_kbit_up":1000},{"ip":"192.168.1.5","rate_kbit":2000}]
JSON

for c in uci ubus nft; do printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/$c"; done
cat > "$MOCKBIN/tc" <<'MOCK'
#!/bin/sh
case "$*" in
    *qdisc\ show*) echo "qdisc htb 1: root refcnt 2 r2q 10 default 0xfffe" ;;
    *class\ show\ dev\ tctl-ifb0*)
        # Upload classes: .101 has its own ceiling, .100 is symmetric.
        for c in "1:1 rate 1Gbit" "1:2 rate 10Mbit" "1:3 rate 1Mbit"; do
            set -- $c
            echo "class htb $1 parent 1:1 prio 0 rate $3 ceil $3 burst 1600b cburst 1600b"
        done ;;
    *class\ show*)
        # TC_FIRST: a known class listed ahead of the root class.
        [ -n "$TC_FIRST" ] && { echo "class htb 1:2 parent 1:1 prio 0 rate 10Mbit ceil 10Mbit burst 1600b cburst 1600b"; echo " Sent 7 bytes 1 pkt (dropped 0, overlimits 0 requeues 0)"; }
        for c in "1:1 rate 1Gbit" "1:2 rate 10Mbit" "1:3 rate 5Mbit" "1:105 rate 2Mbit" "1:fffe rate 1Gbit"; do
            set -- $c
            [ -n "$TC_FIRST" ] && [ "$1" = 1:2 ] && continue
            echo "class htb $1 parent 1:1 prio 0 rate $3 ceil $3 burst 1600b cburst 1600b"
            echo " Sent 1000 bytes 10 pkt (dropped 0, overlimits 0 requeues 0)"
            echo " backlog 0b 0p requeues 0"
            echo " lended: 10 borrowed: 0 giants: 0"
        done ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN"/*

# ── the readers' lookups (trafficctl.ctl) ───────────────────────────────────
# The summary and the device report look the classid up in this map too
# (tests/test_report.sh pins both, the borrowed-class case included).

uc() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$TMPDIR/root" "$@" 2>&1; }
assert_eq "ucode classmap: every record form" \
    '{"192.168.1.100":"1:2","192.168.1.101":"1:3","192.168.1.5":"1:105"}' "$(uc tcall trafficctl.ctl shape_classmap | jq -c .)"
assert_eq "ucode class rates: LAN, root and default left out" \
    '{"1:2":10000,"1:3":5000,"1:105":2000}' "$(uc tcall trafficctl.ctl tc_class_rates '"br-lan"' | jq -c .)"
assert_eq "ucode class rates: IFB" '{"1:2":10000,"1:3":1000}' "$(uc tcall trafficctl.ctl tc_class_rates '"tctl-ifb0"' | jq -c .)"
assert_eq "ucode: default IFB name" "tctl-ifb0" "$(uc tcall trafficctl.ctl ifb_dev)"

# ── the shaper's own lookups (trafficctl.shape) agree with the readers ──────

assert_eq "shaper: the classid of a symmetric record" "1:2" "$(uc tcall trafficctl.shape lookup_classid '"192.168.1.100"')"
assert_eq "shaper: the classid of a record with rate_kbit_up" "1:3" "$(uc tcall trafficctl.shape lookup_classid '"192.168.1.101"')"
assert_eq "shaper: a pre-allocation record has none recorded" "" "$(uc tcall trafficctl.shape lookup_classid '"192.168.1.5"')"
assert_eq "shaper: its class is the derived one" "1:105" "$(uc tcall trafficctl.shape legacy_classid '"192.168.1.5"')"
assert_eq "shaper: never the root class" "" "$(uc tcall trafficctl.shape legacy_classid '"192.168.0.1"')"
assert_eq "shaper: never the default class" "" "$(uc tcall trafficctl.shape legacy_classid '"10.0.255.254"')"
assert_eq "shaper: the next minor skips those in the file and on both devices" "1:4" "$(uc tcall trafficctl.shape alloc_classid)"
assert_eq "shaper: default IFB name" "tctl-ifb0" "$(uc tcall trafficctl.shape ifb_dev)"

# ── shape-stats: every record form is reported ───────────────────────────────

STATS=$(uc tctl shape-stats)
assert_contains "stats: symmetric shape reported" '"ip":"192.168.1.100"' "$STATS"
assert_contains "stats: shape with its own upload ceiling reported" '"ip":"192.168.1.101"' "$STATS"
assert_contains "stats: pre-allocation shape reported" '"ip":"192.168.1.5"' "$STATS"
assert_contains "stats: counters of the class" '"ip":"192.168.1.101","rate_kbit":5000,"bytes":1000,"packets":10,"backlog":0,"drops":0,"overlimits":0,"requeues":0,"lended":10,"borrowed":0' "$STATS"
assert_eq "stats: one record per shape" "3" "$(printf '%s' "$STATS" | jq length)"
# v1.30.0 did not close a record at the root class, so a class listed before
# 1:1 came out twice.
STATS=$(TC_FIRST=1 uc tctl shape-stats)
assert_eq "stats: a class before the root class is reported once" "1" "$(printf '%s' "$STATS" | jq '[.[] | select(.ip == "192.168.1.100")] | length')"
assert_contains "stats: with its own counters" '"ip":"192.168.1.100","rate_kbit":10000,"bytes":7,"packets":1' "$STATS"
mv "$SHAPES" "$SHAPES.off"
assert_eq "stats: no shapes.json, nothing known" "[]" "$(uc tctl shape-stats)"
mv "$SHAPES.off" "$SHAPES"
mkdir -p "$TMPDIR/nohtb"
printf '#!/bin/sh\necho "qdisc fq_codel 0: root refcnt 2"\n' > "$TMPDIR/nohtb/tc"
chmod +x "$TMPDIR/nohtb/tc"
assert_eq "stats: no HTB root, no shapes" "[]" "$(PATH="$TMPDIR/nohtb:$MOCKBIN:$PATH" TCTL_ROOT="$TMPDIR/root" tctl shape-stats 2>&1)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
