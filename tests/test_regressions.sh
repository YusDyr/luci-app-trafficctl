#!/bin/bash
# Regression tests for 8 bugs fixed on this branch. Each test targets the REAL
# production script/function and is written to fail against the OLD (pre-fix)
# behavior — see the "would have failed before" comment on each section.

PASS=0
FAIL=0

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

# 1. log_file is constrained (path traversal / arbitrary root read+truncate):
# lib.valid_log_file, tests/test_ucode_lib.sh.
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

# No direct uci grant: no view reads or writes uci (everything goes through
# luci.trafficctl, which masks the bot token, the ntfy token and the webhook
# auth as ***). A read grant on trafficctl handed those secrets to any
# read-only user in clear text, one on wireless the WiFi keys; a write grant
# set options past the plugin's validation (log_file, max_lines).
assert_eq "acl: no uci access at all, read or write" "" \
    "$(jq -r '.[] | [.read.uci, .write.uci] | map(select(. != null)) | .[]' "$ACL_FILE")"
VIEWS="$(dirname "$ROOT")/htdocs/luci-static/resources/view/trafficctl"
assert_eq "acl: the views are where this looks" yes "$([ -f "$VIEWS/status.js" ] && echo yes)"
assert_eq "acl: and no view needs it (no uci module, no form.Map)" "" \
    "$(grep -lE "'require uci'|form\.Map|uci\.(load|get|set|sections)" "$VIEWS"/*.js 2>/dev/null)"

# 3. Shaper classids are allocated, not derived from the address, and 4.
# a foreign root qdisc (SQM's cake) is declined, never torn down:
# `trafficctl shape` since the ucode port, tests/test_shape.sh.

# 5. Rule removal is anchored, and 6. rule comments are derived from the
# target, not the caller's label: `trafficctl block`/`unblock` since the ucode
# port, tests/test_block.sh ("regressions").

# ════════════════════════════════════════════════════════════════════════════
# 7. telegram-test keeps the bot token out of curl's argv: tests/test_notify.sh
#    (the command is `trafficctl telegram-test` now).
# ════════════════════════════════════════════════════════════════════════════

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
