#!/bin/sh
set -e

PKG_NAME="luci-app-trafficctl"
PKG_VERSION="${1:-1.0.0}"
PKG_RELEASE="${2:-1}"
PKG_ARCH="all"

# Package source tree (feed-compatible subdirectory layout)
SRC="$(dirname "$0")/${PKG_NAME}"

OUTDIR="dist"
WORKDIR=$(mktemp -d)

trap 'rm -rf "$WORKDIR"' EXIT

# Build data.tar.gz — actual package files
DATA="$WORKDIR/data"
mkdir -p "$DATA"

cp -a "$SRC/root/"* "$DATA/"
mkdir -p "$DATA/www/luci-static/resources/view/trafficctl"
cp "$SRC/htdocs/luci-static/resources/view/trafficctl/status.js" "$DATA/www/luci-static/resources/view/trafficctl/"
cp "$SRC/htdocs/luci-static/resources/view/trafficctl/status.css" "$DATA/www/luci-static/resources/view/trafficctl/"

# Ensure scripts are executable
chmod +x "$DATA/usr/local/bin/trafficctl-"*.sh
chmod +x "$DATA/usr/libexec/rpcd/luci.trafficctl"
[ -d "$DATA/etc/init.d" ] && chmod +x "$DATA/etc/init.d/"*

(cd "$DATA" && tar czf "$WORKDIR/data.tar.gz" .)

# Build control.tar.gz — package metadata
CTRL="$WORKDIR/control"
mkdir -p "$CTRL"

cat > "$CTRL/control" <<EOF
Package: $PKG_NAME
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: conntrack, luci-base, rpcd, curl
Source: https://github.com/YusDyr/luci-app-trafficctl
License: Apache-2.0
Section: luci
Architecture: $PKG_ARCH
Maintainer: Denis Iusupov <yusdyr@gmail.com>
Description: Per-device traffic monitoring, rate limiting (nft/iptables),
 traffic shaping (tc/HTB), internet blocking, and WiFi MAC filtering.
EOF

# Conffiles must list ONLY files that ship in data.tar.gz and may be user-edited.
# shapes.json / telegram_known.json are runtime state created by scripts at
# runtime — they're NOT in the package, so listing them as conffiles makes
# opkg complain "Failed to open file" on every install.
cat > "$CTRL/conffiles" <<EOF
/etc/config/trafficctl
EOF

cat > "$CTRL/preinst" <<'EOF'
#!/bin/sh
# Stop telegram bot before upgrade to avoid stale process
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ]; then
    /etc/init.d/trafficctl-telegram stop 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$CTRL/preinst"

cat > "$CTRL/postinst" <<'EOF'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ]; then
    /etc/init.d/rpcd restart 2>/dev/null || true
    if [ -x /etc/init.d/trafficctl-telegram ]; then
        /etc/init.d/trafficctl-telegram start 2>/dev/null || true
    fi
fi
exit 0
EOF
chmod +x "$CTRL/postinst"

cat > "$CTRL/prerm" <<'EOF'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ]; then
    /etc/init.d/trafficctl-telegram stop 2>/dev/null || true
    /etc/init.d/trafficctl-telegram disable 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$CTRL/prerm"

(cd "$CTRL" && tar czf "$WORKDIR/control.tar.gz" .)

# Assemble ipk: gzip-compressed tar archive (OpenWrt opkg format, NOT Debian ar)
echo "2.0" > "$WORKDIR/debian-binary"

mkdir -p "$OUTDIR"
IPK_FILE="$OUTDIR/${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}.ipk"

(cd "$WORKDIR" && tar --numeric-owner --owner=0 --group=0 -czf "$OLDPWD/$IPK_FILE" ./debian-binary ./control.tar.gz ./data.tar.gz)

echo "$IPK_FILE"
