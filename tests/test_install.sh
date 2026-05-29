#!/bin/sh
# Runs INSIDE an OpenWrt rootfs Docker container.
# Usage: sh /tests/test_install.sh /dist/package.ipk
#    or: sh /tests/test_install.sh /dist/package.apk
# Detects format by extension. Extracts and verifies installation.
set -e

PKG="$1"

[ -f "$PKG" ] || { echo "Package not found: $PKG"; exit 1; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

case "$PKG" in
    *.ipk)
        echo "Installing IPK package..."
        if command -v opkg >/dev/null 2>&1; then
            mkdir -p /var/lock /var/log
            # Diagnostic dump so we can read CI logs to understand each image
            echo "=== DIAG: /etc/opkg.conf ==="
            cat /etc/opkg.conf 2>/dev/null || echo "(no opkg.conf)"
            echo "=== DIAG: ls /etc/opkg/ ==="
            ls -la /etc/opkg/ 2>/dev/null || echo "(no /etc/opkg/)"
            echo "=== DIAG: opkg arch-related flags ==="
            opkg --help 2>&1 | grep -iE 'arch|force' || echo "(no arch flags found in help)"
            echo "=== DIAG: installed package sample ==="
            grep -m1 -A1 '^Package: busybox$' /usr/lib/opkg/status 2>/dev/null || echo "(no status)"
            echo "=== END DIAG ==="
            # Older rootfs images don't register the "all" architecture by
            # default, so they reject our _all.ipk. Try --add-arch first, fall
            # back to writing opkg.conf if the flag isn't supported.
            opkg --add-arch all:200 install --force-depends "$PKG" 2>&1 | tee /tmp/opkg-out
            if grep -qE 'Unknown package|incompatible' /tmp/opkg-out; then
                echo "=== Retry: prepend 'arch all 100' to /etc/opkg.conf ==="
                printf 'arch all 100\n%s' "$(cat /etc/opkg.conf)" > /etc/opkg.conf.new
                mv /etc/opkg.conf.new /etc/opkg.conf
                opkg install --force-depends "$PKG"
            fi
        else
            echo "ERROR: opkg not available in this container"
            exit 1
        fi
        ;;
    *.apk)
        echo "Installing APK package..."
        if command -v apk >/dev/null 2>&1; then
            apk add --allow-untrusted "$PKG"
        else
            echo "ERROR: apk not available in this container"
            exit 1
        fi
        ;;
    *)
        echo "Unknown package format: $PKG"
        exit 1
        ;;
esac

# Verify all expected files are present
for f in \
  /usr/local/bin/trafficctl-summary.sh \
  /usr/local/bin/trafficctl-fw.sh \
  /usr/local/bin/trafficctl-device.sh \
  /usr/local/bin/trafficctl-telegram.sh \
  /usr/local/bin/trafficctl-telegram-test.sh \
  /usr/local/bin/trafficctl-block.sh \
  /usr/local/bin/trafficctl-unblock.sh \
  /usr/local/bin/trafficctl-ratelimit.sh \
  /usr/local/bin/trafficctl-ratelimit-stats.sh \
  /usr/local/bin/trafficctl-shape.sh \
  /usr/local/bin/trafficctl-shape-stats.sh \
  /usr/local/bin/trafficctl-bytes.sh \
  /usr/local/bin/trafficctl-rdns.sh \
  /usr/local/bin/trafficctl-macfilter-add.sh \
  /usr/local/bin/trafficctl-macfilter-remove.sh \
  /usr/libexec/rpcd/luci.trafficctl \
  /www/luci-static/resources/view/trafficctl/status.js \
  /www/luci-static/resources/view/trafficctl/status.css \
  /usr/share/luci/menu.d/luci-app-trafficctl.json \
  /usr/share/rpcd/acl.d/luci-app-trafficctl.json \
  /etc/config/trafficctl \
  /etc/hotplug.d/dhcp/99-trafficctl-newdevice \
  /etc/hotplug.d/iface/99-trafficctl-shapes \
  /etc/init.d/trafficctl-telegram; do
  [ -f "$f" ] || { echo "MISSING: $f"; exit 1; }
done

# Verify syntax for all shell scripts
for s in \
  /usr/local/bin/trafficctl-*.sh \
  /usr/libexec/rpcd/luci.trafficctl \
  /etc/hotplug.d/dhcp/99-trafficctl-newdevice \
  /etc/hotplug.d/iface/99-trafficctl-shapes \
  /etc/init.d/trafficctl-telegram; do
  ash -n "$s" || { echo "SYNTAX ERROR: $s"; exit 1; }
done

# Verify execute bit on files that are called directly (not via sh)
for s in \
  /usr/local/bin/trafficctl-*.sh \
  /usr/libexec/rpcd/luci.trafficctl \
  /etc/init.d/trafficctl-telegram; do
  [ -x "$s" ] || { echo "NOT EXECUTABLE: $s"; exit 1; }
done

echo "Install checks passed."

# ── Removal test ─────────────────────────────────────────────────────────────
echo "Testing package removal..."
case "$PKG" in
    *.ipk)
        opkg remove luci-app-trafficctl || {
            echo "REMOVAL FAILED: opkg remove returned non-zero"; exit 1; }
        ;;
    *.apk)
        apk del luci-app-trafficctl || {
            echo "REMOVAL FAILED: apk del returned non-zero"; exit 1; }
        ;;
esac

# Verify primary files are gone (config files in /etc/config may be kept by design)
for f in \
  /usr/local/bin/trafficctl-summary.sh \
  /usr/local/bin/trafficctl-fw.sh \
  /usr/local/bin/trafficctl-block.sh \
  /usr/libexec/rpcd/luci.trafficctl \
  /www/luci-static/resources/view/trafficctl/status.js \
  /www/luci-static/resources/view/trafficctl/status.css \
  /etc/init.d/trafficctl-telegram; do
  [ -f "$f" ] && { echo "REMOVAL FAILED: $f still exists"; exit 1; }
done

echo "Removal verified."
echo "All checks passed ($(echo "$PKG" | sed 's/.*\.//' | tr '[:lower:]' '[:upper:]') format)."
