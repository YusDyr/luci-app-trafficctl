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
# Copy every view/asset so new files (portfw.js, ...) can't be missed
cp "$SRC/htdocs/luci-static/resources/view/trafficctl/"* "$DATA/www/luci-static/resources/view/trafficctl/"

# Ensure scripts are executable
chmod +x "$DATA/usr/local/bin/trafficctl-"*.sh
chmod +x "$DATA/usr/libexec/rpcd/luci.trafficctl"
[ -d "$DATA/etc/init.d" ] && chmod +x "$DATA/etc/init.d/"*
[ -d "$DATA/etc/hotplug.d" ] && find "$DATA/etc/hotplug.d" -type f -exec chmod +x {} +

# Reproducible tar: fixed mtime, numeric owner, sorted entry order. --sort and
# --mtime are GNU-tar-only, so entries are normalized on disk and fed to tar
# pre-sorted via -T - instead, which both GNU tar and BSD tar accept.
TAR_REPRO="--owner=0 --group=0 --numeric-owner"
find "$DATA" -exec touch -t 200001010000 {} +
(cd "$DATA" && find . ! -name '._*' | LC_ALL=C sort | \
    COPYFILE_DISABLE=1 tar --format ustar --no-recursion $TAR_REPRO -cf - -T - | \
    gzip -9n > "$WORKDIR/data.tar.gz")

# Build control.tar.gz — package metadata
CTRL="$WORKDIR/control"
mkdir -p "$CTRL"

cat > "$CTRL/control" <<EOF
Package: $PKG_NAME
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: conntrack, luci-base, rpcd, curl, tc, iw, hostapd-utils
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
# The config holds the Telegram bot token and the metrics token, so it must not
# be world-readable before the first save from the UI applies the same mode.
chmod 0600 "${IPKG_INSTROOT}/etc/config/trafficctl" 2>/dev/null || true
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
# Fail open. A global internet cut left engaged by a package that is going away
# is a lockout with no UI left to undo it — the rule would sit in nftables with
# nothing on the router admitting to owning it.
if [ -z "${IPKG_INSTROOT}" ] && [ -x /usr/local/bin/trafficctl-cut.sh ]; then
    /usr/local/bin/trafficctl-cut.sh release >/dev/null 2>&1 || true
fi
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-cut ]; then
    /etc/init.d/trafficctl-cut stop 2>/dev/null || true
    /etc/init.d/trafficctl-cut disable 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$CTRL/prerm"

find "$CTRL" -exec touch -t 200001010000 {} +
(cd "$CTRL" && find . ! -name '._*' | LC_ALL=C sort | \
    COPYFILE_DISABLE=1 tar --format ustar --no-recursion $TAR_REPRO -cf - -T - | \
    gzip -9n > "$WORKDIR/control.tar.gz")

# Assemble ipk: gzip-compressed tar archive (OpenWrt opkg format, NOT Debian ar)
echo "2.0" > "$WORKDIR/debian-binary"

mkdir -p "$OUTDIR"
IPK_FILE="$OUTDIR/${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${PKG_ARCH}.ipk"

touch -t 200001010000 "$WORKDIR/debian-binary" "$WORKDIR/control.tar.gz" "$WORKDIR/data.tar.gz"
(cd "$WORKDIR" && printf '%s\n' ./debian-binary ./control.tar.gz ./data.tar.gz | \
    COPYFILE_DISABLE=1 tar --format ustar --no-recursion $TAR_REPRO -cf - -T - | \
    gzip -9n > "$OLDPWD/$IPK_FILE")

echo "$IPK_FILE"
