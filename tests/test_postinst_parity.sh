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
# packages: trafficctl (the backend: config, services, helpers),
# trafficctl-telegram (the bot, built from the same Makefile) and
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
TG_MK_POSTINST=$(mk_section "$BE_MAKEFILE" 'Package/trafficctl-telegram/postinst')
TG_MK_PRERM=$(mk_section "$BE_MAKEFILE" 'Package/trafficctl-telegram/prerm')
TG_IPK_PREINST=$(heredoc "$IPK" '$TG_CTRL/preinst')
TG_IPK_POSTINST=$(heredoc "$IPK" '$TG_CTRL/postinst')
TG_IPK_PRERM=$(heredoc "$IPK" '$TG_CTRL/prerm')
TG_APK_PREUPG=$(heredoc "$APK" '$TG_SCRIPTS/pre-upgrade')
TG_APK_POSTINST=$(heredoc "$APK" '$TG_SCRIPTS/post-install')
TG_APK_PREDEL=$(heredoc "$APK" '$TG_SCRIPTS/pre-deinstall')

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
assert_nonempty "trafficctl/Makefile defines a trafficctl-telegram postinst" "$TG_MK_POSTINST"
assert_nonempty "trafficctl/Makefile defines a trafficctl-telegram prerm" "$TG_MK_PRERM"
assert_nonempty "build-ipk.sh writes a trafficctl-telegram preinst" "$TG_IPK_PREINST"
assert_nonempty "build-ipk.sh writes a trafficctl-telegram postinst" "$TG_IPK_POSTINST"
assert_nonempty "build-ipk.sh writes a trafficctl-telegram prerm" "$TG_IPK_PRERM"
assert_nonempty "build-apk.sh writes a trafficctl-telegram pre-upgrade" "$TG_APK_PREUPG"
assert_nonempty "build-apk.sh writes a trafficctl-telegram post-install" "$TG_APK_POSTINST"
assert_nonempty "build-apk.sh writes a trafficctl-telegram pre-deinstall" "$TG_APK_PREDEL"

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

# 3. The exec plugin of releases up to 1.30.x goes, and before the restart:
#    a copy left there registers the same ubus object as the ucode plugin.
OLDPLUGIN='/usr/libexec/rpcd/luci.trafficctl"'
assert_contains "luci-app Makefile postinst removes the exec plugin" "rm -f \"\$\${IPKG_INSTROOT}$OLDPLUGIN" "$FE_MK_POSTINST"
assert_contains "luci-app build-ipk.sh postinst removes the exec plugin" "rm -f \"\${IPKG_INSTROOT}$OLDPLUGIN" "$FE_IPK_POSTINST"
assert_contains "luci-app build-apk.sh post-install removes the exec plugin" "rm -f \"\${IPKG_INSTROOT}$OLDPLUGIN" "$FE_APK_POSTINST"
for s in "$FE_MK_POSTINST" "$FE_IPK_POSTINST" "$FE_APK_POSTINST"; do
    assert_eq "the exec plugin goes before the rpcd restart" "yes" \
        "$(printf '%s' "$s" | awk -v a="$OLDPLUGIN" -v b="$RPCD" \
            'index($0, a) && !ra { ra = NR } index($0, b) && !rb { rb = NR } END { print (ra && rb && ra < rb) ? "yes" : "no" }')"
done

# 4. trafficctl restarts rpcd when the ucode plugin is there: rpcd loads the
#    plugin and the trafficctl modules it imports once, so a backend upgrade
#    alone would leave the old modules running.
RPCD_IF='if [ -f /usr/share/rpcd/ucode/luci.trafficctl.uc ]; then'
assert_contains "trafficctl Makefile postinst restarts rpcd for the plugin" "$RPCD_IF" "$BE_MK_POSTINST"
assert_contains "trafficctl build-ipk.sh postinst restarts rpcd for the plugin" "$RPCD_IF" "$BE_IPK_POSTINST"
assert_contains "trafficctl build-apk.sh post-install restarts rpcd for the plugin" "$RPCD_IF" "$BE_APK_POSTINST"
for s in "$BE_MK_POSTINST" "$BE_IPK_POSTINST" "$BE_APK_POSTINST"; do
    assert_contains "trafficctl postinst: the rpcd restart" "$RPCD" "$s"
done

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
#    upgrade revived a bot that the next reboot would drop again. It is
#    RESTARTED: a bot of a release up to 1.30.x runs the device scan that the
#    notification watcher (trafficctl-notify) took over, and a plain start
#    leaves that old process running, so every new device is announced twice.
#    The bot is trafficctl-telegram's, so its postinst does this, after
#    trafficctl's (a dependency is configured first) has moved the
#    notification options.
for step in "/usr/sbin/trafficctl notify migrate" \
    "/etc/init.d/trafficctl-notify enable" "/etc/init.d/trafficctl-notify restart"; do
    assert_contains "trafficctl Makefile postinst runs '$step'" "$step" "$BE_MK_POSTINST"
    assert_contains "trafficctl build-ipk.sh postinst runs '$step'" "$step" "$BE_IPK_POSTINST"
    assert_contains "trafficctl build-apk.sh post-install runs '$step'" "$step" "$BE_APK_POSTINST"
done
for step in "/etc/init.d/trafficctl-telegram enable" "/etc/init.d/trafficctl-telegram restart"; do
    assert_contains "trafficctl-telegram Makefile postinst runs '$step'" "$step" "$TG_MK_POSTINST"
    assert_contains "trafficctl-telegram build-ipk.sh postinst runs '$step'" "$step" "$TG_IPK_POSTINST"
    assert_contains "trafficctl-telegram build-apk.sh post-install runs '$step'" "$step" "$TG_APK_POSTINST"
    for s in "$BE_MK_POSTINST" "$BE_IPK_POSTINST" "$BE_APK_POSTINST"; do
        assert_not_contains "trafficctl postinst leaves '$step' to trafficctl-telegram" "$step" "$s"
    done
done
gate_of() { printf '"$(uci -q get trafficctl.%s.enabled)" = "1"' "$1"; }
mk_gate() { gate_of "$1" | sed 's/\$/$$/'; }   # Make writes $(...) as $$(...)
assert_contains "trafficctl Makefile postinst reads trafficctl.history.enabled" "$(mk_gate history)" "$BE_MK_POSTINST"
assert_contains "trafficctl build-ipk.sh postinst reads trafficctl.history.enabled" "$(gate_of history)" "$BE_IPK_POSTINST"
assert_contains "trafficctl build-apk.sh post-install reads trafficctl.history.enabled" "$(gate_of history)" "$BE_APK_POSTINST"
assert_contains "trafficctl-telegram Makefile postinst reads trafficctl.telegram.enabled" "$(mk_gate telegram)" "$TG_MK_POSTINST"
assert_contains "trafficctl-telegram build-ipk.sh postinst reads trafficctl.telegram.enabled" "$(gate_of telegram)" "$TG_IPK_POSTINST"
assert_contains "trafficctl-telegram build-apk.sh post-install reads trafficctl.telegram.enabled" "$(gate_of telegram)" "$TG_APK_POSTINST"
assert_contains "build-apk.sh runs the bot's script on an upgrade too" \
    'cp "$TG_SCRIPTS/post-install" "$TG_SCRIPTS/post-upgrade"' "$(cat "$APK")"

# 4a. Removing trafficctl-telegram stops the bot and drops it from rc.d, and
#     an upgrade stops it first (the SDK's default prerm does the same for an
#     SDK-built package; the Makefile prerm says so explicitly).
for s in "$TG_MK_PRERM" "$TG_IPK_PRERM" "$TG_APK_PREDEL"; do
    assert_contains "trafficctl-telegram prerm stops the bot" "/etc/init.d/trafficctl-telegram stop" "$s"
    assert_contains "trafficctl-telegram prerm disables the bot" "/etc/init.d/trafficctl-telegram disable" "$s"
done
for s in "$TG_IPK_PREINST" "$TG_APK_PREUPG"; do
    assert_contains "trafficctl-telegram stops the bot before an upgrade" "/etc/init.d/trafficctl-telegram stop" "$s"
done
for s in "$BE_MK_PRERM" "$BE_IPK_PRERM" "$BE_APK_PREDEL"; do
    assert_not_contains "trafficctl prerm leaves the bot to trafficctl-telegram" "trafficctl-telegram" "$s"
done
assert_eq "build-ipk.sh writes no trafficctl preinst (it only stopped the bot)" "" "$(heredoc "$IPK" '$BE_CTRL/preinst')"
assert_eq "build-apk.sh writes no trafficctl pre-upgrade (it only stopped the bot)" "" "$(heredoc "$APK" '$BE_SCRIPTS/pre-upgrade')"

# 4b. Upgrading trafficctl from 1.30.x without trafficctl-telegram takes the
#     bot's files away. The running bot is stopped and its boot links removed.
LEFT="ubus call service delete '{\"name\":\"trafficctl-telegram\"}'"
for s in "$BE_MK_POSTINST" "$BE_IPK_POSTINST" "$BE_APK_POSTINST"; do
    assert_contains "trafficctl postinst stops a bot whose files are gone" "$LEFT" "$s"
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
CUT="/usr/sbin/trafficctl cut release"
assert_contains "trafficctl Makefile prerm releases the cut" "$CUT" "$BE_MK_PRERM"
assert_contains "trafficctl build-ipk.sh prerm releases the cut" "$CUT" "$BE_IPK_PRERM"
assert_contains "trafficctl build-apk.sh pre-deinstall releases the cut" "$CUT" "$BE_APK_PREDEL"
# ── PR7: the release needs ucode and every module to load, so its effect is
#    made sure of without them too: no state left, no table.
for s in "$BE_MK_PRERM" "$BE_IPK_PRERM" "$BE_APK_PREDEL"; do
    assert_contains "prerm: the cut state goes even if the release failed" \
        "rm -f /var/run/trafficctl/cut.state /etc/trafficctl/cut.state" "$s"
    assert_contains "prerm: and so does the table" "nft delete table inet tctl_cut 2>/dev/null || true" "$s"
done
# ── end PR7

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
printf '%s\n' "$TG_MK_POSTINST" | sed 's/\$\$/$/g' > "$TMP/trafficctl-telegram.postinst"
printf '%s\n' "$TG_MK_PRERM" | sed 's/\$\$/$/g' > "$TMP/trafficctl-telegram.prerm"

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
run_postinst() { # <script> <telegram flag> <history flag> <history in rc.d: 0|1> [IPKG_INSTROOT] [old nft table: 0|1] [cut engaged: 0|1]
    rm -rf "$FAKE"
    mkdir -p "$FAKE/etc/init.d" "$FAKE/etc/config" "$FAKE/rc.d" "$FAKE/bin"
    : > "$FAKE/calls"
    : > "$FAKE/etc/config/trafficctl"
    printf '%s\n' "$2" > "$FAKE/telegram.flag"
    printf '%s\n' "$3" > "$FAKE/history.flag"
    [ "$4" = 1 ] && : > "$FAKE/rc.d/trafficctl-history"
    for svc in trafficctl-telegram trafficctl-history trafficctl-notify trafficctl-cut; do
        # NO_BOT=1: trafficctl-telegram is not installed.
        [ "$svc" = trafficctl-telegram ] && [ "${NO_BOT:-0}" = 1 ] && continue
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
    cat > "$FAKE/bin/trafficctl" <<FAKECLI
#!/bin/sh
echo "trafficctl \$*" >> "$FAKE/calls"
FAKECLI
    chmod +x "$FAKE/bin/trafficctl"
    cat > "$FAKE/bin/ubus" <<FAKEUBUS
#!/bin/sh
echo "ubus \$*" >> "$FAKE/calls"
FAKEUBUS
    chmod +x "$FAKE/bin/ubus"
    # The bot's boot links, as an install with the bot enabled has them.
    : > "$FAKE/rc.d/S99trafficctl-telegram"
    : > "$FAKE/rc.d/K10trafficctl-telegram"
    [ "${6:-0}" = 1 ] && : > "$FAKE/nft.table"
    # A boot link for the cut keeper, as releases up to 1.30.1 left behind.
    : > "$FAKE/rc.d/S95trafficctl-cut"
    # An engaged cut, as its state file says.
    mkdir -p "$FAKE/run"
    [ "${7:-0}" = 1 ] && : > "$FAKE/run/cut.state"
    sed -e "s|/etc/init.d/|$FAKE/etc/init.d/|g" -e "s|/etc/config/|$FAKE/etc/config/|g" \
        -e "s|/etc/rc.d/|$FAKE/rc.d/|g" -e "s|/var/run/trafficctl/|$FAKE/run/|g" -e "s|/usr/sbin/trafficctl|$FAKE/bin/trafficctl|g" "$1" > "$FAKE/postinst"
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
    assert_eq "$n, the bot installed: its init script is not called" 0 "$(grep -c '^trafficctl-telegram ' "$FAKE/calls")"
    assert_eq "$n, the bot installed: it is not stopped" 0 "$(grep -c '^ubus ' "$FAKE/calls")"
    assert_eq "$n, the bot installed: its boot links stay" yes "$(in_rcd S99trafficctl-telegram)"
    assert_eq "$n: the Telegram notification options are migrated" 1 "$(calls 'trafficctl notify migrate')"
    assert_eq "$n: the notification watcher is enabled in rc.d" yes "$(in_rcd trafficctl-notify)"
    assert_eq "$n: the notification watcher is restarted" 1 "$(calls 'trafficctl-notify restart')"
    assert_eq "$n, history.enabled=1: the sampler is enabled in rc.d" yes "$(in_rcd trafficctl-history)"
    assert_eq "$n, history.enabled=1: the sampler is restarted" 1 "$(calls 'trafficctl-history restart')"

    NO_BOT=1 run_postinst "$f" 1 1 0
    assert_eq "$n, the bot not installed: a running one is stopped" 1 \
        "$(calls 'ubus call service delete {"name":"trafficctl-telegram"}')"
    assert_eq "$n, the bot not installed: its boot links are removed" "no no" \
        "$(in_rcd S99trafficctl-telegram) $(in_rcd K10trafficctl-telegram)"
    assert_eq "$n, the bot not installed: the postinst succeeds" 0 "$(cat "$FAKE/rc")"

    run_postinst "$f" 0 0 0
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

    # ── PR7: a keeper started by the old release runs the old code until it
    #    ends; a restart puts procd's `trafficctl cut keeper` in its place.
    #    No cut, no keeper: it is started on demand only.
    run_postinst "$f" 0 0 0 "" 0 1
    assert_eq "$n, cut engaged: the keeper is restarted onto the new code" 1 "$(calls 'trafficctl-cut restart')"
    assert_eq "$n, cut engaged: the postinst succeeds" 0 "$(cat "$FAKE/rc")"
    run_postinst "$f" 0 0 0 "" 0 0
    assert_eq "$n, no cut: the keeper is not started" 0 "$(grep -c '^trafficctl-cut ' "$FAKE/calls")"
    # ── end PR7

    # Unpacking into an image: no services and no rc.d of ours to manage.
    mkdir -p "$TMP/img/etc/config"
    run_postinst "$f" 1 1 0 "$TMP/img"
    assert_eq "$n, IPKG_INSTROOT set: no init script or nft is called" 0 "$(grep -c . "$FAKE/calls")"
    NO_BOT=1 run_postinst "$f" 1 1 0 "$TMP/img"
    assert_eq "$n, IPKG_INSTROOT set, no bot: nothing is called" 0 "$(grep -c . "$FAKE/calls")"
done

# The bot's postinst, every copy.
printf '%s\n' "$TG_IPK_POSTINST" > "$TMP/tg-ipk.postinst"
printf '%s\n' "$TG_APK_POSTINST" > "$TMP/tg-apk.postinst"
for f in "$TMP/trafficctl-telegram.postinst" "$TMP/tg-ipk.postinst" "$TMP/tg-apk.postinst"; do
    n=$(basename "$f")
    run_postinst "$f" 1 0 0
    assert_eq "$n, telegram.enabled=1: the bot is enabled in rc.d" yes "$(in_rcd trafficctl-telegram)"
    assert_eq "$n, telegram.enabled=1: the bot is restarted" 1 "$(calls 'trafficctl-telegram restart')"
    assert_eq "$n, telegram.enabled=1: nothing else is called" 2 "$(grep -c . "$FAKE/calls")"
    run_postinst "$f" 0 1 0
    assert_eq "$n, telegram.enabled=0: the bot is not enabled in rc.d" no "$(in_rcd trafficctl-telegram)"
    assert_eq "$n, telegram.enabled=0: the bot's init script is not called" 0 "$(grep -c '^trafficctl-telegram ' "$FAKE/calls")"
    run_postinst "$f" 1 0 0 "$TMP/img"
    assert_eq "$n, IPKG_INSTROOT set: the bot's init script is not called" 0 "$(grep -c . "$FAKE/calls")"
    assert_eq "$n: the postinst succeeds" 0 "$(cat "$FAKE/rc")"
done

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
