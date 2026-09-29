#!/bin/bash
# IPv6 enforcement tests (issue #67).
#
# Every enforcement path in this package matched "ip saddr"/"ip daddr", so a
# dual-stack client obeyed its 10 Mbit/s cap over IPv4 and ran at 151 Mbit/s
# over IPv6 to the same endpoint — and a "blocked" device kept full, unmetered
# v6 access while the UI read blocked.
#
# What is covered here is the MAC-keyed half: the internet block (both
# families) and the UPLOAD direction of the rate limiter. Download over IPv6
# and byte accounting over IPv6 are deliberately still open; there are
# assertions below pinning that down so the gap cannot close by accident and
# go undocumented.
#
# The nft mock keeps real state for BOTH rule forms — the address-keyed v4 rule
# and the MAC-keyed v6 one — with stable handles, because the interesting
# assertions are about which of several coexisting rules a removal picks.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/local/bin"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
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

BLOCK_SH="$TMPDIR/block.sh"
UNBLOCK_SH="$TMPDIR/unblock.sh"
RATELIMIT_SH="$TMPDIR/ratelimit.sh"
sed "s|/usr/local/bin/trafficctl-fw.sh|$FW|" "$BIN/trafficctl-block.sh" > "$BLOCK_SH"
sed "s|/usr/local/bin/trafficctl-fw.sh|$FW|" "$BIN/trafficctl-unblock.sh" > "$UNBLOCK_SH"
sed "s|/usr/local/bin/trafficctl-fw.sh|$FW|" "$BIN/trafficctl-ratelimit.sh" > "$RATELIMIT_SH"

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
esac
exit 0
MOCK

chmod +x "$MOCKBIN"/*

# br-lan is a bridge with one port: ingress hooks land on the PORT, egress on
# the bridge itself (see tctl_ingress_devices).
mkdir -p "$TMPDIR/sys/class/net/br-lan/brif/lan1" "$TMPDIR/sys/class/net/eth1"
export TCTL_SYSFS_NET="$TMPDIR/sys/class/net"

fw() { PATH="$MOCKBIN:$PATH" sh -c ". $FW >/dev/null 2>&1; $1" 2>&1; }
run_block()     { : > "$NFT_LOG"; : > "$CT_LOG"; PATH="$MOCKBIN:$PATH" sh "$BLOCK_SH" "$@" 2>&1; }
run_unblock()   { : > "$NFT_LOG"; PATH="$MOCKBIN:$PATH" sh "$UNBLOCK_SH" "$@" 2>&1; }
run_ratelimit() { : > "$NFT_LOG"; PATH="$MOCKBIN:$PATH" sh "$RATELIMIT_SH" "$@" 2>&1; }

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

# ── block: dual-stack client ─────────────────────────────────────────────────

: > "$FW4_STATE"
OUT=$(run_block 192.168.1.50)
NFT=$(cat "$NFT_LOG")
assert_contains "block: reports ok" '"ok":true' "$OUT"
assert_contains "block: reports IPv6 covered" '"ipv6":true' "$OUT"
assert_contains "block: the IPv4 rule is unchanged" \
    'ip saddr 192.168.1.50 counter drop comment "tctl_block_192_168_1_50"' "$NFT"
assert_contains "block: an IPv6 rule keyed on the MAC is installed too" \
    'ether saddr aa:bb:cc:dd:ee:50 counter drop comment "tctl_block_192_168_1_50_mac"' "$NFT"

# Scoping matters: without "meta nfproto ipv6" the MAC rule would also swallow
# IPv4, making every v4 outcome depend on a MAC lookup that can fail.
assert_contains "block: the MAC rule is scoped to IPv6 only" \
    'meta nfproto ipv6 ether saddr aa:bb:cc:dd:ee:50' "$NFT"

# fw4's forward chain accepts established/offloaded flows near the top, so a
# rule appended below that never fires.
assert_not_contains "block: the MAC rule is inserted, not appended" \
    "add rule inet fw4 forward" "$NFT"

# The v4 flush alone leaves established v6 flows running — and under flow
# offload they are never re-evaluated against the new rule, so the device
# stays online over v6 indefinitely while the UI reads blocked.
CT=$(cat "$CT_LOG")
assert_contains "block: flushes IPv4 conntrack as before" "-D -s 192.168.1.50" "$CT"
assert_contains "block: flushes the stable SLAAC address" "-D -f ipv6 -s 2001:db8::50" "$CT"
assert_contains "block: flushes the privacy-extension temporary too" \
    "-D -f ipv6 -s 2001:db8::dead:beef" "$CT"
assert_contains "block: flushes the link-local address" "-D -f ipv6 -s fe80::50" "$CT"
assert_contains "block: flushes v6 flows in both directions" "-D -f ipv6 -d 2001:db8::50" "$CT"
assert_not_contains "block: does not flush another device's v6 flows" \
    "2001:db8::99" "$CT"

# Blocking your own device: the v6 flush stays symmetric with the v4 one that
# has always run here. Both rules are forward-only, so LuCI (LAN-local, not
# forwarded) keeps working either way; flushing only one family would leave the
# operator's own device half-blocked, which is harder to reason about than
# either extreme.
: > "$FW4_STATE"
OUT=$(PATH="$MOCKBIN:$PATH" TCTL_SRC=192.168.1.50 sh "$BLOCK_SH" 192.168.1.50 2>&1)
assert_contains "block self: keeps the LuCI-access message" "LuCI access preserved" "$OUT"
assert_contains "block self: still covers IPv6" '"ipv6":true' "$OUT"
assert_contains "block self: flushes v6 exactly as it flushes v4" \
    "-D -f ipv6 -s 2001:db8::50" "$(cat "$CT_LOG")"

# ── block: IPv4-only client ──────────────────────────────────────────────────

: > "$FW4_STATE"
OUT=$(run_block 192.168.1.60)
NFT=$(cat "$NFT_LOG")
CT=$(cat "$CT_LOG")
assert_contains "block v4-only: still gets the MAC rule (it costs nothing)" \
    'ether saddr aa:bb:cc:dd:ee:60' "$NFT"
assert_contains "block v4-only: reports IPv6 covered" '"ipv6":true' "$OUT"
assert_not_contains "block v4-only: no v6 conntrack flush when it has no v6 flows" \
    "-f ipv6" "$CT"

# ── block: no MAC known ──────────────────────────────────────────────────────
#
# A routed/downstream client cannot be keyed on a MAC at all. Reporting plain
# success there would recreate the exact failure of issue #67 in a new place.

: > "$FW4_STATE"
OUT=$(run_block 192.168.1.70)
NFT=$(cat "$NFT_LOG")
assert_contains "block no-mac: the IPv4 block still applies" \
    'ip saddr 192.168.1.70 counter drop' "$NFT"
assert_not_contains "block no-mac: no MAC rule is invented" "ether saddr" "$NFT"
assert_contains "block no-mac: reports IPv6 NOT covered" '"ipv6":false' "$OUT"
assert_contains "block no-mac: says so in words" "IPv4 only" "$OUT"
assert_contains "block no-mac: names the reason" "no MAC known" "$OUT"

# ── block: a downstream router ───────────────────────────────────────────────

: > "$FW4_STATE"
OUT=$(run_block 192.168.1.80)
NFT=$(cat "$NFT_LOG")
assert_contains "block nexthop: the IPv4 block still applies" \
    'ip saddr 192.168.1.80 counter drop' "$NFT"
assert_not_contains "block nexthop: no MAC rule — it would black-hole the subnet behind it" \
    "ether saddr" "$NFT"
assert_contains "block nexthop: reports IPv6 NOT covered" '"ipv6":false' "$OUT"
assert_contains "block nexthop: explains that it is a routed next hop" \
    "routed next hop" "$OUT"

# ── unblock removes both halves, and only the target's ───────────────────────

# .5 and .51 rather than .1 and .10: the comment of the first is a prefix of
# the second's, which is the trap, and .1 is the router's own address here.
: > "$FW4_STATE"
echo 0 > "$FW4_HANDLE"
printf 'x aa:bb:cc:dd:ee:05 192.168.1.5 five *\n'  >> "$LEASES"
printf 'x aa:bb:cc:dd:ee:51 192.168.1.51 fiftyone *\n' >> "$LEASES"
run_block 192.168.1.5  >/dev/null
run_block 192.168.1.51 >/dev/null

STATE_BEFORE=$(cat "$FW4_STATE")
assert_eq "fixture: four rules installed (two devices × two families)" \
    "4" "$(grep -c . <<< "$STATE_BEFORE")"

OUT=$(run_unblock 192.168.1.5)
assert_contains "unblock: reports ok" '"ok":true' "$OUT"
REMAIN=$(cat "$FW4_STATE")
assert_not_contains "unblock: the IPv4 rule is gone" "tctl_block_192_168_1_5	" "$REMAIN"
assert_not_contains "unblock: the IPv6 MAC rule is gone too" \
    "tctl_block_192_168_1_5_mac" "$REMAIN"
# The comment is a prefix of the other device's, which is how a substring match
# once made unblocking 192.168.1.1 delete 192.168.1.10's rule.
assert_contains "unblock: 192.168.1.51's IPv4 rule is untouched" \
    "tctl_block_192_168_1_51" "$REMAIN"
assert_contains "unblock: 192.168.1.51's IPv6 MAC rule is untouched" \
    "tctl_block_192_168_1_51_mac" "$REMAIN"

# ── block-state readers ──────────────────────────────────────────────────────
#
# If a reader does not recognise the form that was installed, the UI reports
# "not blocked" for a blocked device — which is the same lie as before, just
# pointing the other way.

: > "$FW4_STATE"
printf '7\tmac\ttctl_block_192_168_1_50_mac\taa:bb:cc:dd:ee:50\n' > "$FW4_STATE"
assert_eq "is_blocked: true when only the IPv6 MAC rule survives" \
    "YES" "$(fw 'tctl_is_blocked 192.168.1.50 && echo YES || echo NO')"
assert_eq "is_blocked: 192.168.1.5 is not blocked by 192.168.1.50's MAC rule" \
    "NO" "$(fw 'tctl_is_blocked 192.168.1.5 && echo YES || echo NO')"

: > "$FW4_STATE"
printf '8\tv4\ttctl_block_192_168_1_50\t192.168.1.50\n' > "$FW4_STATE"
assert_eq "is_blocked: still true for a v4-only rule from an older version" \
    "YES" "$(fw 'tctl_is_blocked 192.168.1.50 && echo YES || echo NO')"

# The summary table has its own copy of this logic against a prefetched dump.
# Extract it and drive it directly rather than standing up a whole poll.
LOOKUPS="$TMPDIR/lookups.sh"
sed -n '/^lookup_blocked()/,/^}/p;/^lookup_block_bytes()/,/^}/p' \
    "$BIN/trafficctl-summary.sh" > "$LOOKUPS"
assert_contains "harness: the summary lookups were extracted" "lookup_blocked()" "$(cat "$LOOKUPS")"
assert_contains "harness: the byte lookup was extracted too" "lookup_block_bytes()" "$(cat "$LOOKUPS")"

summary_lookup() {
    local dump="$1" call="$2"
    PATH="$MOCKBIN:$PATH" sh -c ". $FW >/dev/null 2>&1; . $LOOKUPS; FWD_DUMP='$dump'; $call" 2>&1
}

V6_ONLY_DUMP='		meta nfproto ipv6 ether saddr aa:bb:cc:dd:ee:50 counter packets 3 bytes 300 drop comment "tctl_block_192_168_1_50_mac"'
BOTH_DUMP="		ip saddr 192.168.1.50 counter packets 1 bytes 100 drop comment \"tctl_block_192_168_1_50\"
$V6_ONLY_DUMP"

assert_eq "summary: reports blocked when only the IPv6 rule is present" \
    "1" "$(summary_lookup "$V6_ONLY_DUMP" 'lookup_blocked 192.168.1.50')"
assert_eq "summary: does not attribute it to a prefix-sharing address" \
    "0" "$(summary_lookup "$V6_ONLY_DUMP" 'lookup_blocked 192.168.1.5')"
assert_eq "summary: unblocked device still reads 0" \
    "0" "$(summary_lookup "" 'lookup_blocked 192.168.1.50')"

# Counting only the v4 rule would make a dual-stack device's dropped bytes read
# low for the same reason the traffic used to escape entirely.
assert_eq "summary: block bytes sum both halves" \
    "400" "$(summary_lookup "$BOTH_DUMP" 'lookup_block_bytes 192.168.1.50')"
assert_eq "summary: block bytes are 0 with no rule at all" \
    "0" "$(summary_lookup "" 'lookup_block_bytes 192.168.1.50')"

# ── rate limiter: upload over IPv6 ───────────────────────────────────────────

OUT=$(run_ratelimit 192.168.1.50 5000)
NFT=$(cat "$NFT_LOG")
assert_contains "limiter: IPv4 upload rule unchanged" \
    "add rule netdev tm_ratelimit ul_lan1 ip saddr 192.168.1.50 limit rate over 625 kbytes/second counter drop comment \"rl_ratelimit_192_168_1_50_ul\"" \
    "$NFT"
assert_contains "limiter: IPv6 upload is policed on the MAC at LAN ingress" \
    "add rule netdev tm_ratelimit ul_lan1 meta protocol ip6 ether saddr aa:bb:cc:dd:ee:50 limit rate over 625 kbytes/second counter drop comment \"rl_ratelimit_192_168_1_50_ul6\"" \
    "$NFT"
assert_contains "limiter: says IPv6 upload is covered" "[IPv6: upload only]" "$OUT"

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

# The download half is the part that is NOT fixed here: "ether daddr" at LAN
# egress is the next hop's MAC, and matching on address needs a per-device set
# fed from ip -6 neigh. Pinning it so the gap cannot close silently.
DL_RULES=$(printf '%s\n' "$NFT" | grep "tm_ratelimit dl_")
assert_not_contains "limiter: download is NOT keyed on a MAC (out of scope, see docs)" \
    "ether" "$DL_RULES"
assert_contains "limiter: download still matches the v4 address" \
    "ip daddr 192.168.1.50" "$DL_RULES"

# A device with no MAC: the v4 limit applies and the report says v4 only.
OUT=$(run_ratelimit 192.168.1.70 5000)
NFT=$(cat "$NFT_LOG")
assert_contains "limiter no-mac: the IPv4 limit still applies" \
    "ip saddr 192.168.1.70 limit rate over 625" "$NFT"
assert_not_contains "limiter no-mac: no MAC rule is invented" "ether saddr" "$NFT"
assert_contains "limiter no-mac: reported as IPv4 only" "[IPv4 only]" "$OUT"
assert_contains "limiter no-mac: exposes it as a field too" '"ipv6_upload":false' "$OUT"

# A CIDR target has no single MAC; the per-address meter keeps working.
OUT=$(run_ratelimit 192.168.1.0/24 5000)
NFT=$(cat "$NFT_LOG")
assert_contains "limiter cidr: still accepted" '"ok":true' "$OUT"
assert_not_contains "limiter cidr: no MAC rule for a whole block" "ether saddr" "$NFT"
assert_contains "limiter cidr: reported as IPv4 only" "[IPv4 only]" "$OUT"

# A next hop is excluded here for the same reason as blocking: its MAC carries
# every downstream client's upload, so the whole subnet would be throttled.
OUT=$(run_ratelimit 192.168.1.80 5000)
NFT=$(cat "$NFT_LOG")
assert_not_contains "limiter nexthop: no MAC rule — it would throttle the subnet behind it" \
    "ether saddr" "$NFT"
assert_contains "limiter nexthop: reported as IPv4 only" "[IPv4 only]" "$OUT"

# ── rate limiter: removal clears the IPv6 rule too ───────────────────────────
#
# "_ul" is a prefix of "_ul6" and the address slugs nest as well, so both
# suffixes are matched with their closing quote. Without the _ul6 arm the
# IPv6 rule outlives the limit it belonged to and keeps dropping traffic.

TAB=$(printf '\t')
cat > "$RL_DUMP" <<EOF
table netdev tm_ratelimit {
${TAB}chain ul_lan1 {
${TAB}${TAB}ip saddr 192.168.1.5 limit rate over 625 kbytes/second counter drop comment "rl_ratelimit_192_168_1_5_ul" # handle 11
${TAB}${TAB}meta protocol ip6 ether saddr aa:bb:cc:dd:ee:05 limit rate over 625 kbytes/second counter drop comment "rl_ratelimit_192_168_1_5_ul6" # handle 12
${TAB}${TAB}ip saddr 192.168.1.50 limit rate over 625 kbytes/second counter drop comment "rl_ratelimit_192_168_1_50_ul" # handle 13
${TAB}${TAB}meta protocol ip6 ether saddr aa:bb:cc:dd:ee:50 limit rate over 625 kbytes/second counter drop comment "rl_ratelimit_192_168_1_50_ul6" # handle 14
${TAB}}
${TAB}chain dl_br_lan {
${TAB}${TAB}ip daddr 192.168.1.5 limit rate over 625 kbytes/second counter drop comment "rl_ratelimit_192_168_1_5" # handle 15
${TAB}}
}
EOF

: > "$NFT_LOG"
fw 'tctl_ratelimit_remove 192.168.1.5 rl_ratelimit_192_168_1_5' >/dev/null
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

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
