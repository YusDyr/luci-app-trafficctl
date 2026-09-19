#!/bin/bash
# Tests for the Prometheus exporter.
# Feeds recorded byte/summary output through the script and checks the
# accumulator's monotonicity rules, which are the part that cannot simply be
# eyeballed: raw conntrack sums drop when flows expire, so exporting them
# directly would look like a counter reset on every expiry.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/local/bin"
FWLIB="$BIN/trafficctl-fw.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"
STATE="$TMPDIR/metrics.state"

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
        printf "FAIL: %s\n  expected NOT to find: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

# metrics.sh shells out to the other trafficctl scripts by absolute path;
# point those at mocks and the state file at the temp dir.
#
# trafficctl-totals.sh is deliberately NOT mocked: the accumulator moved there
# and is the whole point of these monotonicity assertions, so the real script
# runs, with only its own byte source and state path redirected.
sed -e "s|/usr/local/bin/trafficctl-fw.sh|$FWLIB|" \
    -e "s|/usr/local/bin/trafficctl-totals.sh|$TMPDIR/totals.sh|" \
    -e "s|/usr/local/bin/trafficctl-summary.sh|$MOCKBIN/summary|" \
    -e "s|/usr/local/bin/trafficctl-portfw.sh|$MOCKBIN/portfw|" \
    -e "s|/usr/local/bin/trafficctl-netify.sh|$MOCKBIN/netify|" \
    "$BIN/trafficctl-metrics.sh" > "$TMPDIR/metrics.sh"

sed -e "s|/usr/local/bin/trafficctl-fw.sh|$FWLIB|" \
    -e "s|STATE=\"/tmp/trafficctl_totals.state\"|STATE=\"$STATE\"|" \
    -e "s|LOCKD=\"/tmp/trafficctl_totals.lock.d\"|LOCKD=\"$TMPDIR/lock.d\"|" \
    -e "s|/usr/local/bin/trafficctl-bytes.sh|$MOCKBIN/bytes|" \
    "$BIN/trafficctl-totals.sh" > "$TMPDIR/totals.sh"
chmod +x "$TMPDIR/totals.sh"

# sed exits 0 when nothing matched, so a renamed path would leave these
# pointing at the production scripts and /tmp state while the tests still pass.
for must in "$TMPDIR/totals.sh" "$MOCKBIN/summary"; do
    grep -qF "$must" "$TMPDIR/metrics.sh" || \
        { echo "FAIL: metrics.sh was not redirected to $must"; exit 1; }
done
grep -qF "$STATE" "$TMPDIR/totals.sh" || \
    { echo "FAIL: totals.sh still points at the production state file"; exit 1; }

# uci mock: exporter enabled, apps enabled so cardinality guard is exercised
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    trafficctl.metrics.enabled) echo "1" ;;
    trafficctl.metrics.apps)    echo "1" ;;
    *) exit 1 ;;
esac
MOCK

BYTES_FILE="$TMPDIR/bytes.json"
cat > "$MOCKBIN/bytes" <<MOCK
#!/bin/sh
cat "$BYTES_FILE"
MOCK

cat > "$MOCKBIN/summary" <<'MOCK'
#!/bin/sh
printf '[{"ip":"10.0.20.11","name":"Denis-NAS","mac":"aa:bb:cc:dd:ee:ff","conn_type":"routed","app":"google","conns":7,"total":9000,"tcp":7000,"udp":2000,"blocked":true,"block_bytes":4242,"wifi_blocked":false,"rate_limit_kbit":1000,"shape_kbit":0}]\n'
MOCK

cat > "$MOCKBIN/portfw" <<'MOCK'
#!/bin/sh
printf '[{"id":"r0","kind":"forward","name":"Web","proto":"tcp","ext_port":"8080","enabled":true,"paused":true,"limit_kbit":5000,"conns":3,"clients":2,"bytes_in":12345,"bytes_out":678}]\n'
MOCK

cat > "$MOCKBIN/netify" <<'MOCK'
#!/bin/sh
printf '[{"ip":"10.0.20.11","top":"google","apps":[{"name":"google","bytes":5000,"flows":2},{"name":"ntp","bytes":300,"flows":1}]}]\n'
MOCK

chmod +x "$MOCKBIN"/*

# Reverse-DNS cache, as the background resolver leaves it ("-" = cached miss).
RDNS="$TMPDIR/rdns_cache"
printf '10.0.20.11 nas.lan 1787166682\n10.0.20.99 - 1787166682\n' > "$RDNS"
sed -i.bak "s|rdnsfile=/tmp/trafficctl_rdns_cache|rdnsfile=$RDNS|" "$TMPDIR/metrics.sh"

run_metrics() { PATH="$MOCKBIN:$PATH" sh "$TMPDIR/metrics.sh" 2>/dev/null; }

# ── first scrape establishes the baseline ────────────────────────────────────
echo '[{"ip":"10.0.20.11","bytes_in":1000,"bytes_out":500}]' > "$BYTES_FILE"
OUT=$(run_metrics)
assert_contains "first scrape counts current totals" \
    'trafficctl_device_bytes_total{ip="10.0.20.11",direction="rx"} 1000' "$OUT"

# ── growth accumulates the delta, not the raw value twice ───────────────────
echo '[{"ip":"10.0.20.11","bytes_in":1500,"bytes_out":900}]' > "$BYTES_FILE"
OUT=$(run_metrics)
assert_contains "growth adds the delta" \
    'trafficctl_device_bytes_total{ip="10.0.20.11",direction="rx"} 1500' "$OUT"
assert_contains "tx tracked independently" \
    'trafficctl_device_bytes_total{ip="10.0.20.11",direction="tx"} 900' "$OUT"

# ── flows expiring must NOT rewind the counter ──────────────────────────────
# The raw sum collapses to 200; those bytes were already accumulated while the
# flows were alive, so the exported counter must hold, never drop.
echo '[{"ip":"10.0.20.11","bytes_in":200,"bytes_out":100}]' > "$BYTES_FILE"
OUT=$(run_metrics)
assert_contains "expiry does not rewind the counter" \
    'trafficctl_device_bytes_total{ip="10.0.20.11",direction="rx"} 1500' "$OUT"
assert_not_contains "counter never reports the collapsed raw sum" \
    'direction="rx"} 200' "$OUT"

# ── growth after an expiry resumes from the new baseline ────────────────────
echo '[{"ip":"10.0.20.11","bytes_in":700,"bytes_out":100}]' > "$BYTES_FILE"
OUT=$(run_metrics)
assert_contains "growth after expiry adds only the new delta" \
    'trafficctl_device_bytes_total{ip="10.0.20.11",direction="rx"} 2000' "$OUT"

# ── gauges and info ─────────────────────────────────────────────────────────
assert_contains "connections gauge" 'trafficctl_device_connections{ip="10.0.20.11"} 7' "$OUT"
assert_contains "blocked gauge" 'trafficctl_device_blocked{ip="10.0.20.11"} 1' "$OUT"
assert_contains "limiter gauge" 'trafficctl_device_limit_kbit{ip="10.0.20.11",mode="limiter"} 1000' "$OUT"
assert_contains "shaper gauge" 'trafficctl_device_limit_kbit{ip="10.0.20.11",mode="shaper"} 0' "$OUT"
assert_contains "info metric carries device metadata incl. reverse DNS" \
    'trafficctl_device_info{ip="10.0.20.11",name="Denis-NAS",mac="aa:bb:cc:dd:ee:ff",link="routed",app="google",rdns="nas.lan"} 1' "$OUT"

# Everything the app records should be exportable, not just bytes.
assert_contains "conntrack total gauge" 'trafficctl_device_conntrack_bytes{ip="10.0.20.11",proto="all"} 9000' "$OUT"
assert_contains "tcp/udp split exported" 'trafficctl_device_conntrack_bytes{ip="10.0.20.11",proto="tcp"} 7000' "$OUT"
assert_contains "udp split exported" 'trafficctl_device_conntrack_bytes{ip="10.0.20.11",proto="udp"} 2000' "$OUT"
assert_contains "bytes dropped by the block rule" 'trafficctl_device_blocked_bytes{ip="10.0.20.11"} 4242' "$OUT"
assert_contains "wifi block state" 'trafficctl_device_wifi_blocked{ip="10.0.20.11"} 0' "$OUT"

assert_contains "portfw connections" 'trafficctl_portfw_connections{name="Web",proto="tcp",port="8080"} 3' "$OUT"
assert_contains "portfw paused" 'trafficctl_portfw_paused{name="Web",proto="tcp",port="8080"} 1' "$OUT"
assert_contains "portfw rule enabled state" 'trafficctl_portfw_enabled{name="Web",proto="tcp",port="8080"} 1' "$OUT"
assert_contains "portfw inbound limit" 'trafficctl_portfw_limit_kbit{name="Web",proto="tcp",port="8080"} 5000' "$OUT"
assert_contains "portfw byte counters" 'trafficctl_portfw_bytes{name="Web",proto="tcp",port="8080",direction="rx"} 12345' "$OUT"

assert_contains "app metric emitted when enabled" 'trafficctl_app_bytes{ip="10.0.20.11",app="google"} 5000' "$OUT"
assert_contains "second app on the same device" 'trafficctl_app_bytes{ip="10.0.20.11",app="ntp"} 300' "$OUT"
assert_contains "per-app flow counts too" 'trafficctl_app_flows{ip="10.0.20.11",app="google"} 2' "$OUT"

# A counter built from frozen byte counters stalls, and on a dashboard that is
# indistinguishable from an idle device — so the condition is exported as its
# own gauge rather than left to be inferred from a flat rate().
assert_contains "degraded gauge is exported alongside the counter" \
    'trafficctl_device_bytes_degraded{ip="10.0.20.11"} 0' "$OUT"
echo '[{"ip":"10.0.20.11","bytes_in":900,"bytes_out":100,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct","degraded":true}]' > "$BYTES_FILE"
DEG_OUT=$(run_metrics)
assert_contains "degraded gauge goes high when the sampler flags it" \
    'trafficctl_device_bytes_degraded{ip="10.0.20.11"} 1' "$DEG_OUT"
assert_contains "the counter is still exported while degraded" \
    'trafficctl_device_bytes_total{ip="10.0.20.11",direction="rx"} ' "$DEG_OUT"

assert_contains "up metric" 'trafficctl_up 1' "$OUT"
assert_contains "counter is typed for prometheus" '# TYPE trafficctl_device_bytes_total counter' "$OUT"

# ── the state file must not grow without bound ──────────────────────────────
LINES=$(wc -l < "$STATE" | tr -d ' ')
assert_contains "state holds one line per device" "1" "$LINES"

# ── disabled by default ─────────────────────────────────────────────────────
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci"
OUT=$(run_metrics)
assert_contains "inert unless explicitly enabled" "metrics are disabled" "$OUT"
assert_not_contains "no data leaks while disabled" "trafficctl_device_bytes_total{" "$OUT"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
