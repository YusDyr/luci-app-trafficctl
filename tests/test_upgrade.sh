#!/bin/sh
# Runs INSIDE an OpenWrt rootfs Docker container.
# Usage: sh /tests/test_upgrade.sh <old packages...> -- <new packages...>
#   e.g. sh /tests/test_upgrade.sh /dist-old/luci-app-trafficctl.ipk \
#            -- /dist/trafficctl.ipk /dist/trafficctl-telegram.ipk /dist/luci-app-trafficctl.ipk
# Verifies upgrade scenario: install previous release, then install current build.
# Asserts config files are preserved and upgrade hooks don't crash.
#
# Releases up to 1.28.x are ONE package, luci-app-trafficctl, that also carries
# the backend; later releases ship the backend as trafficctl. Upgrading from the
# single package is the case that matters most: every backend file, and the
# conffile, changes owner in the same run. Releases up to 1.30.x carry the bot
# in trafficctl; after that it is trafficctl-telegram, and its files change
# owner the same way.
set -e

OLD_PKGS=
NEW_PKGS=
seen_sep=0
for a in "$@"; do
    if [ "$a" = "--" ]; then seen_sep=1; continue; fi
    [ -f "$a" ] || { echo "Package not found: $a"; exit 1; }
    if [ "$seen_sep" = 1 ]; then NEW_PKGS="$NEW_PKGS $a"; else OLD_PKGS="$OLD_PKGS $a"; fi
done
if [ -z "$OLD_PKGS" ] || [ -z "$NEW_PKGS" ]; then
    echo "usage: $0 <old packages...> -- <new packages...>"
    exit 1
fi
# All files of one run share a format; take it from the first new package.
# shellcheck disable=SC2086 # a list of package files, split on purpose
set -- $NEW_PKGS
FMT=${1##*.}
case "$FMT" in
    ipk|apk) ;;
    *) echo "Unknown format: $1"; exit 1 ;;
esac

# Minimal rootfs containers don't ship with /var/lock or /var/log — opkg needs them.
mkdir -p /var/lock /var/log

if [ "$FMT" = ipk ]; then
    # Detect native arch and register it + 'all' so opkg accepts our _all.ipk.
    NATIVE_ARCH=$(awk '/^Architecture: / && $2 != "all" {print $2; exit}' /usr/lib/opkg/status 2>/dev/null)
    if [ -n "$NATIVE_ARCH" ]; then
        grep -q "^arch $NATIVE_ARCH " /etc/opkg.conf || echo "arch $NATIVE_ARCH 100" >> /etc/opkg.conf
    fi
    grep -q '^arch all ' /etc/opkg.conf || echo 'arch all 200' >> /etc/opkg.conf
    # Disable signature check — our CI IPK is unsigned
    sed -i '/^option check_signature/d' /etc/opkg.conf
fi

# Real opkg install. Minimal rootfs images ship no package index, and opkg
# refuses a local _all.ipk until one is loaded (reporting it as "incompatible
# with the architectures configured"), so refresh the index first. No tar
# fallback: if opkg can't install the package, the test must fail.
# Arguments: a space-separated list of package files.
pkg_install() {
    if [ "$FMT" = ipk ]; then
        opkg update 2>&1 | tee /tmp/opkg-update.out || true
        # --force-downgrade: the CI "new" build is version 0.0.0-test-1, lower
        # than the released "old" package, so installing it on top is a downgrade.
        # shellcheck disable=SC2086 # a list of package files, split on purpose
        opkg install --force-depends --force-downgrade $1 2>&1 | tee /tmp/opkg.out || true
        opkg list-installed | grep -q '^luci-app-trafficctl ' || { cat /tmp/opkg.out; return 1; }
    else
        # shellcheck disable=SC2086 # a list of package files, split on purpose
        apk add --allow-untrusted $1
    fi
}

installed_ver() {
    if [ "$FMT" = ipk ]; then
        opkg list-installed | awk -v n="$1" '$1 == n {print $3}'
    else
        apk info -e -v "$1" 2>/dev/null | head -1
    fi
}

# ── Step 1: install OLD ───────────────────────────────────────────────────────
echo "=== Installing OLD packages:$OLD_PKGS ==="
pkg_install "$OLD_PKGS" || { echo "OLD install failed"; exit 1; }

OLD_VER=$(installed_ver luci-app-trafficctl)
echo "Old version installed: ${OLD_VER:-unknown}"

# Verify file present. Releases up to 1.28.0 installed the helper scripts under
# /usr/local/bin; later ones use /usr/libexec/trafficctl. Accept either, so the
# test keeps working once the previous release is itself a libexec one.
OLD_FW=
for d in /usr/local/bin /usr/libexec/trafficctl; do
    [ -f "$d/trafficctl-fw.sh" ] && OLD_FW="$d/trafficctl-fw.sh" && break
done
[ -n "$OLD_FW" ] || { echo "OLD install: trafficctl-fw.sh missing"; exit 1; }
echo "Old helper scripts at: $(dirname "$OLD_FW")"

# ── Step 1a: rules written by the old release ─────────────────────────────────
# 2.0.0 drops the shell scripts that wrote them; the ucode commands must still
# remove them, and the ifup hook must still restore what rules.json records.
# Needs nf_tables in the container (docker run --cap-add NET_ADMIN); fw4
# itself needs netifd, and its forward chain is all a block writes to. Run
# before the bot is switched on below: a 1.30.x block notifies through it.
OLD_RULES=0
if ip link add br-lan type bridge 2>/dev/null && nft -f - 2>/dev/null <<'NFT'
table inet fw4 {
	chain forward {
		type filter hook forward priority filter; policy accept;
	}
}
NFT
then
    ip link set br-lan up
    ip addr add 192.168.1.1/24 dev br-lan
    uci set trafficctl.main.persist_rules=1
    uci commit trafficctl
    D=$(dirname "$OLD_FW")
    sh "$D/trafficctl-block.sh" 192.168.1.50 >/dev/null 2>&1 || true
    sh "$D/trafficctl-portfw.sh" pause forward tcp 192.168.1.60 80 >/dev/null 2>&1 || true
    if nft list chain inet fw4 forward | grep -q '"tctl_block_192_168_1_50"' &&
       nft list table inet tctl_pfw 2>/dev/null | grep -q '"tctl_pfw_pause_tcp_192.168.1.60_80"'; then
        OLD_RULES=1
        echo "Old release wrote a block and a port pause"
    else
        echo "FAIL: the old release did not write its block and port pause"
        nft list ruleset
        exit 1
    fi
else
    echo "No nf_tables in this container (run it with --cap-add NET_ADMIN): old-rule checks skipped"
fi

# ── Step 1b: services switched on in uci but not enabled in rc.d ──────────────
# The state a router reached with every earlier release: the Settings toggle
# set trafficctl.telegram.enabled and only reloaded the bot, and no postinst
# ever enabled it, so the bot did not survive a reboot. After the upgrade both
# services must be enabled, because their flags are 1.
uci -q get trafficctl.telegram >/dev/null || uci set trafficctl.telegram=telegram
uci set trafficctl.telegram.enabled=1
uci -q get trafficctl.history >/dev/null || uci set trafficctl.history=history
uci set trafficctl.history.enabled=1
uci commit trafficctl
for svc in trafficctl-telegram trafficctl-history; do
    if [ -x "/etc/init.d/$svc" ]; then "/etc/init.d/$svc" disable 2>/dev/null || true; fi
done

# ── Step 2: tag config file to verify preservation ────────────────────────────
[ -f /etc/config/trafficctl ] || touch /etc/config/trafficctl
# A section, not a comment: the upgrade from 1.30.x moves the Telegram
# notification options once (`trafficctl notify migrate` in the postinst), and
# uci keeps every section and option when it saves but drops comments.
MARKER="m$(date +%s)"
printf "\nconfig marker 'upgrade_marker'\n\toption id '%s'\n" "$MARKER" >> /etc/config/trafficctl
echo "Marker section added to /etc/config/trafficctl: $MARKER"

# ── Step 3: install NEW on top ────────────────────────────────────────────────
# Real package-manager upgrade, so the config-preservation assertion below
# exercises the conffile machinery (not a manual cp), including the change of
# the conffile's owner from luci-app-trafficctl to trafficctl.
echo "=== Installing NEW packages on top:$NEW_PKGS ==="
pkg_install "$NEW_PKGS" || { echo "NEW install failed"; exit 1; }

NEW_VER=$(installed_ver luci-app-trafficctl)
echo "New version installed: ${NEW_VER:-unknown}"

# ── Step 4: verify ────────────────────────────────────────────────────────────
echo "=== Verification ==="

# Config preserved?
if [ "$(uci -q get trafficctl.upgrade_marker.id)" = "$MARKER" ]; then
    echo "OK: config file marker preserved across upgrade"
else
    echo "FAIL: /etc/config/trafficctl marker lost — config was overwritten"
    exit 1
fi

# What runs after the upgrade must also run after a reboot.
for svc in trafficctl-telegram trafficctl-history; do
    if ! "/etc/init.d/$svc" enabled; then
        echo "FAIL: trafficctl.${svc#trafficctl-}.enabled is 1 but $svc is not enabled in rc.d after the upgrade"
        exit 1
    fi
done
echo "OK: services switched on in uci are enabled in rc.d"

# New files present?
for f in /usr/sbin/trafficctl \
         /usr/share/ucode/trafficctl/ctl.uc \
         /usr/libexec/trafficctl/trafficctl-telegram.uc \
         /usr/libexec/rpcd/luci.trafficctl \
         /www/cgi-bin/trafficctl-metrics \
         /www/luci-static/resources/view/trafficctl/status.js; do
    [ -f "$f" ] || { echo "FAIL: $f missing after upgrade"; exit 1; }
done

# Files the old package owned and the new one does not must be gone: the
# package manager removes them on upgrade, which is why postinst does no
# cleanup of /usr/local/bin or /usr/libexec/trafficctl. A leftover copy
# would be a stale second set of helpers that nothing updates. 2.0.0 ships
# no shell scripts at all.
for f in "$(dirname "$OLD_FW")"/trafficctl-*.sh /usr/libexec/trafficctl/*.sh; do
    if [ -e "$f" ]; then echo "FAIL: $f left behind by the upgrade"; exit 1; fi
done
echo "OK: the old shell scripts were removed by the upgrade"

# The old release's rules, through the ucode commands: the ifup hook puts back
# what rules.json records, and unblock and resume take them away.
if [ "$OLD_RULES" = 1 ]; then
    nft flush chain inet fw4 forward
    nft delete table inet tctl_pfw
    ACTION=ifup INTERFACE=lan sh /etc/hotplug.d/iface/99-trafficctl-shapes
    nft list chain inet fw4 forward | grep -q '"tctl_block_192_168_1_50"' ||
        { echo "FAIL: the ifup hook did not restore the old release's block"; nft list ruleset; exit 1; }
    nft list table inet tctl_pfw 2>/dev/null | grep -q '"tctl_pfw_pause_tcp_192.168.1.60_80"' ||
        { echo "FAIL: the ifup hook did not restore the old release's port pause"; nft list ruleset; exit 1; }
    echo "OK: the ifup hook restored the old release's block and port pause"
    /usr/sbin/trafficctl unblock 192.168.1.50 >/dev/null
    /usr/sbin/trafficctl portfw resume forward tcp 192.168.1.60 80 >/dev/null
    if nft list chain inet fw4 forward | grep -q '"tctl_block_192_168_1_50'; then
        echo "FAIL: trafficctl unblock left the old release's block"; nft list ruleset; exit 1
    fi
    if nft list table inet tctl_pfw 2>/dev/null | grep -q '"tctl_pfw_pause_tcp_192.168.1.60_80"'; then
        echo "FAIL: trafficctl portfw resume left the old release's pause"; nft list ruleset; exit 1
    fi
    if grep -qE '"ip":"(192\.168\.1\.50|forward/tcp/192\.168\.1\.60/80)"' /etc/trafficctl/rules.json; then
        echo "FAIL: rules.json still records a removed rule: $(cat /etc/trafficctl/rules.json)"; exit 1
    fi
    echo "OK: the ucode commands removed the old release's block and port pause"
fi
if [ -e /lib/upgrade/keep.d/luci-app-trafficctl ]; then
    echo "FAIL: the old keep.d entry /lib/upgrade/keep.d/luci-app-trafficctl is left behind"
    exit 1
fi

# Exactly one copy of each package installed?
for name in trafficctl trafficctl-telegram luci-app-trafficctl; do
    if [ "$FMT" = ipk ]; then
        COUNT=$(opkg list-installed | awk -v n="$name" '$1 == n' | wc -l)
    else
        COUNT=$(apk info -e "$name" 2>/dev/null | wc -l)
    fi
    if [ "$COUNT" != "1" ]; then
        echo "FAIL: expected exactly 1 installed copy of $name after upgrade, got $COUNT"
        exit 1
    fi
done

# Every backend file now belongs to trafficctl, the web interface keeps its
# own. A backend file still registered to luci-app-trafficctl would be deleted
# by the next upgrade or removal of the web interface.
owner_of() {
    if [ "$FMT" = ipk ]; then
        opkg search "$1" 2>/dev/null | awk '{print $1; exit}'
    else
        apk info --who-owns "$1" 2>/dev/null \
            | sed -n 's/^.* is owned by \(.*\)-[0-9][^-]*-r[0-9]*$/\1/p' | head -1
    fi
}
for f in /usr/sbin/trafficctl /usr/share/ucode/trafficctl/lib.uc /etc/config/trafficctl \
         /www/cgi-bin/trafficctl-metrics /lib/upgrade/keep.d/trafficctl; do
    o=$(owner_of "$f")
    [ "$o" = trafficctl ] || { echo "FAIL: $f is owned by '$o' after the upgrade, expected trafficctl"; exit 1; }
done
for f in /etc/init.d/trafficctl-telegram /usr/libexec/trafficctl/trafficctl-telegram.uc; do
    o=$(owner_of "$f")
    [ "$o" = trafficctl-telegram ] || { echo "FAIL: $f is owned by '$o' after the upgrade, expected trafficctl-telegram"; exit 1; }
done
if [ "$FMT" = ipk ] && grep -qE '(trafficctl-telegram(\.sh|\.uc)?|/telegram\.uc)$' /usr/lib/opkg/info/trafficctl.list; then
    echo "FAIL: trafficctl still lists the bot's files"
    exit 1
fi
o=$(owner_of /usr/libexec/rpcd/luci.trafficctl)
[ "$o" = luci-app-trafficctl ] || { echo "FAIL: the rpcd plugin is owned by '$o', expected luci-app-trafficctl"; exit 1; }
echo "OK: backend files owned by trafficctl, the rpcd plugin by luci-app-trafficctl"

if [ "$FMT" = ipk ]; then
    if grep -E '^/(usr/libexec/trafficctl|etc|www/cgi-bin|lib/upgrade)/' \
            /usr/lib/opkg/info/luci-app-trafficctl.list; then
        echo "FAIL: luci-app-trafficctl still lists backend files"
        exit 1
    fi
    # The backend's dependencies must survive the move. opkg removes a
    # dependency the old luci-app-trafficctl pulled in once nothing installed
    # needs it, and trafficctl does not count while it is still being installed
    # in the same run; that is why luci-app-trafficctl repeats them.
    for dep in conntrack curl iw hostapd-utils; do
        opkg list-installed | grep -q "^$dep " \
            || { echo "FAIL: dependency $dep was removed by the upgrade"; exit 1; }
    done
    echo "OK: backend dependencies kept"
fi

# opkg keeps a copy of a modified conffile whose owner changes; the postinst
# removes it, the config itself was checked above.
if [ -e /etc/config/trafficctl-opkg.backup ]; then
    echo "FAIL: /etc/config/trafficctl-opkg.backup left behind"
    exit 1
fi

# The package manager must actually have swapped the version (real upgrade,
# not a no-op). OLD is a released version; NEW is 0.0.0-test-1.
if [ -n "$OLD_VER" ] && [ "$NEW_VER" = "$OLD_VER" ]; then
    echo "FAIL: version unchanged after upgrade ($NEW_VER) — install did not take"
    exit 1
fi

echo "Upgrade test passed: ${OLD_VER:-?} -> ${NEW_VER:-?}"
