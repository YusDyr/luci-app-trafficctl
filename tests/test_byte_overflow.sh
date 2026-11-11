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
# The byte samplers and the accumulator are ucode now (int64, no awk), so
# sections 2 and 3 test them directly, values past 2^53 included; the awk
# loop remains for metrics.sh, which still reads the accumulator with awk.
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
FWLIB="$BIN/trafficctl-fw.sh"

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
# 2. `trafficctl bytes-nft` reports a counter past 2 GiB, and past 2^53,
#    intact. The ucode port has no awk in the path (int64 throughout), so this
#    runs once; the 2^53+2 upload is exact there, where a double would round.
# ════════════════════════════════════════════════════════════════════════════

printf 'table inet trafficctl_mon {\n  chain mon_forward {\n    update @bytes_in { ip daddr counter }\n    update @bytes_out { ip saddr counter }\n  }\n}\n' \
    > "$BE_NFT/list chain inet trafficctl_mon mon_forward"
printf 'table inet trafficctl_mon {\n  map bytes_in {\n    elements = { 192.168.0.50 : counter packets 4000000 bytes %s }\n  }\n}\n' "$BIG" \
    > "$BE_NFT/list map inet trafficctl_mon bytes_in"
printf 'table inet trafficctl_mon {\n  map bytes_out {\n    elements = { 192.168.0.50 : counter packets 3000000 bytes %s, 192.168.0.51 : counter packets 1 bytes %s }\n  }\n}\n' "$HUGE" "$PAST53" \
    > "$BE_NFT/list map inet trafficctl_mon bytes_out"

out=$(be_run bytes-nft)
assert_contains "bytes-nft: 5 GiB download survives" "\"bytes_in\":$BIG" "$out"
assert_contains "bytes-nft: 2^53-1 upload survives" "\"bytes_out\":$HUGE" "$out"
assert_contains "bytes-nft: 2^53+2 upload is exact" "\"bytes_out\":$PAST53" "$out"
assert_not_contains "bytes-nft: nothing pinned at 2^31-1" "$CLAMP" "$out"
assert_not_contains "bytes-nft: no wrapped negative byte count" "$WRAPPED" "$out"

# The same through nft -j.
printf '{"nftables": [{"map": {"name": "bytes_in", "elem": [["192.168.0.50", {"counter": {"packets": 1, "bytes": %s}}]]}}]}\n' "$PAST53" \
    > "$BE_NFT/-j list map inet trafficctl_mon bytes_in"
out=$(be_run bytes-nft)
assert_contains "bytes-nft -j: 2^53+2 download is exact" "\"bytes_in\":$PAST53" "$out"

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
#    The exporter is driven end to end here (metrics.sh -> `trafficctl
#    totals --all` -> a recorded byte sample) because the round trip through
#    the state file is exactly what has to survive. The accumulator is ucode
#    now; metrics.sh still reads its output with awk, so that part runs once
#    per awk implementation.
# ════════════════════════════════════════════════════════════════════════════

STATE="$BE_ROOT/tmp/trafficctl_totals.state"
METRICS_MOCK="$TMP/mbin"
mkdir -p "$METRICS_MOCK"

sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FWLIB|" \
    -e "s|/usr/libexec/trafficctl/trafficctl-totals.sh|$TMP/totals.sh|" \
    -e "s|/usr/libexec/trafficctl/trafficctl-summary.sh|$METRICS_MOCK/summary|" \
    -e "s|/usr/libexec/trafficctl/trafficctl-portfw.sh|$METRICS_MOCK/portfw|" \
    -e "s|/usr/libexec/trafficctl/trafficctl-netify.sh|$METRICS_MOCK/netify|" \
    "$BIN/trafficctl-metrics.sh" > "$TMP/metrics.sh"

# sed exits 0 on no match. If these paths are ever renamed, the rewrites would
# silently no-op and this section would test the production scripts against the
# real /tmp state file, or nothing at all.
assert_contains "metrics.sh is redirected at the accumulator under test" \
    "$TMP/totals.sh" "$(cat "$TMP/metrics.sh")"

BYTES_FILE="$TMP/bytes.json"
cat > "$TMP/totals.sh" <<MOCK
#!/bin/sh
TCTL_ROOT="$BE_ROOT" exec "$UCODE" -S -L "$UC_LIB" -- "$UC_TESTLIB/totals.uc" "$BYTES_FILE" "\$@"
MOCK
cat > "$METRICS_MOCK/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    trafficctl.metrics.enabled) echo "1" ;;
    *) exit 1 ;;
esac
MOCK
for m in summary portfw netify; do
    printf '#!/bin/sh\nprintf "[]\\n"\n' > "$METRICS_MOCK/$m"
done
chmod +x "$METRICS_MOCK"/* "$TMP/totals.sh"

for a in $AWKS; do
    shim="$TMP/shim-$a"
    mkdir -p "$shim"
    case "$a" in
        busybox-awk) printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$shim/awk" ;;
        *) printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$a")" > "$shim/awk" ;;
    esac
    chmod +x "$shim/awk"

    # Prior state: a device sitting just under the clamp. Fields are
    # ip rx_acc tx_acc rx_last tx_last seen tcp_acc udp_acc tcp_last udp_last
    # src since degraded.
    printf '192.168.0.50 2100000000 10 2100000000 10 1700000000 0 0 -1 -1 ct 1700000000 false\n' > "$STATE"
    # Live conntrack has moved on by 200 MB, which must push the accumulator
    # past 2^31-1 rather than parking it there.
    printf '[{"ip":"192.168.0.50","bytes_in":2300000000,"bytes_out":10,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct"}]\n' > "$BYTES_FILE"

    out=$(PATH="$shim:$METRICS_MOCK:$PATH" sh "$TMP/metrics.sh" 2>/dev/null)
    assert_contains "metrics ($a): rx counter crosses 2^31-1" \
        'trafficctl_device_bytes_total{ip="192.168.0.50",direction="rx"} 2300000000' "$out"
    assert_not_contains "metrics ($a): counter is not pinned at the clamp" \
        "direction=\"rx\"} $CLAMP" "$out"

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

# Past 2^53 the state file stays exact even though the awk reading it in
# metrics.sh would round: the store is the one place a lost byte never comes
# back.
printf '192.168.0.52 %s 0 %s 0 1700000000 0 0 -1 -1 ct 1700000000 false\n' "$HUGE" "$HUGE" > "$STATE"
printf '[{"ip":"192.168.0.52","bytes_in":%s,"bytes_out":0,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct"}]\n' "$PAST53" > "$BYTES_FILE"
"$TMP/totals.sh" >/dev/null
assert_contains "accumulator: a 3-byte delta past 2^53 lands in the store" \
    "192.168.0.52 $PAST53 " "$(cat "$STATE")"

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
assert_contains "summary.sh: conntrack byte sums use %.0f" \
    'printf "%s %.0f %.0f %.0f %d %s\n", ip, total[ip]+0, tcp[ip]+0, udp[ip]+0, conns[ip], kind[ip]' \
    "$(cat "$BIN/trafficctl-summary.sh")"
assert_contains "device.sh: conntrack byte total uses %.0f" \
    'END { printf "%.0f %d %d %d %d %d %d %d", total, n_tcp, n_udp, n_other, est, tw, ss, cw }' \
    "$(cat "$BIN/trafficctl-device.sh")"
assert_contains "netify.sh: per-app byte total uses %.0f" \
    'printf "%s %s %.0f %d\n", p[1], p[2], total[k], flows[k]' \
    "$(cat "$BIN/trafficctl-netify.sh")"
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
    echo "NOTE: no 32-bit awk is installed here, so the metrics.sh part of"
    echo "section 3 could not fail even with the bug present: it passed"
    echo "vacuously. Install busybox to exercise it. Sections 2 and 4 are"
    echo "interpreter-independent."
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
