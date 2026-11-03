#!/bin/bash
# Reading a device's rate limit back out of the nft ruleset.
#
# The summary and the device view used `grep "daddr <ip>"`, the stats only
# understood "kbytes":
#
#   * 192.168.1.5 matched 192.168.1.50's rule as well (a prefix, and the dots
#     were regex wildcards), so an unlimited device showed another's limit.
#   * the download rule sits on EVERY LAN device's egress chain, so a router
#     with two bridges produced two numbers, which printf then rejected.
#   * nft prints a rate in the largest unit that keeps it whole: 1024
#     kbytes/second lists as "1 mbytes/second" (nftables 1.0.9). 8192 kbit/s
#     therefore read as 0 in the summary and as 8 kbit/s in the stats.
#
# The dump below is in the exact format nft lists, including those units.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/local/bin"
FWLIB="$BIN/trafficctl-fw.sh"

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
        printf "FAIL: %s\n  expected to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    fi
}

DUMP="$TMPDIR/rl.dump"
TAB=$(printf '\t')
cat > "$DUMP" <<DUMP
table netdev tm_ratelimit {
${TAB}chain dl_br_lan {
${TAB}${TAB}type filter hook egress device "br-lan" priority filter; policy accept;
${TAB}${TAB}ip daddr 192.168.1.5 limit rate over 625 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5"
${TAB}${TAB}ip daddr 192.168.1.50 limit rate over 1250 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_50"
${TAB}${TAB}ip daddr 192.168.1.7 limit rate over 1 mbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_7"
${TAB}${TAB}ip daddr 192.168.1.9 limit rate over 512 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_9"
${TAB}${TAB}ip daddr 192.168.1.8 meter tctl_d_192_168_1_8 { ip daddr limit rate over 2 mbytes/second } counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_8"
${TAB}${TAB}ip6 daddr @tctl_v6_192_168_1_5 limit rate over 625 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5_dl6"
${TAB}}
${TAB}chain dl_br_guest {
${TAB}${TAB}type filter hook egress device "br-guest" priority filter; policy accept;
${TAB}${TAB}ip daddr 192.168.1.5 limit rate over 625 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5"
${TAB}}
${TAB}chain ul_lan1 {
${TAB}${TAB}type filter hook ingress device "lan1" priority -200; policy accept;
${TAB}${TAB}ip saddr 192.168.1.60 limit rate over 125 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_60_ul"
${TAB}}
}
DUMP

cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    *"list table netdev tm_ratelimit"*) cat "$DUMP" ;;
esac
exit 0
MOCK
for c in uci ubus iptables; do printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/$c"; done
chmod +x "$MOCKBIN"/*

rate_of() { PATH="$MOCKBIN:$PATH" sh -c ". $FWLIB >/dev/null 2>&1; tctl_rl_rate_kbit $1" < "$DUMP" 2>&1; }

# ── tctl_rl_rate_kbit ────────────────────────────────────────────────────────

assert_eq "helper: a kbytes rate converts to kbit" "5000" "$(rate_of 192.168.1.5)"
assert_eq "helper: one number although the rule sits on two bridges" "1" "$(rate_of 192.168.1.5 | grep -c .)"
assert_eq "helper: the longer address gets its own limit" "10000" "$(rate_of 192.168.1.50)"
assert_eq "helper: a prefix of a limited address is not limited" "" "$(rate_of 192.168.1.51)"
assert_eq "helper: an address that only prefixes another reads nothing" "" "$(rate_of 192.168.1.)"
assert_eq "helper: 'mbytes' as nft prints 1024 kbytes" "8192" "$(rate_of 192.168.1.7)"
assert_eq "helper: per-device (meter) rule in mbytes" "16384" "$(rate_of 192.168.1.8)"
# nft steps its units by 1024: 512 bytes/second is half a kbyte, 4 kbit/s.
assert_eq "helper: bytes scale by 1024 like nft's other units" "4" "$(rate_of 192.168.1.9)"
assert_eq "helper: an upload-only rule is not a download ceiling" "" "$(rate_of 192.168.1.60)"
assert_eq "helper: dots are not wildcards" "" "$(rate_of 192x168x1x5)"

# ── summary: lookup_rate_limit ───────────────────────────────────────────────

LOOKUP="$TMPDIR/lookup.sh"
sed -n '/^lookup_rate_limit()/,/^}/p' "$BIN/trafficctl-summary.sh" > "$LOOKUP"
assert_contains "harness: lookup_rate_limit extracted" "lookup_rate_limit()" "$(cat "$LOOKUP")"
summary_rate() {
    PATH="$MOCKBIN:$PATH" sh -c ". $FWLIB >/dev/null 2>&1; . $LOOKUP; TCTL_FW=nft; RL_DUMP=\$(cat $DUMP); lookup_rate_limit $1" 2>&1
}
assert_eq "summary: own limit" "5000" "$(summary_rate 192.168.1.5)"
assert_eq "summary: 1024 kbytes is 8192 kbit, not 0" "8192" "$(summary_rate 192.168.1.7)"
assert_eq "summary: unlimited device reads 0" "0" "$(summary_rate 192.168.1.51)"

# ── device view uses the same reader ─────────────────────────────────────────

assert_contains "device: reads its limit through tctl_rl_rate_kbit" \
    'tctl_rl_rate_kbit "$IP"' "$(cat "$BIN/trafficctl-device.sh")"

# ── stats: units ─────────────────────────────────────────────────────────────

STATS_SH="$TMPDIR/rl-stats.sh"
sed "s|/usr/local/bin/trafficctl-fw.sh|$FWLIB|" "$BIN/trafficctl-ratelimit-stats.sh" > "$STATS_SH"
STATS=$(PATH="$MOCKBIN:$PATH" sh "$STATS_SH" 2>/dev/null)
assert_contains "stats: kbytes rate" '"ip":"192.168.1.5","mode":"shared","rate_kbit":5000' "$STATS"
assert_contains "stats: mbytes rate is not read as 8 kbit/s" '"ip":"192.168.1.7","mode":"shared","rate_kbit":8192' "$STATS"
assert_contains "stats: per-device rule in mbytes" '"ip":"192.168.1.8","mode":"each","rate_kbit":16384' "$STATS"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
