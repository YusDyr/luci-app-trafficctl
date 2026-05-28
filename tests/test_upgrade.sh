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

# ── Step 1: install OLD ───────────────────────────────────────────────────────
echo "=== Installing OLD package: $OLD_PKG ==="
case "$OLD_PKG" in
    *.ipk) opkg install --force-depends "$OLD_PKG" ;;
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

# Verify file present
[ -f /usr/local/bin/trafficctl-fw.sh ] || { echo "OLD install: trafficctl-fw.sh missing"; exit 1; }

# ── Step 2: tag config file to verify preservation ────────────────────────────
[ -f /etc/config/trafficctl ] || touch /etc/config/trafficctl
echo "# UPGRADE_MARKER_$(date +%s)" >> /etc/config/trafficctl
MARKER=$(grep UPGRADE_MARKER /etc/config/trafficctl)
echo "Marker line added to /etc/config/trafficctl: $MARKER"

# ── Step 3: install NEW on top ────────────────────────────────────────────────
echo "=== Installing NEW package on top: $NEW_PKG ==="
case "$NEW_PKG" in
    *.ipk) opkg install --force-depends "$NEW_PKG" ;;
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
for f in /usr/local/bin/trafficctl-fw.sh \
         /www/luci-static/resources/view/trafficctl/status.js; do
    [ -f "$f" ] || { echo "FAIL: $f missing after upgrade"; exit 1; }
done

# Only one version installed?
case "$NEW_PKG" in
    *.ipk)
        COUNT=$(opkg list-installed | awk '/^luci-app-trafficctl /' | wc -l)
        ;;
    *.apk)
        COUNT=$(apk info -e luci-app-trafficctl 2>/dev/null | wc -l)
        ;;
esac
if [ "$COUNT" -ne 1 ]; then
    echo "FAIL: expected exactly 1 installed copy, got $COUNT"
    exit 1
fi

echo "Upgrade test passed: ${OLD_VER:-?} -> ${NEW_VER:-?}"
