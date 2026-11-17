#!/bin/bash
# IPv6 and the internet block (issue #67), on `trafficctl block`/`unblock`
# since the ucode port. The limiter's half stays in tests/test_ipv6.sh.
#
# The block matched "ip saddr" only, so a "blocked" device kept full,
# unmetered v6 access while the UI read blocked. The block now adds a second
# rule keyed on the MAC (privacy addresses rotate, so no v6 address is), and
# flushes the device's v6 flows.
#
# The nft fake (tests/lib/nft-fw4.uc) keeps real state for both rule forms
# with stable handles, because the interesting assertions are about which of
# several coexisting rules a removal picks.

PASS=0
FAIL=0

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/fw4_env.sh
. "$UC_TESTLIB/fw4_env.sh"

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}
assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$1" "$2" "$3"
    fi
}
assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$1" "$2"
    else
        PASS=$((PASS + 1))
    fi
}

fw_cfg 0
printf 'inet 192.168.1.1/24\n' > "$STATE/ip4_br-lan"
run_block()   { fw_clear; fw_run block "$@"; }
run_unblock() { fw_clear; fw_run unblock "$@"; }
net() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.net "$@" 2>&1; }
ctl() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.ctl "$@" 2>&1; }

# The fixture LAN:
#   .50  dual-stack laptop      — lease, ARP entry, three v6 addresses
#   .60  IPv4-only printer      — lease and ARP entry, no v6 at all
#   .70  routed downstream host — neither lease nor ARP entry
#   .80  downstream ROUTER      — lease, but it is the next hop for 10.0.5.0/24
printf 'x AA:BB:CC:DD:EE:50 192.168.1.50 laptop *\n' >> "$LEASES"
printf 'x aa:bb:cc:dd:ee:60 192.168.1.60 printer *\n' >> "$LEASES"
printf 'x aa:bb:cc:dd:ee:80 192.168.1.80 downstream *\n' >> "$LEASES"
printf '192.168.1.50 dev br-lan lladdr aa:bb:cc:dd:ee:50 REACHABLE\n' >> "$STATE/neigh"
printf '192.168.1.60 dev br-lan lladdr aa:bb:cc:dd:ee:60 STALE\n' >> "$STATE/neigh"
printf '192.168.1.90 dev br-lan lladdr aa:bb:cc:dd:ee:90 REACHABLE\n' >> "$STATE/neigh"
# The laptop holds a stable SLAAC address, a privacy-extension temporary that
# will rotate, and a link-local — which is exactly why rules are not written
# against any of them.
printf '2001:db8::50 dev br-lan lladdr aa:bb:cc:dd:ee:50 REACHABLE\n' >> "$STATE/neigh6"
printf '2001:db8::dead:beef dev br-lan lladdr AA:BB:CC:DD:EE:50 STALE\n' >> "$STATE/neigh6"
printf 'fe80::50 dev br-lan lladdr aa:bb:cc:dd:ee:50 REACHABLE\n' >> "$STATE/neigh6"
printf '2001:db8::99 dev br-lan lladdr aa:bb:cc:dd:ee:99 REACHABLE\n' >> "$STATE/neigh6"
printf '10.0.5.0/24 via 192.168.1.80 dev br-lan\n' >> "$STATE/route"
printf 'default via 10.1.1.1 dev eth1\n' >> "$STATE/route"

# ── MAC resolution (net.lookup_mac, tctl_lookup_mac's port) ─────────────────

assert_eq "mac: resolved from the DHCP lease, lowercased" \
    "aa:bb:cc:dd:ee:50" "$(net lookup_mac '"192.168.1.50"')"
assert_eq "mac: falls back to the neighbour table with no lease" \
    "aa:bb:cc:dd:ee:90" "$(net lookup_mac '"192.168.1.90"')"
# A routed/downstream client has neither. Silently doing nothing there is the
# failure this issue is about, so the lookup must FAIL rather than return junk.
assert_eq "mac: unknown device yields nothing" "" "$(net lookup_mac '"192.168.1.70"')"
# The MAC is interpolated into an nft rule string, so it is validated as six
# hex pairs rather than merely trimmed.
printf 'x aa:bb:cc;nft flush ruleset;:ee 192.168.1.66 evil *\n' >> "$LEASES"
assert_eq "mac: a malformed lease field is refused, not interpolated" "" "$(net lookup_mac '"192.168.1.66"')"

# ── which targets may be keyed on a MAC ──────────────────────────────────────

assert_eq "target: a plain host qualifies" "aa:bb:cc:dd:ee:50" "$(net target_mac '"192.168.1.50"')"
assert_eq "target: /32 is the same single host" "aa:bb:cc:dd:ee:50" "$(net target_mac '"192.168.1.50/32"')"
assert_eq "target: a CIDR block has no single MAC" "" "$(net target_mac '"192.168.1.0/24"')"
assert_eq "target: \"all\" has no single MAC" "" "$(net target_mac '"0.0.0.0/0"')"
# The big over-block hazard: a next hop's MAC is the source address of every
# packet it FORWARDS, so keying a rule on it takes out the whole subnet behind
# it. Excluded, and the caller is made to say why.
assert_eq "target: a routed next hop is excluded" "" "$(net target_mac '"192.168.1.80"')"
assert_eq "nexthop: recognised from the routing table" "true" "$(net ip_is_nexthop '"192.168.1.80"')"
assert_eq "nexthop: an ordinary client is not one" "false" "$(net ip_is_nexthop '"192.168.1.50"')"
# "via" as a device name or in another position must not count.
printf '172.16.0.0/16 dev via scope link\n' >> "$STATE/route"
assert_eq "nexthop: \"via\" as a device name is not a next hop" "false" "$(net ip_is_nexthop '"via"')"

# ── block: dual-stack client ─────────────────────────────────────────────────

fw_flush
OUT=$(run_block 192.168.1.50)
NFT=$(cat "$NFT_LOG")
assert_contains "block: reports ok" '"ok":true' "$OUT"
assert_contains "block: reports IPv6 covered" '"ipv6":true' "$OUT"
assert_contains "block: the IPv4 rule is unchanged" \
    'ip saddr 192.168.1.50 counter drop comment "tctl_block_192_168_1_50"' "$(fw_rules)"
assert_contains "block: an IPv6 rule keyed on the MAC is installed too" \
    'ether saddr aa:bb:cc:dd:ee:50 counter drop comment "tctl_block_192_168_1_50_mac"' "$(fw_rules)"
# Scoping matters: without "meta nfproto ipv6" the MAC rule would also swallow
# IPv4, making every v4 outcome depend on a MAC lookup that can fail.
assert_contains "block: the MAC rule is scoped to IPv6 only" \
    'meta nfproto ipv6 ether saddr aa:bb:cc:dd:ee:50' "$(fw_rules)"
# fw4's forward chain accepts established/offloaded flows near the top, so a
# rule appended below that never fires.
assert_not_contains "block: the MAC rule is inserted, not appended" "add rule inet fw4 forward" "$NFT"

# The v4 flush alone leaves established v6 flows running — and under flow
# offload they are never re-evaluated against the new rule, so the device
# stays online over v6 indefinitely while the UI reads blocked.
CT=$(cat "$CONNTRACK_LOG")
assert_contains "block: flushes IPv4 conntrack as before" "-D -s 192.168.1.50" "$CT"
assert_contains "block: flushes the stable SLAAC address" "-D -f ipv6 -s 2001:db8::50" "$CT"
assert_contains "block: flushes the privacy-extension temporary too" "-D -f ipv6 -s 2001:db8::dead:beef" "$CT"
assert_contains "block: flushes the link-local address" "-D -f ipv6 -s fe80::50" "$CT"
assert_contains "block: flushes v6 flows in both directions" "-D -f ipv6 -d 2001:db8::50" "$CT"
assert_not_contains "block: does not flush another device's v6 flows" "2001:db8::99" "$CT"

# Blocking your own device: the v6 flush stays symmetric with the v4 one that
# has always run here. Both rules are forward-only, so LuCI (LAN-local, not
# forwarded) keeps working either way.
fw_flush
fw_clear
OUT=$(TCTL_SRC=192.168.1.50 fw_run block 192.168.1.50)
assert_contains "block self: keeps the LuCI-access message" "LuCI access preserved" "$OUT"
assert_contains "block self: still covers IPv6" '"ipv6":true' "$OUT"
assert_contains "block self: flushes v6 exactly as it flushes v4" "-D -f ipv6 -s 2001:db8::50" "$(cat "$CONNTRACK_LOG")"

# ── block: IPv4-only client ──────────────────────────────────────────────────

fw_flush
OUT=$(run_block 192.168.1.60)
assert_contains "block v4-only: still gets the MAC rule (it costs nothing)" 'ether saddr aa:bb:cc:dd:ee:60' "$(fw_rules)"
assert_contains "block v4-only: reports IPv6 covered" '"ipv6":true' "$OUT"
assert_not_contains "block v4-only: no v6 conntrack flush when it has no v6 flows" "-f ipv6" "$(cat "$CONNTRACK_LOG")"

# ── block: no MAC known ──────────────────────────────────────────────────────
# A routed/downstream client cannot be keyed on a MAC at all. Reporting plain
# success there would recreate the exact failure of issue #67 in a new place.

fw_flush
OUT=$(run_block 192.168.1.70)
assert_contains "block no-mac: the IPv4 block still applies" 'ip saddr 192.168.1.70 counter drop' "$(fw_rules)"
assert_not_contains "block no-mac: no MAC rule is invented" "ether saddr" "$(fw_rules)"
assert_contains "block no-mac: reports IPv6 NOT covered" '"ipv6":false' "$OUT"
assert_contains "block no-mac: says so in words" "IPv4 only" "$OUT"
assert_contains "block no-mac: names the reason" "no MAC known" "$OUT"

# ── block: a downstream router ───────────────────────────────────────────────

fw_flush
OUT=$(run_block 192.168.1.80)
assert_contains "block nexthop: the IPv4 block still applies" 'ip saddr 192.168.1.80 counter drop' "$(fw_rules)"
assert_not_contains "block nexthop: no MAC rule — it would black-hole the subnet behind it" "ether saddr" "$(fw_rules)"
assert_contains "block nexthop: reports IPv6 NOT covered" '"ipv6":false' "$OUT"
assert_contains "block nexthop: explains that it is a routed next hop" "routed next hop" "$OUT"

# ── a MAC rule nft refuses ───────────────────────────────────────────────────
# The v4 block stands; the reply says v6 is not covered.
fw_flush
OUT=$(NFT_FAIL='ether saddr' fw_run block 192.168.1.50)
assert_contains "block, v6 rule refused: still ok" '"ok":true' "$OUT"
assert_contains "block, v6 rule refused: reports IPv6 NOT covered" '"ipv6":false' "$OUT"

# ── unblock removes both halves, and only the target's ───────────────────────
# .5 and .51 rather than .1 and .10: the comment of the first is a prefix of
# the second's, which is the trap, and .1 is the router's own address here.
fw_flush
printf 'x aa:bb:cc:dd:ee:05 192.168.1.5 five *\n'  >> "$LEASES"
printf 'x aa:bb:cc:dd:ee:51 192.168.1.51 fiftyone *\n' >> "$LEASES"
run_block 192.168.1.5  >/dev/null
run_block 192.168.1.51 >/dev/null
assert_eq "fixture: four rules installed (two devices × two families)" "4" "$(fw_rules | grep -c .)"

OUT=$(run_unblock 192.168.1.5)
assert_contains "unblock: reports ok" '"ok":true' "$OUT"
REMAIN=$(fw_rules)
assert_not_contains "unblock: the IPv4 rule is gone" '"tctl_block_192_168_1_5"' "$REMAIN"
assert_not_contains "unblock: the IPv6 MAC rule is gone too" '"tctl_block_192_168_1_5_mac"' "$REMAIN"
# The comment is a prefix of the other device's, which is how a substring match
# once made unblocking 192.168.1.1 delete 192.168.1.10's rule.
assert_contains "unblock: 192.168.1.51's IPv4 rule is untouched" '"tctl_block_192_168_1_51"' "$REMAIN"
assert_contains "unblock: 192.168.1.51's IPv6 MAC rule is untouched" '"tctl_block_192_168_1_51_mac"' "$REMAIN"

# ── block-state readers ──────────────────────────────────────────────────────
# If a reader does not recognise the form that was installed, the UI reports
# "not blocked" for a blocked device — which is the same lie as before, just
# pointing the other way.

fw_flush
fw_put 'meta nfproto ipv6 ether saddr aa:bb:cc:dd:ee:50 counter packets 3 bytes 300 drop comment "tctl_block_192_168_1_50_mac"'
assert_eq "is_blocked: true when only the IPv6 MAC rule survives" "true" "$(ctl is_blocked '"192.168.1.50"')"
assert_eq "is_blocked: 192.168.1.5 is not blocked by 192.168.1.50's MAC rule" "false" "$(ctl is_blocked '"192.168.1.5"')"
fw_flush
fw_put 'ip saddr 192.168.1.50 counter packets 1 bytes 100 drop comment "tctl_block_192_168_1_50"'
assert_eq "is_blocked: still true for a v4-only rule from an older version" "true" "$(ctl is_blocked '"192.168.1.50"')"
# An accept that happens to name the address is not a block.
fw_flush
fw_put 'ip saddr 192.168.1.50 counter accept comment "someone_else"'
assert_eq "is_blocked: an accept rule is not a block" "false" "$(ctl is_blocked '"192.168.1.50"')"

# The summary and the device report read the same rule forms, the MAC half
# included: tests/test_report.sh.

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
