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
# and read back by nft's own 1024 steps. The fixture holds what the limiter
# writes now, plus rules written before, as rate_kbit / 8 "kbytes", which read
# as what they really police. The shell reader (tctl_rl_rate_kbit) went with
# the limiter's port to ucode; the figures it gave are the expectations below.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
TMPDIR="$UC_TMP/t"
mkdir -p "$TMPDIR/root"
FIXTURES="$UC_REPO/tests/fixtures"
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

# The readers ask for JSON: the ruleset as the nft of OpenWrt
# 22.03 (1.0.2) or 25.12 (1.1.6) prints it (tests/fixtures/nft-src/rl.nft).
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    "-j list table netdev tm_ratelimit") cat "$FIXTURES/nft-\$NFTV/rl.tm_ratelimit.json" ;;
esac
exit 0
MOCK
for c in uci ubus; do printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/$c"; done
chmod +x "$MOCKBIN"/*

# The summary and the device report read the same dumps in ucode; their
# lookups are pinned in tests/test_report.sh.

# ── the reads from nft -j, on both nft versions ────────────────────────────
# address  download  upload ("-" = no ceiling)
#   192.168.1.5: one number although the rule sits on two bridges
#   192.168.1.50/.51: a prefix of a limited address is not limited
#   192.168.1.7: 8192 kbit/s is 1024000 bytes/s, which nft lists as 1000 kbytes
#   192.168.1.6/.4: written as rate_kbit / 8 nft kbytes, 2.4% above what was
#     asked, and reported as what it polices
#   192.168.1.9: 512 bytes/second is half a kbyte, 4 kbit/s
#   192x168x1x5: dots are not wildcards
EXPECT="
192.168.1.5 5000 1000
192.168.1.50 10000 -
192.168.1.51 - -
192.168.1. - -
192.168.1.7 8192 -
192.168.1.8 16384 2000
192.168.1.6 5120 -
192.168.1.4 8389 -
192.168.1.9 4 -
192.168.1.60 - 1024
192x168x1x5 - -"

for NFTV in 1.0.2 1.1.6; do
    export NFTV
    RULES=$(PATH="$MOCKBIN:$PATH" TCTL_ROOT="$TMPDIR/root" tcall trafficctl.ctl rl_rules)
    uc_rate() { tcall trafficctl.ctl rl_rate_kbit "$RULES" "\"$1\"" "\"${2:-daddr}\""; }
    while read -r ip dl ul; do
        [ -n "$ip" ] || continue
        [ "$dl" = - ] && dl=""
        [ "$ul" = - ] && ul=""
        assert_eq "ucode $NFTV: $ip download" "$dl" "$(uc_rate "$ip")"
        assert_eq "ucode $NFTV: $ip upload" "$ul" "$(uc_rate "$ip" saddr)"
    done <<EOF
$EXPECT
EOF

    STATS=$(PATH="$MOCKBIN:$PATH" TCTL_ROOT="$TMPDIR/root" tctl ratelimit-stats 2>&1)
    assert_contains "stats $NFTV: bytes rate" '"ip":"192.168.1.5","mode":"shared","rate_kbit":5000' "$STATS"
    assert_contains "stats $NFTV: kbytes listing" '"ip":"192.168.1.7","mode":"shared","rate_kbit":8192' "$STATS"
    assert_contains "stats $NFTV: mbytes listing is not read as 8 kbit/s" '"ip":"192.168.1.4","mode":"shared","rate_kbit":8389' "$STATS"
    # nft 1.1 lists the meter as "add @set { ... }": the shell reader looked
    # for " meter " and called this limit shared there.
    assert_contains "stats $NFTV: per-device rule in kbytes" '"ip":"192.168.1.8","mode":"each","rate_kbit":16384' "$STATS"
    # Both bridges' counters, past 2^32, and the upload rules not at all.
    assert_contains "stats $NFTV: one device's chains summed" '"ip":"192.168.1.5","mode":"shared","rate_kbit":5000,"packets":7,"bytes":5000000300' "$STATS"
    assert_eq "stats $NFTV: one record per download address" "7" "$(printf '%s' "$STATS" | jq length)"
done

STATS=$(PATH="$MOCKBIN:$PATH" TCTL_ROOT="$TMPDIR/root" tctl ratelimit-stats bogus 2>&1)
mkdir -p "$TMPDIR/none"; printf '#!/bin/sh\necho "Error: No such file or directory" >&2\nexit 1\n' > "$TMPDIR/none/nft"; chmod +x "$TMPDIR/none/nft"
assert_eq "stats: no table is an empty array" "[]" "$(PATH="$TMPDIR/none:$PATH" TCTL_ROOT="$TMPDIR/root" tctl ratelimit-stats 2>/dev/null)"
assert_contains "stats: arguments are ignored, as by the shell script" '"ip":"192.168.1.8"' "$STATS"
assert_eq "shim: the script is the CLI command" 'exec /usr/sbin/trafficctl ratelimit-stats "$@"' "$(tail -n 1 "$BIN/trafficctl-ratelimit-stats.sh")"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
