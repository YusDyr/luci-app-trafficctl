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
#   * The behavioural tests only fail under a 32-bit awk. GitHub runners have
#     gawk, whose %d is 64-bit clean, so on CI they pass EVEN WITH THE BUG
#     PRESENT. They are real coverage on a router (or any box with busybox)
#     and are reported as inconclusive elsewhere.
#   * The static assertions do not depend on the local awk at all and are what
#     actually holds the line in CI.
#
# Nothing here needs %.0f on values that are not 64-bit kernel counters, and
# %.0f emits no decimal point, so the consumers that re-parse this output with
# /"bytes":[0-9]+/ keep working.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin"
FWLIB="$BIN/trafficctl-fw.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The two values a broken 32-bit %d has been observed to produce; neither may
# appear in output. Detection never relies on them — it compares against the
# true value — but they make a failure message readable.
CLAMP=2147483647
WRAPPED=-2147483648
BIG=5368709120          # 5 GiB, comfortably past the clamp
HUGE=9007199254740991   # 2^53-1, the largest integer a double holds exactly

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
# 2. trafficctl-bytes-nft.sh reports a counter past 2 GiB intact.
#    Runs the REAL script with nft mocked, once per awk implementation.
# ════════════════════════════════════════════════════════════════════════════

MOCKBIN="$TMP/bin"
mkdir -p "$MOCKBIN"

# The chain listing satisfies the gate in both the pre- and post-#54 script:
# it carries "saddr" (old gate) and "bytes_in ... daddr" (current gate), so
# neither version tries to rebuild the table through the mock.
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
case "\$*" in
    "list chain inet trafficctl_mon mon_forward")
        echo "table inet trafficctl_mon {"
        echo "  chain mon_forward {"
        echo "    update @bytes_in { ip daddr counter }"
        echo "    update @bytes_out { ip saddr counter }"
        echo "  }"
        echo "}"
        ;;
    "list map inet trafficctl_mon bytes_in")
        echo "table inet trafficctl_mon {"
        echo "  map bytes_in {"
        echo "    elements = { 192.168.0.50 : counter packets 4000000 bytes $BIG }"
        echo "  }"
        echo "}"
        ;;
    "list map inet trafficctl_mon bytes_out")
        echo "table inet trafficctl_mon {"
        echo "  map bytes_out {"
        echo "    elements = { 192.168.0.50 : counter packets 3000000 bytes $HUGE }"
        echo "  }"
        echo "}"
        ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$MOCKBIN/nft"

sed -e "s|/usr/local/bin/trafficctl-fw.sh|$FWLIB|" \
    "$BIN/trafficctl-bytes-nft.sh" > "$TMP/bytes-nft.sh"
chmod +x "$TMP/bytes-nft.sh"

for a in $AWKS; do
    shim="$TMP/shim-$a"
    mkdir -p "$shim"
    case "$a" in
        busybox-awk) printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$shim/awk" ;;
        *) printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$a")" > "$shim/awk" ;;
    esac
    chmod +x "$shim/awk"

    out=$(PATH="$shim:$MOCKBIN:$PATH" sh "$TMP/bytes-nft.sh" 2>/dev/null)
    assert_contains "bytes-nft ($a): 5 GiB download survives" "\"bytes_in\":$BIG" "$out"
    assert_contains "bytes-nft ($a): 2^53-1 upload survives" "\"bytes_out\":$HUGE" "$out"
    assert_not_contains "bytes-nft ($a): nothing pinned at 2^31-1" "$CLAMP" "$out"
    assert_not_contains "bytes-nft ($a): no wrapped negative byte count" "$WRAPPED" "$out"
done

# ════════════════════════════════════════════════════════════════════════════
# 3. The metrics accumulator is not permanently pinned.
#
#    This is the worst instance of the bug and the only one that does not heal
#    itself once the format is fixed: the exporter writes the running total to
#    a state file and seeds from it on the next scrape. Written through a
#    32-bit %d the stored value saturates, is read back saturated, saturates
#    again — so trafficctl_device_bytes_total, declared a monotonic counter,
#    stops at 2147483647 and never moves again.
# ════════════════════════════════════════════════════════════════════════════

STATE="$TMP/metrics.state"
METRICS_MOCK="$TMP/mbin"
mkdir -p "$METRICS_MOCK"

sed -e "s|/usr/local/bin/trafficctl-fw.sh|$FWLIB|" \
    -e "s|STATE=\"/tmp/trafficctl_metrics.state\"|STATE=\"$STATE\"|" \
    -e "s|/usr/local/bin/trafficctl-bytes.sh|$METRICS_MOCK/bytes|" \
    -e "s|/usr/local/bin/trafficctl-summary.sh|$METRICS_MOCK/summary|" \
    -e "s|/usr/local/bin/trafficctl-portfw.sh|$METRICS_MOCK/portfw|" \
    -e "s|/usr/local/bin/trafficctl-netify.sh|$METRICS_MOCK/netify|" \
    "$BIN/trafficctl-metrics.sh" > "$TMP/metrics.sh"

cat > "$METRICS_MOCK/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    trafficctl.metrics.enabled) echo "1" ;;
    *) exit 1 ;;
esac
MOCK

BYTES_FILE="$TMP/bytes.json"
cat > "$METRICS_MOCK/bytes" <<MOCK
#!/bin/sh
cat "$BYTES_FILE"
MOCK
for m in summary portfw netify; do
    printf '#!/bin/sh\nprintf "[]\\n"\n' > "$METRICS_MOCK/$m"
done
chmod +x "$METRICS_MOCK"/*

for a in $AWKS; do
    shim="$TMP/shim-$a"

    # Prior state: a device sitting just under the clamp. Fields are
    # ip rx_acc tx_acc rx_last tx_last seen.
    printf '192.168.0.50 2100000000 10 2100000000 10 1700000000\n' > "$STATE"
    # Live conntrack has moved on by 200 MB, which must push the accumulator
    # past 2^31-1 rather than parking it there.
    printf '[{"ip":"192.168.0.50","bytes_in":2300000000,"bytes_out":10}]\n' > "$BYTES_FILE"

    out=$(PATH="$shim:$METRICS_MOCK:$PATH" sh "$TMP/metrics.sh" 2>/dev/null)
    assert_contains "metrics ($a): rx counter crosses 2^31-1" \
        'trafficctl_device_bytes_total{ip="192.168.0.50",direction="rx"} 2300000000' "$out"

    # And the value that goes back to disk must not be clamped either, or the
    # next scrape starts from the ceiling again.
    assert_contains "metrics ($a): state file keeps the full total" \
        "192.168.0.50 2300000000" "$(cat "$STATE")"

    # Second scrape with no further movement: still above the clamp, proving
    # the seed/round-trip did not truncate.
    out2=$(PATH="$shim:$METRICS_MOCK:$PATH" sh "$TMP/metrics.sh" 2>/dev/null)
    assert_contains "metrics ($a): total survives a re-seed from the state file" \
        'trafficctl_device_bytes_total{ip="192.168.0.50",direction="rx"} 2300000000' "$out2"
done

# ════════════════════════════════════════════════════════════════════════════
# 4. Static guard — the part that works on gawk, i.e. in CI.
#
#    Every byte-valued field in a shipped script must be formatted with %.0f.
#    Shell printf is 64-bit safe on busybox, so the shell sites are not the
#    bug; requiring %.0f there too costs nothing and keeps one rule instead of
#    "it depends which printf this line reaches".
# ════════════════════════════════════════════════════════════════════════════

SCRIPTS=$(find "$BIN" -name 'trafficctl-*.sh' | sort)
assert_eq "found the shipped scripts to scan" "0" \
    "$([ -n "$SCRIPTS" ] && echo 0 || echo 1)"

# Unambiguous byte fields: any JSON key containing "bytes", and any Prometheus
# metric whose name ends in _bytes / _bytes_total.
offenders=$(grep -nE '"[a-z_]*bytes[a-z_]*\\?":%d|_bytes(_total)?\{[^}]*\}[^"]*%d' \
    $SCRIPTS 2>/dev/null | sed "s|$REPO_ROOT/||")
assert_eq "no byte-named field is printed with %d" "" "$offenders"

# Positional and context-dependent sites, where the key is not adjacent to the
# conversion and the generic scan above cannot see it. Pinned literally.
#   summary.sh  : total/tcp/udp accumulate conntrack BYTES (conns is a count)
#   device.sh   : total accumulates bytes; n_tcp/est/... are counts
#   netify.sh   : per-app byte totals (flows is a count)
#   metrics.sh  : the persisted accumulator line
assert_contains "summary.sh: conntrack byte sums use %.0f" \
    'printf "%s %.0f %.0f %.0f %d %s\n", ip, total[ip]+0, tcp[ip]+0, udp[ip]+0, conns[ip], kind[ip]' \
    "$(cat "$BIN/trafficctl-summary.sh")"
assert_contains "device.sh: conntrack byte total uses %.0f" \
    'END { printf "%.0f %d %d %d %d %d %d %d", total, n_tcp, n_udp, n_other, est, tw, ss, cw }' \
    "$(cat "$BIN/trafficctl-device.sh")"
assert_contains "netify.sh: per-app byte total uses %.0f" \
    'printf "%s %s %.0f %d\n", p[1], p[2], total[k], flows[k]' \
    "$(cat "$BIN/trafficctl-netify.sh")"
assert_contains "metrics.sh: persisted accumulator uses %.0f" \
    'printf "%s %.0f %.0f %.0f %.0f %d\n", ip, rxa[ip], txa[ip], rxl[ip], txl[ip], now > tmp' \
    "$(cat "$BIN/trafficctl-metrics.sh")"
# shape-stats reports tc's cumulative counters: bytes and packets, but also
# drops/overlimits/requeues/lended/borrowed/ecn_mark, which climb for the life
# of the qdisc and overflow the same way. Only "bytes" is byte-named, so the
# generic scan above cannot see the other six — without this line they would
# quietly drift back to %d on the next edit.
assert_contains "shape-stats.sh: cumulative tc counters use %.0f" \
    '"bytes\":%.0f,\"packets\":%.0f,\"backlog\":%d,\"drops\":%.0f,\"overlimits\":%.0f,\"requeues\":%.0f,\"lended\":%.0f,\"borrowed\":%.0f,\"ecn_mark\":%.0f' \
    "$(cat "$BIN/trafficctl-shape-stats.sh")"

# ════════════════════════════════════════════════════════════════════════════

if [ -z "$NARROW" ]; then
    echo
    echo "NOTE: no 32-bit awk is installed here, so sections 2 and 3 could not"
    echo "fail even with the bug present — they passed vacuously. Install"
    echo "busybox to exercise them. Section 4 is interpreter-independent and"
    echo "is what guards this in CI."
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
