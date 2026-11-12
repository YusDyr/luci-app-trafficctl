#!/bin/bash
# Guards the 2 GiB ceiling on byte counters (#56).
#
# busybox awk formats "%d" through a 32-bit int, and what it does with a value
# that does not fit is undefined — it differs between builds of the SAME
# busybox version:
#
#     OpenWrt 24.10, busybox 1.36.1   printf "%d", 5368709120  ->  2147483647
#     Alpine 3.20,   busybox 1.36.1   printf "%d", 5368709120  -> -2147483648
#
# So this cannot be pinned to one wrong number. The test asserts only that the
# value comes back INTACT, which is the property that actually matters.
#
# On the saturating builds the failure is quiet — a counter that stops moving
# reads as "stale statistics", not as a broken one — which is why it shipped
# for so long. On the wrapping builds it emits a negative byte count into JSON
# and into a Prometheus counter.
#
# TWO KINDS OF TEST LIVE HERE, and the split is the point:
#
#   * The awk behavioural tests only fail under a 32-bit awk. GitHub runners have
#     gawk, whose %d is 64-bit clean, so on CI they pass EVEN WITH THE BUG
#     PRESENT. They are real coverage on a router (or any box with busybox)
#     and are reported as inconclusive elsewhere.
#   * The static assertions do not depend on the local awk at all and are what
#     actually holds the line in CI.
#
# The byte sampler, the accumulator, the exporter and the reports are ucode
# now (int64, no awk), so sections 2 to 4 test them directly, values past
# 2^53 included. The %d scan remains for the shell scripts still shipped.
#
# Nothing here needs %.0f on values that are not 64-bit kernel counters, and
# %.0f emits no decimal point, so the consumers that re-parse this output with
# /"bytes":[0-9]+/ keep working.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/bytes_env.sh
. "$(dirname "$0")/lib/bytes_env.sh"

PASS=0
FAIL=0

REPO_ROOT="$UC_REPO"
BIN="$REPO_ROOT/trafficctl/files/usr/libexec/trafficctl"

TMP="$UC_TMP/overflow"
mkdir -p "$TMP"

# The two values a broken 32-bit %d has been observed to produce; neither may
# appear in output. Detection never relies on them — it compares against the
# true value — but they make a failure message readable.
CLAMP=2147483647
WRAPPED=-2147483648
BIG=5368709120          # 5 GiB, comfortably past the clamp
HUGE=9007199254740991   # 2^53-1, the largest integer a double holds exactly
PAST53=9007199254740994 # 2^53+2: a double holds it, but not 2^53+3 next to it

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

# ════════════════════════════════════════════════════════════════════════════
# Discover the awk implementations present, and which of them are 32-bit.
# ════════════════════════════════════════════════════════════════════════════

AWKS=""
for cand in gawk mawk awk; do
    command -v "$cand" >/dev/null 2>&1 && AWKS="$AWKS $cand"
done
if command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{}' 2>/dev/null; then
    AWKS="$AWKS busybox-awk"
fi

run_awk() {   # run_awk <impl> <program...>
    local impl="$1"; shift
    case "$impl" in
        busybox-awk) busybox awk "$@" ;;
        *) "$impl" "$@" ;;
    esac
}

NARROW=""
echo "awk implementations under test:$AWKS"
for a in $AWKS; do
    got=$(run_awk "$a" -v v="$BIG" 'BEGIN{ printf "%d", v }' 2>/dev/null)
    # Anything other than the exact value is a narrow %d, however it mangles
    # it. Matching a specific wrong number here would have silently downgraded
    # coverage on builds that wrap instead of saturating.
    if [ "$got" != "$BIG" ]; then
        NARROW="$NARROW $a"
        printf '  %-12s %%d mangles 5 GiB into %-12s <- exercises the bug\n' "$a" "$got"
    else
        printf '  %-12s %%d is 64-bit clean\n' "$a"
    fi
done
echo

# ════════════════════════════════════════════════════════════════════════════
# 1. The premise itself: %.0f survives where %d does not, on every awk here.
# ════════════════════════════════════════════════════════════════════════════

for a in $AWKS; do
    assert_eq "$a: %.0f prints 5 GiB exactly" "$BIG" \
        "$(run_awk "$a" -v v="$BIG" 'BEGIN{ printf "%.0f", v }' 2>/dev/null)"
    assert_eq "$a: %.0f prints 2^53-1 exactly" "$HUGE" \
        "$(run_awk "$a" -v v="$HUGE" 'BEGIN{ printf "%.0f", v }' 2>/dev/null)"
    # No decimal point: the JSON and Prometheus consumers re-parse these with
    # integer regexes, so a "5368709120.0" would break them just as badly.
    assert_not_contains "$a: %.0f emits no decimal point" "." \
        "$(run_awk "$a" -v v="$BIG" 'BEGIN{ printf "%.0f", v }' 2>/dev/null)"
done

# ════════════════════════════════════════════════════════════════════════════
# 2. `trafficctl bytes` reports a conntrack counter past 2 GiB, and past 2^53,
#    intact. The ucode port has no awk in the path (int64 throughout), so this
#    runs once; the 2^53+2 upload is exact there, where a double would round.
# ════════════════════════════════════════════════════════════════════════════

be_offload none
printf 'ipv4     2 tcp      6 431999 ESTABLISHED src=192.168.1.50 dst=203.0.113.9 sport=40000 dport=443 packets=3000000 bytes=%s src=203.0.113.9 dst=192.168.1.50 sport=443 dport=40000 packets=4000000 bytes=%s [ASSURED] mark=0 use=2\n' "$HUGE" "$BIG" > "$BE_CT"
printf 'ipv4     2 udp      17 29 src=192.168.1.51 dst=203.0.113.9 sport=40001 dport=443 packets=1 bytes=%s src=203.0.113.9 dst=192.168.1.51 sport=443 dport=40001 packets=1 bytes=%s mark=0 use=2\n' "$PAST53" "$PAST53" >> "$BE_CT"

out=$(be_run bytes)
assert_contains "bytes: 5 GiB download survives" "\"bytes_in\":$BIG" "$out"
assert_contains "bytes: 2^53-1 upload survives" "\"bytes_out\":$HUGE" "$out"
assert_contains "bytes: 2^53+2 upload is exact" "\"bytes_out\":$PAST53" "$out"
assert_not_contains "bytes: nothing pinned at 2^31-1" "$CLAMP" "$out"
assert_not_contains "bytes: no wrapped negative byte count" "$WRAPPED" "$out"
: > "$BE_CT"

# ════════════════════════════════════════════════════════════════════════════
# 3. The shared accumulator is not permanently pinned.
#
#    This is the worst instance of the bug and the only one that does not heal
#    itself once the format is fixed: the accumulator writes the running total
#    to a state file and seeds from it on the next sample. Written through a
#    32-bit %d the stored value saturates, is read back saturated, saturates
#    again, so trafficctl_device_bytes_total, declared a monotonic counter,
#    stops at 2147483647 and never moves again. Since 1.14 the same store also
#    feeds the LuCI Bytes column, so a pinned value is visible in two places.
#
#    The exporter is driven end to end here (`trafficctl metrics` -> the
#    accumulator -> a recorded byte sample, tests/lib/metrics.uc) because the
#    round trip through the state file is exactly what has to survive.
# ════════════════════════════════════════════════════════════════════════════

STATE="$BE_ROOT/tmp/trafficctl_totals.state"
BYTES_FILE="$TMP/bytes.json"
MSRC="$TMP/msrc"     # the summary, portfw and netify sources: silent
mkdir -p "$MSRC"
printf "config metrics 'metrics'\n\toption enabled '1'\n" > "$BE_ROOT/etc/config/trafficctl"
run_metrics() {
    TCTL_ROOT="$BE_ROOT" "$UCODE" -S -L "$UC_LIB" -- "$UC_TESTLIB/metrics.uc" "$BYTES_FILE" "$MSRC" 2>/dev/null
}

# Prior state: a device sitting just under the clamp. Fields are
# ip rx_acc tx_acc rx_last tx_last seen tcp_acc udp_acc tcp_last udp_last
# src since degraded.
printf '192.168.0.50 2100000000 10 2100000000 10 1700000000 0 0 -1 -1 ct 1700000000 false\n' > "$STATE"
# Live conntrack has moved on by 200 MB, which must push the accumulator
# past 2^31-1 rather than parking it there.
printf '[{"ip":"192.168.0.50","bytes_in":2300000000,"bytes_out":10,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct"}]\n' > "$BYTES_FILE"

out=$(run_metrics)
assert_contains "metrics: rx counter crosses 2^31-1" \
    'trafficctl_device_bytes_total{ip="192.168.0.50",direction="rx"} 2300000000' "$out"
assert_not_contains "metrics: counter is not pinned at the clamp" \
    "direction=\"rx\"} $CLAMP" "$out"
# And the value that goes back to disk must not be clamped either, or the
# next scrape starts from the ceiling again.
assert_contains "metrics: state file keeps the full total" \
    "192.168.0.50 2300000000" "$(cat "$STATE")"
# Second scrape with no further movement: still above the clamp, proving
# the seed/round-trip did not truncate.
out2=$(run_metrics)
assert_contains "metrics: total survives a re-seed from the state file" \
    'trafficctl_device_bytes_total{ip="192.168.0.50",direction="rx"} 2300000000' "$out2"

# Past 2^53 the exporter prints the integer, where the shell one's awk
# rounded it through a double.
printf '192.168.0.52 %s 0 %s 0 1700000000 0 0 -1 -1 ct 1700000000 false\n' "$HUGE" "$HUGE" > "$STATE"
printf '[{"ip":"192.168.0.52","bytes_in":%s,"bytes_out":0,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct"}]\n' "$PAST53" > "$BYTES_FILE"
out=$(run_metrics)
assert_contains "metrics: a 3-byte delta past 2^53 is exported exactly" \
    "trafficctl_device_bytes_total{ip=\"192.168.0.52\",direction=\"rx\"} $PAST53" "$out"
assert_contains "accumulator: a 3-byte delta past 2^53 lands in the store" \
    "192.168.0.52 $PAST53 " "$(cat "$STATE")"

# ════════════════════════════════════════════════════════════════════════════
# 4. The reports: the summary and the device detail sum conntrack bytes, and
#    the DPI collector sums per-app bytes. The shell versions formatted those
#    sums with awk, so each needed a %.0f; the ucode ones keep the integer.
#    Then the static guard over the shell scripts still shipped.
# ════════════════════════════════════════════════════════════════════════════

: > "$BE_ROOT/etc/config/trafficctl"
printf 'ipv4     2 tcp      6 431999 ESTABLISHED src=192.168.1.50 dst=203.0.113.9 sport=40000 dport=443 packets=3000000 bytes=%s src=203.0.113.9 dst=192.168.1.50 sport=443 dport=40000 packets=4000000 bytes=%s [ASSURED] mark=0 use=2\n' "$BIG" "$BIG" > "$BE_CT"
printf 'ipv4     2 udp      17 29 src=192.168.1.50 dst=203.0.113.9 sport=40001 dport=443 packets=1 bytes=%s src=203.0.113.9 dst=192.168.1.50 sport=443 dport=40001 packets=1 bytes=%s mark=0 use=2\n' "$HUGE" "$BIG" >> "$BE_CT"
# Both report the original direction's bytes, as the shell ones did.
SUM_TCP=$BIG
SUM_UDP=$HUGE
SUM_ALL=$((BIG + HUGE))
out=$(be_run summary)
assert_contains "summary: the conntrack byte sum past 2^53 is exact" \
    "\"total\":$SUM_ALL,\"tcp\":$SUM_TCP,\"udp\":$SUM_UDP" "$out"
assert_not_contains "summary: nothing pinned at 2^31-1" "$CLAMP" "$out"
out=$(be_run device 192.168.1.50)
assert_contains "device: the conntrack byte total is exact" "\"total\":$SUM_ALL," "$out"
assert_not_contains "device: no wrapped negative byte count" "$WRAPPED" "$out"
printf '{"stats":[{"application_id":"1.netify.big","download":%s,"upload":%s,"local_ip":"192.168.1.50"}]}\n' "$BIG" "$BIG" > "$TMP/feed5.json"
TCTL_NETIFY_FEED="$TMP/feed5.json" be_run netify collect 1 >/dev/null
assert_contains "netify: the per-app byte total is exact" "\"name\":\"big\",\"bytes\":$((BIG * 2))" \
    "$(cat "$BE_ROOT/tmp/trafficctl_netify.json" 2>/dev/null)"
: > "$BE_CT"

SCRIPTS=$(find "$BIN" -name 'trafficctl-*.sh' | sort)
assert_eq "found the shipped scripts to scan" "0" \
    "$([ -n "$SCRIPTS" ] && echo 0 || echo 1)"

# Every byte-valued field in a shipped script must be formatted with %.0f.
# Shell printf is 64-bit safe on busybox, so the shell sites are not the bug;
# requiring %.0f there too costs nothing and keeps one rule instead of "it
# depends which printf this line reaches". Unambiguous byte fields: any JSON
# key containing "bytes", and any Prometheus metric whose name ends in
# _bytes / _bytes_total.
offenders=$(grep -nE '"[a-z_]*bytes[a-z_]*\\?":%d|_bytes(_total)?\{[^}]*\}[^"]*%d' \
    $SCRIPTS 2>/dev/null | sed "s|$REPO_ROOT/||")
assert_eq "no byte-named field is printed with %d" "" "$offenders"

# shape-stats reports tc's cumulative counters: bytes and packets, but also
# drops/overlimits/requeues/lended/borrowed, which climb for the life of the
# qdisc and overflow the same way. The ucode reader keeps them as 64-bit
# integers; this pins every one past 2^32.
SS="$TMP/shape-stats"
mkdir -p "$SS/bin" "$SS/root/etc/trafficctl"
echo '[{"ip":"192.168.1.100","rate_kbit":10000,"classid":"1:2"}]' > "$SS/root/etc/trafficctl/shapes.json"
cat > "$SS/bin/tc" <<'MOCK'
#!/bin/sh
case "$*" in
    *qdisc\ show*) echo "qdisc htb 1: root refcnt 2 r2q 10 default 0xfffe" ;;
    *class\ show*)
        echo "class htb 1:2 parent 1:1 prio 0 rate 10Mbit ceil 10Mbit burst 1600b cburst 1600b"
        echo " Sent 9007199254740000 bytes 4294967297 pkt (dropped 4294967298, overlimits 4294967299 requeues 4294967300)"
        echo " backlog 0b 0p requeues 4294967300"
        echo " lended: 4294967301 borrowed: 4294967302 giants: 0" ;;
esac
MOCK
chmod +x "$SS/bin/tc"
assert_contains "shape-stats: cumulative tc counters past 2^32 stay exact" \
    '"bytes":9007199254740000,"packets":4294967297,"backlog":0,"drops":4294967298,"overlimits":4294967299,"requeues":4294967300,"lended":4294967301,"borrowed":4294967302' \
    "$(PATH="$SS/bin:$PATH" TCTL_ROOT="$SS/root" tctl shape-stats 2>&1)"

# ════════════════════════════════════════════════════════════════════════════

if [ -z "$NARROW" ]; then
    echo
    echo "NOTE: no 32-bit awk is installed here, so section 1 could not fail"
    echo "even with a narrow %d: it passed vacuously. Install busybox to"
    echo "exercise it. Sections 2 to 4 are interpreter-independent."
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
