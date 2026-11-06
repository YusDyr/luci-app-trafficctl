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
#   * nft prints a rate in the largest unit that keeps it whole, stepping by
#     1024: 1024 bytes/second lists as "1 kbytes/second", 1024 kbytes/second
#     as "1 mbytes/second" (nftables 1.0.9). A reader that only knew "kbytes"
#     read those as 0, or as 8 kbit/s in the stats.
#
# Rules are written in bytes/second, kbit * 125 (SI, see tctl_rate_bytes),
# and read back by nft's own 1024 steps. The dump below is in the exact format
# nft lists: what the limiter writes now, plus rules written before, as
# rate_kbit / 8 "kbytes", which read as what they really police.

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
${TAB}${TAB}ip daddr 192.168.1.5 limit rate over 625000 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5"
${TAB}${TAB}ip daddr 192.168.1.50 limit rate over 1250000 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_50"
${TAB}${TAB}ip daddr 192.168.1.7 limit rate over 1000 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_7"
${TAB}${TAB}ip daddr 192.168.1.6 limit rate over 625 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_6"
${TAB}${TAB}ip daddr 192.168.1.4 limit rate over 1 mbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_4"
${TAB}${TAB}ip daddr 192.168.1.9 limit rate over 512 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_9"
${TAB}${TAB}ip daddr 192.168.1.8 meter tctl_d_192_168_1_8 { ip daddr limit rate over 2000 kbytes/second } counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_8"
${TAB}${TAB}ip6 daddr @tctl_v6_192_168_1_5 limit rate over 625 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5_dl6"
${TAB}}
${TAB}chain dl_br_guest {
${TAB}${TAB}type filter hook egress device "br-guest" priority filter; policy accept;
${TAB}${TAB}ip daddr 192.168.1.5 limit rate over 625000 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5"
${TAB}}
${TAB}chain ul_lan1 {
${TAB}${TAB}type filter hook ingress device "lan1" priority -200; policy accept;
${TAB}${TAB}ip saddr 192.168.1.60 limit rate over 125 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_60_ul"
${TAB}${TAB}ip saddr 192.168.1.5 limit rate over 125000 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5_ul"
${TAB}${TAB}ip saddr 192.168.1.8 meter tctl_u_192_168_1_8 { ip saddr limit rate over 250000 bytes/second } counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_8_ul"
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

assert_eq "helper: a bytes rate converts to SI kbit" "5000" "$(rate_of 192.168.1.5)"
assert_eq "helper: one number although the rule sits on two bridges" "1" "$(rate_of 192.168.1.5 | grep -c .)"
assert_eq "helper: the longer address gets its own limit" "10000" "$(rate_of 192.168.1.50)"
assert_eq "helper: a prefix of a limited address is not limited" "" "$(rate_of 192.168.1.51)"
assert_eq "helper: an address that only prefixes another reads nothing" "" "$(rate_of 192.168.1.)"
# 8192 kbit/s is 1024000 bytes/s, which nft lists as 1000 kbytes.
assert_eq "helper: 'kbytes' as nft lists 1024000 bytes" "8192" "$(rate_of 192.168.1.7)"
assert_eq "helper: per-device (meter) rule in kbytes" "16384" "$(rate_of 192.168.1.8)"
# Written before rates were stored in bytes: rate_kbit / 8 nft kbytes, i.e.
# 2.4% above what was asked. Reported as what it polices.
assert_eq "helper: a legacy kbytes rule reads as what it polices" "5120" "$(rate_of 192.168.1.6)"
assert_eq "helper: 'mbytes' (a legacy 8192 kbit/s rule)" "8389" "$(rate_of 192.168.1.4)"
# nft steps its units by 1024: 512 bytes/second is half a kbyte, 4 kbit/s.
assert_eq "helper: bytes scale by 1024 like nft's other units" "4" "$(rate_of 192.168.1.9)"
assert_eq "helper: an upload-only rule is not a download ceiling" "" "$(rate_of 192.168.1.60)"
assert_eq "helper: dots are not wildcards" "" "$(rate_of 192x168x1x5)"

# Upload has its own ceiling since #83, read from the "ip saddr" rule.
rate_up_of() { PATH="$MOCKBIN:$PATH" sh -c ". $FWLIB >/dev/null 2>&1; tctl_rl_rate_kbit $1 saddr" < "$DUMP" 2>&1; }
assert_eq "helper up: a split ceiling reads its own upload figure" "1000" "$(rate_up_of 192.168.1.5)"
assert_eq "helper up: per-device (meter) upload rule" "2000" "$(rate_up_of 192.168.1.8)"
assert_eq "helper up: an upload-only rule" "1024" "$(rate_up_of 192.168.1.60)"
assert_eq "helper up: a download-only rule is not an upload ceiling" "" "$(rate_up_of 192.168.1.50)"

# ── summary: lookup_rate_limit ───────────────────────────────────────────────

LOOKUP="$TMPDIR/lookup.sh"
sed -n '/^lookup_rate_limit()/,/^}/p' "$BIN/trafficctl-summary.sh" > "$LOOKUP"
assert_contains "harness: lookup_rate_limit extracted" "lookup_rate_limit()" "$(cat "$LOOKUP")"
summary_rate() {
    PATH="$MOCKBIN:$PATH" sh -c ". $FWLIB >/dev/null 2>&1; . $LOOKUP; TCTL_FW=nft; RL_DUMP=\$(cat $DUMP); lookup_rate_limit $1" 2>&1
}
assert_eq "summary: own limit" "5000" "$(summary_rate 192.168.1.5)"
assert_eq "summary: a kbytes listing is not read as 0" "8192" "$(summary_rate 192.168.1.7)"
assert_eq "summary: unlimited device reads 0" "0" "$(summary_rate 192.168.1.51)"
assert_eq "summary up: own upload ceiling" "1000" "$(summary_rate '192.168.1.5 up')"
assert_eq "summary up: no upload rule reads 0" "0" "$(summary_rate '192.168.1.50 up')"
assert_contains "summary: the upload ceiling is in the JSON" '"rate_limit_kbit_up":%.0f' "$(cat "$BIN/trafficctl-summary.sh")"

# ── device view uses the same reader ─────────────────────────────────────────

assert_contains "device: reads its limit through tctl_rl_rate_kbit" \
    'tctl_rl_rate_kbit "$IP"' "$(cat "$BIN/trafficctl-device.sh")"
assert_contains "device: reads the upload ceiling too" \
    'tctl_rl_rate_kbit "$IP" saddr' "$(cat "$BIN/trafficctl-device.sh")"
assert_contains "device: the upload ceiling is in the JSON" \
    '"rate_limit_kbit_up":%d' "$(cat "$BIN/trafficctl-device.sh")"

# ── stats: units ─────────────────────────────────────────────────────────────

STATS_SH="$TMPDIR/rl-stats.sh"
sed "s|/usr/local/bin/trafficctl-fw.sh|$FWLIB|" "$BIN/trafficctl-ratelimit-stats.sh" > "$STATS_SH"
STATS=$(PATH="$MOCKBIN:$PATH" sh "$STATS_SH" 2>/dev/null)
assert_contains "stats: bytes rate" '"ip":"192.168.1.5","mode":"shared","rate_kbit":5000' "$STATS"
assert_contains "stats: kbytes listing" '"ip":"192.168.1.7","mode":"shared","rate_kbit":8192' "$STATS"
assert_contains "stats: mbytes listing is not read as 8 kbit/s" '"ip":"192.168.1.4","mode":"shared","rate_kbit":8389' "$STATS"
assert_contains "stats: per-device rule in kbytes" '"ip":"192.168.1.8","mode":"each","rate_kbit":16384' "$STATS"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
