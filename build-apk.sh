#!/bin/sh
# Build .apk package for OpenWrt 25.12+ (apk-tools v3)
# Requires: apk-tools compiled with -Dminimal=false (provides 'apk mkpkg')
# Usage: sh build-apk.sh <version> <release>
# Output: dist/luci-app-trafficctl_<version>-r<release>_noarch.apk
set -e

PKG_NAME="luci-app-trafficctl"
PKG_VERSION="${1:-1.0.0}"
PKG_RELEASE="${2:-1}"

# Package source tree (feed-compatible subdirectory layout)
SRC="$(dirname "$0")/${PKG_NAME}"

OUTDIR="dist"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# --- Prepare package file tree ---
DATA="$WORKDIR/data"
mkdir -p "$DATA"

cp -a "$SRC/root/"* "$DATA/"
mkdir -p "$DATA/www/luci-static/resources/view/trafficctl"
cp "$SRC/htdocs/luci-static/resources/view/trafficctl/status.js" "$DATA/www/luci-static/resources/view/trafficctl/"
cp "$SRC/htdocs/luci-static/resources/view/trafficctl/status.css" "$DATA/www/luci-static/resources/view/trafficctl/"

chmod +x "$DATA/usr/local/bin/trafficctl-"*.sh
chmod +x "$DATA/usr/libexec/rpcd/luci.trafficctl"
[ -d "$DATA/etc/init.d" ] && chmod +x "$DATA/etc/init.d/"*

# --- Conffiles (embedded in lib/apk/packages for APK protected-paths) ---
# Only list files that ship in the package; shapes.json / telegram_known.json
# are runtime state created by scripts and should NOT be conffiles.
mkdir -p "$DATA/lib/apk/packages"
cat > "$DATA/lib/apk/packages/${PKG_NAME}.conffiles" <<'EOF'
/etc/config/trafficctl
EOF

# --- Lifecycle scripts ---
SCRIPTS="$WORKDIR/scripts"
mkdir -p "$SCRIPTS"

cat > "$SCRIPTS/post-install" <<'SCRIPT'
#!/bin/sh
[ -n "${IPKG_INSTROOT}" ] || /etc/init.d/rpcd restart 2>/dev/null || true
exit 0
SCRIPT

cat > "$SCRIPTS/pre-upgrade" <<'SCRIPT'
#!/bin/sh
# Stop telegram bot before upgrade to avoid stale process
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ]; then
    /etc/init.d/trafficctl-telegram stop 2>/dev/null || true
fi
exit 0
SCRIPT

cat > "$SCRIPTS/post-upgrade" <<'SCRIPT'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ]; then
    /etc/init.d/rpcd restart 2>/dev/null || true
    if [ -x /etc/init.d/trafficctl-telegram ]; then
        /etc/init.d/trafficctl-telegram start 2>/dev/null || true
    fi
fi
exit 0
SCRIPT

cat > "$SCRIPTS/pre-deinstall" <<'SCRIPT'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ]; then
    /etc/init.d/trafficctl-telegram stop 2>/dev/null || true
    /etc/init.d/trafficctl-telegram disable 2>/dev/null || true
fi
exit 0
SCRIPT

chmod +x "$SCRIPTS"/*

# --- Build .apk ---
mkdir -p "$OUTDIR"
APK_FILE="$OUTDIR/${PKG_NAME}_${PKG_VERSION}-r${PKG_RELEASE}_noarch.apk"

if command -v apk >/dev/null 2>&1 && apk mkpkg --help >/dev/null 2>&1; then
    # Use apk mkpkg if available (OpenWrt's apk-tools fork)
    apk mkpkg \
        --info "name:${PKG_NAME}" \
        --info "version:${PKG_VERSION}-r${PKG_RELEASE}" \
        --info "description:Per-device traffic monitoring, rate limiting (nft/iptables), traffic shaping (tc/HTB), internet blocking, WiFi MAC filtering, and Telegram bot control." \
        --info "arch:noarch" \
        --info "license:Apache-2.0" \
        --info "origin:https://github.com/YusDyr/luci-app-trafficctl" \
        --info "url:https://github.com/YusDyr/luci-app-trafficctl" \
        --info "maintainer:Denis Iusupov <yusdyr@gmail.com>" \
        --info "depends:conntrack luci-base rpcd" \
        --info "provides:${PKG_NAME}=${PKG_VERSION}-r${PKG_RELEASE}" \
        --info "tags:openwrt:section=luci" \
        --script "post-install:$SCRIPTS/post-install" \
        --script "pre-upgrade:$SCRIPTS/pre-upgrade" \
        --script "post-upgrade:$SCRIPTS/post-upgrade" \
        --script "pre-deinstall:$SCRIPTS/pre-deinstall" \
        --files "$DATA" \
        --output "$APK_FILE"
else
    # Fallback: build APKv2 manually (two concatenated gzipped tars)
    CTRL="$WORKDIR/control"
    mkdir -p "$CTRL"

    cat > "$CTRL/.PKGINFO" <<PKGINFO
pkgname = ${PKG_NAME}
pkgver = ${PKG_VERSION}-r${PKG_RELEASE}
pkgdesc = Per-device traffic monitoring, rate limiting (nft/iptables), traffic shaping (tc/HTB), internet blocking, WiFi MAC filtering, and Telegram bot control.
arch = noarch
license = Apache-2.0
origin = https://github.com/YusDyr/luci-app-trafficctl
url = https://github.com/YusDyr/luci-app-trafficctl
maintainer = Denis Iusupov <yusdyr@gmail.com>
depend = conntrack
depend = luci-base
depend = rpcd
PKGINFO

    cp "$SCRIPTS/post-install" "$CTRL/.post-install"
    cp "$SCRIPTS/pre-upgrade" "$CTRL/.pre-upgrade"
    cp "$SCRIPTS/post-upgrade" "$CTRL/.post-upgrade"
    cp "$SCRIPTS/pre-deinstall" "$CTRL/.pre-deinstall"

    # Control tar (metadata + scripts)
    tar -czf "$WORKDIR/control.tar.gz" -C "$CTRL" .

    # Data tar (package files)
    tar -czf "$WORKDIR/data.tar.gz" -C "$DATA" .

    # APKv2: concatenate control + data
    cat "$WORKDIR/control.tar.gz" "$WORKDIR/data.tar.gz" > "$APK_FILE"
fi

echo "$APK_FILE"
