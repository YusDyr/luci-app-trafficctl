#!/bin/bash
# Tests for the Prometheus exporter (`trafficctl metrics`, trafficctl.report).
# Feeds recorded byte samples and source output through it and checks the
# accumulator's monotonicity rules, which are the part that cannot simply be
# eyeballed: raw conntrack sums drop when flows expire, so exporting them
# directly would look like a counter reset on every expiry.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PASS=0
FAIL=0

TMPDIR="$UC_TMP/metrics"
ROOT="$TMPDIR/root"
mkdir -p "$ROOT/etc/config" "$ROOT/tmp/.uci"
STATE="$ROOT/tmp/trafficctl_totals.state"

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

# The accumulator is deliberately NOT mocked: it is the whole point of these
# monotonicity assertions, so net.totals runs for real (tests/lib/metrics.uc)
# on a recorded byte sample. The summary, port forwards and DPI apps are
# recorded output.
BYTES_FILE="$TMPDIR/bytes.json"
metrics_config() {   # metrics_config <option value>...: the metrics section
    {
        printf "config metrics 'metrics'\n"
        while [ $# -gt 1 ]; do printf "\toption %s '%s'\n" "$1" "$2"; shift 2; done
    } > "$ROOT/etc/config/trafficctl"
}
# Exporter enabled, apps enabled so the cardinality guard is exercised.
metrics_config enabled 1 apps 1

printf '[{"ip":"10.0.20.11","name":"Denis-NAS","mac":"aa:bb:cc:dd:ee:ff","conn_type":"routed","app":"google","conns":7,"total":9000,"tcp":7000,"udp":2000,"blocked":true,"block_bytes":4242,"wifi_blocked":false,"rate_limit_kbit":1000,"rate_limit_kbit_up":250,"shape_kbit":0,"shape_kbit_up":0}]\n' \
    > "$TMPDIR/summary.json"
printf '[{"id":"r0","kind":"forward","name":"Web","proto":"tcp","ext_port":"8080","enabled":true,"paused":true,"limit_kbit":5000,"conns":3,"clients":2,"bytes_in":12345,"bytes_out":678}]\n' \
    > "$TMPDIR/portfw.json"
printf '[{"ip":"10.0.20.11","top":"google","apps":[{"name":"google","bytes":5000,"flows":2},{"name":"ntp","bytes":300,"flows":1}]}]\n' \
    > "$TMPDIR/netify.json"

# Reverse-DNS cache, as the background resolver leaves it ("-" = cached miss).
printf '10.0.20.11 nas.lan 1787166682\n10.0.20.99 - 1787166682\n' > "$ROOT/tmp/trafficctl_rdns_cache"

run_metrics() {
    TCTL_ROOT="$ROOT" "$UCODE" -S -L "$UC_LIB" -- "$UC_TESTLIB/metrics.uc" "$BYTES_FILE" "$TMPDIR" 2>/dev/null
}

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
assert_contains "limiter upload gauge (split ceiling)" 'trafficctl_device_limit_up_kbit{ip="10.0.20.11",mode="limiter"} 250' "$OUT"
assert_contains "shaper upload gauge" 'trafficctl_device_limit_up_kbit{ip="10.0.20.11",mode="shaper"} 0' "$OUT"
assert_contains "the download gauge did not pick up the upload field" 'trafficctl_device_limit_kbit{ip="10.0.20.11",mode="limiter"} 1000' "$OUT"
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

# ── the layout: section and line order ──────────────────────────────────────
# tests/equiv.sh compares the lines as a set (the shell exporter listed
# devices in awk hash order), so the order of the families is pinned here:
# H/T = HELP/TYPE, S = a sample, by metric name.
kinds() { awk '$1 == "#" { print substr($2, 1, 1), $3; next } { sub(/[{ ].*/, ""); print "S", $0 }'; }
EXPECTED_KINDS='H trafficctl_device_bytes_total
T trafficctl_device_bytes_total
H trafficctl_device_bytes_degraded
T trafficctl_device_bytes_degraded
S trafficctl_device_bytes_total
S trafficctl_device_bytes_total
S trafficctl_device_bytes_degraded
H trafficctl_device_connections
T trafficctl_device_connections
H trafficctl_device_blocked
T trafficctl_device_blocked
H trafficctl_device_limit_kbit
T trafficctl_device_limit_kbit
H trafficctl_device_limit_up_kbit
T trafficctl_device_limit_up_kbit
H trafficctl_device_wifi_blocked
T trafficctl_device_wifi_blocked
H trafficctl_device_conntrack_bytes
T trafficctl_device_conntrack_bytes
H trafficctl_device_blocked_bytes
T trafficctl_device_blocked_bytes
H trafficctl_device_info
T trafficctl_device_info
S trafficctl_device_connections
S trafficctl_device_blocked
S trafficctl_device_wifi_blocked
S trafficctl_device_limit_kbit
S trafficctl_device_limit_kbit
S trafficctl_device_limit_up_kbit
S trafficctl_device_limit_up_kbit
S trafficctl_device_conntrack_bytes
S trafficctl_device_conntrack_bytes
S trafficctl_device_conntrack_bytes
S trafficctl_device_blocked_bytes
S trafficctl_device_info
H trafficctl_portfw_connections
T trafficctl_portfw_connections
H trafficctl_portfw_clients
T trafficctl_portfw_clients
H trafficctl_portfw_paused
T trafficctl_portfw_paused
H trafficctl_portfw_enabled
T trafficctl_portfw_enabled
H trafficctl_portfw_limit_kbit
T trafficctl_portfw_limit_kbit
H trafficctl_portfw_bytes
T trafficctl_portfw_bytes
S trafficctl_portfw_connections
S trafficctl_portfw_clients
S trafficctl_portfw_paused
S trafficctl_portfw_enabled
S trafficctl_portfw_limit_kbit
S trafficctl_portfw_bytes
S trafficctl_portfw_bytes
H trafficctl_app_bytes
T trafficctl_app_bytes
S trafficctl_app_bytes
S trafficctl_app_flows
S trafficctl_app_bytes
S trafficctl_app_flows
H trafficctl_up
T trafficctl_up
S trafficctl_up'
GOT_KINDS=$(printf '%s\n' "$OUT" | kinds)
if [ "$GOT_KINDS" = "$EXPECTED_KINDS" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    echo "FAIL: the families are not in the exporter's order"
    diff <(printf '%s\n' "$EXPECTED_KINDS") <(printf '%s\n' "$GOT_KINDS")
fi
assert_contains "the output ends in a newline" "trafficctl_up 1
" "$OUT
"

# ── the optional families ───────────────────────────────────────────────────
metrics_config enabled 1 state 0 portfw 0
OUT=$(run_metrics)
assert_contains "the byte counters do not depend on the state option" \
    'trafficctl_device_bytes_total{ip="10.0.20.11",direction="rx"} ' "$OUT"
assert_not_contains "state 0 drops the per-device gauges" "trafficctl_device_connections" "$OUT"
assert_not_contains "state 0 drops the info metric" "trafficctl_device_info" "$OUT"
assert_not_contains "portfw 0 drops the port-forward families" "trafficctl_portfw_" "$OUT"
assert_not_contains "apps are off unless asked for" "trafficctl_app_" "$OUT"
assert_contains "the up metric is always last" "trafficctl_up 1" "$OUT"

# A source that printed nothing (portfw failed, no DPI cache) leaves the
# HELP lines and no samples, never a broken document.
metrics_config enabled 1 apps 1
mv "$TMPDIR/portfw.json" "$TMPDIR/portfw.json.off"
printf '' > "$TMPDIR/netify.json"
OUT=$(run_metrics)
assert_contains "a silent source keeps its HELP line" "# TYPE trafficctl_portfw_bytes gauge" "$OUT"
assert_not_contains "a silent source has no samples" "trafficctl_portfw_connections{" "$OUT"
assert_contains "the exporter still completes" "trafficctl_up 1" "$OUT"

# An app record without a flow count still exports its bytes.
printf '[{"ip":"10.0.20.11","top":"x","apps":[{"name":"x","bytes":7}]}]\n' > "$TMPDIR/netify.json"
OUT=$(run_metrics)
assert_contains "app bytes without flows" 'trafficctl_app_bytes{ip="10.0.20.11",app="x"} 7' "$OUT"
assert_not_contains "no flow line without a flow count" 'trafficctl_app_flows{ip="10.0.20.11",app="x"}' "$OUT"

# ── disabled by default ─────────────────────────────────────────────────────
: > "$ROOT/etc/config/trafficctl"
OUT=$(run_metrics)
assert_contains "inert unless explicitly enabled" "metrics are disabled" "$OUT"
assert_not_contains "no data leaks while disabled" "trafficctl_device_bytes_total{" "$OUT"
metrics_config enabled 0
OUT=$(run_metrics)
assert_contains "enabled 0 is disabled too" "metrics are disabled" "$OUT"

# ── the CLI ─────────────────────────────────────────────────────────────────
metrics_config enabled 0
OUT=$(TCTL_ROOT="$ROOT" tctl metrics)
assert_contains "trafficctl metrics runs the exporter" "metrics are disabled" "$OUT"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
