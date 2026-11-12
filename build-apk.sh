#!/bin/sh
# Build .apk packages for OpenWrt 25.12+ (apk-tools v3)
# Requires: apk-tools compiled with -Dminimal=false (provides 'apk mkpkg')
# Usage: sh build-apk.sh <version> <release>
# Output: dist/trafficctl_<version>-r<release>_noarch.apk (the backend),
#         dist/luci-i18n-trafficctl-<lang>_<version>-r<release>_noarch.apk,
#         dist/luci-app-trafficctl_<version>-r<release>_noarch.apk (last line)
set -e

PKG_NAME="luci-app-trafficctl"
BE_NAME="trafficctl"
PKG_VERSION="${1:-1.0.0}"
PKG_RELEASE="${2:-1}"

# Package source trees (feed-compatible subdirectory layout)
TCTL_ROOT="$(dirname "$0")"
SRC="$TCTL_ROOT/${PKG_NAME}"
BACKEND_SRC="$TCTL_ROOT/${BE_NAME}"

# Runtime dependencies of the backend (DEPENDS in trafficctl/Makefile). They
# are repeated on luci-app-trafficctl for the reason given at LUCI_DEPENDS in
# luci-app-trafficctl/Makefile.
# hostapd-utils is optional for the backend (wired-only builds) and is only
# repeated on luci-app-trafficctl.
BE_DEPENDS="conntrack curl tc iw kmod-nft-netdev"
FE_EXTRA_DEPENDS="hostapd-utils"

OUTDIR="dist"
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

have_mkpkg() {
    command -v apk >/dev/null 2>&1 && apk mkpkg --help >/dev/null 2>&1
}

# build_apk <name> <section> <description> <depends> <data dir> <scripts dir> [replaces]
# Prints the path of the package written. <scripts dir> may be empty or hold
# any of post-install, pre-upgrade, post-upgrade, pre-deinstall.
build_apk() {
    _name="$1" _section="$2" _desc="$3" _deps="$4" _data="$5" _scripts="$6" _replaces="${7:-}"
    _file="$OUTDIR/${_name}_${PKG_VERSION}-r${PKG_RELEASE}_noarch.apk"
    mkdir -p "$OUTDIR"

    if have_mkpkg; then
        # Use apk mkpkg if available (OpenWrt's apk-tools fork)
        set -- \
            --info "name:${_name}" \
            --info "version:${PKG_VERSION}-r${PKG_RELEASE}" \
            --info "description:${_desc}" \
            --info "arch:noarch" \
            --info "license:Apache-2.0" \
            --info "origin:https://github.com/YusDyr/luci-app-trafficctl" \
            --info "url:https://github.com/YusDyr/luci-app-trafficctl" \
            --info "maintainer:Denis Iusupov <yusdyr@gmail.com>" \
            --info "depends:${_deps}" \
            --info "provides:${_name}=${PKG_VERSION}-r${PKG_RELEASE}" \
            --info "tags:openwrt:section=${_section}"
        [ -n "$_replaces" ] && set -- "$@" --info "replaces:${_replaces}"
        for _s in post-install pre-upgrade post-upgrade pre-deinstall; do
            [ -n "$_scripts" ] && [ -f "$_scripts/$_s" ] && set -- "$@" --script "$_s:$_scripts/$_s"
        done
        apk mkpkg "$@" --files "$_data" --output "$_file"
    else
        # Fallback: build APKv2 manually (two concatenated gzipped tars)
        _ctrl="$WORKDIR/control-$_name"
        mkdir -p "$_ctrl"
        {
            echo "pkgname = ${_name}"
            echo "pkgver = ${PKG_VERSION}-r${PKG_RELEASE}"
            echo "pkgdesc = ${_desc}"
            echo "arch = noarch"
            echo "license = Apache-2.0"
            echo "origin = https://github.com/YusDyr/luci-app-trafficctl"
            echo "url = https://github.com/YusDyr/luci-app-trafficctl"
            echo "maintainer = Denis Iusupov <yusdyr@gmail.com>"
            for _d in $_deps; do echo "depend = $_d"; done
            [ -n "$_replaces" ] && echo "replaces = $_replaces"
        } > "$_ctrl/.PKGINFO"
        for _s in post-install pre-upgrade post-upgrade pre-deinstall; do
            [ -n "$_scripts" ] && [ -f "$_scripts/$_s" ] && cp "$_scripts/$_s" "$_ctrl/.$_s"
        done

        # Control tar (metadata + scripts), data tar (package files)
        tar -czf "$WORKDIR/control-$_name.tar.gz" -C "$_ctrl" .
        tar -czf "$WORKDIR/data-$_name.tar.gz" -C "$_data" .

        # APKv2: concatenate control + data
        cat "$WORKDIR/control-$_name.tar.gz" "$WORKDIR/data-$_name.tar.gz" > "$_file"
    fi
    echo "$_file"
}

# ── trafficctl: the backend ────────────────────────────────────────────────
BE_DATA="$WORKDIR/backend-data"
mkdir -p "$BE_DATA"
cp -a "$BACKEND_SRC/files/"* "$BE_DATA/"

chmod +x "$BE_DATA/usr/libexec/trafficctl/trafficctl-"*.sh
chmod +x "$BE_DATA/www/cgi-bin/trafficctl-metrics"
[ -d "$BE_DATA/etc/init.d" ] && chmod +x "$BE_DATA/etc/init.d/"*
[ -d "$BE_DATA/etc/hotplug.d" ] && find "$BE_DATA/etc/hotplug.d" -type f -exec chmod +x {} +

# --- Conffiles (embedded in lib/apk/packages for APK protected-paths) ---
# Only list files that ship in the package; shapes.json / telegram_known.json
# are runtime state created by scripts and should NOT be conffiles.
mkdir -p "$BE_DATA/lib/apk/packages"
cat > "$BE_DATA/lib/apk/packages/${BE_NAME}.conffiles" <<'EOF'
/etc/config/trafficctl
EOF

BE_SCRIPTS="$WORKDIR/backend-scripts"
mkdir -p "$BE_SCRIPTS"

# The same steps as Package/trafficctl/postinst in trafficctl/Makefile, which
# explains each one; the SDK runs that one after an install and an upgrade.
cat > "$BE_SCRIPTS/post-install" <<'SCRIPT'
#!/bin/sh
# The config holds the Telegram bot token and the metrics token, so it must not
# be world-readable before the first save from the UI applies the same mode.
chmod 0600 "${IPKG_INSTROOT}/etc/config/trafficctl" 2>/dev/null || true
if [ -z "${IPKG_INSTROOT}" ]; then
    # Releases up to 1.30.1 gave the cut keeper START=95, so rc.d may
    # still link it for boot. It is started on demand only.
    rm -f /etc/rc.d/S95trafficctl-cut /etc/rc.d/K10trafficctl-cut
    # Each service follows its uci flag, so what runs now is what runs after
    # the next reboot: enabled in rc.d and started when the flag is 1, left
    # alone when it is 0.
    if [ -x /etc/init.d/trafficctl-telegram ] && [ "$(uci -q get trafficctl.telegram.enabled)" = "1" ]; then
        /etc/init.d/trafficctl-telegram enable 2>/dev/null || true
        /etc/init.d/trafficctl-telegram start 2>/dev/null || true
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
    # tctl_block_add inserts drop rules into inet fw4 forward (or iptables
    # FORWARD). fw4 reload rebuilds that table from /etc/config/firewall,
    # so every trafficctl block disappears while rules.json and the UI
    # still say the device is blocked. The lan-ifup hotplug hook restores
    # them after a reboot, but not after a mid-session reload
    # (https-dns-proxy restart, a LuCI firewall edit, ...). This include
    # runs the restore after every firewall reload. Rate limits and
    # port-forward pauses live in their own tables (netdev tm_ratelimit,
    # inet tctl_pfw) and survive a fw4 reload, so they are not replayed.
    # delete+set so an upgrade is idempotent.
    if command -v uci >/dev/null 2>&1 && [ -f /etc/config/firewall ]; then
        uci -q delete firewall.trafficctl_restore
        uci -q set firewall.trafficctl_restore=include
        uci -q set firewall.trafficctl_restore.type=script
        uci -q set firewall.trafficctl_restore.path=/usr/libexec/trafficctl/trafficctl-fw-restore.sh
        uci -q set firewall.trafficctl_restore.fw4_compatible=1
        uci -q commit firewall
    fi
fi
exit 0
SCRIPT
cp "$BE_SCRIPTS/post-install" "$BE_SCRIPTS/post-upgrade"

cat > "$BE_SCRIPTS/pre-upgrade" <<'SCRIPT'
#!/bin/sh
# Stop telegram bot before upgrade to avoid stale process
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ]; then
    /etc/init.d/trafficctl-telegram stop 2>/dev/null || true
fi
exit 0
SCRIPT

cat > "$BE_SCRIPTS/pre-deinstall" <<'SCRIPT'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-telegram ]; then
    /etc/init.d/trafficctl-telegram stop 2>/dev/null || true
    /etc/init.d/trafficctl-telegram disable 2>/dev/null || true
fi
# Fail open. A global internet cut left engaged by a package that is going away
# is a lockout with no UI left to undo it.
if [ -z "${IPKG_INSTROOT}" ] && [ -x /usr/libexec/trafficctl/trafficctl-cut.sh ]; then
    /usr/libexec/trafficctl/trafficctl-cut.sh release >/dev/null 2>&1 || true
fi
if [ -z "${IPKG_INSTROOT}" ] && [ -x /etc/init.d/trafficctl-cut ]; then
    /etc/init.d/trafficctl-cut stop 2>/dev/null || true
    /etc/init.d/trafficctl-cut disable 2>/dev/null || true
fi
# Drop the firewall include so a leftover path does not fail a later fw4 reload.
if [ -z "${IPKG_INSTROOT}" ] && command -v uci >/dev/null 2>&1; then
    uci -q delete firewall.trafficctl_restore
    uci -q commit firewall
fi
exit 0
SCRIPT
chmod +x "$BE_SCRIPTS"/*

# replaces: releases up to 1.28.x shipped these files in luci-app-trafficctl.
# Lets this package be added on its own, or before the new
# luci-app-trafficctl, over an old install. The SDK build cannot set it and
# does not need it when both are upgraded in one transaction.
build_apk "$BE_NAME" net \
    "Per-device traffic monitoring (conntrack), rate limiting (nft/iptables), traffic shaping (tc/HTB), internet blocking, WiFi MAC filtering, a global internet cut, a Telegram bot and a Prometheus exporter. The web interface is luci-app-trafficctl. WiFi MAC filtering needs hostapd-utils (optional; without it a WiFi block is a temporary ban)." \
    "$BE_DEPENDS" "$BE_DATA" "$BE_SCRIPTS" "$PKG_NAME"

# ── luci-app-trafficctl: the web interface ─────────────────────────────────
DATA="$WORKDIR/data"
mkdir -p "$DATA"

cp -a "$SRC/root/"* "$DATA/"
mkdir -p "$DATA/www/luci-static/resources/view/trafficctl"
# Copy every view/asset so new files (portfw.js, ...) can't be missed
cp "$SRC/htdocs/luci-static/resources/view/trafficctl/"* "$DATA/www/luci-static/resources/view/trafficctl/"

chmod +x "$DATA/usr/libexec/rpcd/luci.trafficctl"

SCRIPTS="$WORKDIR/scripts"
mkdir -p "$SCRIPTS"

# The same steps as Package/luci-app-trafficctl/postinst in
# luci-app-trafficctl/Makefile, after an install and after an upgrade.
cat > "$SCRIPTS/post-install" <<'SCRIPT'
#!/bin/sh
if [ -z "${IPKG_INSTROOT}" ]; then
    rm -f /tmp/luci-indexcache.*
    rm -rf /tmp/luci-modulecache
    /etc/init.d/rpcd restart 2>/dev/null || true
fi
exit 0
SCRIPT
cp "$SCRIPTS/post-install" "$SCRIPTS/post-upgrade"
chmod +x "$SCRIPTS"/*

# The backend is pinned to the same version, as in build-ipk.sh.
APK_FILE=$(build_apk "$PKG_NAME" luci \
    "Per-device traffic monitoring, rate limiting (nft/iptables), traffic shaping (tc/HTB), internet blocking, WiFi MAC filtering, and Telegram bot control." \
    "${BE_NAME}=${PKG_VERSION}-r${PKG_RELEASE} $BE_DEPENDS $FE_EXTRA_DEPENDS luci-base rpcd" "$DATA" "$SCRIPTS")

# --- Translations, one package per language ---
#
# Same split the feed build produces (luci.mk's LuciTranslation) and the same
# split build-ipk.sh produces: a separate arch-all package per language that
# depends on the main one. These carry no lifecycle scripts — the uci-defaults
# snippet that registers the language is run by OpenWrt itself on first boot
# after install.
# shellcheck source=tools/i18n.sh
. "$TCTL_ROOT/tools/i18n.sh"

for lang in $(i18n_langs); do
    code=$(i18n_code "$lang") || { echo "unknown language '$lang' — add it to tools/luci-languages.tsv" >&2; exit 1; }
    i18n_pkg=$(i18n_pkgname "$lang")
    i18n_data="$WORKDIR/i18n-$code"

    i18n_stage "$lang" "$i18n_data" || {
        echo "no translatable strings for '$lang' — skipping $i18n_pkg" >&2
        continue
    }

    i18n_file="$OUTDIR/${i18n_pkg}_${PKG_VERSION}-r${PKG_RELEASE}_noarch.apk"

    if command -v apk >/dev/null 2>&1 && apk mkpkg --help >/dev/null 2>&1; then
        apk mkpkg \
            --info "name:${i18n_pkg}" \
            --info "version:${PKG_VERSION}-r${PKG_RELEASE}" \
            --info "description:Translation for ${PKG_NAME} - $(i18n_name "$lang")" \
            --info "arch:noarch" \
            --info "license:Apache-2.0" \
            --info "origin:https://github.com/YusDyr/luci-app-trafficctl" \
            --info "url:https://github.com/YusDyr/luci-app-trafficctl" \
            --info "maintainer:Denis Iusupov <yusdyr@gmail.com>" \
            --info "depends:${PKG_NAME}" \
            --info "provides:${i18n_pkg}=${PKG_VERSION}-r${PKG_RELEASE}" \
            --info "tags:openwrt:section=luci" \
            --files "$i18n_data" \
            --output "$i18n_file"
    else
        I18N_CTRL="$WORKDIR/i18n-control-$code"
        mkdir -p "$I18N_CTRL"
        cat > "$I18N_CTRL/.PKGINFO" <<PKGINFO
pkgname = ${i18n_pkg}
pkgver = ${PKG_VERSION}-r${PKG_RELEASE}
pkgdesc = Translation for ${PKG_NAME} - $(i18n_name "$lang")
arch = noarch
license = Apache-2.0
origin = https://github.com/YusDyr/luci-app-trafficctl
url = https://github.com/YusDyr/luci-app-trafficctl
maintainer = Denis Iusupov <yusdyr@gmail.com>
depend = ${PKG_NAME}
PKGINFO
        tar -czf "$WORKDIR/i18n-control-$code.tar.gz" -C "$I18N_CTRL" .
        tar -czf "$WORKDIR/i18n-data-$code.tar.gz" -C "$i18n_data" .
        cat "$WORKDIR/i18n-control-$code.tar.gz" "$WORKDIR/i18n-data-$code.tar.gz" > "$i18n_file"
    fi

    echo "$i18n_file"
done

if ! command -v apk >/dev/null 2>&1; then
    # The fallback path emits the older concatenated-tarball layout. apk-tools 3
    # (OpenWrt 25.12+) rejects it with "file format is invalid or inconsistent";
    # only the SDK build in auto-release.yml produces an installable APK.
    echo "WARNING: built without 'apk mkpkg' — this file is NOT installable by apk-tools 3." >&2
    echo "         For a dev install, extract the payload tarball directly instead." >&2
fi

echo "$APK_FILE"
