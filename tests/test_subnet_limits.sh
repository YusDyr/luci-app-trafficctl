#!/bin/bash
# Aggregate (per-subnet) rate limits — issue #64.
#
# The engine has taken a CIDR target and an each/shared bucket layout since
# v1.13, but three things around it were broken or missing, and all three are
# invisible from the CLI success message:
#
#   1. trafficctl-ratelimit-stats.sh reported the target of every "each"-mode
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

BIN="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/local/bin"
HOTPLUG="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/etc/hotplug.d/iface/99-trafficctl-shapes"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MOCKBIN="$TMP/bin"
mkdir -p "$MOCKBIN"
NFT_LOG="$TMP/nft.log"
RULES="$TMP/rules.json"
SHAPES="$TMP/shapes.json"

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

# fw.sh names its state files by absolute path, as it must on the router; the
# tests rewrite those into the scratch directory rather than adding test-only
# seams to the shipped script.
FW="$TMP/trafficctl-fw.sh"
sed -e "s|TCTL_RULES_FILE=\"/etc/trafficctl/rules.json\"|TCTL_RULES_FILE=\"$RULES\"|" \
    -e "s|TCTL_SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|TCTL_SHAPES_FILE=\"$SHAPES\"|" \
    "$BIN/trafficctl-fw.sh" > "$FW"
assert_not_contains "harness: no production rules path survived the rewrite" \
    "/etc/trafficctl/rules.json" "$(cat "$FW")"

# Every script under test sources fw.sh by absolute path too.
patch_script() {
    sed -e "s|/usr/local/bin/trafficctl-fw.sh|$FW|" "$1" > "$2"
    chmod +x "$2"
}
patch_script "$BIN/trafficctl-ratelimit-stats.sh" "$TMP/ratelimit-stats.sh"
patch_script "$BIN/trafficctl-subnets.sh"         "$TMP/subnets.sh"
patch_script "$BIN/trafficctl-ratelimit.sh"       "$TMP/ratelimit.sh"

run() { PATH="$MOCKBIN:$PATH" sh "$@" 2>/dev/null; }

# ════════════════════════════════════════════════════════════════════════════
# 1. Rate-limit statistics: the target of an "each"-mode rule
# ════════════════════════════════════════════════════════════════════════════
#
# The download rule is installed on EVERY LAN device's egress chain, so one
# subnet limit appears once per bridge. Only the chain on the device the
# subnet lives behind ever matches; the copies are what made "take one entry"
# report zero drops for most targets.
cat > "$TMP/nft_table.txt" <<'TABLE'
table netdev tm_ratelimit {
	chain dl_br_lan {
		type filter hook egress device "br-lan" priority filter; policy accept;
		ip daddr 192.168.20.0/24 meter tctl_d_192_168_20_0_24 { ip daddr limit rate over 2500 kbytes/second } counter packets 12 bytes 3456 drop comment "rl_ratelimit_192_168_20_0_24"
		ip daddr 10.0.0.0/24 limit rate over 1250 kbytes/second counter packets 40 bytes 5000 drop comment "rl_ratelimit_10_0_0_0_24"
		ip daddr 192.168.1.50 limit rate over 625 kbytes/second counter packets 7 bytes 900 drop comment "rl_ratelimit_192_168_1_50"
	}
	chain dl_br_guest {
		type filter hook egress device "br-guest" priority filter; policy accept;
		ip daddr 192.168.20.0/24 meter tctl_d_192_168_20_0_24 { ip daddr limit rate over 2500 kbytes/second } counter packets 8 bytes 1544 drop comment "rl_ratelimit_192_168_20_0_24"
		ip daddr 10.0.0.0/24 limit rate over 1250 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_10_0_0_0_24"
		ip daddr 192.168.1.50 limit rate over 625 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_50"
	}
	chain ul_lan1 {
		type filter hook ingress device "lan1" priority -200; policy accept;
		ip saddr 192.168.20.0/24 meter tctl_u_192_168_20_0_24 { ip saddr limit rate over 2500 kbytes/second } counter packets 3 bytes 300 drop comment "rl_ratelimit_192_168_20_0_24_ul"
	}
}
TABLE

STATS=$(run "$TMP/ratelimit-stats.sh")

assert_contains "stats: an each-mode subnet reports its CIDR as the target" \
    '"ip":"192.168.20.0/24"' "$STATS"
# The exact symptom: the meter key "ip daddr limit ..." overwrote the target.
assert_not_contains "stats: no rule reports the target as 'limit'" \
    '"ip":"limit"' "$STATS"
assert_contains "stats: a per-device subnet limit is labelled each" \
    '"ip":"192.168.20.0/24","mode":"each"' "$STATS"
assert_contains "stats: an aggregate subnet limit is labelled shared" \
    '"ip":"10.0.0.0/24","mode":"shared"' "$STATS"
assert_contains "stats: a single host is labelled shared" \
    '"ip":"192.168.1.50","mode":"shared"' "$STATS"
assert_contains "stats: rate survives the meter form (2500 kbytes = 20000 kbit)" \
    '"192.168.20.0/24","mode":"each","rate_kbit":20000' "$STATS"

# Summed across chains: 12+8 packets, 3456+1544 bytes. Not 12, and not 8.
assert_contains "stats: counters are summed across the per-device chains" \
    '"packets":20,"bytes":5000' "$STATS"
assert_eq "stats: one entry per target, not one per chain" "3" \
    "$(printf '%s' "$STATS" | tr ',' '\n' | grep -c '"ip":')"
# The upload rule matches on saddr and must not become a second entry.
assert_eq "stats: upload rules are not counted as separate targets" "1" \
    "$(printf '%s' "$STATS" | grep -o '192.168.20.0/24' | wc -l | tr -d ' ')"

: > "$TMP/nft_table.txt"
assert_eq "stats: an empty table is an empty array" "[]" "$(run "$TMP/ratelimit-stats.sh")"

# ════════════════════════════════════════════════════════════════════════════
# 2. Which subnets a limit can be enforced on
# ════════════════════════════════════════════════════════════════════════════
rm -f "$TCTL_TEST_GUEST_MASQ"
SUBNETS=$(run "$TMP/subnets.sh")

assert_contains "subnets: a connected LAN is offered, with its device" \
    '{"cidr":"10.10.4.128/25","device":"br-lan","kind":"lan"}' "$SUBNETS"
assert_contains "subnets: a guest VLAN without masq is offered" \
    '{"cidr":"192.168.20.0/24","device":"br-guest","kind":"lan"}' "$SUBNETS"
assert_contains "subnets: a downstream routed subnet is offered too" \
    '{"cidr":"10.0.5.0/24","device":"br-lan","kind":"routed"}' "$SUBNETS"
assert_not_contains "subnets: the wan zone is never offered" '"eth1"' "$SUBNETS"

# The #64 case: masq on a non-lan zone takes it out of tctl_lan_subnets, so no
# netdev hook is ever attached to br-guest and a limit there matches nothing.
# The list must not offer it — the dashboard picker is built from this.
: > "$TCTL_TEST_GUEST_MASQ"
SUBNETS_MASQ=$(run "$TMP/subnets.sh")
assert_not_contains "subnets: a masquerading guest VLAN is NOT offered" \
    '192.168.20.0/24' "$SUBNETS_MASQ"
assert_contains "subnets: the other LANs are unaffected by that exclusion" \
    '10.10.4.128/25' "$SUBNETS_MASQ"
rm -f "$TCTL_TEST_GUEST_MASQ"

# ════════════════════════════════════════════════════════════════════════════
# 3. The bucket layout survives a reboot
# ════════════════════════════════════════════════════════════════════════════
: > "$TCTL_TEST_PERSIST"
printf '[]\n' > "$RULES"

: > "$NFT_LOG"
OUT=$(run "$TMP/ratelimit.sh" 192.168.20.0/24 20000 "iot-cap" each)
assert_contains "ratelimit: an each-mode subnet limit is accepted" '"ok":true' "$OUT"
assert_contains "persist: the mode is stored beside the rate" \
    '"type":"ratelimit","ip":"192.168.20.0/24","param":"20000","mode":"each"' "$(cat "$RULES")"

printf '[]\n' > "$RULES"
run "$TMP/ratelimit.sh" 10.0.0.0/24 20000 "guest-cap" shared >/dev/null
assert_contains "persist: a shared cap is stored as shared" \
    '"ip":"10.0.0.0/24","param":"20000","mode":"shared"' "$(cat "$RULES")"

# A block record has no bucket layout and must keep its exact previous shape,
# or an older restore hook would choke on the extra field.
printf '[]\n' > "$RULES"
PATH="$MOCKBIN:$PATH" sh -c ". '$FW' >/dev/null 2>&1; tctl_persist_save block 192.168.1.9 ''" 2>/dev/null
assert_eq "persist: a block record is unchanged" \
    '[{"type":"block","ip":"192.168.1.9","param":""}]' "$(cat "$RULES")"

# ── the restore path ────────────────────────────────────────────────────────
HOOK="$TMP/99-trafficctl-shapes"
sed -e "s|/usr/local/bin/trafficctl-fw.sh|$FW|" \
    -e "s|RULES_FILE=\"/etc/trafficctl/rules.json\"|RULES_FILE=\"$RULES\"|" \
    -e "s|SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|SHAPES_FILE=\"$SHAPES\"|" \
    -e "s|/etc/trafficctl/cut.state|$TMP/cut.state|" \
    "$HOTPLUG" > "$HOOK"
assert_not_contains "harness: the hook's rules path was redirected" \
    "/etc/trafficctl/rules.json" "$(cat "$HOOK")"

restore() {
    printf '%s\n' "$1" > "$RULES"
    : > "$NFT_LOG"
    PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HOOK" >/dev/null 2>&1
    cat "$NFT_LOG"
}

# "meter" is what makes a bucket per-device, so its presence is the mode.
RESTORED=$(restore '[{"type":"ratelimit","ip":"192.168.20.0/24","param":"20000","mode":"each"}]')
assert_contains "restore: an each-mode subnet limit comes back per-device" \
    "meter tctl_d_192_168_20_0_24" "$RESTORED"

RESTORED=$(restore '[{"type":"ratelimit","ip":"10.0.0.0/24","param":"20000","mode":"shared"}]')
assert_contains "restore: a shared cap comes back" \
    "ip daddr 10.0.0.0/24 limit rate over 2500 kbytes/second" "$RESTORED"
assert_not_contains "restore: a shared cap does NOT come back per-device" \
    "meter" "$RESTORED"

# Records written before the mode was stored must land on the same default the
# CLI would have chosen, not on tctl_ratelimit_add's own "shared" fallback —
# that turned "5 Mbit each" into "5 Mbit for the whole subnet" on reboot.
RESTORED=$(restore '[{"type":"ratelimit","ip":"192.168.20.0/24","param":"20000"}]')
assert_contains "restore: a legacy subnet record defaults to per-device" \
    "meter tctl_d_192_168_20_0_24" "$RESTORED"

RESTORED=$(restore '[{"type":"ratelimit","ip":"192.168.1.50","param":"5000"}]')
assert_contains "restore: a legacy host record still applies" \
    "ip daddr 192.168.1.50 limit rate over 625 kbytes/second" "$RESTORED"
assert_not_contains "restore: a host needs no meter" "meter" "$RESTORED"

# ── the default itself ──────────────────────────────────────────────────────
mode_of() { PATH="$MOCKBIN:$PATH" sh -c ". '$FW' >/dev/null 2>&1; tctl_ratelimit_default_mode '$1'" 2>/dev/null; }
assert_eq "default mode: a subnet is per-device"      "each"   "$(mode_of 192.168.20.0/24)"
assert_eq "default mode: a /32 is a single host"      "shared" "$(mode_of 192.168.1.50/32)"
assert_eq "default mode: a bare address is one host"  "shared" "$(mode_of 192.168.1.50)"
assert_eq "default mode: the whole network is split"  "each"   "$(mode_of 0.0.0.0/0)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
