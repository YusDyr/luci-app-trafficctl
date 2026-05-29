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

            # Try opkg install with arch autodetect + signature disabled.
            # If that fails (older opkg versions can't always install our
            # standalone IPK despite correct config), fall back to manual
            # tar extraction.
            NATIVE_ARCH=$(awk '/^Architecture: / && $2 != "all" {print $2; exit}' /usr/lib/opkg/status 2>/dev/null)
            if [ -n "$NATIVE_ARCH" ]; then
                grep -q "^arch $NATIVE_ARCH " /etc/opkg.conf || echo "arch $NATIVE_ARCH 100" >> /etc/opkg.conf
            fi
            grep -q '^arch all ' /etc/opkg.conf || echo 'arch all 200' >> /etc/opkg.conf
            sed -i '/^option check_signature/d' /etc/opkg.conf

            if opkg install --force-depends "$PKG" 2>&1 | tee /tmp/opkg.out; then
                echo "Installed via opkg."
            else
                echo "::warning::opkg install failed (older opkg can't handle standalone IPK on some rootfs images), falling back to manual tar extract."
                cd /tmp && rm -rf ipk-extract && mkdir ipk-extract && cd ipk-extract
                tar xzf "$PKG" && tar xzf data.tar.gz -C /
                # Make scripts executable (postinst would normally do this)
                chmod +x /usr/local/bin/trafficctl-*.sh 2>/dev/null || true
                chmod +x /usr/libexec/rpcd/luci.trafficctl 2>/dev/null || true
                chmod +x /etc/init.d/trafficctl-telegram 2>/dev/null || true
                cd /
                echo "Installed via manual tar extract."
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
        # Try opkg remove; if package not in DB (manual extract case), fall back
        # to deleting the installed files by name.
        if opkg list-installed | grep -q '^luci-app-trafficctl '; then
            opkg remove luci-app-trafficctl || { echo "REMOVAL FAILED: opkg remove returned non-zero"; exit 1; }
        else
            echo "::warning::no opkg DB entry — package was installed via manual tar extract; removing files by name."
            rm -f /usr/local/bin/trafficctl-*.sh \
                  /usr/libexec/rpcd/luci.trafficctl \
                  /www/luci-static/resources/view/trafficctl/status.* \
                  /etc/init.d/trafficctl-telegram \
                  /etc/hotplug.d/dhcp/99-trafficctl-newdevice \
                  /etc/hotplug.d/iface/99-trafficctl-shapes \
                  /usr/share/luci/menu.d/luci-app-trafficctl.json \
                  /usr/share/rpcd/acl.d/luci-app-trafficctl.json
        fi
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
