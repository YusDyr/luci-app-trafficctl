#!/bin/bash
# IPv6 enforcement tests (issue #67).
#
# Every enforcement path in this package matched "ip saddr"/"ip daddr", so a
# dual-stack client obeyed its 10 Mbit/s cap over IPv4 and ran at 151 Mbit/s
# over IPv6 to the same endpoint — and a "blocked" device kept full, unmetered
# v6 access while the UI read blocked.
#
# What is covered here: the MAC lookups the limiter shares with the block, the
# UPLOAD direction of the rate limiter (MAC-keyed) and its DOWNLOAD direction
# (an address set the client's own upload packets feed). Byte accounting over
# IPv6 is deliberately still open. The internet block (both families,
# MAC-keyed) is tests/test_ipv6_block.sh.
#
# The nft mock keeps real state for BOTH rule forms — the address-keyed v4 rule
# and the MAC-keyed v6 one — with stable handles, because the interesting
# assertions are about which of several coexisting rules a removal picks.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"

# The limiter is `trafficctl ratelimit` (ucode, run with TCTL_ROOT=$ROOT); the
# MAC helpers it shares with the shell readers are still fw.sh's.
# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
TMPDIR="$UC_TMP/ipv6"
ROOT="$TMPDIR/root"
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

# ── scratch state the mocks read and write ───────────────────────────────────

export LEASES="$TMPDIR/dhcp.leases"
export NEIGH4="$TMPDIR/neigh4"
export NEIGH6="$TMPDIR/neigh6"
export ROUTES="$TMPDIR/routes"
export FW4_STATE="$TMPDIR/fw4.state"
export FW4_HANDLE="$TMPDIR/fw4.handle"
export RL_DUMP="$TMPDIR/rl.dump"
export NFT_LOG="$TMPDIR/nft.log"
export CT_LOG="$TMPDIR/conntrack.log"
: > "$LEASES"; : > "$NEIGH4"; : > "$NEIGH6"; : > "$ROUTES"
: > "$FW4_STATE"; : > "$RL_DUMP"; : > "$NFT_LOG"; : > "$CT_LOG"
echo 0 > "$FW4_HANDLE"

# fw.sh names /tmp/dhcp.leases by absolute path, as it must on the router. The
# tests rewrite that line into the scratch directory rather than have the
# shipped script carry a test-only override (test_newdevice.sh's approach, and
# it asserts that no production path survives the rewrite).
FW="$TMPDIR/fw.sh"
sed -e "s|TCTL_LEASES_FILE=\"/tmp/dhcp.leases\"|TCTL_LEASES_FILE=\"$LEASES\"|" \
    "$BIN/trafficctl-fw.sh" > "$FW"
assert_contains "harness: the lease path was redirected into the scratch dir" \
    "$LEASES" "$(cat "$FW")"
assert_eq "harness: no production lease path survived the rewrite" "" \
    "$(grep -n '/tmp/dhcp.leases' "$FW")"

# The scratch root of the ucode limiter: the same LAN as the shell mocks
# below, br-lan bridging lan1, eth1 the WAN.
mkdir -p "$ROOT/etc/config" "$ROOT/etc/trafficctl" "$ROOT/tmp" "$TMPDIR/ubus"
ln -s "$LEASES" "$ROOT/tmp/dhcp.leases"
printf "config trafficctl 'main'\n\toption persist_rules '0'\n\nconfig logging 'logging'\n\toption enabled '0'\n" \
    > "$ROOT/etc/config/trafficctl"
printf "config interface 'lan'\n\toption device 'br-lan'\n\nconfig interface 'wan'\n\toption device 'eth1'\n" \
    > "$ROOT/etc/config/network"
printf "config zone\n\toption name 'lan'\n\tlist network 'lan'\n\nconfig zone\n\toption name 'wan'\n\tlist network 'wan'\n\toption masq '1'\n" \
    > "$ROOT/etc/config/firewall"
printf '{"interface":[{"interface":"lan","up":true,"l3_device":"br-lan","ipv4-address":[{"address":"192.168.1.1","mask":24}]},{"interface":"wan","up":true,"l3_device":"eth1"}]}\n' \
    > "$TMPDIR/ubus/network.interface@dump.json"
printf '{"up":true,"l3_device":"eth1"}\n' > "$TMPDIR/ubus/network.interface.wan@status.json"
ubus_start "$TMPDIR/ubus"

# ── mocks ────────────────────────────────────────────────────────────────────

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    network.lan.device) echo "br-lan" ;;
    network.wan.device) echo "eth1" ;;
    "firewall.@zone[0].name") echo "lan" ;;
    "firewall.@zone[0].network") echo "lan" ;;
    *) exit 1 ;;
esac
MOCK

cat > "$MOCKBIN/ubus" <<'MOCK'
#!/bin/sh
case "$2" in
    network.interface.wan) echo '{"l3_device":"eth1"}' ;;
    *) echo '{"l3_device":"br-lan","ipv4-address":[{"address":"192.168.1.1","mask":24}]}' ;;
esac
MOCK

cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
input=$(cat)
case "$2" in
    '@.l3_device') echo "$input" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].address') echo "$input" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].mask') echo "$input" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p' ;;
esac
MOCK

cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    -4\ addr\ show*)  echo "inet 192.168.1.1/24" ;;
    -6\ neigh\ show*) cat "$NEIGH6" ;;
    neigh\ show*)     cat "$NEIGH4" ;;
    route\ show*)     cat "$ROUTES" ;;
    *) exit 1 ;;
esac
MOCK

cat > "$MOCKBIN/conntrack" <<'MOCK'
#!/bin/sh
echo "$*" >> "$CT_LOG"
exit 0
MOCK

# nft mock with real state for both rule forms.
#
# Handles are allocated from a counter and stay stable across deletions, the
# way the kernel's do. A mock that renumbered on delete would hide the bug
# where a removal collects several handles and then invalidates them one by
# one as it goes.
cat > "$MOCKBIN/nft" <<'MOCK'
#!/bin/sh
echo "$*" >> "$NFT_LOG"
arg="$*"
tab=$(printf '\t')
case "$arg" in
    "list tables") echo "table inet fw4"; exit 0 ;;
    insert\ rule\ inet\ fw4\ forward*)
        cmt=$(printf '%s' "$arg" | sed -n 's/.*comment "\([^"]*\)".*/\1/p')
        h=$(cat "$FW4_HANDLE"); h=$((h + 1)); echo "$h" > "$FW4_HANDLE"
        if printf '%s' "$arg" | grep -q 'ether saddr'; then
            val=$(printf '%s' "$arg" | sed -n 's/.*ether saddr \([0-9a-f:]*\).*/\1/p')
            printf '%s\tmac\t%s\t%s\n' "$h" "$cmt" "$val" >> "$FW4_STATE"
        else
            val=$(printf '%s' "$arg" | sed -n 's/.*ip saddr \([0-9.]*\).*/\1/p')
            printf '%s\tv4\t%s\t%s\n' "$h" "$cmt" "$val" >> "$FW4_STATE"
        fi
        ;;
    -a\ list\ chain\ inet\ fw4\ forward|list\ chain\ inet\ fw4\ forward)
        showh=0
        case "$arg" in -a*) showh=1 ;; esac
        while IFS="$tab" read -r h form cmt val; do
            [ -n "$h" ] || continue
            if [ "$form" = "mac" ]; then
                line="		meta nfproto ipv6 ether saddr $val counter packets 3 bytes 300 drop comment \"$cmt\""
            else
                line="		ip saddr $val counter packets 1 bytes 100 drop comment \"$cmt\""
            fi
            if [ "$showh" = "1" ]; then
                printf '%s # handle %s\n' "$line" "$h"
            else
                printf '%s\n' "$line"
            fi
        done < "$FW4_STATE"
        ;;
    delete\ rule\ inet\ fw4\ forward\ handle\ *)
        h=${arg##* }
        awk -F"$tab" -v h="$h" '$1 != h' "$FW4_STATE" > "$FW4_STATE.new"
        mv "$FW4_STATE.new" "$FW4_STATE"
        ;;
    -a\ list\ table\ netdev\ tm_ratelimit) cat "$RL_DUMP" ;;
    add\ set\ netdev\ tm_ratelimit*) [ -z "$NFT_FAIL_SET" ] || exit 1 ;;
esac
exit 0
MOCK

chmod +x "$MOCKBIN"/*

# br-lan is a bridge with one port: ingress hooks land on the PORT, egress on
# the bridge itself (see tctl_ingress_devices).
mkdir -p "$TMPDIR/sys/class/net/br-lan/brif/lan1" "$TMPDIR/sys/class/net/eth1" \
         "$TMPDIR/sys/class/net/lan1"
export TCTL_SYSFS_NET="$TMPDIR/sys/class/net"
ln -s "$TMPDIR/sys" "$ROOT/sys"

fw() { PATH="$MOCKBIN:$PATH" sh -c ". $FW >/dev/null 2>&1; $1" 2>&1; }
run_ratelimit() { : > "$NFT_LOG"; PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tctl ratelimit "$@" 2>&1; }

# The fixture LAN:
#   .50  dual-stack laptop      — lease, ARP entry, three v6 addresses
#   .60  IPv4-only printer      — lease and ARP entry, no v6 at all
#   .70  routed downstream host — neither lease nor ARP entry
#   .80  downstream ROUTER      — lease, but it is the next hop for 10.0.5.0/24
printf 'x AA:BB:CC:DD:EE:50 192.168.1.50 laptop *\n' >> "$LEASES"
printf 'x aa:bb:cc:dd:ee:60 192.168.1.60 printer *\n' >> "$LEASES"
printf 'x aa:bb:cc:dd:ee:80 192.168.1.80 downstream *\n' >> "$LEASES"
printf '192.168.1.50 dev br-lan lladdr aa:bb:cc:dd:ee:50 REACHABLE\n' >> "$NEIGH4"
printf '192.168.1.60 dev br-lan lladdr aa:bb:cc:dd:ee:60 STALE\n' >> "$NEIGH4"
printf '192.168.1.90 dev br-lan lladdr aa:bb:cc:dd:ee:90 REACHABLE\n' >> "$NEIGH4"
# The laptop holds a stable SLAAC address, a privacy-extension temporary that
# will rotate, and a link-local — which is exactly why rules are not written
# against any of them.
printf '2001:db8::50 dev br-lan lladdr aa:bb:cc:dd:ee:50 REACHABLE\n' >> "$NEIGH6"
printf '2001:db8::dead:beef dev br-lan lladdr AA:BB:CC:DD:EE:50 STALE\n' >> "$NEIGH6"
printf 'fe80::50 dev br-lan lladdr aa:bb:cc:dd:ee:50 REACHABLE\n' >> "$NEIGH6"
printf '2001:db8::99 dev br-lan lladdr aa:bb:cc:dd:ee:99 REACHABLE\n' >> "$NEIGH6"
printf '10.0.5.0/24 via 192.168.1.80 dev br-lan\n' >> "$ROUTES"
printf 'default via 10.1.1.1 dev eth1\n' >> "$ROUTES"

# ── MAC resolution ───────────────────────────────────────────────────────────

assert_eq "mac: resolved from the DHCP lease, lowercased" \
    "aa:bb:cc:dd:ee:50" "$(fw 'tctl_lookup_mac 192.168.1.50')"

assert_eq "mac: falls back to the neighbour table with no lease" \
    "aa:bb:cc:dd:ee:90" "$(fw 'tctl_lookup_mac 192.168.1.90')"

# A routed/downstream client has neither. Silently doing nothing there is the
# failure this issue is about, so the lookup must FAIL rather than return junk.
assert_eq "mac: unknown device yields nothing and fails" \
    "NOMAC" "$(fw 'tctl_lookup_mac 192.168.1.70 || echo NOMAC')"

# The MAC is interpolated into an nft rule string, so it is validated as six
# hex pairs rather than merely trimmed.
printf 'x aa:bb:cc;nft flush ruleset;:ee 192.168.1.66 evil *\n' >> "$LEASES"
assert_eq "mac: a malformed lease field is refused, not interpolated" \
    "NOMAC" "$(fw 'tctl_lookup_mac 192.168.1.66 || echo NOMAC')"

# ── which targets may be keyed on a MAC ──────────────────────────────────────

assert_eq "target: a plain host qualifies" \
    "aa:bb:cc:dd:ee:50" "$(fw 'tctl_target_mac 192.168.1.50')"
assert_eq "target: /32 is the same single host" \
    "aa:bb:cc:dd:ee:50" "$(fw 'tctl_target_mac 192.168.1.50/32')"
assert_eq "target: a CIDR block has no single MAC" \
    "NONE" "$(fw 'tctl_target_mac 192.168.1.0/24 || echo NONE')"
assert_eq "target: \"all\" has no single MAC" \
    "NONE" "$(fw 'tctl_target_mac 0.0.0.0/0 || echo NONE')"

# The big over-block hazard: a next hop's MAC is the source address of every
# packet it FORWARDS, so keying a rule on it takes out the whole subnet behind
# it. Excluded, and the caller is made to say why.
assert_eq "target: a routed next hop is excluded" \
    "NONE" "$(fw 'tctl_target_mac 192.168.1.80 || echo NONE')"
assert_eq "nexthop: recognised from the routing table" \
    "YES" "$(fw 'tctl_ip_is_nexthop 192.168.1.80 && echo YES || echo NO')"
assert_eq "nexthop: an ordinary client is not one" \
    "NO" "$(fw 'tctl_ip_is_nexthop 192.168.1.50 && echo YES || echo NO')"
# "via" as a device name or in another position must not count.
printf '172.16.0.0/16 dev via scope link\n' >> "$ROUTES"
assert_eq "nexthop: \"via\" as a device name is not a next hop" \
    "NO" "$(fw 'tctl_ip_is_nexthop via && echo YES || echo NO')"

# The block's half (the MAC rule, the v6 conntrack flush, removal of both
# halves) is `trafficctl block` since the ucode port: tests/test_ipv6_block.sh.

# ── rate limiter: upload over IPv6 ───────────────────────────────────────────

OUT=$(run_ratelimit 192.168.1.50 5000)
NFT=$(cat "$NFT_LOG")
assert_contains "limiter: IPv4 upload rule unchanged" \
    "add rule netdev tm_ratelimit ul_lan1 ip saddr 192.168.1.50 limit rate over 625000 bytes/second counter drop comment \"rl_ratelimit_192_168_1_50_ul\"" \
    "$NFT"
assert_contains "limiter: IPv6 upload is policed on the MAC at LAN ingress" \
    "add rule netdev tm_ratelimit ul_lan1 meta protocol ip6 ether saddr aa:bb:cc:dd:ee:50 limit rate over 625000 bytes/second counter drop comment \"rl_ratelimit_192_168_1_50_ul6\"" \
    "$NFT"
assert_contains "limiter: says both IPv6 directions are covered" "[IPv6: both directions]" "$OUT"
assert_contains "limiter: exposes v6 upload as a field" '"ipv6_upload":true' "$OUT"
assert_contains "limiter: exposes v6 download as a field" '"ipv6_download":true' "$OUT"

# Download over IPv6 is matched on the device's addresses. They rotate, so the
# set is fed by the data path rather than written from a snapshot: a dynamic
# set with a timeout, filled from the client's own frames at LAN ingress.
assert_contains "limiter: the v6 address set is dynamic with a timeout" \
    "add set netdev tm_ratelimit tctl_v6_192_168_1_50 { type ipv6_addr; flags dynamic,timeout; timeout 1h; }" \
    "$NFT"
assert_contains "limiter: the client's v6 frames feed the set at LAN ingress" \
    "add rule netdev tm_ratelimit ul_lan1 meta protocol ip6 ether saddr aa:bb:cc:dd:ee:50 ip6 saddr != fe80::/10 update @tctl_v6_192_168_1_50 { ip6 saddr } comment \"rl_ratelimit_192_168_1_50_v6\"" \
    "$NFT"
assert_contains "limiter: IPv6 download is policed on the set at LAN egress" \
    "add rule netdev tm_ratelimit dl_br_lan meta protocol ip6 ip6 daddr @tctl_v6_192_168_1_50 limit rate over 625000 bytes/second counter drop comment \"rl_ratelimit_192_168_1_50_dl6\"" \
    "$NFT"

# The set must exist before a rule names it, and the feed must come before the
# upload policer, or a packet that policer drops stops refreshing its address.
LINE_SET=$(printf '%s\n' "$NFT" | grep -n 'add set netdev tm_ratelimit tctl_v6_' | head -1 | cut -d: -f1)
LINE_DL6=$(printf '%s\n' "$NFT" | grep -n '_dl6"' | head -1 | cut -d: -f1)
LINE_FEED=$(printf '%s\n' "$NFT" | grep -n '_v6"' | head -1 | cut -d: -f1)
LINE_UL6=$(printf '%s\n' "$NFT" | grep -n '_ul6"' | head -1 | cut -d: -f1)
assert_eq "limiter: the set is created before the rules that name it" \
    "yes" "$([ "$LINE_SET" -lt "$LINE_DL6" ] && [ "$LINE_SET" -lt "$LINE_FEED" ] && echo yes || echo no)"
assert_eq "limiter: the feed rule precedes the v6 upload policer" \
    "yes" "$([ "$LINE_FEED" -lt "$LINE_UL6" ] && echo yes || echo no)"

# The limiter's chains are in the NETDEV family, where nft rejects "meta
# nfproto" outright: "meta nfproto is only useful in the inet family" (verified
# with nft --check against nftables 1.1.1 / kernel 6.6). The block's rule lives
# in inet fw4 and does use nfproto. Reaching for nfproto here is the obvious
# mistake — the rule simply fails to load and IPv6 upload goes unlimited.
assert_not_contains "limiter: does not use nfproto, which netdev rejects" \
    "meta nfproto" "$NFT"

# An unscoped ether rule would police a dual-stack client's IPv4 twice — once
# by address and once by MAC — silently halving the ceiling it was given.
UL_RULES=$(printf '%s\n' "$NFT" | grep "tm_ratelimit ul_")
assert_not_contains "limiter: no unscoped ether rule (would double-police IPv4)" \
    "ul_lan1 ether saddr" "$UL_RULES"

# "ether daddr" at LAN egress is the next hop's MAC, not the client's, so the
# download rules must never be keyed on one.
DL_RULES=$(printf '%s\n' "$NFT" | grep "tm_ratelimit dl_")
assert_not_contains "limiter: download is NOT keyed on a MAC" \
    "ether" "$DL_RULES"
assert_contains "limiter: download still matches the v4 address" \
    "ip daddr 192.168.1.50" "$DL_RULES"

# A set that cannot be created means no download half at all, reported as
# such — never a rule over a set that does not exist.
OUT=$(NFT_FAIL_SET=1 run_ratelimit 192.168.1.50 5000)
NFT=$(cat "$NFT_LOG")
assert_not_contains "limiter set-fail: no rule names the missing set" "@tctl_v6_" "$NFT"
assert_contains "limiter set-fail: v6 upload still applies" '_ul6"' "$NFT"
assert_contains "limiter set-fail: reported as upload only" "[IPv6: upload only]" "$OUT"
assert_contains "limiter set-fail: download field is false" '"ipv6_download":false' "$OUT"

# A device with no MAC: the v4 limit applies and the report says v4 only.
OUT=$(run_ratelimit 192.168.1.70 5000)
NFT=$(cat "$NFT_LOG")
assert_contains "limiter no-mac: the IPv4 limit still applies" \
    "ip saddr 192.168.1.70 limit rate over 625" "$NFT"
assert_not_contains "limiter no-mac: no MAC rule is invented" "ether saddr" "$NFT"
assert_contains "limiter no-mac: reported as IPv4 only" "[IPv4 only]" "$OUT"
assert_contains "limiter no-mac: exposes it as a field too" '"ipv6_upload":false' "$OUT"
assert_contains "limiter no-mac: no v6 download either" '"ipv6_download":false' "$OUT"
assert_not_contains "limiter no-mac: no address set is created" "add set" "$NFT"

# A CIDR target has no single MAC; the per-address meter keeps working.
OUT=$(run_ratelimit 192.168.1.0/24 5000)
NFT=$(cat "$NFT_LOG")
assert_contains "limiter cidr: still accepted" '"ok":true' "$OUT"
assert_not_contains "limiter cidr: no MAC rule for a whole block" "ether saddr" "$NFT"
assert_contains "limiter cidr: reported as IPv4 only" "[IPv4 only]" "$OUT"
assert_not_contains "limiter cidr: no address set for a whole block" "add set" "$NFT"

# A next hop is excluded here for the same reason as blocking: its MAC carries
# every downstream client's upload, so the whole subnet would be throttled.
OUT=$(run_ratelimit 192.168.1.80 5000)
NFT=$(cat "$NFT_LOG")
assert_not_contains "limiter nexthop: no MAC rule — it would throttle the subnet behind it" \
    "ether saddr" "$NFT"
assert_contains "limiter nexthop: reported as IPv4 only" "[IPv4 only]" "$OUT"
# Feeding a set from a router's MAC would collect every downstream client's
# address, and the download half would then throttle the whole subnet.
assert_not_contains "limiter nexthop: no address set fed from a router's MAC" "add set" "$NFT"

# ── rate limiter: removal clears the IPv6 rule too ───────────────────────────
#
# "_ul" is a prefix of "_ul6" and the address slugs nest as well, so both
# suffixes are matched with their closing quote. Without the _ul6 arm the
# IPv6 rule outlives the limit it belonged to and keeps dropping traffic.

TAB=$(printf '\t')
cat > "$RL_DUMP" <<EOF
table netdev tm_ratelimit {
${TAB}chain ul_lan1 {
${TAB}${TAB}ip saddr 192.168.1.5 limit rate over 625000 bytes/second counter drop comment "rl_ratelimit_192_168_1_5_ul" # handle 11
${TAB}${TAB}meta protocol ip6 ether saddr aa:bb:cc:dd:ee:05 limit rate over 625000 bytes/second counter drop comment "rl_ratelimit_192_168_1_5_ul6" # handle 12
${TAB}${TAB}ip saddr 192.168.1.50 limit rate over 625000 bytes/second counter drop comment "rl_ratelimit_192_168_1_50_ul" # handle 13
${TAB}${TAB}meta protocol ip6 ether saddr aa:bb:cc:dd:ee:50 limit rate over 625000 bytes/second counter drop comment "rl_ratelimit_192_168_1_50_ul6" # handle 14
${TAB}}
${TAB}${TAB}ether saddr aa:bb:cc:dd:ee:05 ip6 saddr != fe80::/10 update @tctl_v6_192_168_1_5 { ip6 saddr } comment "rl_ratelimit_192_168_1_5_v6" # handle 16
${TAB}${TAB}ether saddr aa:bb:cc:dd:ee:50 ip6 saddr != fe80::/10 update @tctl_v6_192_168_1_50 { ip6 saddr } comment "rl_ratelimit_192_168_1_50_v6" # handle 17
${TAB}}
${TAB}chain dl_br_lan {
${TAB}${TAB}ip daddr 192.168.1.5 limit rate over 625000 bytes/second counter drop comment "rl_ratelimit_192_168_1_5" # handle 15
${TAB}${TAB}ip6 daddr @tctl_v6_192_168_1_5 limit rate over 625000 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5_dl6" # handle 18
${TAB}${TAB}ip6 daddr @tctl_v6_192_168_1_50 limit rate over 625000 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_50_dl6" # handle 19
${TAB}}
}
EOF

: > "$NFT_LOG"
PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.limit remove '"192.168.1.5"' '"rl_ratelimit_192_168_1_5"' >/dev/null
DELS=$(grep '^delete rule netdev' "$NFT_LOG")
assert_contains "limiter removal: deletes the IPv4 upload rule" \
    "delete rule netdev tm_ratelimit ul_lan1 handle 11" "$DELS"
assert_contains "limiter removal: deletes the IPv6 upload rule" \
    "delete rule netdev tm_ratelimit ul_lan1 handle 12" "$DELS"
assert_contains "limiter removal: deletes the download rule" \
    "delete rule netdev tm_ratelimit dl_br_lan handle 15" "$DELS"
assert_not_contains "limiter removal: leaves 192.168.1.50's IPv4 rule alone" \
    "handle 13" "$DELS"
assert_not_contains "limiter removal: leaves 192.168.1.50's IPv6 rule alone" \
    "handle 14" "$DELS"
assert_contains "limiter removal: deletes the rule feeding the v6 set" \
    "delete rule netdev tm_ratelimit ul_lan1 handle 16" "$DELS"
assert_contains "limiter removal: deletes the IPv6 download rule" \
    "delete rule netdev tm_ratelimit dl_br_lan handle 18" "$DELS"
assert_not_contains "limiter removal: leaves 192.168.1.50's v6 feed alone" \
    "handle 17" "$DELS"
assert_not_contains "limiter removal: leaves 192.168.1.50's v6 download rule alone" \
    "handle 19" "$DELS"
# nft refuses to delete a set that a rule still references, so the set goes
# last, and only the target's own.
LAST=$(grep '^delete' "$NFT_LOG" | tail -1)
assert_eq "limiter removal: the v6 set is deleted after its rules" \
    "delete set netdev tm_ratelimit tctl_v6_192_168_1_5" "$LAST"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
