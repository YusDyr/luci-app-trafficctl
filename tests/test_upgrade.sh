#!/bin/sh
# Runs INSIDE an OpenWrt rootfs Docker container.
# Usage: sh /tests/test_upgrade.sh /dist/old.ipk /dist/new.ipk
#    or: sh /tests/test_upgrade.sh /dist/old.apk /dist/new.apk
# Verifies upgrade scenario: install previous release, then install current build.
# Asserts config files are preserved and upgrade hooks don't crash.
set -e

OLD_PKG="$1"
NEW_PKG="$2"

[ -f "$OLD_PKG" ] || { echo "Old package not found: $OLD_PKG"; exit 1; }
[ -f "$NEW_PKG" ] || { echo "New package not found: $NEW_PKG"; exit 1; }

# Minimal rootfs containers don't ship with /var/lock or /var/log — opkg needs them.
mkdir -p /var/lock /var/log

# Detect native arch and register it + 'all' so opkg accepts our _all.ipk.
# Also disable signature check since CI-built IPK is unsigned.
NATIVE_ARCH=$(awk '/^Architecture: / && $2 != "all" {print $2; exit}' /usr/lib/opkg/status 2>/dev/null)
if [ -n "$NATIVE_ARCH" ]; then
    grep -q "^arch $NATIVE_ARCH " /etc/opkg.conf || echo "arch $NATIVE_ARCH 100" >> /etc/opkg.conf
fi
grep -q '^arch all ' /etc/opkg.conf || echo 'arch all 200' >> /etc/opkg.conf
# Disable signature check — our CI IPK is unsigned
sed -i '/^option check_signature/d' /etc/opkg.conf

# Real opkg install. Minimal rootfs images ship no package index, and opkg
# refuses a local _all.ipk until one is loaded (reporting it as "incompatible
# with the architectures configured"), so refresh the index first. No tar
# fallback: if opkg can't install the package, the test must fail.
opkg_install() {
    PKG_FILE="$1"
    opkg update 2>&1 | tee /tmp/opkg-update.out || true
    # --force-downgrade: the CI "new" build is version 0.0.0-test-1, lower than
    # the released "old" package, so installing it on top is a downgrade.
    opkg install --force-depends --force-downgrade "$PKG_FILE" 2>&1 | tee /tmp/opkg.out || true
    opkg list-installed | grep -q '^luci-app-trafficctl '
}

# ── Step 1: install OLD ───────────────────────────────────────────────────────
echo "=== Installing OLD package: $OLD_PKG ==="
case "$OLD_PKG" in
    *.ipk) opkg_install "$OLD_PKG" || { echo "OLD install failed"; cat /tmp/opkg.out; exit 1; } ;;
    *.apk) apk add --allow-untrusted "$OLD_PKG" ;;
    *) echo "Unknown format: $OLD_PKG"; exit 1 ;;
esac

OLD_VER=$(
    if command -v opkg >/dev/null 2>&1; then
        opkg list-installed | awk '/^luci-app-trafficctl /{print $3}'
    else
        apk info -e -v luci-app-trafficctl 2>/dev/null | head -1
    fi
)
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

# ── Step 2: tag config file to verify preservation ────────────────────────────
[ -f /etc/config/trafficctl ] || touch /etc/config/trafficctl
echo "# UPGRADE_MARKER_$(date +%s)" >> /etc/config/trafficctl
MARKER=$(grep UPGRADE_MARKER /etc/config/trafficctl)
echo "Marker line added to /etc/config/trafficctl: $MARKER"

# ── Step 3: install NEW on top ────────────────────────────────────────────────
echo "=== Installing NEW package on top: $NEW_PKG ==="
case "$NEW_PKG" in
    *.ipk)
        # Real opkg upgrade. This now genuinely exercises opkg's conffiles
        # machinery — the config-preservation assertion below is meaningful
        # because opkg (not a manual cp) is what must preserve the marked file.
        opkg_install "$NEW_PKG" || { echo "NEW install failed"; cat /tmp/opkg.out; exit 1; }
        echo "NEW installed via opkg."
        ;;
    *.apk) apk add --allow-untrusted "$NEW_PKG" ;;
esac

NEW_VER=$(
    if command -v opkg >/dev/null 2>&1; then
        opkg list-installed | awk '/^luci-app-trafficctl /{print $3}'
    else
        apk info -e -v luci-app-trafficctl 2>/dev/null | head -1
    fi
)
echo "New version installed: ${NEW_VER:-unknown}"

# ── Step 4: verify ────────────────────────────────────────────────────────────
echo "=== Verification ==="

# Config preserved?
if grep -q UPGRADE_MARKER /etc/config/trafficctl 2>/dev/null; then
    echo "OK: config file marker preserved across upgrade"
else
    echo "FAIL: /etc/config/trafficctl marker lost — config was overwritten"
    exit 1
fi

# New files present?
for f in /usr/libexec/trafficctl/trafficctl-fw.sh \
         /www/luci-static/resources/view/trafficctl/status.js; do
    [ -f "$f" ] || { echo "FAIL: $f missing after upgrade"; exit 1; }
done

# Files the old package owned and the new one does not must be gone: the
# package manager removes them on upgrade, which is why postinst does no
# cleanup of /usr/local/bin. A leftover copy there would be a stale second
# set of helpers that nothing updates.
if [ "$OLD_FW" != /usr/libexec/trafficctl/trafficctl-fw.sh ]; then
    for f in "$(dirname "$OLD_FW")"/trafficctl-*.sh; do
        if [ -e "$f" ]; then echo "FAIL: $f left behind by the upgrade"; exit 1; fi
    done
    echo "OK: helper scripts at the old path removed by the upgrade"
fi

# Only one version installed?
case "$NEW_PKG" in
    *.ipk)
        COUNT=$(opkg list-installed | awk '/^luci-app-trafficctl /' | wc -l)
        ;;
    *.apk)
        COUNT=$(apk info -e luci-app-trafficctl 2>/dev/null | wc -l)
        ;;
esac
if [ "$COUNT" != "1" ]; then
    echo "FAIL: expected exactly 1 installed copy after upgrade, got $COUNT"
    exit 1
fi

# The package manager must actually have swapped the version (real upgrade,
# not a no-op). OLD is a released version; NEW is 0.0.0-test-1.
if [ -n "$OLD_VER" ] && [ "$NEW_VER" = "$OLD_VER" ]; then
    echo "FAIL: version unchanged after upgrade ($NEW_VER) — install did not take"
    exit 1
fi
# so opkg's DB doesn't reflect the installed package. The files-present check
# above already verified the install succeeded.

echo "Upgrade test passed: ${OLD_VER:-?} -> ${NEW_VER:-?}"
