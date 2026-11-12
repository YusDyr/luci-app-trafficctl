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

# 4. The Telegram bot follows its uci flag: enabled in rc.d and started when
#    trafficctl.telegram.enabled is 1, so it is still there after a reboot.
#    The postinst used to start it unconditionally and never enable it, so an
#    upgrade revived a bot that the next reboot would drop again.
for step in "/etc/init.d/trafficctl-telegram enable" "/etc/init.d/trafficctl-telegram start"; do
    assert_contains "trafficctl Makefile postinst runs '$step'" "$step" "$BE_MK_POSTINST"
    assert_contains "trafficctl build-ipk.sh postinst runs '$step'" "$step" "$BE_IPK_POSTINST"
    assert_contains "trafficctl build-apk.sh post-install runs '$step'" "$step" "$BE_APK_POSTINST"
done
for flag in telegram history; do
    gate="\"\$(uci -q get trafficctl.$flag.enabled)\" = \"1\""
    # Make needs the command substitution written as $$(...).
    assert_contains "trafficctl Makefile postinst reads trafficctl.$flag.enabled" \
        "$(printf '%s' "$gate" | sed 's/\$/$$/')" "$BE_MK_POSTINST"
    assert_contains "trafficctl build-ipk.sh postinst reads trafficctl.$flag.enabled" "$gate" "$BE_IPK_POSTINST"
    assert_contains "trafficctl build-apk.sh post-install reads trafficctl.$flag.enabled" "$gate" "$BE_APK_POSTINST"
done

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

# 8. The cut keeper is never started at boot. default_postinst runs `enable` on
#    every init script, and rc.common's enable links S<START>/K<STOP>, so the
#    script must carry neither. A boot-time keeper finds no cut and removes any
#    rule it sees, which can race the ifup restore of a persisted cut.
CUT_INIT="$REPO_ROOT/trafficctl/files/etc/init.d/trafficctl-cut"
assert_eq "trafficctl-cut sets no START or STOP, so enable links nothing" "" \
    "$(grep -E '^[[:space:]]*(START|STOP)=' "$CUT_INIT")"
# Installs from 1.30.1 and older already have the links.
LINK="/etc/rc.d/S95trafficctl-cut"
assert_contains "trafficctl Makefile postinst removes the old boot link" "$LINK" "$BE_MK_POSTINST"
assert_contains "trafficctl build-ipk.sh postinst removes the old boot link" "$LINK" "$BE_IPK_POSTINST"
assert_contains "trafficctl build-apk.sh post-install removes the old boot link" "$LINK" "$BE_APK_POSTINST"

# 9. Releases up to 1.30.x built an nft table for per-device byte counters,
#    usually half-built because no kernel took its dynamic counter maps.
#    Nothing reads it any more, so the upgrade drops it (apk runs post-install
#    on an upgrade too: it is copied to post-upgrade). The luci-app package
#    never owned it.
MON="nft delete table inet trafficctl_mon 2>/dev/null || true"
assert_contains "trafficctl Makefile postinst drops the old byte counter table" "$MON" "$BE_MK_POSTINST"
assert_contains "trafficctl build-ipk.sh postinst drops the old byte counter table" "$MON" "$BE_IPK_POSTINST"
assert_contains "trafficctl build-apk.sh post-install drops the old byte counter table" "$MON" "$BE_APK_POSTINST"
assert_contains "build-apk.sh runs the same script on an upgrade" \
    'cp "$BE_SCRIPTS/post-install" "$BE_SCRIPTS/post-upgrade"' "$(cat "$APK")"
for s in "$FE_MK_POSTINST" "$FE_IPK_POSTINST" "$FE_APK_POSTINST"; do
    assert_not_contains "luci-app postinst leaves the nft table to trafficctl" "trafficctl_mon" "$s"
done

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

# ── Behaviour ─────────────────────────────────────────────────────────────
# Run every copy of the trafficctl postinst against fake init scripts and a
# fake uci. What runs after the install must be what runs after a reboot, and
# a reboot runs only what rc.d enables, so for each service: flag 1 means
# enabled in rc.d and (re)started, flag 0 means nothing is started and rc.d is
# not touched.
FAKE="$TMP/fake"
run_postinst() { # <script> <telegram flag> <history flag> <history in rc.d: 0|1> [IPKG_INSTROOT] [old nft table: 0|1]
    rm -rf "$FAKE"
    mkdir -p "$FAKE/etc/init.d" "$FAKE/etc/config" "$FAKE/rc.d" "$FAKE/bin"
    : > "$FAKE/calls"
    : > "$FAKE/etc/config/trafficctl"
    printf '%s\n' "$2" > "$FAKE/telegram.flag"
    printf '%s\n' "$3" > "$FAKE/history.flag"
    [ "$4" = 1 ] && : > "$FAKE/rc.d/trafficctl-history"
    for svc in trafficctl-telegram trafficctl-history; do
        cat > "$FAKE/etc/init.d/$svc" <<FAKEINIT
#!/bin/sh
echo "$svc \$1" >> "$FAKE/calls"
case "\$1" in
    enable) : > "$FAKE/rc.d/$svc" ;;
    disable) rm -f "$FAKE/rc.d/$svc" ;;
    enabled) [ -e "$FAKE/rc.d/$svc" ] ;;
esac
FAKEINIT
        chmod +x "$FAKE/etc/init.d/$svc"
    done
    cat > "$FAKE/bin/uci" <<FAKEUCI
#!/bin/sh
case "\$*" in
    "-q get trafficctl.telegram.enabled") cat "$FAKE/telegram.flag" ;;
    "-q get trafficctl.history.enabled") cat "$FAKE/history.flag" ;;
    *) exit 1 ;;
esac
FAKEUCI
    chmod +x "$FAKE/bin/uci"
    # nft fails the way it does when the table is absent unless told it exists.
    cat > "$FAKE/bin/nft" <<FAKENFT
#!/bin/sh
echo "nft \$*" >> "$FAKE/calls"
[ -e "$FAKE/nft.table" ] || { echo "Error: No such file or directory" >&2; exit 1; }
FAKENFT
    chmod +x "$FAKE/bin/nft"
    [ "${6:-0}" = 1 ] && : > "$FAKE/nft.table"
    # A boot link for the cut keeper, as releases up to 1.30.1 left behind.
    : > "$FAKE/rc.d/S95trafficctl-cut"
    sed -e "s|/etc/init.d/|$FAKE/etc/init.d/|g" -e "s|/etc/config/|$FAKE/etc/config/|g" \
        -e "s|/etc/rc.d/|$FAKE/rc.d/|g" "$1" > "$FAKE/postinst"
    # shellcheck disable=SC2086 # SHELL_CMD may be "busybox ash"
    IPKG_INSTROOT="${5:-}" PATH="$FAKE/bin:$PATH" ${SHELL_CMD:-sh} "$FAKE/postinst" >/dev/null 2>&1
    echo "$?" > "$FAKE/rc"
}
calls() { grep -c -x "$1" "$FAKE/calls"; }
in_rcd() { [ -e "$FAKE/rc.d/$1" ] && echo yes || echo no; }

printf '%s\n' "$BE_IPK_POSTINST" > "$TMP/ipk.postinst"
printf '%s\n' "$BE_APK_POSTINST" > "$TMP/apk.postinst"
for f in "$TMP/trafficctl.postinst" "$TMP/ipk.postinst" "$TMP/apk.postinst"; do
    n=$(basename "$f")

    run_postinst "$f" 1 1 0
    assert_eq "$n: the old boot link of the cut keeper is removed" no "$(in_rcd S95trafficctl-cut)"
    assert_eq "$n, telegram.enabled=1: the bot is enabled in rc.d" yes "$(in_rcd trafficctl-telegram)"
    assert_eq "$n, telegram.enabled=1: the bot is started" 1 "$(calls 'trafficctl-telegram start')"
    assert_eq "$n, history.enabled=1: the sampler is enabled in rc.d" yes "$(in_rcd trafficctl-history)"
    assert_eq "$n, history.enabled=1: the sampler is restarted" 1 "$(calls 'trafficctl-history restart')"

    run_postinst "$f" 0 0 0
    assert_eq "$n, telegram.enabled=0: the bot is not enabled in rc.d" no "$(in_rcd trafficctl-telegram)"
    assert_eq "$n, telegram.enabled=0: the bot's init script is not called" 0 "$(grep -c '^trafficctl-telegram ' "$FAKE/calls")"
    assert_eq "$n, history.enabled=0: the sampler is not enabled in rc.d" no "$(in_rcd trafficctl-history)"
    assert_eq "$n, history.enabled=0: the sampler is not started" 0 "$(calls 'trafficctl-history restart')"

    # A sampler already enabled in rc.d starts at boot whatever the flag, so
    # it is restarted onto the new helpers, and never disabled here.
    run_postinst "$f" 0 0 1
    assert_eq "$n, history in rc.d with the flag at 0: restarted as at boot" 1 "$(calls 'trafficctl-history restart')"
    assert_eq "$n, history in rc.d with the flag at 0: left enabled" yes "$(in_rcd trafficctl-history)"

    # The 1.30.x byte counter table is dropped when it is there, and its
    # absence (nft fails) neither fails the install nor stops the steps after.
    DROP='nft delete table inet trafficctl_mon'
    run_postinst "$f" 0 1 0 "" 1
    assert_eq "$n, old nft table present: it is deleted" 1 "$(calls "$DROP")"
    assert_eq "$n, old nft table present: the postinst succeeds" 0 "$(cat "$FAKE/rc")"
    run_postinst "$f" 0 1 0 "" 0
    assert_eq "$n, no old nft table: the delete is still tried once" 1 "$(calls "$DROP")"
    assert_eq "$n, no old nft table: the postinst succeeds" 0 "$(cat "$FAKE/rc")"
    assert_eq "$n, no old nft table: the steps after it still run" 1 "$(calls 'trafficctl-history restart')"
    assert_eq "$n, nft is asked for nothing else" 1 "$(grep -c '^nft ' "$FAKE/calls")"

    # Unpacking into an image: no services and no rc.d of ours to manage.
    mkdir -p "$TMP/img/etc/config"
    run_postinst "$f" 1 1 0 "$TMP/img"
    assert_eq "$n, IPKG_INSTROOT set: no init script or nft is called" 0 "$(grep -c . "$FAKE/calls")"
done

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
