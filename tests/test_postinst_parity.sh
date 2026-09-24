#!/bin/bash
# The three package builders must agree on what happens after installation.
#
# There are three of them — the OpenWrt Makefile (used by the SDK, i.e. what
# builds the RELEASED packages), build-ipk.sh and build-apk.sh (used locally) —
# and they carry three separate copies of the postinst script. They drifted:
# both local builders restarted rpcd, the Makefile did not.
#
# That drift was invisible in every test and in every local install, because
# the local builders were correct. It only reached users installing the
# published artifacts, where rpcd never learned about the plugin and every ubus
# call returned "Object not found" (-32000) until the router was rebooted.
# Reported on 2026-09-24 against OpenWrt 25.12.5, and almost certainly behind
# earlier installation complaints too.
#
# So this file does not test "the Makefile restarts rpcd" — it tests that the
# three copies agree, which is the property that actually broke.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAKEFILE="$REPO_ROOT/luci-app-trafficctl/Makefile"
IPK="$REPO_ROOT/build-ipk.sh"
APK="$REPO_ROOT/build-apk.sh"

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n" "$desc" "$needle"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

for f in "$MAKEFILE" "$IPK" "$APK"; do
    assert_eq "builder exists: $(basename "$f")" "yes" "$([ -f "$f" ] && echo yes || echo no)"
done

# The Makefile's postinst, from `define ... postinst` to its `endef`.
MK_POSTINST=$(awk '
    /^define Package\/\$\(PKG_NAME\)\/postinst/ { f = 1; next }
    f && /^endef/ { exit }
    f { print }
' "$MAKEFILE")

assert_eq "the Makefile actually defines a postinst" "yes" \
    "$([ -n "$MK_POSTINST" ] && echo yes || echo no)"

# ── The three behaviours a postinst has to carry ───────────────────────────

# 1. rpcd restart. Without it the plugin is installed but unregistered, and the
#    whole app is dead until a reboot.
assert_contains "Makefile postinst restarts rpcd" \
    "/etc/init.d/rpcd restart" "$MK_POSTINST"
assert_contains "build-ipk.sh postinst restarts rpcd" \
    "/etc/init.d/rpcd restart" "$(cat "$IPK")"
assert_contains "build-apk.sh postinst restarts rpcd" \
    "/etc/init.d/rpcd restart" "$(cat "$APK")"

# 2. The restart must be skipped for an offline install into an image root:
#    there is no running rpcd there, and calling its init script reaches for
#    the build host's.
assert_contains "Makefile guards the restart on IPKG_INSTROOT" \
    'if [ -z "$${IPKG_INSTROOT}" ]; then' "$MK_POSTINST"
assert_contains "build-ipk.sh guards the restart on IPKG_INSTROOT" \
    'if [ -z "${IPKG_INSTROOT}" ]; then' "$(cat "$IPK")"

# 3. The config carries the Telegram and metrics tokens, so its mode is
#    tightened before anything can read it.
assert_contains "Makefile postinst tightens the config mode" \
    'chmod 0600' "$MK_POSTINST"
assert_contains "build-ipk.sh postinst tightens the config mode" \
    'chmod 0600' "$(cat "$IPK")"
assert_contains "build-apk.sh postinst tightens the config mode" \
    'chmod 0600' "$(cat "$APK")"

# 4. A Telegram bot that was running before the upgrade comes back without a
#    reboot. Same drift, lower stakes.
assert_contains "Makefile postinst starts the telegram service when present" \
    "/etc/init.d/trafficctl-telegram start" "$MK_POSTINST"
assert_contains "build-ipk.sh postinst starts the telegram service when present" \
    "/etc/init.d/trafficctl-telegram start" "$(cat "$IPK")"

# ── Syntax ────────────────────────────────────────────────────────────────
# The postinst runs under the router's ash. A syntax error there fails the
# install on the device, where it is least convenient to debug.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$MK_POSTINST" | sed 's/\$\$/$/g' > "$TMP/postinst.sh"

SHELL_CMD=""
for candidate in dash ash busybox sh; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if [ "$candidate" = "busybox" ]; then
            busybox ash -c 'exit 0' >/dev/null 2>&1 && SHELL_CMD="busybox ash"
        else
            SHELL_CMD="$candidate"
        fi
        [ -n "$SHELL_CMD" ] && break
    fi
done

if [ -n "$SHELL_CMD" ]; then
    # shellcheck disable=SC2086 # SHELL_CMD may be "busybox ash", intentionally split
    if $SHELL_CMD -n "$TMP/postinst.sh" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: the Makefile postinst is not valid POSIX shell (%s -n)\n" "$SHELL_CMD"
        # shellcheck disable=SC2086
        $SHELL_CMD -n "$TMP/postinst.sh"
    fi
else
    echo "NOTE: no POSIX shell found to syntax-check the postinst with."
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
