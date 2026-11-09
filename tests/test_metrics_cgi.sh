#!/bin/bash
# Tests for root/www/cgi-bin/trafficctl-metrics — previously had NO test
# coverage at all. This is the Prometheus scrape endpoint reachable with NO
# LuCI session, so its enable-gate and token check are the entire attack
# surface. Runs the real cgi-bin script with uci faked and the downstream
# exporter (trafficctl-metrics.sh) stubbed.

PASS=0
FAIL=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files"
CGI="$ROOT/www/cgi-bin/trafficctl-metrics"

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
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

# The cgi-bin execs /usr/libexec/trafficctl/trafficctl-metrics.sh by absolute path on
# success; stub it so this test targets only the auth gate in the cgi-bin
# itself (the exporter has its own coverage in test_metrics.sh).
mkdir -p "$MOCKBIN/../usr/libexec/trafficctl"
STUB_METRICS="$MOCKBIN/trafficctl-metrics.sh"
cat > "$STUB_METRICS" <<'MOCK'
#!/bin/sh
echo "EXPORTER_RAN"
MOCK
chmod +x "$STUB_METRICS"

CGI_TEST="$TMPDIR/trafficctl-metrics"
sed "s|/usr/libexec/trafficctl/trafficctl-metrics.sh|$STUB_METRICS|" "$CGI" > "$CGI_TEST"
chmod +x "$CGI_TEST"

run_cgi() {
    local qs="$1"
    QUERY_STRING="$qs" PATH="$MOCKBIN:$PATH" sh "$CGI_TEST" 2>&1
}

# ── disabled by default ──────────────────────────────────────────────────────

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci"

OUT=$(run_cgi "")
assert_contains "disabled by default: 403 status line" "403 Forbidden" "$OUT"
assert_contains "disabled by default: explanatory body" "trafficctl metrics disabled" "$OUT"
assert_not_contains "disabled by default: exporter never runs" "EXPORTER_RAN" "$OUT"

# ── enabled, no token configured: open (no auth required) ──────────────────

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    trafficctl.metrics.enabled) echo "1" ;;
    trafficctl.metrics.token) echo "" ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/uci"

OUT=$(run_cgi "")
assert_contains "enabled, no token: exporter runs" "EXPORTER_RAN" "$OUT"
assert_contains "enabled, no token: correct content-type header" "text/plain" "$OUT"

# ── enabled with a token: correct token required ────────────────────────────

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    trafficctl.metrics.enabled) echo "1" ;;
    trafficctl.metrics.token) echo "supersecret123" ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/uci"

OUT=$(run_cgi "")
assert_contains "enabled with token, no query string: 403" "403 Forbidden" "$OUT"
assert_not_contains "enabled with token, no query string: exporter never runs" "EXPORTER_RAN" "$OUT"

OUT=$(run_cgi "token=wrongvalue")
assert_contains "enabled with token, wrong value: 403" "403 Forbidden" "$OUT"
assert_not_contains "enabled with token, wrong value: exporter never runs" "EXPORTER_RAN" "$OUT"

OUT=$(run_cgi "token=supersecret123")
assert_contains "enabled with token, correct value: exporter runs" "EXPORTER_RAN" "$OUT"

# The token check is anchored between & on both sides — a query string that
# merely CONTAINS the right token as a substring of a longer value (or with
# extra params) must not accidentally satisfy it via a loose substring match.
OUT=$(run_cgi "token=supersecret123extra")
assert_contains "token check is exact, not a prefix match" "403 Forbidden" "$OUT"
assert_not_contains "token check is exact, not a prefix match — exporter did not run" "EXPORTER_RAN" "$OUT"

OUT=$(run_cgi "other=1&token=supersecret123")
assert_contains "token check works when not the first query param" "EXPORTER_RAN" "$OUT"

OUT=$(run_cgi "token=supersecret123&other=1")
assert_contains "token check works when not the last query param" "EXPORTER_RAN" "$OUT"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
