#!/bin/bash
# The three package builders must agree on what happens after installation.
#
# There are three of them — the OpenWrt Makefiles (used by the SDK, i.e. what
# builds the RELEASED packages), build-ipk.sh and build-apk.sh (used locally) —
# and they carry separate copies of every install script. They drifted: both
# local builders restarted rpcd, the Makefile did not.
#
# That drift was invisible in every test and in every local install, because
# the local builders were correct. It only reached users installing the
# published artifacts, where rpcd never learned about the plugin and every ubus
# call returned "Object not found" (-32000) until the router was rebooted.
# Reported on 2026-09-24 against OpenWrt 25.12.5, and almost certainly behind
# earlier installation complaints too.
#
# So this file does not test "the Makefile restarts rpcd" — it tests that the
# copies agree, which is the property that actually broke. There are two
# packages: trafficctl (the backend: config, services, helpers) and
# luci-app-trafficctl (the web interface: rpcd plugin, views). Each script is
# compared with the copy for the SAME package, so a step that moves to the
# wrong package fails here too.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BE_MAKEFILE="$REPO_ROOT/trafficctl/Makefile"
FE_MAKEFILE="$REPO_ROOT/luci-app-trafficctl/Makefile"
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

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  did not expect: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
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

assert_nonempty() {
    assert_eq "$1" "yes" "$([ -n "$2" ] && echo yes || echo no)"
}

for f in "$BE_MAKEFILE" "$FE_MAKEFILE" "$IPK" "$APK"; do
    assert_eq "builder exists: ${f#"$REPO_ROOT"/}" "yes" "$([ -f "$f" ] && echo yes || echo no)"
done

# A Makefile section: from `define <name>` to its `endef`.
mk_section() {
    awk -v want="define $2" '
        $0 == want { f = 1; next }
        f && /^endef/ { exit }
        f { print }
    ' "$1"
}

# A script a builder writes with a quoted here-document: the lines between
# `cat > "<target>" <<'TAG'` and `TAG`.
heredoc() {
    awk -v want="cat > \"$2\" <<'" '
        index($0, want) == 1 { tag = substr($0, length(want) + 1); sub(/'"'"'.*/, "", tag); f = 1; next }
        f && $0 == tag { exit }
        f { print }
    ' "$1"
}

BE_MK_POSTINST=$(mk_section "$BE_MAKEFILE" 'Package/trafficctl/postinst')
BE_MK_PRERM=$(mk_section "$BE_MAKEFILE" 'Package/trafficctl/prerm')
FE_MK_POSTINST=$(mk_section "$FE_MAKEFILE" 'Package/$(PKG_NAME)/postinst')
FE_MK_PRERM=$(mk_section "$FE_MAKEFILE" 'Package/$(PKG_NAME)/prerm')
BE_IPK_POSTINST=$(heredoc "$IPK" '$BE_CTRL/postinst')
BE_IPK_PRERM=$(heredoc "$IPK" '$BE_CTRL/prerm')
FE_IPK_POSTINST=$(heredoc "$IPK" '$CTRL/postinst')
BE_APK_POSTINST=$(heredoc "$APK" '$BE_SCRIPTS/post-install')
BE_APK_PREDEL=$(heredoc "$APK" '$BE_SCRIPTS/pre-deinstall')
FE_APK_POSTINST=$(heredoc "$APK" '$SCRIPTS/post-install')

assert_nonempty "trafficctl/Makefile defines a postinst" "$BE_MK_POSTINST"
assert_nonempty "trafficctl/Makefile defines a prerm" "$BE_MK_PRERM"
assert_nonempty "luci-app-trafficctl/Makefile defines a postinst" "$FE_MK_POSTINST"
assert_eq "luci-app-trafficctl/Makefile has no prerm (the cut release moved to trafficctl)" "" "$FE_MK_PRERM"
assert_nonempty "build-ipk.sh writes a trafficctl postinst" "$BE_IPK_POSTINST"
assert_nonempty "build-ipk.sh writes a trafficctl prerm" "$BE_IPK_PRERM"
assert_nonempty "build-ipk.sh writes a luci-app-trafficctl postinst" "$FE_IPK_POSTINST"
assert_nonempty "build-apk.sh writes a trafficctl post-install" "$BE_APK_POSTINST"
assert_nonempty "build-apk.sh writes a trafficctl pre-deinstall" "$BE_APK_PREDEL"
assert_nonempty "build-apk.sh writes a luci-app-trafficctl post-install" "$FE_APK_POSTINST"

# ── luci-app-trafficctl ─────────────────────────────────────────────────────

# 1. rpcd restart. Without it the plugin is installed but unregistered, and the
#    whole app is dead until a reboot. The plugin is in luci-app-trafficctl.
RPCD="/etc/init.d/rpcd restart"
assert_contains "luci-app Makefile postinst restarts rpcd" "$RPCD" "$FE_MK_POSTINST"
assert_contains "luci-app build-ipk.sh postinst restarts rpcd" "$RPCD" "$FE_IPK_POSTINST"
assert_contains "luci-app build-apk.sh post-install restarts rpcd" "$RPCD" "$FE_APK_POSTINST"

# 2. The restart must be skipped for an offline install into an image root:
#    there is no running rpcd there, and calling its init script reaches for
#    the build host's.
assert_contains "luci-app Makefile guards the restart on IPKG_INSTROOT" \
    'if [ -z "$${IPKG_INSTROOT}" ]; then' "$FE_MK_POSTINST"
assert_contains "luci-app build-ipk.sh guards the restart on IPKG_INSTROOT" \
    'if [ -z "${IPKG_INSTROOT}" ]; then' "$FE_IPK_POSTINST"
assert_contains "luci-app build-apk.sh guards the restart on IPKG_INSTROOT" \
    'if [ -z "${IPKG_INSTROOT}" ]; then' "$FE_APK_POSTINST"

# The web interface no longer owns the config or the services.
for s in 'chmod 0600' 'trafficctl-telegram' 'trafficctl-history' 'trafficctl-cut'; do
    assert_not_contains "luci-app Makefile postinst leaves '$s' to trafficctl" "$s" "$FE_MK_POSTINST"
    assert_not_contains "luci-app build-ipk.sh postinst leaves '$s' to trafficctl" "$s" "$FE_IPK_POSTINST"
    assert_not_contains "luci-app build-apk.sh post-install leaves '$s' to trafficctl" "$s" "$FE_APK_POSTINST"
done

# ── trafficctl ──────────────────────────────────────────────────────────────

# 3. The config carries the Telegram and metrics tokens, so its mode is
#    tightened before anything can read it.
assert_contains "trafficctl Makefile postinst tightens the config mode" 'chmod 0600' "$BE_MK_POSTINST"
assert_contains "trafficctl build-ipk.sh postinst tightens the config mode" 'chmod 0600' "$BE_IPK_POSTINST"
assert_contains "trafficctl build-apk.sh post-install tightens the config mode" 'chmod 0600' "$BE_APK_POSTINST"

# 4. A Telegram bot that was running before the upgrade comes back without a
#    reboot. Same drift, lower stakes.
TG="/etc/init.d/trafficctl-telegram start"
assert_contains "trafficctl Makefile postinst starts the telegram service" "$TG" "$BE_MK_POSTINST"
assert_contains "trafficctl build-ipk.sh postinst starts the telegram service" "$TG" "$BE_IPK_POSTINST"
assert_contains "trafficctl build-apk.sh post-install starts the telegram service" "$TG" "$BE_APK_POSTINST"

# 5. The history sampler is restarted after an upgrade. It is a loop that
#    calls the helpers by absolute path, so one started by a release that
#    installed them under /usr/local/bin would record nothing until a reboot.
HIST_RESTART="/etc/init.d/trafficctl-history restart"
assert_contains "trafficctl Makefile postinst restarts the history sampler" "$HIST_RESTART" "$BE_MK_POSTINST"
assert_contains "trafficctl build-ipk.sh postinst restarts the history sampler" "$HIST_RESTART" "$BE_IPK_POSTINST"
assert_contains "trafficctl build-apk.sh post-install restarts the history sampler" "$HIST_RESTART" "$BE_APK_POSTINST"

# 6. opkg keeps a copy of a modified conffile whose owner changes, which is what
#    the move of /etc/config/trafficctl out of the single package of releases up
#    to 1.28.x does. Only that exact file is removed, and only next to a config.
#    apk makes no such copy, so build-apk.sh has nothing to remove.
BACKUP='rm -f /etc/config/trafficctl-opkg.backup'
assert_contains "trafficctl Makefile postinst removes the opkg backup" "$BACKUP" "$BE_MK_POSTINST"
assert_contains "trafficctl build-ipk.sh postinst removes the opkg backup" "$BACKUP" "$BE_IPK_POSTINST"
assert_contains "luci-app Makefile postinst removes the opkg backup" "$BACKUP" "$FE_MK_POSTINST"
assert_contains "luci-app build-ipk.sh postinst removes the opkg backup" "$BACKUP" "$FE_IPK_POSTINST"
for s in "$BE_MK_POSTINST" "$BE_IPK_POSTINST" "$FE_MK_POSTINST" "$FE_IPK_POSTINST"; do
    assert_eq "the backup removal only touches that one file" "1" \
        "$(printf '%s\n' "$s" | grep -c 'rm -f /etc/config/')"
done

# 7. Removal fails open: a global internet cut left engaged by a package that is
#    going away is a lockout with no UI left to undo it.
CUT="/usr/libexec/trafficctl/trafficctl-cut.sh release"
assert_contains "trafficctl Makefile prerm releases the cut" "$CUT" "$BE_MK_PRERM"
assert_contains "trafficctl build-ipk.sh prerm releases the cut" "$CUT" "$BE_IPK_PRERM"
assert_contains "trafficctl build-apk.sh pre-deinstall releases the cut" "$CUT" "$BE_APK_PREDEL"

# ── Syntax ────────────────────────────────────────────────────────────────
# The scripts run under the router's ash. A syntax error there fails the
# install on the device, where it is least convenient to debug.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' "$BE_MK_POSTINST" | sed 's/\$\$/$/g' > "$TMP/trafficctl.postinst"
printf '%s\n' "$BE_MK_PRERM" | sed 's/\$\$/$/g' > "$TMP/trafficctl.prerm"
printf '%s\n' "$FE_MK_POSTINST" | sed 's/\$\$/$/g' > "$TMP/luci-app-trafficctl.postinst"

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
    for f in "$TMP"/*; do
        # shellcheck disable=SC2086 # SHELL_CMD may be "busybox ash", intentionally split
        if $SHELL_CMD -n "$f" 2>/dev/null; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            printf "FAIL: the Makefile script %s is not valid POSIX shell (%s -n)\n" "$(basename "$f")" "$SHELL_CMD"
            # shellcheck disable=SC2086
            $SHELL_CMD -n "$f"
        fi
    done
else
    echo "NOTE: no POSIX shell found to syntax-check the Makefile scripts with."
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
