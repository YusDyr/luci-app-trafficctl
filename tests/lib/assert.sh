#!/bin/sh
# shellcheck shell=sh
# Shared assertions for tests/test_*.sh. Source it near the top, before any
# cd. It is POSIX sh, because tests/test_build_ipk.sh also runs under dash:
#
#   # shellcheck source=tests/lib/assert.sh
#   . "$(dirname "$0")/lib/assert.sh"
#
# It sets PASS=0 and FAIL=0 and defines:
#   assert_eq <desc> <expected> <actual>
#   assert_contains <desc> <needle> <haystack>       fixed string (grep -F)
#   assert_not_contains <desc> <needle> <haystack>
#   summary     prints "<n> passed, <m> failed", then exits: 1 on any failure,
#               0 otherwise. The last line of a test.
#
# A test that sets CTX gets "[$CTX] " in front of each failure, to tell the
# rounds of a loop apart. A test that needs another failure text defines its
# own assert_* after the source line, which replaces the shared one.

PASS=0
FAIL=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s%s\n  expected: '%s'\n  actual:   '%s'\n" "${CTX:+[$CTX] }" "$1" "$2" "$3"
    fi
}

assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s%s\n  expected to find: '%s'\n  in:\n%s\n" "${CTX:+[$CTX] }" "$1" "$2" "$3"
    fi
}

assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s%s\n  should NOT contain: '%s'\n  in:\n%s\n" "${CTX:+[$CTX] }" "$1" "$2" "$3"
    else
        PASS=$((PASS + 1))
    fi
}

summary() {
    printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
}
