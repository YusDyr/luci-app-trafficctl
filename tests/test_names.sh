#!/bin/bash
# Tests for device naming: manual aliases (`trafficctl names`) and the
# reverse-DNS cache (`trafficctl rdns`, `trafficctl rdns-refresh`).
# Runs the ucode CLI against a scratch TCTL_ROOT; nslookup is a PATH mock,
# network.rrdns comes from tests/lib/ubus-mock.uc.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PASS=0
FAIL=0

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

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected NOT to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}

export TCTL_ROOT="$UC_TMP/root"
mkdir -p "$TCTL_ROOT/etc/config" "$TCTL_ROOT/tmp/.uci"
cat > "$TCTL_ROOT/etc/config/trafficctl" <<'EOF'
config trafficctl 'main'
	option rdns_server '192.168.2.254'
EOF
NAMES_FILE="$TCTL_ROOT/etc/trafficctl/names"
CACHE_FILE="$TCTL_ROOT/tmp/trafficctl_rdns_cache"
# No ubusd at this path: rrdns fails the way it does without the daemon.
export TCTL_UBUS_SOCKET="$UC_TMP/no-ubus.sock"

# ── mocks ────────────────────────────────────────────────────────────────────
MOCKBIN="$UC_TMP/bin"
mkdir -p "$MOCKBIN"
# Both BusyBox output shapes, an NXDOMAIN, a resolver that echoes the reverse
# zone back instead of failing, and one that never answers.
cat > "$MOCKBIN/nslookup" <<MOCK
#!/bin/sh
echo "\$*" >> "$UC_TMP/nslookup.log"
case "\$1" in
    10.0.0.55) printf '55.0.0.10.in-addr.arpa\tname = denis-laptop.lan.\n' ;;
    10.0.0.66) printf 'Name:      office-nas\nAddress 1: 10.0.0.66\n' ;;
    10.0.0.88) printf '88.0.0.10.in-addr.arpa\tname = 88.0.0.10.in-addr.arpa.\n' ;;
    10.0.0.44) exec sleep 30 ;;
    *) echo "nslookup: can't resolve '\$1'"; exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/nslookup"
export PATH="$MOCKBIN:$PATH"

# ── aliases ──────────────────────────────────────────────────────────────────

assert_eq "list: no file is an empty array" "[]" "$(tctl names list)"

OUT=$(tctl names set 10.0.0.55 "Denis Laptop")
assert_eq "set: legacy reply" '{"ok":true,"msg":"named 10.0.0.55 as Denis Laptop"}' "$OUT"

OUT=$(tctl names list)
assert_contains "list: stored alias" '{"ip":"10.0.0.55","name":"Denis Laptop"}' "$OUT"
assert_eq "store: 'IP NAME' lines" "10.0.0.55 Denis Laptop" "$(cat "$NAMES_FILE")"

# Re-setting the same IP replaces rather than duplicating.
tctl names set 10.0.0.55 "Denis Desktop" >/dev/null
OUT=$(tctl names list)
assert_contains "set: replaces existing" '"name":"Denis Desktop"' "$OUT"
assert_not_contains "set: no duplicate entry" 'Denis Laptop' "$OUT"

tctl names set 10.0.0.90 "Printer (HP)" >/dev/null
OUT=$(tctl names list)
assert_contains "set: parentheses kept" '"name":"Printer (HP)"' "$OUT"

# Shell/JSON metacharacters must not survive into the file or the JSON.
tctl names set 10.0.0.91 'evil"; rm -rf /; echo "' >/dev/null
OUT=$(tctl names list)
assert_not_contains "sanitize: no quotes" '\"; rm' "$OUT"
assert_not_contains "sanitize: no slashes" 'rm -rf /' "$OUT"
OUT=$(python3 -c "import json,sys; json.loads(sys.stdin.read()); print('VALID')" <<< "$(tctl names list)" 2>/dev/null)
assert_contains "list: valid JSON after injection attempt" "VALID" "$OUT"

tctl names set 10.0.0.93 "$(printf 'a%.0s' $(seq 40))" >/dev/null
assert_contains "sanitize: cut to 32 characters" "10.0.0.93 $(printf 'a%.0s' $(seq 32))" "$(cat "$NAMES_FILE")"
assert_not_contains "sanitize: nothing past 32" "$(printf 'a%.0s' $(seq 33))" "$(cat "$NAMES_FILE")"

OUT=$(tctl names set 'bad;ip' "x"); RC=$?
assert_eq "set: invalid IP rejected" '{"ok":false,"msg":"invalid IP address"}' "$OUT"
assert_eq "set: invalid IP exits 1" "1" "$RC"

OUT=$(tctl names set 10.0.0.92 '!!!')
assert_eq "set: name empty after sanitizing rejected" '{"ok":false,"msg":"name is empty after sanitizing"}' "$OUT"

OUT=$(tctl names remove 10.0.0.55)
assert_eq "remove: legacy reply" '{"ok":true,"msg":"name cleared for 10.0.0.55"}' "$OUT"
OUT=$(tctl names list)
assert_not_contains "remove: entry gone" '10.0.0.55' "$OUT"
assert_contains "remove: other entries kept" '10.0.0.90' "$OUT"

tctl names bogus >/dev/null; RC=$?
assert_eq "names: unknown subcommand exits 1" "1" "$RC"

mv "$NAMES_FILE" "$UC_TMP/names.bak"
assert_eq "remove: nothing stored" '{"ok":true,"msg":"no aliases stored"}' "$(tctl names remove 10.0.0.90)"
mv "$UC_TMP/names.bak" "$NAMES_FILE"

# A stored line the CLI did not write (hand edit, older release).
printf '10.0.0.70  two  spaces\n10.0.0.71\n' >> "$NAMES_FILE"
OUT=$(tctl names list)
assert_contains "list: name keeps inner spacing, leading run dropped" '{"ip":"10.0.0.70","name":"two  spaces"}' "$OUT"
assert_not_contains "list: a line with no name is skipped" '10.0.0.71' "$OUT"

# ── one-shot lookup ──────────────────────────────────────────────────────────

assert_eq "rdns: nslookup fallback" '{"ip":"10.0.0.55","host":"denis-laptop.lan"}' "$(tctl rdns 10.0.0.55)"
OUT=$(tctl rdns); RC=$?
assert_eq "rdns: no argument" '{"ip":"","host":""}' "$OUT"
assert_eq "rdns: no argument exits 1" "1" "$RC"
OUT=$(tctl rdns 'x"y'); RC=$?
assert_eq "rdns: invalid IP is still valid JSON" '{"ip":"x\"y","host":""}' "$OUT"
assert_eq "rdns: invalid IP exits 1" "1" "$RC"

mkdir -p "$UC_TMP/ubus"
printf '{"10.0.0.66":"tv.lan"}\n' > "$UC_TMP/ubus/network.rrdns@lookup.json"
unset TCTL_UBUS_SOCKET
ubus_start "$UC_TMP/ubus"
assert_eq "rdns: network.rrdns answers first" '{"ip":"10.0.0.66","host":"tv.lan"}' "$(tctl rdns 10.0.0.66)"
ubus_stop
export TCTL_UBUS_SOCKET="$UC_TMP/no-ubus.sock"

# ── reverse DNS cache ────────────────────────────────────────────────────────

: > "$UC_TMP/nslookup.log"
tctl rdns-refresh 10.0.0.55 10.0.0.66 10.0.0.77 10.0.0.88 'bad;ip'
CACHE=$(cat "$CACHE_FILE" 2>/dev/null)

assert_contains "rdns: 'name = host.lan.' form resolved to bare host" "10.0.0.55 denis-laptop" "$CACHE"
assert_contains "rdns: 'Name:' form resolved" "10.0.0.66 office-nas" "$CACHE"
assert_contains "rdns: NXDOMAIN cached negatively" "10.0.0.77 -" "$CACHE"
assert_contains "rdns: reverse-zone echo rejected" "10.0.0.88 -" "$CACHE"
assert_not_contains "rdns: arpa never stored as a name" "in-addr.arpa" "$CACHE"
assert_not_contains "rdns: invalid IP skipped" "bad;ip" "$CACHE"
assert_contains "rdns: configured server asked first" "10.0.0.55 192.168.2.254" "$(head -1 "$UC_TMP/nslookup.log")"
assert_eq "rdns: 'IP HOST TS', space separated" "1" \
    "$(grep -cE '^10\.0\.0\.55 denis-laptop [0-9]+$' "$CACHE_FILE")"

# Re-running must refresh in place, not append duplicates.
tctl rdns-refresh 10.0.0.55
assert_eq "rdns: entry refreshed in place" "1" "$(grep -c '^10\.0\.0\.55 ' "$CACHE_FILE")"
assert_eq "rdns: lock released" "no" "$([ -d "$TCTL_ROOT/tmp/trafficctl_rdns.lock" ] && echo yes || echo no)"

# A refresher already running: this one leaves at once.
mkdir "$TCTL_ROOT/tmp/trafficctl_rdns.lock"
tctl rdns-refresh 10.0.0.99
assert_not_contains "rdns: a held lock is respected" "10.0.0.99" "$(cat "$CACHE_FILE")"
# One left behind by a killed refresher is taken over after 300 s.
touch -d '@'"$(( $(date +%s) - 400 ))" "$TCTL_ROOT/tmp/trafficctl_rdns.lock"
tctl rdns-refresh 10.0.0.99
assert_contains "rdns: a stale lock is stolen" "10.0.0.99 -" "$(cat "$CACHE_FILE")"

# A resolver that hangs is killed, so the lock cannot be held forever.
START=$(date +%s)
tctl rdns-refresh 10.0.0.44
assert_eq "rdns: a hung nslookup is cut off" "yes" "$([ $(( $(date +%s) - START )) -lt 25 ] && echo yes || echo no)"
assert_contains "rdns: and cached negatively" "10.0.0.44 -" "$(cat "$CACHE_FILE")"

# ── Results ──────────────────────────────────────────────────────────────────

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
