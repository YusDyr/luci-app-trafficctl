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
  /usr/sbin/trafficctl \
  /usr/share/ucode/trafficctl/lib.uc \
  /usr/share/ucode/trafficctl/net.uc \
  /usr/share/ucode/trafficctl/report.uc \
  /usr/share/ucode/trafficctl/cut.uc \
  /usr/share/ucode/trafficctl/portfw.uc \
  /usr/libexec/trafficctl/trafficctl-cut.sh \
  /usr/libexec/trafficctl/trafficctl-portfw.sh \
  /etc/init.d/trafficctl-cut \
  /usr/libexec/trafficctl/trafficctl-summary.sh \
  /usr/libexec/trafficctl/trafficctl-fw.sh \
  /usr/libexec/trafficctl/trafficctl-device.sh \
  /usr/libexec/trafficctl/trafficctl-names.sh \
  /usr/libexec/trafficctl/trafficctl-subnets.sh \
  /usr/libexec/trafficctl/trafficctl-ifaces.sh \
  /usr/libexec/trafficctl/trafficctl-rdns-refresh.sh \
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
  /etc/hotplug.d/dhcp/99-trafficctl-newdevice \
  /etc/hotplug.d/iface/99-trafficctl-shapes \
  /etc/init.d/trafficctl-telegram; do
  ash -n "$s" || { echo "SYNTAX ERROR: $s"; exit 1; }
done

# Verify execute bit on files that are called directly (not via sh)
for s in \
  /usr/sbin/trafficctl \
  /usr/libexec/trafficctl/trafficctl-*.sh \
  /usr/libexec/rpcd/luci.trafficctl \
  /etc/init.d/trafficctl-telegram; do
  [ -x "$s" ] || { echo "NOT EXECUTABLE: $s"; exit 1; }
done

# The ucode CLI runs on this release's own interpreter and finds its modules
# on the default search path, directly and through the old script names.
# None of these needs a running ubusd.
for c in "/usr/sbin/trafficctl names list" "/usr/libexec/trafficctl/trafficctl-names.sh list"; do
    out=$($c 2>&1)
    [ "$out" = "[]" ] || { echo "CLI FAILED: $c printed: $out"; exit 1; }
done
for c in subnets ifaces bytes totals "totals --all" summary "netify list"; do
    out=$(/usr/sbin/trafficctl $c 2>&1)
    case "$out" in "["*"]") ;; *) echo "CLI FAILED: trafficctl $c printed: $out"; exit 1 ;; esac
done
for c in "/usr/sbin/trafficctl metrics" /usr/libexec/trafficctl/trafficctl-metrics.sh; do
    out=$($c 2>&1)
    case "$out" in "# trafficctl metrics are disabled"*) ;; *) echo "CLI FAILED: $c printed: $out"; exit 1 ;; esac
done
# ── PR7: cut and portfw. Status only reads (no rule, no keeper), and a
#    container without nf_tables still answers with JSON.
for c in "/usr/sbin/trafficctl cut status" "/usr/libexec/trafficctl/trafficctl-cut.sh status"; do
    out=$($c 2>&1)
    case "$out" in '{"ok":true,"active":false,'*) ;; *) echo "CLI FAILED: $c printed: $out"; exit 1 ;; esac
done
for c in "/usr/sbin/trafficctl portfw list" "/usr/libexec/trafficctl/trafficctl-portfw.sh list"; do
    out=$($c 2>&1)
    case "$out" in "["*"]") ;; *) echo "CLI FAILED: $c printed: $out"; exit 1 ;; esac
done
# ── end PR7
if /usr/sbin/trafficctl bogus >/dev/null 2>&1; then
    echo "CLI FAILED: an unknown command exited 0"; exit 1
fi

# PR8 history
# history.uc, its init script and the old script name, which is a shim now.
for f in /usr/share/ucode/trafficctl/history.uc /etc/init.d/trafficctl-history \
         /usr/libexec/trafficctl/trafficctl-history.sh; do
    [ -f "$f" ] || { echo "MISSING: $f"; exit 1; }
done
grep -q '/usr/sbin/trafficctl history keeper' /etc/init.d/trafficctl-history ||
    { echo "INIT FAILED: trafficctl-history does not run the ucode keeper"; exit 1; }
for c in "/usr/sbin/trafficctl history status" "/usr/libexec/trafficctl/trafficctl-history.sh status"; do
    out=$($c 2>&1)
    case "$out" in '{"enabled":false,'*'}') ;; *) echo "CLI FAILED: $c printed: $out"; exit 1 ;; esac
done
out=$(/usr/sbin/trafficctl history periods 2>&1)
[ "$out" = "[]" ] || { echo "CLI FAILED: trafficctl history periods printed: $out"; exit 1; }
/usr/sbin/trafficctl history validate-dir /mnt/usb ||
    { echo "CLI FAILED: validate-dir refused /mnt/usb"; exit 1; }
if /usr/sbin/trafficctl history validate-dir /etc; then
    echo "CLI FAILED: validate-dir accepted /etc"; exit 1
fi
# end PR8 history

# The rpcd plugin is ucode too: its signature table, a read that needs only
# uci, and the version, read from this package manager's database (never
# "dev" once installed, never by running opkg).
RPCD=/usr/libexec/rpcd/luci.trafficctl
case "$($RPCD list 2>&1)" in *'"version":{}'*) ;; *) echo "RPCD FAILED: list printed: $($RPCD list 2>&1)"; exit 1 ;; esac
out=$(echo '{}' | $RPCD call config_get 2>&1)
case "$out" in '{"enabled":'*) ;; *) echo "RPCD FAILED: config_get printed: $out"; exit 1 ;; esac
out=$(echo '{}' | $RPCD call version 2>&1)
case "$out" in '{"version":"dev"}'|'{"version":""}'|*error*) echo "RPCD FAILED: version printed: $out"; exit 1 ;;
    '{"version":"'*) echo "rpcd plugin: $out" ;;
    *) echo "RPCD FAILED: version printed: $out"; exit 1 ;; esac

# The same plugin behind this release's own rpcd. rpcd writes a call's
# arguments to the plugin's stdin and closes it; the plugin reads to the end,
# so a call with arguments returning at all (well inside rpcd's 30 s exec
# timeout) is what proves the close.
if [ -x /sbin/rpcd ] && [ -x /sbin/ubusd ]; then
    mkdir -p /var/run
    /sbin/ubusd & UBUSD_PID=$!
    sleep 1
    /sbin/rpcd & RPCD_PID=$!
    i=0
    until ubus list luci.trafficctl >/dev/null 2>&1; do
        i=$((i + 1))
        [ "$i" -lt 20 ] || { echo "RPCD FAILED: rpcd never registered luci.trafficctl"; exit 1; }
        sleep 1
    done
    t0=$(date +%s)
    out=$(ubus -t 10 call luci.trafficctl name_set '{"ip":"192.168.77.5","name":"ci-probe"}' 2>&1) || {
        echo "RPCD FAILED: name_set through rpcd: $out"; exit 1; }
    case "$out" in *'"ok": true'*) ;; *) echo "RPCD FAILED: name_set through rpcd printed: $out"; exit 1 ;; esac
    out=$(ubus -t 10 call luci.trafficctl names_list 2>&1)
    case "$out" in *ci-probe*) ;; *) echo "RPCD FAILED: names_list through rpcd printed: $out"; exit 1 ;; esac
    out=$(ubus -t 10 call luci.trafficctl name_clear '{"ip":"192.168.77.5"}' 2>&1) || {
        echo "RPCD FAILED: name_clear through rpcd: $out"; exit 1; }
    echo "rpcd: calls with arguments returned in $(( $(date +%s) - t0 )) s"
    kill "$RPCD_PID" "$UBUSD_PID" 2>/dev/null || true
    wait "$RPCD_PID" "$UBUSD_PID" 2>/dev/null || true
else
    echo "rpcd: not in this image, skipped the call through rpcd"
fi

# Each file belongs to the package that is meant to ship it: the backend to
# trafficctl, the view and its rpcd plugin to luci-app-trafficctl.
owner_of() {
    case "$PKG" in
        *.ipk) opkg search "$1" | awk '{print $1; exit}' ;;
        *.apk) apk info --who-owns "$1" 2>/dev/null | awk '{print $NF; exit}' | sed 's/-[0-9][^-]*-r[0-9]*$//' ;;
    esac
}
for f in \
  /usr/sbin/trafficctl \
  /usr/share/ucode/trafficctl/lib.uc \
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
  /usr/sbin/trafficctl \
  /usr/share/ucode/trafficctl/lib.uc \
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
