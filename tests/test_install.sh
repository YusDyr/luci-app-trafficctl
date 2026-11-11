#!/bin/sh
# Runs INSIDE an OpenWrt rootfs Docker container.
# Usage: sh /tests/test_install.sh /dist/trafficctl.ipk /dist/luci-app-trafficctl.ipk
#    or: sh /tests/test_install.sh /dist/trafficctl.apk /dist/luci-app-trafficctl.apk
# Detects format by extension. Installs both packages in one run, verifies the
# files and who owns them, then removes both.
set -e

[ "$#" -ge 2 ] || { echo "usage: $0 <trafficctl package> <luci-app-trafficctl package>"; exit 1; }
PKG="$1"
for p in "$@"; do
    [ -f "$p" ] || { echo "Package not found: $p"; exit 1; }
    [ "${p##*.}" = "${PKG##*.}" ] || { echo "Mixed package formats: $*"; exit 1; }
done
PKGS="trafficctl luci-app-trafficctl"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

case "$PKG" in
    *.ipk)
        echo "Installing IPK package..."
        if command -v opkg >/dev/null 2>&1; then
            mkdir -p /var/lock /var/log

            # Register native arch + 'all', drop signature check
            NATIVE_ARCH=$(awk '/^Architecture: / && $2 != "all" {print $2; exit}' /usr/lib/opkg/status 2>/dev/null)
            if [ -n "$NATIVE_ARCH" ]; then
                grep -q "^arch $NATIVE_ARCH " /etc/opkg.conf || echo "arch $NATIVE_ARCH 100" >> /etc/opkg.conf
            fi
            grep -q '^arch all ' /etc/opkg.conf || echo 'arch all 200' >> /etc/opkg.conf
            sed -i '/^option check_signature/d' /etc/opkg.conf

            # Load a package index. Minimal rootfs images ship none, and opkg
            # refuses to install even a local _all.ipk until an index is present
            # (it misreports the condition as "incompatible with the
            # architectures configured"). This is what makes the real opkg
            # install path actually work in these containers.
            opkg update 2>&1 | tee /tmp/opkg-update.out || true

            # Install for real and require success — no tar fallback, so a
            # genuine opkg failure fails the test instead of being masked.
            opkg install --force-depends "$@" 2>&1 | tee /tmp/opkg.out || true
            for name in $PKGS; do
                if ! opkg list-installed | grep -q "^$name "; then
                    echo "ERROR: opkg install failed — $name not registered"
                    cat /tmp/opkg.out
                    exit 1
                fi
            done
            echo "Installed via opkg."
        else
            echo "ERROR: opkg not available in this container"
            exit 1
        fi
        ;;
    *.apk)
        echo "Installing APK package..."
        if command -v apk >/dev/null 2>&1; then
            # Installing a local .apk still resolves its dependencies from the
            # distribution feeds, so unreachable feeds make this test impossible
            # to run — a different thing from the package being broken. Probe
            # first and report that distinctly (78), so the caller can tell
            # "upstream is down" from "our package failed to install".
            if ! apk update >/tmp/apk-update.out 2>&1; then
                echo "::warning::package feeds are unreachable in this image:"
                tail -5 /tmp/apk-update.out
                echo "SKIP: cannot resolve dependencies, upstream feeds unavailable"
                exit 78
            fi
            # Tolerate post-install hook failures from OTHER packages (e.g.,
            # upstream rpcd-mod-luci / rpcd-mod-ucode post-install scripts in
            # the snapshot rootfs occasionally exit non-zero). What matters is
            # that OUR package's files land on the rootfs — the file-presence
            # check below will fail loudly if they didn't.
            apk add --allow-untrusted "$@" || {
                APK_EXIT=$?
                echo "::warning::apk add exited $APK_EXIT — checking whether both packages installed regardless."
                for name in $PKGS; do
                    if apk info -e "$name" >/dev/null 2>&1; then
                        echo "$name is installed despite apk add exit $APK_EXIT (likely upstream post-install hook noise)."
                    else
                        echo "ERROR: apk add failed and $name is not installed."
                        exit "$APK_EXIT"
                    fi
                done
            }
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
  /usr/libexec/trafficctl/trafficctl-summary.sh \
  /usr/libexec/trafficctl/trafficctl-fw.sh \
  /usr/libexec/trafficctl/trafficctl-device.sh \
  /usr/libexec/trafficctl/trafficctl-telegram.sh \
  /usr/libexec/trafficctl/trafficctl-telegram-test.sh \
  /usr/libexec/trafficctl/trafficctl-block.sh \
  /usr/libexec/trafficctl/trafficctl-unblock.sh \
  /usr/libexec/trafficctl/trafficctl-ratelimit.sh \
  /usr/libexec/trafficctl/trafficctl-ratelimit-stats.sh \
  /usr/libexec/trafficctl/trafficctl-shape.sh \
  /usr/libexec/trafficctl/trafficctl-shape-stats.sh \
  /usr/libexec/trafficctl/trafficctl-bytes.sh \
  /usr/libexec/trafficctl/trafficctl-totals.sh \
  /usr/libexec/trafficctl/trafficctl-rdns.sh \
  /usr/libexec/trafficctl/trafficctl-rules.sh \
  /usr/libexec/trafficctl/trafficctl-macfilter-add.sh \
  /usr/libexec/trafficctl/trafficctl-macfilter-remove.sh \
  /usr/libexec/rpcd/luci.trafficctl \
  /www/luci-static/resources/view/trafficctl/status.js \
  /www/luci-static/resources/view/trafficctl/status.css \
  /usr/share/luci/menu.d/luci-app-trafficctl.json \
  /usr/share/rpcd/acl.d/luci-app-trafficctl.json \
  /etc/config/trafficctl \
  /etc/hotplug.d/dhcp/99-trafficctl-newdevice \
  /etc/hotplug.d/iface/99-trafficctl-shapes \
  /etc/init.d/trafficctl-telegram \
  /lib/upgrade/keep.d/trafficctl \
  /www/cgi-bin/trafficctl-metrics; do
  [ -f "$f" ] || { echo "MISSING: $f"; exit 1; }
done

# Verify syntax for all shell scripts
for s in \
  /usr/libexec/trafficctl/trafficctl-*.sh \
  /usr/libexec/rpcd/luci.trafficctl \
  /etc/hotplug.d/dhcp/99-trafficctl-newdevice \
  /etc/hotplug.d/iface/99-trafficctl-shapes \
  /etc/init.d/trafficctl-telegram; do
  ash -n "$s" || { echo "SYNTAX ERROR: $s"; exit 1; }
done

# Verify execute bit on files that are called directly (not via sh)
for s in \
  /usr/libexec/trafficctl/trafficctl-*.sh \
  /usr/libexec/rpcd/luci.trafficctl \
  /etc/init.d/trafficctl-telegram; do
  [ -x "$s" ] || { echo "NOT EXECUTABLE: $s"; exit 1; }
done

# Each file belongs to the package that is meant to ship it: the backend to
# trafficctl, the view and its rpcd plugin to luci-app-trafficctl.
owner_of() {
    case "$PKG" in
        *.ipk) opkg search "$1" | awk '{print $1; exit}' ;;
        *.apk) apk info --who-owns "$1" 2>/dev/null | awk '{print $NF; exit}' | sed 's/-[0-9][^-]*-r[0-9]*$//' ;;
    esac
}
for f in \
  /usr/libexec/trafficctl/trafficctl-fw.sh \
  /etc/config/trafficctl \
  /etc/init.d/trafficctl-telegram \
  /etc/hotplug.d/iface/99-trafficctl-shapes \
  /lib/upgrade/keep.d/trafficctl \
  /www/cgi-bin/trafficctl-metrics; do
  o=$(owner_of "$f")
  [ "$o" = trafficctl ] || { echo "WRONG OWNER: $f is owned by '$o', expected trafficctl"; exit 1; }
done
for f in \
  /usr/libexec/rpcd/luci.trafficctl \
  /www/luci-static/resources/view/trafficctl/status.js \
  /usr/share/rpcd/acl.d/luci-app-trafficctl.json; do
  o=$(owner_of "$f")
  [ "$o" = luci-app-trafficctl ] || { echo "WRONG OWNER: $f is owned by '$o', expected luci-app-trafficctl"; exit 1; }
done

# The shipped config has the bot and the history sampler off, and the postinst
# enables in rc.d only what its uci flag switches on. Only for the ipk, which
# build-ipk.sh makes with our postinst alone: the apk comes from the SDK, whose
# default_postinst enables every init script on a fresh install, and the flag
# check in each service is what keeps that harmless.
if [ "${PKG##*.}" = ipk ]; then
    for svc in trafficctl-telegram trafficctl-history; do
        if /etc/init.d/$svc enabled; then
            echo "ENABLED: $svc is in rc.d although trafficctl.${svc#trafficctl-}.enabled is 0"
            exit 1
        fi
    done
fi

# The nft byte counters, against this image's real nft and the host kernel.
# The unit tests replay listings; only here does the shipped script talk to a
# real nft, so a table nft refuses, or a listing the parser cannot read, shows
# up as the silent conntrack fallback it causes on a router. Needs
# --cap-add NET_ADMIN; TCTL_EXPECT_NFT=1 (set by compat.yml for every fw4
# release) turns "cannot run" into a failure instead of a skip. The kernel is
# the CI runner's, not OpenWrt's: this proves the userspace half (syntax,
# listing format, parser) per release, and the kernel half only for the
# runner's kernel.
nft_bytes_check() {
    B=/usr/libexec/trafficctl/trafficctl-bytes-nft.sh
    nft delete table inet trafficctl_mon 2>/dev/null || true
    sh "$B" >/dev/null 2>&1 || true
    if ! nft -t list table inet trafficctl_mon > "$TMPDIR/mon.txt" 2>&1; then
        echo "NFT BYTES: the counter table was not built (the script fell back to conntrack)"
        # The script discards nft's error; replay its batch to show it.
        sed -n "/<<'NFT'/,/^NFT\$/p" "$B" | sed '1d;$d' | nft -f - || true
        return 1
    fi
    cat "$TMPDIR/mon.txt"
    if ! grep -q 'set bytes_in {' "$TMPDIR/mon.txt" || ! grep -q 'set bytes_out {' "$TMPDIR/mon.txt"; then
        echo "NFT BYTES: bytes_in/bytes_out are not sets"
        return 1
    fi
    # Count real packets through the same two rules on an output hook (a
    # container forwards nothing), then read them back through the script.
    nft add chain inet trafficctl_mon ci_out '{ type filter hook output priority 0; policy accept; }'
    nft add rule inet trafficctl_mon ci_out 'update @bytes_in { ip daddr counter }'
    nft add rule inet trafficctl_mon ci_out 'update @bytes_out { ip saddr counter }'
    ping -c 3 -W 1 127.0.0.1 >/dev/null 2>&1 || true
    nft delete chain inet trafficctl_mon ci_out
    # Twice: as shipped (JSON where the image has it), and with `nft -j`
    # refused, as on nftables-nojson, so the text parser meets real output too.
    mkdir -p "$TMPDIR/nojson"
    printf '#!/bin/sh\n[ "$1" = -j ] && exit 1\nexec %s "$@"\n' "$(command -v nft)" > "$TMPDIR/nojson/nft"
    chmod +x "$TMPDIR/nojson/nft"
    for mode in default nojson; do
        if [ "$mode" = nojson ]; then
            out=$(PATH="$TMPDIR/nojson:$PATH" sh "$B" 2>&1)
        else
            out=$(sh "$B" 2>&1)
        fi
        echo "bytes-nft ($mode): $out"
        case "$out" in
            *'"ip":"127.0.0.1","bytes_in":'[1-9]*'"src":"nft","degraded":false'*) ;;
            *) echo "NFT BYTES ($mode): counted loopback traffic is missing or degraded"; return 1 ;;
        esac
    done
    nft delete table inet trafficctl_mon
}
if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
    nft_bytes_check || exit 1
    echo "nft byte counters verified."
elif [ "${TCTL_EXPECT_NFT:-0}" = 1 ]; then
    echo "NFT BYTES: nft is unusable here (missing, or no NET_ADMIN), but TCTL_EXPECT_NFT=1"
    exit 1
else
    echo "SKIP: nft byte counters (no usable nft in this container)"
fi

echo "Install checks passed."

# ── Removal test ─────────────────────────────────────────────────────────────
echo "Testing package removal..."
case "$PKG" in
    *.ipk)
        # Install is now guaranteed to have gone through opkg, so the package is
        # in opkg's DB — remove it the real way and require success.
        # The web interface first: it depends on the backend.
        opkg remove luci-app-trafficctl || { echo "REMOVAL FAILED: opkg remove luci-app-trafficctl returned non-zero"; exit 1; }
        opkg remove trafficctl || { echo "REMOVAL FAILED: opkg remove trafficctl returned non-zero"; exit 1; }
        ;;
    *.apk)
        apk del luci-app-trafficctl trafficctl || {
            echo "REMOVAL FAILED: apk del returned non-zero"; exit 1; }
        ;;
esac

# Verify primary files are gone (config files in /etc/config may be kept by design)
for f in \
  /usr/libexec/trafficctl/trafficctl-summary.sh \
  /usr/libexec/trafficctl/trafficctl-fw.sh \
  /usr/libexec/trafficctl/trafficctl-block.sh \
  /usr/libexec/rpcd/luci.trafficctl \
  /www/luci-static/resources/view/trafficctl/status.js \
  /www/luci-static/resources/view/trafficctl/status.css \
  /etc/init.d/trafficctl-telegram \
  /www/cgi-bin/trafficctl-metrics; do
  [ -f "$f" ] && { echo "REMOVAL FAILED: $f still exists"; exit 1; }
done

echo "Removal verified."
echo "All checks passed ($(echo "$PKG" | sed 's/.*\.//' | tr '[:lower:]' '[:upper:]') format)."
