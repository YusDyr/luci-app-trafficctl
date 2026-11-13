#!/bin/bash
# Aggregate (per-subnet) rate limits — issue #64.
#
# The engine has taken a CIDR target and an each/shared bucket layout since
# v1.13, but three things around it were broken or missing, and all three are
# invisible from the CLI success message:
#
#   1. trafficctl-ratelimit-stats.sh (now `trafficctl ratelimit-stats`) reported the target of every "each"-mode
#      rule as the literal string "limit" (the meter key is a bare "ip daddr"
#      with no operand and the parser took the LAST match). "each" is the
#      default for a CIDR, so every per-device subnet limit was invisible to
#      the dashboard and to tctl_has_limit.
#   2. The mode was not persisted, so "5 Mbit each" came back from a reboot as
#      "5 Mbit for the whole subnet" — the one mistake this feature exists to
#      prevent, applied silently.
#   3. Nothing told the dashboard which subnets can actually be policed. A
#      masquerading non-lan zone (a guest VLAN, typically) is not monitored,
#      its device gets no netdev hook, and a limit on it matches nothing.

PASS=0
FAIL=0

HOTPLUG="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/etc/hotplug.d/iface/99-trafficctl-shapes"

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
TMP="$UC_TMP/t"
mkdir -p "$TMP/root"
MOCKBIN="$TMP/bin"
mkdir -p "$MOCKBIN"
NFT_LOG="$TMP/nft.log"
# rules.json under the TCTL_ROOT the CLI runs with (a symlink would not do:
# the writer renames a new file over it).
RULES="$TMP/root/etc/trafficctl/rules.json"
mkdir -p "$TMP/root/etc/trafficctl" "$TMP/root/etc/config" "$TMP/root/tmp"

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

# ── shared mocks ────────────────────────────────────────────────────────────
# Three zones: lan, a masquerading guest VLAN, and wan. The guest zone is the
# case from #64 — masq is how a guest VLAN is usually isolated, and it is also
# what takes the zone out of tctl_lan_subnets.
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    network.wan.device) echo "eth1" ;;
    network.lan.device) echo "br-lan" ;;
    # Quoted: [0] is a glob character class otherwise, so these would never
    # match the literal uci key.
    "firewall.@zone[0].name")    echo "lan" ;;
    "firewall.@zone[0].network") echo "lan" ;;
    "firewall.@zone[1].name")    echo "guest" ;;
    "firewall.@zone[1].network") echo "guest" ;;
    "firewall.@zone[1].masq")    [ -f "$TCTL_TEST_GUEST_MASQ" ] && echo "1" || exit 1 ;;
    "firewall.@zone[2].name")    echo "wan" ;;
    "firewall.@zone[2].network") echo "wan" ;;
    trafficctl.main.persist_rules) [ -f "$TCTL_TEST_PERSIST" ] && echo "1" || exit 1 ;;
    *) exit 1 ;;
esac
MOCK

cat > "$MOCKBIN/ubus" <<'MOCK'
#!/bin/sh
case "$2" in
    network.interface.wan)   echo '{"l3_device":"eth1"}' ;;
    network.interface.guest) echo '{"l3_device":"br-guest","ipv4-address":[{"address":"192.168.20.1","mask":24}]}' ;;
    # A /25 rather than another /24: the CIDR is rebuilt from a packed integer
    # and a block size, so a non-octet boundary is the case that catches a
    # wrong mask.
    *) echo '{"l3_device":"br-lan","ipv4-address":[{"address":"10.10.4.130","mask":25}]}' ;;
esac
MOCK

# Parses stdin (or -i FILE) rather than hardcoding answers, so both the ubus
# status objects and the persisted rules file go through the same mock.
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
file=""
expr=""
while [ $# -gt 0 ]; do
    case "$1" in
        -i) file="$2"; shift 2 ;;
        -e) expr="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
if [ -n "$file" ]; then
    [ -f "$file" ] || exit 1
    input=$(cat "$file")
else
    input=$(cat)
fi
case "$expr" in
    '@.l3_device') echo "$input" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].address') echo "$input" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].mask') echo "$input" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p' ;;
    '@[*]') echo "$input" | awk '{ n = split($0, a, "},{"); for (i = 1; i <= n; i++) print i }' ;;
    '@['*'].'*)
        idx=$(echo "$expr" | sed -n 's/^@\[\([0-9]*\)\]\..*/\1/p')
        key=$(echo "$expr" | sed -n 's/^@\[[0-9]*\]\.\(.*\)$/\1/p')
        printf '%s' "$input" | awk -v n="$idx" -v k="$key" '
        {
            gsub(/^\[/, ""); gsub(/\]$/, "")
            m = split($0, a, "},{")
            if (n + 1 > m) exit
            s = a[n + 1]
            if (match(s, "\"" k "\":\"[^\"]*\"")) {
                t = substr(s, RSTART, RLENGTH)
                sub("\"" k "\":\"", "", t)
                sub("\"$", "", t)
                print t
            }
        }'
        ;;
esac
MOCK

cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    "route show") echo "10.0.5.0/24 via 10.10.4.200 dev br-lan" ;;
esac
exit 0
MOCK

cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
echo "\$*" >> "$NFT_LOG"
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    "list table netdev tm_ratelimit") cat "$TMP/nft_table.txt" 2>/dev/null ;;
    "-j list table netdev tm_ratelimit") cat "$TMP/nft_table.json" 2>/dev/null ;;
    # fw4_late holds how many more probes fail before fw4 has its table.
    "list table inet fw4")
        n=\$(cat "$TMP/fw4_late" 2>/dev/null || echo 0)
        [ "\$n" -gt 0 ] && { echo \$((n - 1)) > "$TMP/fw4_late"; exit 1; }
        ;;
esac
exit 0
MOCK

cat > "$MOCKBIN/tc" <<'MOCK'
#!/bin/sh
exit 0
MOCK

cat > "$MOCKBIN/logger" <<'MOCK'
#!/bin/sh
exit 0
MOCK

chmod +x "$MOCKBIN"/*

export TCTL_TEST_GUEST_MASQ="$TMP/guest_masq"
export TCTL_TEST_PERSIST="$TMP/persist_on"

# Bridges, so the ingress hooks resolve the same way they do on a router.
mkdir -p "$TMP/sys/class/net/br-lan/brif/lan1" "$TMP/sys/class/net/br-guest/brif/lan4"
export TCTL_SYSFS_NET="$TMP/sys/class/net"

# The same router for the ucode CLI: lan (br-lan, 10.10.4.128/25), a guest
# VLAN (br-guest, 192.168.20.0/24) and wan, as the uci and ubus fakes above.
printf "config trafficctl 'main'\n\toption persist_rules '1'\n" > "$TMP/root/etc/config/trafficctl"
printf "config interface 'lan'\n\toption device 'br-lan'\n\nconfig interface 'guest'\n\toption device 'br-guest'\n\nconfig interface 'wan'\n\toption device 'eth1'\n" \
    > "$TMP/root/etc/config/network"
printf "config zone\n\toption name 'lan'\n\tlist network 'lan'\n\nconfig zone\n\toption name 'guest'\n\tlist network 'guest'\n\nconfig zone\n\toption name 'wan'\n\tlist network 'wan'\n\toption masq '1'\n" \
    > "$TMP/root/etc/config/firewall"
mkdir -p "$TMP/ubus" "$TMP/sys/class/net/eth1" "$TMP/sys/class/net/lan1" "$TMP/sys/class/net/lan4"
ln -s "$TMP/sys" "$TMP/root/sys"
printf '{"interface":[{"interface":"lan","up":true,"l3_device":"br-lan","ipv4-address":[{"address":"10.10.4.130","mask":25}]},{"interface":"guest","up":true,"l3_device":"br-guest","ipv4-address":[{"address":"192.168.20.1","mask":24}]},{"interface":"wan","up":true,"l3_device":"eth1"}]}\n' \
    > "$TMP/ubus/network.interface@dump.json"
printf '{"up":true,"l3_device":"eth1"}\n' > "$TMP/ubus/network.interface.wan@status.json"
ubus_start "$TMP/ubus"

rl() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$TMP/root" tctl ratelimit "$@" 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
# 1. Rate-limit statistics: the target of an "each"-mode rule
# ════════════════════════════════════════════════════════════════════════════
#
# The download rule is installed on EVERY LAN device's egress chain, so one
# subnet limit appears once per bridge. Only the chain on the device the
# subnet lives behind ever matches; the copies are what made "take one entry"
# report zero drops for most targets.
# The table is tests/fixtures/nft-src/subnet.nft, as `nft -j` of OpenWrt
# 22.03 (nft 1.0.2) and 25.12 (1.1.6) lists it.
stats() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$TMP/root" tctl ratelimit-stats 2>/dev/null; }
for v in 1.0.2 1.1.6; do
    cp "$UC_REPO/tests/fixtures/nft-$v/subnet.tm_ratelimit.json" "$TMP/nft_table.json"
    STATS=$(stats)

    assert_contains "stats $v: an each-mode subnet reports its CIDR as the target" \
        '"ip":"192.168.20.0/24"' "$STATS"
    # The exact symptom: the meter key "ip daddr limit ..." overwrote the target.
    assert_not_contains "stats $v: no rule reports the target as 'limit'" \
        '"ip":"limit"' "$STATS"
    assert_contains "stats $v: a per-device subnet limit is labelled each" \
        '"ip":"192.168.20.0/24","mode":"each"' "$STATS"
    assert_contains "stats $v: an aggregate subnet limit is labelled shared" \
        '"ip":"10.0.0.0/24","mode":"shared"' "$STATS"
    assert_contains "stats $v: a single host is labelled shared" \
        '"ip":"192.168.1.50","mode":"shared"' "$STATS"
    assert_contains "stats $v: rate survives the meter form (2500000 bytes = 20000 kbit)" \
        '"192.168.20.0/24","mode":"each","rate_kbit":20000' "$STATS"

    # Summed across chains: 12+8 packets, 3456+1544 bytes. Not 12, and not 8.
    assert_contains "stats $v: counters are summed across the per-device chains" \
        '"packets":20,"bytes":5000' "$STATS"
    # The whole network (target "all"): per-device, 1250000 bytes = 10000
    # kbit, 30+2 packets and 4000+600 bytes over the two bridges.
    assert_contains "stats $v: the whole network is one each-mode target" \
        '"ip":"0.0.0.0/0","mode":"each","rate_kbit":10000,"packets":32,"bytes":4600' "$STATS"
    assert_eq "stats $v: the whole network's upload rule is no target of its own" "1" \
        "$(printf '%s' "$STATS" | grep -o '0.0.0.0/0' | wc -l | tr -d ' ')"
    assert_eq "stats $v: one entry per target, not one per chain" "4" \
        "$(printf '%s' "$STATS" | tr ',' '\n' | grep -c '"ip":')"
    # The upload rule matches on saddr and must not become a second entry.
    assert_eq "stats $v: upload rules are not counted as separate targets" "1" \
        "$(printf '%s' "$STATS" | grep -o '192.168.20.0/24' | wc -l | tr -d ' ')"
done

printf '{"nftables": [{"metainfo": {"version": "1.0.2", "release_name": "Lester Gooch", "json_schema_version": 1}}, {"table": {"family": "netdev", "name": "tm_ratelimit", "handle": 9}}]}\n' > "$TMP/nft_table.json"
assert_eq "stats: an empty table is an empty array" "[]" "$(stats)"
rm -f "$TMP/nft_table.json"
assert_eq "stats: no table is an empty array" "[]" "$(stats)"

# Which subnets a limit can be enforced on (`trafficctl subnets`, now ucode):
# tests/test_ucode_lib.sh.

# ════════════════════════════════════════════════════════════════════════════
# 3. The bucket layout survives a reboot
# ════════════════════════════════════════════════════════════════════════════
: > "$TCTL_TEST_PERSIST"
printf '[]\n' > "$RULES"

: > "$NFT_LOG"
OUT=$(rl 192.168.20.0/24 20000 "iot-cap" each)
assert_contains "ratelimit: an each-mode subnet limit is accepted" '"ok":true' "$OUT"
assert_contains "persist: the mode is stored beside the rate" \
    '"type":"ratelimit","ip":"192.168.20.0/24","param":"20000","mode":"each"' "$(cat "$RULES")"

printf '[]\n' > "$RULES"
rl 10.0.0.0/24 20000 "guest-cap" shared >/dev/null
assert_contains "persist: a shared cap is stored as shared" \
    '"ip":"10.0.0.0/24","param":"20000","mode":"shared"' "$(cat "$RULES")"

# A block record has no bucket layout and must keep its exact previous shape,
# or an older restore hook would choke on the extra field.
printf '[]\n' > "$RULES"
PATH="$MOCKBIN:$PATH" TCTL_ROOT="$TMP/root" tcall trafficctl.lib persist_save '"block"' '"192.168.1.9"' '""' >/dev/null 2>&1
assert_eq "persist: a block record is unchanged" \
    '[{"type":"block","ip":"192.168.1.9","param":""}]' "$(cat "$RULES")"

# ── the restore path ────────────────────────────────────────────────────────
HOOK="$TMP/99-trafficctl-shapes"
sed -e "s|/usr/sbin/trafficctl|$TMP/tctl-cli|" "$HOTPLUG" > "$HOOK"
# The hook runs `trafficctl restore`, here on the same fake nft and the same
# rules.json.
printf '#!/bin/sh\nTCTL_ROOT="%s" exec "%s" -S -L "%s" -- "%s" "$@"\n' "$TMP/root" "$UCODE" "$UC_LIB" \
    "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" > "$TMP/tctl-cli"
chmod +x "$TMP/tctl-cli"
assert_contains "harness: the hook runs the CLI under test" "$TMP/tctl-cli restore" "$(cat "$HOOK")"

# What ends the restore loop is a sentinel, not a counted range (#108), so a
# broken sentinel is an infinite loop and a skipped increment is an infinite
# loop. Both have to fail here rather than hang the suite, and CI, for hours.
#
# Bounded by killing the hook, not by starving it of input: a shim that stops
# answering jsonfilter cannot stop a loop whose exit condition has been
# deleted — it just spins on empty answers. Only a deadline works for that.
# The deadline is generous because it only ever fires on a broken loop: the
# 101-record fixture below takes about ten seconds of mocked forks as it is.
HOOK_DEADLINE=60

restore() {
    printf '%s\n' "$1" > "$RULES"
    : > "$NFT_LOG"
    PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HOOK" >/dev/null 2>&1 &
    _hpid=$!
    # stdout must be redirected or command substitution around restore() waits
    # for this subshell's inherited stdout to close, i.e. for the full sleep.
    ( sleep "$HOOK_DEADLINE"; kill -9 "$_hpid" 2>/dev/null ) >/dev/null 2>&1 &
    _wpid=$!
    wait "$_hpid"
    printf '%s' "$?" > "$TMP/hookrc"
    kill "$_wpid" 2>/dev/null
    cat "$NFT_LOG"
}

# A killed hook exits non-zero, so this distinguishes "ended on its own" from
# "was still going when the deadline hit" — otherwise a runaway reads as a
# pass, because the nft log it leaves behind still contains earlier rules.
assert_terminated() {
    _rc=$(cat "$TMP/hookrc" 2>/dev/null)
    if [ "$_rc" = "0" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s — the hook did not end on its own (exit %s, deadline %ss)\n" \
            "$1" "$_rc" "$HOOK_DEADLINE"
        # Stop here. A restore loop that does not terminate makes every later
        # restore in this file hit the deadline too, which turns one real
        # failure into ten minutes of waiting, and there is nothing further to
        # learn from a hook that never finishes.
        printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
        exit 1
    fi
}

# "meter" is what makes a bucket per-device, so its presence is the mode.
RESTORED=$(restore '[{"type":"ratelimit","ip":"192.168.20.0/24","param":"20000","mode":"each"}]')
assert_terminated "restore: the loop ended on its own"
assert_contains "restore: an each-mode subnet limit comes back per-device" \
    "meter tctl_m_192_168_20_0_24_dl_" "$RESTORED"

RESTORED=$(restore '[{"type":"ratelimit","ip":"10.0.0.0/24","param":"20000","mode":"shared"}]')
assert_terminated "restore: the loop ended on its own"
assert_contains "restore: a shared cap comes back" \
    "ip daddr 10.0.0.0/24 limit rate over 2500000 bytes/second" "$RESTORED"
assert_not_contains "restore: a shared cap does NOT come back per-device" \
    "meter" "$RESTORED"

# Records written before the mode was stored must land on the same default the
# CLI would have chosen, not on the limiter's own "shared" fallback —
# that turned "5 Mbit each" into "5 Mbit for the whole subnet" on reboot.
RESTORED=$(restore '[{"type":"ratelimit","ip":"192.168.20.0/24","param":"20000"}]')
assert_terminated "restore: the loop ended on its own"
assert_contains "restore: a legacy subnet record defaults to per-device" \
    "meter tctl_m_192_168_20_0_24_dl_" "$RESTORED"

RESTORED=$(restore '[{"type":"ratelimit","ip":"192.168.1.50","param":"5000"}]')
assert_terminated "restore: the loop ended on its own"
assert_contains "restore: a legacy host record still applies" \
    "ip daddr 192.168.1.50 limit rate over 625000 bytes/second" "$RESTORED"
assert_not_contains "restore: a host needs no meter" "meter" "$RESTORED"

# At boot ifup lan can come before fw4 has loaded its ruleset. A block restored
# then went nowhere, so `trafficctl restore` waits for inet fw4 first.
echo 2 > "$TMP/fw4_late"
RESTORED=$(restore '[{"type":"block","ip":"192.168.1.60","param":""}]')
assert_terminated "restore: the loop ended on its own"
assert_eq "restore: the hook waits for inet fw4 before restoring a block" \
    "list table inet fw4|list table inet fw4|list table inet fw4|insert rule inet fw4 forward" \
    "$(printf '%s\n' "$RESTORED" | grep -E '^(list table inet fw4|insert rule inet fw4 forward)' \
        | sed 's/^\(insert rule inet fw4 forward\).*/\1/' | head -4 | paste -sd'|' -)"
rm -f "$TMP/fw4_late"

# ── the restore loop's bounds (#108) ───────────────────────────────────────
# The loop used to be `for idx in $(seq 0 99)`, so rule 101 onward was never
# read: the records sat in rules.json, the UI showed them as persisted, and
# they were simply absent from the kernel after a reboot. A silent, selective
# failure — the first hundred come back and the rest do not — which is the
# hardest kind to notice. Pinned at the boundary and well past it, because
# raising 99 to a bigger number would satisfy a single-point check while
# leaving the cliff in place.
many() {
    python3 - "$1" <<'PY2'
import json, sys
n = int(sys.argv[1])
print(json.dumps([{"type": "block", "ip": "10.9.%d.%d" % (i // 250 + 1, i % 250 + 1),
                   "param": ""} for i in range(n)], separators=(',', ':')))
PY2
}

# 101 records and not also 100: with the old `seq 0 99` a hundred records
# restore perfectly well, so a 100-record case pins the behaviour that was
# never broken. 101 is the first one that was. Larger fixtures were dropped
# again — a healthy 300-record restore costs 32 seconds of mocked forks, and
# what they were guarding against (a cliff at some other constant) is pinned
# structurally below, which is the stronger pin anyway.
RESTORED=$(restore "$(many 101)")
assert_terminated "restore: the loop ended on its own"
assert_contains "restore: the hundred-and-first rule comes back" \
    "10.9.1.101" "$RESTORED"
assert_terminated "restore: a hundred-and-one records end the loop on their own"

# A fixture cannot prove the absence of a bound. Up to 1.30.x the port-forward
# records were read by a shell loop in the hook (`while :; do`, ended by the
# absent-record sentinel); `trafficctl restore` walks the parsed array, so
# there is no index or bound left to pin.
# A record with no address is skipped, and the next one still restored: the
# shell loop spun forever on it when its increment came after the `continue`.
RESTORED=$(restore '[{"type":"block"},{"type":"block","ip":"192.168.1.77","param":""}]')
assert_terminated "restore: a record with no ip must not spin the loop"
assert_contains "restore: a record after a malformed one is still restored" \
    "192.168.1.77" "$RESTORED"



# 4. The shaper declining under SQM says so: `trafficctl shape` since the
# ucode port, tests/test_shape.sh.

# ── the default itself ──────────────────────────────────────────────────────
mode_of() { tcall trafficctl.limit default_mode "\"$1\"" 2>/dev/null; }
assert_eq "default mode: a subnet is per-device"      "each"   "$(mode_of 192.168.20.0/24)"
assert_eq "default mode: a /32 is a single host"      "shared" "$(mode_of 192.168.1.50/32)"
assert_eq "default mode: a bare address is one host"  "shared" "$(mode_of 192.168.1.50)"
assert_eq "default mode: the whole network is split"  "each"   "$(mode_of 0.0.0.0/0)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
