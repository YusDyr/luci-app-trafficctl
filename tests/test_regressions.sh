#!/bin/bash
# Regression tests for 8 bugs fixed on this branch. Each test targets the REAL
# production script/function and is written to fail against the OLD (pre-fix)
# behavior — see the "would have failed before" comment on each section.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"
ROOT="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root"

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

# ════════════════════════════════════════════════════════════════════════════
# 1. log_file is constrained (path traversal / arbitrary root read+truncate)
# ════════════════════════════════════════════════════════════════════════════

uci() { echo ""; }
export -f uci
. "$BIN/trafficctl-fw.sh"

assert_eq "log_file: rejects /etc/shadow" 1 \
    "$(tctl_validate_log_file '/etc/shadow' && echo 0 || echo 1)"
assert_eq "log_file: rejects /etc/config/network" 1 \
    "$(tctl_validate_log_file '/etc/config/network' && echo 0 || echo 1)"
assert_eq "log_file: rejects traversal out of /tmp/trafficctl" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/../../etc/shadow' && echo 0 || echo 1)"
assert_eq "log_file: rejects trailing traversal" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/..' && echo 0 || echo 1)"
assert_eq "log_file: rejects shell metacharacters" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/x;rm -rf /' && echo 0 || echo 1)"
assert_eq "log_file: rejects glob metacharacters" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/*' && echo 0 || echo 1)"
assert_eq "log_file: rejects backtick" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/$(whoami)' && echo 0 || echo 1)"
assert_eq "log_file: accepts /tmp/trafficctl/activity.log" 0 \
    "$(tctl_validate_log_file '/tmp/trafficctl/activity.log' && echo 0 || echo 1)"
assert_eq "log_file: accepts /var/log/trafficctl.log" 0 \
    "$(tctl_validate_log_file '/var/log/trafficctl.log' && echo 0 || echo 1)"

# tctl_log_file falls back to the default when uci returns a rejected value.
_log_file_with() {
    (
        _val="$1"
        uci() { [ "$3" = "trafficctl.logging.log_file" ] && echo "$_val" || echo ""; }
        . "$BIN/trafficctl-fw.sh"
        tctl_log_file
    )
}
assert_eq "log_file: falls back to default for /etc/shadow" \
    "/tmp/trafficctl/activity.log" "$(_log_file_with '/etc/shadow')"
assert_eq "log_file: passes through a legitimate value" \
    "/var/log/trafficctl.log" "$(_log_file_with '/var/log/trafficctl.log')"

# logging_config_set, the rpcd method, refuses a bad log_file and a max_lines
# outside 20..100000 before it writes anything: tests/test_rpcd.sh, which runs
# the ucode plugin.

# ════════════════════════════════════════════════════════════════════════════
# 2. activity_log removed from the read ACL + general mutating/read invariant
# ════════════════════════════════════════════════════════════════════════════

ACL_FILE="$ROOT/usr/share/rpcd/acl.d/luci-app-trafficctl.json"

READ_METHODS=$(sed -n '/"read"/,/"write"/p' "$ACL_FILE" | sed -n '/"luci\.trafficctl"/,/\]/p')
WRITE_METHODS=$(sed -n '/"write"/,$p' "$ACL_FILE" | sed -n '/"luci\.trafficctl"/,/\]/p')

assert_not_contains "acl: activity_log is not in the read ACL" "activity_log" "$READ_METHODS"
assert_contains "acl: activity_log is in the write ACL" "activity_log" "$WRITE_METHODS"

# General invariant: every method the write ACL lists as mutating must be
# ABSENT from the read ACL. Anything present in both would be readable
# without the write grant. This catches a FUTURE regression too, not just
# activity_log specifically.
WRITE_LIST=$(printf '%s' "$WRITE_METHODS" | grep -oE '"[a-z_]+"' | tr -d '"' | grep -v '^luci\.trafficctl$')
OFFENDERS=""
for m in $WRITE_LIST; do
    if printf '%s' "$READ_METHODS" | grep -qE "\"$m\""; then
        OFFENDERS="$OFFENDERS $m"
    fi
done
assert_eq "acl: no mutating method also appears in the read ACL" "" "$OFFENDERS"

# 3. Shaper classids are allocated, not derived from the address, and 4.
# a foreign root qdisc (SQM's cake) is declined, never torn down:
# `trafficctl shape` since the ucode port, tests/test_shape.sh.

# 5. Rule removal is anchored, and 6. rule comments are derived from the
# target, not the caller's label: `trafficctl block`/`unblock` since the ucode
# port, tests/test_block.sh ("regressions").

# ════════════════════════════════════════════════════════════════════════════
# 7. Telegram bot token never appears in fake-curl argv (goes via stdin)
# ════════════════════════════════════════════════════════════════════════════
# (Covered end-to-end against tg_api/tg_send in test_security.sh; repeated
# here narrowly against trafficctl-telegram-test.sh's independent tg call
# path, which has its own curl invocation.)

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
echo "OpenWrt"
MOCK
CURL_ARGV="$TMPDIR/curl_argv2.log"
CURL_STDIN="$TMPDIR/curl_stdin2.log"
: > "$CURL_ARGV"; : > "$CURL_STDIN"
cat > "$MOCKBIN/curl" <<MOCK
#!/bin/sh
echo "\$*" >> "$CURL_ARGV"
cat >> "$CURL_STDIN"
echo '{"ok":true}'
MOCK
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
exit 1
MOCK
cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci" "$MOCKBIN/curl" "$MOCKBIN/jsonfilter" "$MOCKBIN/ip"

PATH="$MOCKBIN:$PATH" sh "$BIN/trafficctl-telegram-test.sh" "999999:SECRETTOKENVALUE" "12345" >/dev/null 2>&1
assert_not_contains "telegram-test.sh: bot token absent from curl argv" \
    "SECRETTOKENVALUE" "$(cat "$CURL_ARGV")"
assert_contains "telegram-test.sh: bot token present on curl's stdin (--config -)" \
    "SECRETTOKENVALUE" "$(cat "$CURL_STDIN")"

# ════════════════════════════════════════════════════════════════════════════

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
