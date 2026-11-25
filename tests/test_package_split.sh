#!/bin/bash
# The backend and the web interface are separate packages: trafficctl (helpers,
# config, services, hotplug, keep.d, metrics CGI), trafficctl-telegram (the
# bot, from the same Makefile), trafficctl-shaper and trafficctl-wifi (no
# files, the shaper's and the WiFi part's dependencies, since 2.2.0),
# trafficctl-full (no files, every part, since 2.3.0) and
# luci-app-trafficctl (rpcd plugin, views, menu, ACL, translations). Releases up to 1.28.x shipped all of it as
# luci-app-trafficctl, releases up to 1.30.x the bot in trafficctl.
#
# trafficctl/Makefile lists every file it installs by name, so a file added
# under trafficctl/files/ and not to the Makefile would build fine and silently
# go missing from the SDK-built release. This test is what makes that list
# safe to maintain by hand. It also pins the package relationships the
# upgrade from the single package depends on.

# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/lib/assert.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BE_MK="$REPO_ROOT/trafficctl/Makefile"
FE_MK="$REPO_ROOT/luci-app-trafficctl/Makefile"

# ── trafficctl/Makefile installs exactly the tree under files/ ──────────────
# Between its two packages, each file once.

mk_define() { awk -v want="define $1" '$0 == want {f=1;next} f&&/^endef/{exit} f' "$BE_MK"; }
# "<macro> <source path relative to files/> <destination dir>" per installed file.
listed() {
    printf '%s\n' "$1" | awk '
    $1 ~ /^\$\(INSTALL_(BIN|CONF|DATA)\)$/ {
        src = $2; sub(/^\.\/files\//, "", src)
        dst = $3; sub(/^\$\(1\)\//, "", dst); sub(/\/$/, "", dst)
        m = $1; gsub(/[$()]/, "", m)
        print m, src, dst
    }'
}
TREE=$(cd "$REPO_ROOT/trafficctl/files" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
ALL=
for pkg in trafficctl trafficctl-telegram; do
INSTALL=$(mk_define "Package/$pkg/install")
assert_eq "trafficctl/Makefile has an install section for $pkg" "yes" "$([ -n "$INSTALL" ] && echo yes || echo no)"
LISTED=$(listed "$INSTALL")
ALL="$ALL$LISTED
"
[ "$pkg" = trafficctl-telegram ] && assert_eq "trafficctl-telegram installs the bot and nothing else" \
    "etc/init.d/trafficctl-telegram
usr/libexec/trafficctl/trafficctl-telegram.uc
usr/share/ucode/trafficctl/telegram.uc" "$(printf '%s\n' "$LISTED" | awk '{print $2}' | LC_ALL=C sort)"

while read -r macro src dst; do
    [ -n "$src" ] || continue
    # Installed at the same path it has under files/.
    assert_eq "$src: installed to its own directory" "$(dirname "$src")" "$dst"
    # The destination directory is created before the file is copied into it.
    assert_eq "$src: INSTALL_DIR for its directory" "1" \
        "$(printf '%s\n' "$INSTALL" | grep -cFx "	\$(INSTALL_DIR) \$(1)/$dst")"
    # The mode follows the file: executables with INSTALL_BIN, the config
    # (which holds the Telegram and metrics tokens) with INSTALL_CONF (0600).
    if [ "$src" = etc/config/trafficctl ]; then
        want=INSTALL_CONF
    elif [ -x "$REPO_ROOT/trafficctl/files/$src" ]; then
        want=INSTALL_BIN
    else
        want=INSTALL_DATA
    fi
    assert_eq "$src: installed with $want" "$want" "$macro"
done <<EOF
$LISTED
EOF
done

# The code they enable is in trafficctl, which checks for the tools at run
# time; ucode's require() cannot load a module a package may lack.
for pkg in trafficctl-shaper trafficctl-wifi trafficctl-full; do
    assert_eq "$pkg installs no files" "true" \
        "$(mk_define "Package/$pkg/install" | sed 's/^[[:space:]]*//' | grep -v '^$')"
done

assert_eq "every file under trafficctl/files is installed by one package, and nothing else" \
    "$TREE" "$(printf '%s' "$ALL" | awk 'NF {print $2}' | LC_ALL=C sort)"
# 2.0.0 is ucode end to end: the shell scripts of 1.30.x in /usr/libexec are
# gone, and init.d, hotplug.d, uci-defaults and the CGI are the only shell.
assert_eq "no shell scripts under usr/libexec/trafficctl" "" \
    "$(printf '%s\n' "$TREE" | grep -E '^usr/libexec/trafficctl/.*\.sh$')"
assert_eq "the backend's layout: the CLI, its modules, the bot entry and the hooks" \
    "etc/config/trafficctl
etc/hotplug.d/dhcp/99-trafficctl-newdevice
etc/hotplug.d/iface/99-trafficctl-shapes
etc/init.d/trafficctl-cut
etc/init.d/trafficctl-history
etc/init.d/trafficctl-notify
etc/init.d/trafficctl-telegram
etc/uci-defaults/80_trafficctl-notify
lib/upgrade/keep.d/trafficctl
usr/libexec/trafficctl/trafficctl-telegram.uc
usr/sbin/trafficctl
www/cgi-bin/trafficctl-metrics" \
    "$(printf '%s\n' "$TREE" | grep -v '^usr/share/ucode/trafficctl/[a-z]*\.uc$')"
for b in build-ipk.sh build-apk.sh; do
    assert_eq "$b moves the files of trafficctl-telegram to it" \
        "$(mk_define Package/trafficctl-telegram/install | awk '$1 ~ /INSTALL_(BIN|DATA)/ {sub(/^\.\/files\//, "", $2); print $2}' | LC_ALL=C sort)" \
        "$(sed -n 's/^TG_FILES="\(.*\)"$/\1/p' "$REPO_ROOT/$b" | tr ' ' '\n' | LC_ALL=C sort)"
done

assert_eq "the config is the trafficctl conffile" "/etc/config/trafficctl" \
    "$(awk '/^define Package\/trafficctl\/conffiles$/{f=1;next} f&&/^endef/{exit} f' "$BE_MK")"
assert_eq "luci-app-trafficctl has no conffiles any more" "0" \
    "$(grep -c 'conffiles' "$FE_MK")"

# ── luci-app-trafficctl keeps only the web interface ────────────────────────

FE_ROOT=$(cd "$REPO_ROOT/luci-app-trafficctl/root" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
assert_eq "luci-app-trafficctl/root holds only the rpcd plugin, the menu and the ACL" \
    "usr/share/luci/menu.d/luci-app-trafficctl.json
usr/share/rpcd/acl.d/luci-app-trafficctl.json
usr/share/rpcd/ucode/luci.trafficctl.uc" "$FE_ROOT"

# ── Package relationships ────────────────────────────────────────────────────

# The web interface calls the helpers, so it depends on the backend, and
# through trafficctl-full on every part: it configures the bot, which an
# upgrade from 1.30.x must keep, and shows the shaper and WiFi controls.
assert_eq "LUCI_DEPENDS starts with +trafficctl +trafficctl-full" "1" \
    "$(grep -cE '^LUCI_DEPENDS:=\+trafficctl \+trafficctl-full( |$)' "$FE_MK")"
for d in +trafficctl-telegram +trafficctl-shaper +trafficctl-wifi; do
    assert_eq "LUCI_DEPENDS gets ${d#+} only through trafficctl-full" "0" \
        "$(sed -n 's/^LUCI_DEPENDS:=//p' "$FE_MK" | tr ' ' '\n' | grep -cxF -- "$d")"
done
assert_eq "trafficctl-full depends on trafficctl and every part" \
    "+trafficctl +trafficctl-shaper +trafficctl-wifi +trafficctl-telegram" \
    "$(mk_define Package/trafficctl-full | sed -n 's/^[[:space:]]*DEPENDS:=//p')"
assert_eq "trafficctl-full pins each of them to its own build" \
    'trafficctl (=$(PKG_VERSION)-r$(PKG_RELEASE)), trafficctl-shaper (=$(PKG_VERSION)-r$(PKG_RELEASE)), trafficctl-wifi (=$(PKG_VERSION)-r$(PKG_RELEASE)), trafficctl-telegram (=$(PKG_VERSION)-r$(PKG_RELEASE))' \
    "$(mk_define Package/trafficctl-full | sed -n 's/^[[:space:]]*EXTRA_DEPENDS:=//p')"
assert_eq "trafficctl-telegram depends on trafficctl and curl" "+trafficctl +curl" \
    "$(mk_define Package/trafficctl-telegram | sed -n 's/^[[:space:]]*DEPENDS:=//p')"
assert_eq "trafficctl-shaper depends on trafficctl, tc, kmod-sched-core and kmod-ifb" \
    "+trafficctl +tc +kmod-sched-core +kmod-ifb" \
    "$(mk_define Package/trafficctl-shaper | sed -n 's/^[[:space:]]*DEPENDS:=//p')"
assert_eq "trafficctl-wifi depends on trafficctl, iw and hostapd-utils" \
    "+trafficctl +iw +hostapd-utils" \
    "$(mk_define Package/trafficctl-wifi | sed -n 's/^[[:space:]]*DEPENDS:=//p')"
# Pinned to the exact build, as in-tree split packages do (net/bind): the
# parts and the core come from one source and load each other's code, so
# only the same build is a tested pair. PKG_VERSION and PKG_RELEASE, not a
# literal, as the packages move in lockstep. build-ipk/apk.sh pin the same.
for pkg in trafficctl-telegram trafficctl-shaper trafficctl-wifi; do
    assert_eq "$pkg pins trafficctl to its own build" \
        'trafficctl (=$(PKG_VERSION)-r$(PKG_RELEASE))' \
        "$(mk_define "Package/$pkg" | sed -n 's/^[[:space:]]*EXTRA_DEPENDS:=//p')"
done
# The core carries none of the optional parts' tools (2.2.0).
for d in +tc +iw +curl +hostapd-utils +kmod-sched-core +kmod-ifb; do
    assert_eq "trafficctl does not depend on ${d#+}" "0" \
        "$(mk_define Package/trafficctl | sed -n 's/^[[:space:]]*DEPENDS:=//p' | tr ' ' '\n' | grep -cxF -- "$d")"
done
# The build scripts declare the same dependencies as the Makefile.
mk_deps() { mk_define "Package/$1" | sed -n 's/^[[:space:]]*DEPENDS:=//p' | tr ' ' '\n' | sed -n 's/^+//p' | grep -vx trafficctl | LC_ALL=C sort; }
for b in build-ipk.sh build-apk.sh; do
    for pair in BE_DEPENDS:trafficctl SH_DEPENDS:trafficctl-shaper WF_DEPENDS:trafficctl-wifi; do
        assert_eq "$b ${pair%%:*} matches ${pair#*:}'s DEPENDS" "$(mk_deps "${pair#*:}")" \
            "$(sed -n "s/^${pair%%:*}=\"\(.*\)\"$/\1/p" "$REPO_ROOT/$b" | tr -d , | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort)"
    done
done
assert_eq "luci-app-trafficctl needs trafficctl and trafficctl-full of its own version or newer" \
    'trafficctl (>=$(PKG_VERSION)), trafficctl-full (>=$(PKG_VERSION))' "$(sed -n 's/^LUCI_EXTRA_DEPENDS:=//p' "$FE_MK")"
# The backend's own dependencies are repeated on luci-app-trafficctl: without
# them opkg removes conntrack, curl, iw and hostapd-utils as orphans of the old
# single package in the same run that installs trafficctl. So are curl, tc and
# iw, which trafficctl depended on up to 2.1.x.
BE_DEPS=$(mk_define Package/trafficctl | sed -n 's/^[[:space:]]*DEPENDS:=//p')
FE_DEPS=$(sed -n 's/^LUCI_DEPENDS:=//p' "$FE_MK")
for d in $BE_DEPS +curl +tc +iw +hostapd-utils; do
    case " $FE_DEPS " in
        *" $d "*) PASS=$((PASS + 1)) ;;
        *) FAIL=$((FAIL + 1)); printf "FAIL: LUCI_DEPENDS lacks the backend dependency %s\n" "$d" ;;
    esac
done
# The limiter's table is in the nft netdev family, which only kmod-nft-netdev
# enables; firewall4 and kmod-nft-offload do not pull it in.
assert_eq "trafficctl depends on kmod-nft-netdev" "1" \
    "$(printf '%s\n' "$BE_DEPS" | tr ' ' '\n' | grep -cx '+kmod-nft-netdev')"
for b in build-ipk.sh build-apk.sh; do
    assert_eq "$b repeats kmod-nft-netdev in BE_DEPENDS" "1" \
        "$(grep -c '^BE_DEPENDS=.*kmod-nft-netdev' "$REPO_ROOT/$b")"
done
assert_eq "trafficctl does not depend on LuCI" "" \
    "$(printf '%s\n' "$BE_DEPS" | tr ' ' '\n' | grep -E 'luci|rpcd')"

# CONFLICTS between the two would make the package manager refuse the upgrade
# from the single package instead of moving the files over.
for mk in "$BE_MK" "$FE_MK"; do
    assert_eq "no CONFLICTS in ${mk#"$REPO_ROOT"/}" "0" "$(grep -cE '^[[:space:]]*(LUCI_)?CONFLICTS[[:space:]]*[:+?]?=' "$mk")"
done

for pkg in trafficctl trafficctl-shaper trafficctl-wifi trafficctl-telegram trafficctl-full; do
    assert_eq "$pkg is architecture independent" "1" \
        "$(mk_define "Package/$pkg" | grep -cE '^[[:space:]]*PKGARCH:=all$')"
done
assert_eq "trafficctl/Makefile ends with a BuildPackage per package" \
    '$(eval $(call BuildPackage,trafficctl))
$(eval $(call BuildPackage,trafficctl-shaper))
$(eval $(call BuildPackage,trafficctl-wifi))
$(eval $(call BuildPackage,trafficctl-telegram))
$(eval $(call BuildPackage,trafficctl-full))' "$(grep -v '^[[:space:]]*$' "$BE_MK" | tail -5)"
# Every openwrt/luci application Makefile ends with this comment; luci.mk makes
# the BuildPackage call itself, so an explicit one would be a duplicate.
assert_eq "luci-app-trafficctl ends with the buildroot signature" \
    '# call BuildPackage - OpenWrt buildroot signature' "$(grep -v '^[[:space:]]*$' "$FE_MK" | tail -1)"
assert_eq "luci-app-trafficctl makes no BuildPackage call of its own" "0" \
    "$(grep -c '^[^#]*call BuildPackage' "$FE_MK")"

v_fe=$(sed -n 's/^PKG_VERSION:=//p' "$FE_MK")
v_be=$(sed -n 's/^PKG_VERSION:=//p' "$BE_MK")
assert_eq "both packages carry the same PKG_VERSION" "$v_fe" "$v_be"
assert_eq "both Makefiles name the same maintainer" \
    "$(grep '^PKG_MAINTAINER:=' "$FE_MK")" "$(grep '^PKG_MAINTAINER:=' "$BE_MK")"

summary
