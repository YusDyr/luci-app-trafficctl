#!/bin/bash
# Tests for root/www/cgi-bin/trafficctl-metrics — previously had NO test
# coverage at all. This is the Prometheus scrape endpoint reachable with NO
# LuCI session, so its enable-gate and token check are the entire attack
# surface. Runs the real cgi-bin script with uci faked and the downstream
# exporter (`trafficctl metrics`) stubbed, then once end to end with the real
# CLI behind it.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PASS=0
FAIL=0

CGI="$UC_REPO/trafficctl/files/www/cgi-bin/trafficctl-metrics"

TMPDIR="$UC_TMP/cgi"
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

# The cgi-bin execs `/usr/sbin/trafficctl metrics` on success; stub the CLI so
# these cases target only the auth gate in the cgi-bin itself (the exporter
# has its own coverage in test_metrics.sh).
STUB_CLI="$MOCKBIN/trafficctl"
cat > "$STUB_CLI" <<'MOCK'
#!/bin/sh
echo "EXPORTER_RAN $*"
MOCK
chmod +x "$STUB_CLI"

CGI_TEST="$TMPDIR/trafficctl-metrics"
sed "s|exec /usr/sbin/trafficctl metrics|exec $STUB_CLI metrics|" "$CGI" > "$CGI_TEST"
chmod +x "$CGI_TEST"
# sed exits 0 when nothing matched: a changed exec line would leave the gate
# tests running the router's path while still passing.
grep -qF "exec $STUB_CLI metrics" "$CGI_TEST" ||
    { echo "FAIL: the cgi-bin was not redirected to the stub CLI"; exit 1; }

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

# ── enabled, no token configured: refused ──────────────────────────────────
# The shipped config has an empty token. Reading that as "no auth" made
# enabling metrics publish every device name and MAC to anyone on the network.

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
assert_contains "enabled, no token: 403" "403 Forbidden" "$OUT"
assert_contains "enabled, no token: says how to set one" "uci set trafficctl.metrics.token" "$OUT"
assert_not_contains "enabled, no token: exporter never runs" "EXPORTER_RAN" "$OUT"
OUT=$(run_cgi "token=")
assert_contains "enabled, no token: an empty ?token= does not match it" "403 Forbidden" "$OUT"
assert_not_contains "enabled, no token: exporter never runs for ?token=" "EXPORTER_RAN" "$OUT"

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
assert_contains "enabled with token, correct value: it is the metrics command" "EXPORTER_RAN metrics" "$OUT"
assert_contains "enabled with token, correct value: correct content-type header" "text/plain; version=0.0.4" "$OUT"

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

# ── end to end: the real CLI behind the gate ───────────────────────────────
# The headers, a blank line, then the exporter's own document.
E2E_ROOT="$TMPDIR/root"
mkdir -p "$E2E_ROOT/etc/config" "$E2E_ROOT/tmp/.uci" "$E2E_ROOT/proc/net"
: > "$E2E_ROOT/proc/net/nf_conntrack"
printf "config metrics 'metrics'\n\toption enabled '1'\n\toption state '0'\n\toption portfw '0'\n" \
    > "$E2E_ROOT/etc/config/trafficctl"
cat > "$TMPDIR/cli" <<EOF
#!/bin/sh
TCTL_ROOT="$E2E_ROOT" exec "$UCODE" -S -L "$UC_LIB" -- "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" "\$@"
EOF
chmod +x "$TMPDIR/cli"
CGI_E2E="$TMPDIR/trafficctl-metrics-e2e"
sed "s|exec /usr/sbin/trafficctl metrics|exec $TMPDIR/cli metrics|" "$CGI" > "$CGI_E2E"
OUT=$(QUERY_STRING="token=supersecret123" PATH="$MOCKBIN:$PATH" sh "$CGI_E2E" 2>&1)
assert_eq "end to end: headers, blank line, the document" \
    "Content-Type: text/plain; version=0.0.4; charset=utf-8" "$(printf '%s\n' "$OUT" | head -1 | tr -d '\r')"
assert_eq "end to end: the header block ends in an empty line" "" "$(printf '%s\n' "$OUT" | sed -n 2p | tr -d '\r')"
assert_contains "end to end: the exporter ran" "trafficctl_up 1" "$OUT"
assert_contains "end to end: the byte families are there" "# TYPE trafficctl_device_bytes_total counter" "$OUT"
OUT=$(QUERY_STRING="token=nope" PATH="$MOCKBIN:$PATH" sh "$CGI_E2E" 2>&1)
assert_not_contains "end to end: a wrong token never reaches the CLI" "trafficctl_up" "$OUT"

# An exporter that fails after the CGI sent its Content-Type: the CLI's JSON
# error object would make the scrape unparseable, so the body stays empty
# (no trafficctl_up: the exporter did not run) and the error goes to stderr.
BROKEN="$TMPDIR/broken"
mkdir -p "$BROKEN/trafficctl"
cp "$UC_LIB"/trafficctl/*.uc "$BROKEN/trafficctl/"
sed 's|^function metrics(src) {$|&\n\tdie("uci: cannot read trafficctl");|' "$UC_LIB/trafficctl/report.uc" \
    > "$BROKEN/trafficctl/report.uc"
grep -q 'cannot read trafficctl' "$BROKEN/trafficctl/report.uc" || { echo "FAIL: the exporter was not broken"; exit 1; }
cat > "$TMPDIR/cli" <<EOF
#!/bin/sh
TCTL_ROOT="$E2E_ROOT" exec "$UCODE" -S -L "$BROKEN" -- "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" "\$@"
EOF
OUT=$(QUERY_STRING="token=supersecret123" PATH="$MOCKBIN:$PATH" sh "$CGI_E2E" 2>"$TMPDIR/cgi.err")
assert_eq "exporter error: the headers, then an empty body" \
    "Content-Type: text/plain; version=0.0.4; charset=utf-8" "$(printf '%s\n' "$OUT" | tr -d '\r' | grep .)"
assert_not_contains "exporter error: no JSON in the scrape" '"ok":false' "$OUT"
assert_contains "exporter error: said on stderr" "cannot read trafficctl" "$(cat "$TMPDIR/cgi.err")"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
