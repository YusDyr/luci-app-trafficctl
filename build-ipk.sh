#!/bin/sh
set -e

PKG_NAME="luci-app-trafficctl"
PKG_VERSION="${1:-1.0.0}"
PKG_RELEASE="${2:-1}"
PKG_ARCH="all"

# The packages, in the feed-compatible subdirectory layout: the backend
# (trafficctl), the Telegram bot (trafficctl-telegram, from the same
# directory) and the web interface that depends on both (luci-app-trafficctl).
BE_NAME="trafficctl"
TG_NAME="trafficctl-telegram"
# The bot's files under trafficctl/files (Package/trafficctl-telegram/install).
TG_FILES="usr/share/ucode/trafficctl/telegram.uc usr/libexec/trafficctl/trafficctl-telegram.sh usr/libexec/trafficctl/trafficctl-telegram.uc etc/init.d/trafficctl-telegram"
TCTL_ROOT="$(dirname "$0")"
SRC="$TCTL_ROOT/${PKG_NAME}"
BACKEND_SRC="$TCTL_ROOT/${BE_NAME}"
# Runtime dependencies of the backend (DEPENDS in trafficctl/Makefile).
# hostapd-utils is optional for the backend (wired-only builds) and is only
# repeated on luci-app-trafficctl; see LUCI_DEPENDS in its Makefile.
BE_DEPENDS="conntrack, curl, tc, iw, kmod-nft-netdev, firewall4, ucode, ucode-mod-fs, ucode-mod-uci, ucode-mod-ubus"
FE_EXTRA_DEPENDS="hostapd-utils"

# Overridable so tests can build without touching a developer's dist/.
OUTDIR="${OUTDIR:-dist}"
WORKDIR=$(mktemp -d)

trap 'rm -rf "$WORKDIR"' EXIT

# Reproducible tar: fixed mtime, numeric owner, sorted entry order. --sort and
# --mtime are GNU-tar-only, so entries are normalized on disk and fed to tar
# pre-sorted via -T - instead, which both GNU tar and BSD tar accept.
TAR_REPRO="--owner=0 --group=0 --numeric-owner"

repro_tar() { # <source dir> <output .tar.gz>
    find "$1" -exec touch -t 200001010000 {} +
    (cd "$1" && find . ! -name '._*' | LC_ALL=C sort | \
        COPYFILE_DISABLE=1 tar --format ustar --no-recursion $TAR_REPRO -cf - -T - | \
        gzip -9n) > "$2"
}

# Assemble ipk: gzip-compressed tar archive (OpenWrt opkg format, NOT Debian ar)
assemble_ipk() { # <package name> <arch> <stage dir with data/ and control/>
    _name="$1"
    _arch="$2"
    _stage="$3"

    repro_tar "$_stage/data" "$_stage/data.tar.gz"
    repro_tar "$_stage/control" "$_stage/control.tar.gz"
    echo "2.0" > "$_stage/debian-binary"

    mkdir -p "$OUTDIR"
    _ipk="$OUTDIR/${_name}_${PKG_VERSION}-${PKG_RELEASE}_${_arch}.ipk"
    # The archive is written from inside $_stage, so the destination has to be
    # resolved here — OUTDIR may be given as either a relative or an absolute path.
    case "$_ipk" in /*) _out="$_ipk" ;; *) _out="$PWD/$_ipk" ;; esac

    touch -t 200001010000 "$_stage/debian-binary" "$_stage/control.tar.gz" "$_stage/data.tar.gz"
    (cd "$_stage" && printf '%s\n' ./debian-binary ./control.tar.gz ./data.tar.gz | \
        COPYFILE_DISABLE=1 tar --format ustar --no-recursion $TAR_REPRO -cf - -T - | \
        gzip -9n > "$_out")

    echo "$_ipk"
}

# ── trafficctl: the backend ────────────────────────────────────────────────
# Helper scripts, init scripts, hotplug hooks, the config and the metrics CGI.
BE_STAGE="$WORKDIR/backend"
BE_DATA="$BE_STAGE/data"
mkdir -p "$BE_DATA"

cp -a "$BACKEND_SRC/files/"* "$BE_DATA/"

# Ensure scripts are executable
chmod +x "$BE_DATA/usr/libexec/trafficctl/trafficctl-"*.sh "$BE_DATA/usr/sbin/trafficctl"
chmod +x "$BE_DATA/www/cgi-bin/trafficctl-metrics"
[ -d "$BE_DATA/etc/init.d" ] && chmod +x "$BE_DATA/etc/init.d/"*
[ -d "$BE_DATA/etc/hotplug.d" ] && find "$BE_DATA/etc/hotplug.d" -type f -exec chmod +x {} +
[ -d "$BE_DATA/etc/uci-defaults" ] && chmod +x "$BE_DATA/etc/uci-defaults/"*

BE_CTRL="$BE_STAGE/control"
mkdir -p "$BE_CTRL"

# Replaces: releases up to 1.28.x shipped every file of this package inside
# luci-app-trafficctl. The SDK build cannot emit this field and needs none
# (opkg hands the files over when both packages are installed in one run), but
# with it these files also install in either order, or this one on its own
# over an old luci-app-trafficctl. No Conflicts: the new luci-app-trafficctl
# depends on this package, so a conflict would make the upgrade impossible.
cat > "$BE_CTRL/control" <<EOF
Package: $BE_NAME
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: $BE_DEPENDS
Replaces: $PKG_NAME
Source: https://github.com/YusDyr/luci-app-trafficctl
License: Apache-2.0
Section: net
Architecture: $PKG_ARCH
Maintainer: Denis Iusupov <yusdyr@gmail.com>
Description: Per-device traffic monitoring (conntrack), rate limiting
 (nftables), traffic shaping (tc/HTB), internet blocking, WiFi MAC
 filtering, a global internet cut, device notifications and a Prometheus
 exporter. The web interface is luci-app-trafficctl, the Telegram bot
 trafficctl-telegram. WiFi MAC filtering needs
 hostapd-utils (optional; without it a WiFi block is a temporary ban).
EOF

# Conffiles must list ONLY files that ship in data.tar.gz and may be user-edited.
# shapes.json / telegram_known.json are runtime state created by scripts at
# runtime — they're NOT in the package, so listing them as conffiles makes
# opkg complain "Failed to open file" on every install.
cat > "$BE_CTRL/conffiles" <<EOF
/etc/config/trafficctl
EOF

# The same steps as Package/trafficctl/postinst in trafficctl/Makefile, which
# explains each one; tests/test_postinst_parity.sh keeps the copies in step.
cat > "$BE_CTRL/postinst" <<'EOF'
#!/bin/sh
# The config holds the Telegram bot token and the metrics token, so it must not
# be world-readable before the first save from the UI applies the same mode.
chmod 0600 "${IPKG_INSTROOT}/etc/config/trafficctl" 2>/dev/null || true
if [ -z "${IPKG_INSTROOT}" ]; then
    # opkg's copy of the config, left by the move out of the single package of
    # releases up to 1.28.x. The config itself is kept.
    if [ -f /etc/config/trafficctl ]; then
        rm -f /etc/config/trafficctl-opkg.backup
    fi
    # The byte counter table of releases up to 1.30.x, often left half-built.
    nft delete table inet trafficctl_mon 2>/dev/null || true
    # Releases up to 1.30.1 gave the cut keeper START=95, so rc.d may
    # still link it for boot. It is started on demand only.
    rm -f /etc/rc.d/S95trafficctl-cut /etc/rc.d/K10trafficctl-cut
    # An engaged cut's keeper runs the old release's code; restart it onto
    # `trafficctl cut keeper`.
    if [ -f /var/run/trafficctl/cut.state ] && [ -x /etc/init.d/trafficctl-cut ]; then
        /etc/init.d/trafficctl-cut restart 2>/dev/null || true
    fi
    # Each service follows its uci flag, so what runs now is what runs after
    # the next reboot: enabled in rc.d and started when the flag is 1, left
    # alone when it is 0.
    # The Telegram options of releases up to 1.30.x move to the notification
    # senders (once: only while the 'notify' section is missing).
    if [ -x /usr/sbin/trafficctl ]; then
        /usr/sbin/trafficctl notify migrate >/dev/null 2>&1 || true
    fi
    # A bot of a release up to 1.30.x lost its files to trafficctl-telegram
    # with this upgrade. Without that package it would run on until the next
    # reboot, and rc.d would keep links to a missing init script.
    if [ ! -e /etc/init.d/trafficctl-telegram ]; then
        ubus call service delete '{"name":"trafficctl-telegram"}' >/dev/null 2>&1 || true
        rm -f /etc/rc.d/S99trafficctl-telegram /etc/rc.d/K10trafficctl-telegram
    fi
    # The watcher decides for itself whether anything wants the scan.
    if [ -x /etc/init.d/trafficctl-notify ]; then
        /etc/init.d/trafficctl-notify enable 2>/dev/null || true
        /etc/init.d/trafficctl-notify restart 2>/dev/null || true
    fi
    # A sampler started by a release up to 1.28.0 still calls the helpers at
    # /usr/local/bin, which this upgrade removed; restart it onto the new path.
    if [ -x /etc/init.d/trafficctl-history ]; then
        if [ "$(uci -q get trafficctl.history.enabled)" = "1" ]; then
            /etc/init.d/trafficctl-history enable 2>/dev/null || true
        fi
        if /etc/init.d/trafficctl-history enabled; then
            /etc/init.d/trafficctl-history restart 2>/dev/null || true
        fi
    fi
fi
exit 0
EOF

cat > "$BE_CTRL/prerm" <<'EOF'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-notify ]; then
    /etc/init.d/trafficctl-notify stop 2>/dev/null || true
    /etc/init.d/trafficctl-notify disable 2>/dev/null || true
fi
# Fail open. A global internet cut left engaged by a package that is going away
# is a lockout with no UI left to undo it — the rule would sit in nftables with
# nothing on the router admitting to owning it.
# The release needs ucode; whatever it managed, no state is left for a keeper
# to re-assert from, and no table.
if [ -z "${IPKG_INSTROOT}" ]; then
    /usr/sbin/trafficctl cut release >/dev/null 2>&1 || true
    rm -f /var/run/trafficctl/cut.state /etc/trafficctl/cut.state
    nft delete table inet tctl_cut 2>/dev/null || true
fi
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-cut ]; then
    /etc/init.d/trafficctl-cut stop 2>/dev/null || true
    /etc/init.d/trafficctl-cut disable 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$BE_CTRL/postinst" "$BE_CTRL/prerm"

# ── trafficctl-telegram: the bot ───────────────────────────────────────────
# The files of Package/trafficctl-telegram/install in trafficctl/Makefile,
# moved out of the backend's tree.
TG_STAGE="$WORKDIR/telegram"
TG_DATA="$TG_STAGE/data"
for f in $TG_FILES; do
    mkdir -p "$TG_DATA/$(dirname "$f")"
    mv "$BE_DATA/$f" "$TG_DATA/$f"
done
chmod +x "$TG_DATA/usr/libexec/trafficctl/"* "$TG_DATA/etc/init.d/"*

TG_CTRL="$TG_STAGE/control"
mkdir -p "$TG_CTRL"

# Replaces: releases up to 1.30.x shipped these files in trafficctl, so this
# package installs over one of those in either order.
cat > "$TG_CTRL/control" <<EOF
Package: $TG_NAME
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: $BE_NAME (= ${PKG_VERSION}-${PKG_RELEASE}), curl
Replaces: $BE_NAME
Source: https://github.com/YusDyr/luci-app-trafficctl
License: Apache-2.0
Section: net
Architecture: $PKG_ARCH
Maintainer: Denis Iusupov <yusdyr@gmail.com>
Description: A Telegram bot for trafficctl: device status, and block, WiFi
 block, limit and shape buttons per device.
EOF

cat > "$TG_CTRL/preinst" <<'EOF'
#!/bin/sh
# Stop the bot before the upgrade replaces it.
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ]; then
    /etc/init.d/trafficctl-telegram stop 2>/dev/null || true
fi
exit 0
EOF

# The same steps as Package/trafficctl-telegram/postinst and prerm in
# trafficctl/Makefile; tests/test_postinst_parity.sh keeps the copies in step.
cat > "$TG_CTRL/postinst" <<'EOF'
#!/bin/sh
# Restarted, not started: a bot of a release up to 1.30.x runs the device scan
# itself, which the notification watcher took over. Enabled in rc.d and
# started only when trafficctl.telegram.enabled is 1, so what runs now is what
# runs after the next reboot.
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ] && [ "$(uci -q get trafficctl.telegram.enabled)" = "1" ]; then
    /etc/init.d/trafficctl-telegram enable 2>/dev/null || true
    /etc/init.d/trafficctl-telegram restart 2>/dev/null || true
fi
exit 0
EOF

cat > "$TG_CTRL/prerm" <<'EOF'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ]; then
    /etc/init.d/trafficctl-telegram stop 2>/dev/null || true
    /etc/init.d/trafficctl-telegram disable 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$TG_CTRL/preinst" "$TG_CTRL/postinst" "$TG_CTRL/prerm"

# ── luci-app-trafficctl: the web interface ─────────────────────────────────
STAGE="$WORKDIR/main"
DATA="$STAGE/data"
mkdir -p "$DATA"

cp -a "$SRC/root/"* "$DATA/"
mkdir -p "$DATA/www/luci-static/resources/view/trafficctl"
# Copy every view/asset so new files (portfw.js, ...) can't be missed
cp "$SRC/htdocs/luci-static/resources/view/trafficctl/"* "$DATA/www/luci-static/resources/view/trafficctl/"

chmod +x "$DATA/usr/libexec/rpcd/luci.trafficctl"

CTRL="$STAGE/control"
mkdir -p "$CTRL"

# The backend is pinned to the same version: the rpcd plugin calls the helpers
# with the arguments of its own release, and without the pin
# `opkg upgrade luci-app-trafficctl` would leave an older backend in place.
#
# The backend's own dependencies are repeated here on purpose; see
# LUCI_DEPENDS in luci-app-trafficctl/Makefile. Without them, upgrading from a
# release up to 1.28.x makes opkg drop conntrack, curl, iw and hostapd-utils
# as orphans of the old luci-app-trafficctl, in the same run that installs
# trafficctl, which needs them.
cat > "$CTRL/control" <<EOF
Package: $PKG_NAME
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: $BE_NAME (= ${PKG_VERSION}-${PKG_RELEASE}), $TG_NAME (= ${PKG_VERSION}-${PKG_RELEASE}), $BE_DEPENDS, $FE_EXTRA_DEPENDS, luci-base, rpcd
Source: https://github.com/YusDyr/luci-app-trafficctl
License: Apache-2.0
Section: luci
Architecture: $PKG_ARCH
Maintainer: Denis Iusupov <yusdyr@gmail.com>
Description: Per-device traffic monitoring, rate limiting (nftables),
 traffic shaping (tc/HTB), internet blocking, and WiFi MAC filtering.
EOF

# The same steps as Package/luci-app-trafficctl/postinst in
# luci-app-trafficctl/Makefile, which explains each one.
cat > "$CTRL/postinst" <<'EOF'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ]; then
    if [ -f /etc/config/trafficctl ]; then
        rm -f /etc/config/trafficctl-opkg.backup
    fi
    rm -f /tmp/luci-indexcache.*
    rm -rf /tmp/luci-modulecache
    /etc/init.d/rpcd restart 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$CTRL/postinst"

# Printed first; callers taking the last line of stdout get luci-app-trafficctl.
assemble_ipk "$BE_NAME" "$PKG_ARCH" "$BE_STAGE"
assemble_ipk "$TG_NAME" "$PKG_ARCH" "$TG_STAGE"

# Translations, one package per language, mirroring what the feed build
# produces. Printed BEFORE luci-app-trafficctl so that callers taking the last
# line of stdout still get luci-app-trafficctl itself.
# shellcheck source=tools/i18n.sh
. "$TCTL_ROOT/tools/i18n.sh"

for lang in $(i18n_langs); do
    code=$(i18n_code "$lang") || { echo "unknown language '$lang' — add it to tools/luci-languages.tsv" >&2; exit 1; }
    i18n_pkg=$(i18n_pkgname "$lang")
    i18n_stage_dir="$WORKDIR/i18n-$code"
    mkdir -p "$i18n_stage_dir/control"

    i18n_stage "$lang" "$i18n_stage_dir/data" || {
        echo "no translatable strings for '$lang' — skipping $i18n_pkg" >&2
        continue
    }

    cat > "$i18n_stage_dir/control/control" <<EOF
Package: $i18n_pkg
Version: ${PKG_VERSION}-${PKG_RELEASE}
Depends: $PKG_NAME
Source: https://github.com/YusDyr/luci-app-trafficctl
License: Apache-2.0
Section: luci
Architecture: all
Maintainer: Denis Iusupov <yusdyr@gmail.com>
Description: Translation for $PKG_NAME - $(i18n_name "$lang")
EOF

    assemble_ipk "$i18n_pkg" "all" "$i18n_stage_dir"
done

assemble_ipk "$PKG_NAME" "$PKG_ARCH" "$STAGE"
