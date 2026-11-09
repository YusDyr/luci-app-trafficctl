#!/bin/bash
# Tests for device naming: manual aliases (trafficctl-names.sh) and the
# reverse-DNS cache refresher (trafficctl-rdns-refresh.sh).
# Mocks uci/nslookup/ubus as PATH executables and redirects the storage paths
# into a temp dir so nothing touches the host.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"
FWLIB="$BIN/trafficctl-fw.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected NOT to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}

# ── rewrite scripts to use temp paths ────────────────────────────────────────
NAMES_FILE="$TMPDIR/names"
CACHE_FILE="$TMPDIR/rdns_cache"

sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FWLIB|" \
    -e "s|NAMES_FILE=\"/etc/trafficctl/names\"|NAMES_FILE=\"$NAMES_FILE\"|" \
    "$BIN/trafficctl-names.sh" > "$TMPDIR/names.sh"

sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FWLIB|" \
    -e "s|CACHE=\"/tmp/trafficctl_rdns_cache\"|CACHE=\"$CACHE_FILE\"|" \
    -e "s|LOCK=\"/tmp/trafficctl_rdns.lock\"|LOCK=\"$TMPDIR/rdns.lock\"|" \
    "$BIN/trafficctl-rdns-refresh.sh" > "$TMPDIR/refresh.sh"

# ── mocks ────────────────────────────────────────────────────────────────────
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    trafficctl.main.rdns_server) echo "192.168.2.254" ;;
    *) exit 1 ;;
esac
MOCK

# Covers both BusyBox nslookup output shapes, an NXDOMAIN, and a resolver that
# echoes the reverse zone back instead of failing.
cat > "$MOCKBIN/nslookup" <<'MOCK'
#!/bin/sh
case "$1" in
    10.0.0.55) printf '55.0.0.10.in-addr.arpa\tname = denis-laptop.lan.\n' ;;
    10.0.0.66) printf 'Name:      office-nas\nAddress 1: 10.0.0.66\n' ;;
    10.0.0.88) printf '88.0.0.10.in-addr.arpa\tname = 88.0.0.10.in-addr.arpa.\n' ;;
    *) echo "nslookup: can't resolve '$1'"; exit 1 ;;
esac
MOCK

printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/ubus"
chmod +x "$MOCKBIN/uci" "$MOCKBIN/nslookup" "$MOCKBIN/ubus"

run_names()   { PATH="$MOCKBIN:$PATH" sh "$TMPDIR/names.sh" "$@" 2>/dev/null; }
run_refresh() { PATH="$MOCKBIN:$PATH" sh "$TMPDIR/refresh.sh" "$@" 2>/dev/null; }

# ── aliases ──────────────────────────────────────────────────────────────────

OUT=$(run_names set 10.0.0.55 "Denis Laptop")
assert_contains "set: ok" '"ok":true' "$OUT"

OUT=$(run_names list)
assert_contains "list: stored alias" '{"ip":"10.0.0.55","name":"Denis Laptop"}' "$OUT"

# Re-setting the same IP replaces rather than duplicating.
run_names set 10.0.0.55 "Denis Desktop" >/dev/null
OUT=$(run_names list)
assert_contains "set: replaces existing" '"name":"Denis Desktop"' "$OUT"
assert_not_contains "set: no duplicate entry" 'Denis Laptop' "$OUT"

run_names set 10.0.0.90 "Printer (HP)" >/dev/null
OUT=$(run_names list)
assert_contains "set: parentheses kept" '"name":"Printer (HP)"' "$OUT"

# Shell/JSON metacharacters must not survive into the file or the JSON.
run_names set 10.0.0.91 'evil"; rm -rf /; echo "' >/dev/null
OUT=$(run_names list)
assert_not_contains "sanitize: no quotes" '\"; rm' "$OUT"
assert_not_contains "sanitize: no slashes" 'rm -rf /' "$OUT"
OUT=$(python3 -c "import json,sys; json.loads(sys.stdin.read()); print('VALID')" <<< "$(run_names list)" 2>/dev/null)
assert_contains "list: valid JSON after injection attempt" "VALID" "$OUT"

OUT=$(run_names set 'bad;ip' "x")
assert_contains "set: invalid IP rejected" '"ok":false' "$OUT"

OUT=$(run_names set 10.0.0.92 '!!!')
assert_contains "set: name empty after sanitizing rejected" '"ok":false' "$OUT"

OUT=$(run_names remove 10.0.0.55)
assert_contains "remove: ok" '"ok":true' "$OUT"
OUT=$(run_names list)
assert_not_contains "remove: entry gone" '10.0.0.55' "$OUT"
assert_contains "remove: other entries kept" '10.0.0.90' "$OUT"

# ── reverse DNS cache ────────────────────────────────────────────────────────

run_refresh 10.0.0.55 10.0.0.66 10.0.0.77 10.0.0.88 'bad;ip'
CACHE=$(cat "$CACHE_FILE" 2>/dev/null)

assert_contains "rdns: 'name = host.lan.' form resolved to bare host" "10.0.0.55 denis-laptop" "$CACHE"
assert_contains "rdns: 'Name:' form resolved" "10.0.0.66 office-nas" "$CACHE"
assert_contains "rdns: NXDOMAIN cached negatively" "10.0.0.77 -" "$CACHE"
assert_contains "rdns: reverse-zone echo rejected" "10.0.0.88 -" "$CACHE"
assert_not_contains "rdns: arpa never stored as a name" "in-addr.arpa" "$CACHE"
assert_not_contains "rdns: invalid IP skipped" "bad;ip" "$CACHE"

# Re-running must refresh in place, not append duplicates.
run_refresh 10.0.0.55
COUNT=$(grep -c '^10\.0\.0\.55 ' "$CACHE_FILE")
assert_contains "rdns: entry refreshed in place" "1" "$COUNT"

# ── Results ──────────────────────────────────────────────────────────────────

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
