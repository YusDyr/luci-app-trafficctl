#!/bin/sh
# Runs INSIDE an OpenWrt rootfs Docker container.
# Usage: sh /tests/test_dependencies.sh /dist/package.ipk
#    or: sh /tests/test_dependencies.sh /dist/package.apk
#
# Verifies that:
#   1) Installing WITHOUT resolving deps fails with a sane error
#   2) After `opkg update` / proper feed config, install succeeds and resolves deps
#
# Note: the minimal OpenWrt rootfs containers have no conntrack/luci-base installed
# out of the box, so this exercises the "missing deps" failure path naturally.

# Diagnostic: confirm script entered + show args. Dependencies 25.12.4 has been
# exiting 1 in ~2s with no stdout — this surfaces whether the script even runs.
set -e

PKG="$1"
[ -f "$PKG" ] || { echo "Package not found: $PKG"; exit 1; }

# opkg-specific setup. Skip entirely on apk-only rootfs images (25.12+) where
# /usr/lib/opkg/status and /etc/opkg.conf don't exist — running awk on the
# missing status file makes `set -e` + busybox ash kill the script silently
# inside `VAR=$(awk ...)`.
if command -v opkg >/dev/null 2>&1; then
    # Minimal rootfs containers don't ship with /var/lock or /var/log — opkg needs them.
    mkdir -p /var/lock /var/log

    # Detect native arch and register it + 'all' so opkg accepts our _all.ipk.
    # Also disable signature check since CI-built IPK is unsigned.
    NATIVE_ARCH=$(awk '/^Architecture: / && $2 != "all" {print $2; exit}' /usr/lib/opkg/status 2>/dev/null || true)
    if [ -n "$NATIVE_ARCH" ]; then
        grep -q "^arch $NATIVE_ARCH " /etc/opkg.conf || echo "arch $NATIVE_ARCH 100" >> /etc/opkg.conf
    fi
    grep -q '^arch all ' /etc/opkg.conf || echo 'arch all 200' >> /etc/opkg.conf
    sed -i '/^option check_signature/d' /etc/opkg.conf
fi

# ── Phase 1: install without --force-depends, expect failure ─────────────────
echo "=== Phase 1: install without dep resolution (expecting failure) ==="
case "$PKG" in
    *.ipk)
        # Without --force-depends, opkg should refuse if deps missing
        if opkg install "$PKG" 2>&1 | tee /tmp/opkg.out; then
            # Did it actually install? Check
            if opkg list-installed | grep -q "^luci-app-trafficctl "; then
                echo "WARNING: install succeeded — deps may already be present in this image."
                echo "Skipping Phase 1 failure assertion."
            fi
        else
            if grep -qiE "satisfy|depend" /tmp/opkg.out; then
                echo "OK: opkg refused install with missing deps (expected)"
            else
                echo "FAIL: opkg failed but not because of missing deps"
                exit 1
            fi
        fi
        ;;
    *.apk)
        if apk add --allow-untrusted "$PKG" 2>&1 | tee /tmp/apk.out; then
            if apk info -e luci-app-trafficctl >/dev/null 2>&1; then
                echo "WARNING: apk install succeeded — deps may already be present."
            fi
        else
            if grep -qiE "depend|missing|unsatisfied" /tmp/apk.out; then
                echo "OK: apk refused install with missing deps (expected)"
            else
                echo "FAIL: apk failed but not because of missing deps"
                exit 1
            fi
        fi
        ;;
esac

# ── Phase 2: update package index, then install — should resolve deps ────────
echo "=== Phase 2: install with dep resolution ==="
case "$PKG" in
    *.ipk)
        # Try to update opkg's package index. May fail if network/feeds aren't set up.
        if ! opkg update 2>&1 | tee /tmp/opkg-update.out; then
            echo "WARNING: opkg update failed — skipping Phase 2"
            echo "(this typically means distfeeds.conf isn't configured in the rootfs)"
            exit 0
        fi
        # Now install — opkg should pull in conntrack/luci-base/rpcd automatically
        opkg install --force-depends "$PKG"
        ;;
    *.apk)
        if ! apk update 2>&1 | tee /tmp/apk-update.out; then
            echo "WARNING: apk update failed — skipping Phase 2"
            exit 0
        fi
        apk add --allow-untrusted "$PKG"
        ;;
esac

# Verify deps were actually pulled in
echo "=== Verifying deps installed ==="
for dep in conntrack rpcd luci-base; do
    case "$PKG" in
        *.ipk)
            if opkg list-installed | grep -q "^$dep "; then
                echo "OK: $dep is installed"
            else
                echo "FAIL: dep $dep not installed after package install"
                exit 1
            fi
            ;;
        *.apk)
            if apk info -e "$dep" >/dev/null 2>&1; then
                echo "OK: $dep is installed"
            else
                echo "FAIL: dep $dep not installed after package install"
                exit 1
            fi
            ;;
    esac
done

echo "Dependency test passed."
