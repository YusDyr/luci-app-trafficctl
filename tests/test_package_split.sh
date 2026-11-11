#!/bin/bash
# The backend and the web interface are two packages: trafficctl (helpers,
# config, services, hotplug, keep.d, metrics CGI) and luci-app-trafficctl (rpcd
# plugin, views, menu, ACL, translations). Releases up to 1.28.x shipped all of
# it as luci-app-trafficctl.
#
# trafficctl/Makefile lists every file it installs by name, so a file added
# under trafficctl/files/ and not to the Makefile would build fine and silently
# go missing from the SDK-built release. This test is what makes that list
# safe to maintain by hand. It also pins the package relationships the
# upgrade from the single package depends on.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BE_MK="$REPO_ROOT/trafficctl/Makefile"
FE_MK="$REPO_ROOT/luci-app-trafficctl/Makefile"

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

# ── trafficctl/Makefile installs exactly the tree under files/ ──────────────

INSTALL=$(awk '/^define Package\/trafficctl\/install$/{f=1;next} f&&/^endef/{exit} f' "$BE_MK")
assert_eq "trafficctl/Makefile has an install section" "yes" "$([ -n "$INSTALL" ] && echo yes || echo no)"

# "<macro> <source path relative to files/> <destination dir>" per installed file.
LISTED=$(printf '%s\n' "$INSTALL" | awk '
    $1 ~ /^\$\(INSTALL_(BIN|CONF|DATA)\)$/ {
        src = $2; sub(/^\.\/files\//, "", src)
        dst = $3; sub(/^\$\(1\)\//, "", dst); sub(/\/$/, "", dst)
        m = $1; gsub(/[$()]/, "", m)
        print m, src, dst
    }')
TREE=$(cd "$REPO_ROOT/trafficctl/files" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

assert_eq "every file under trafficctl/files is installed, and nothing else" \
    "$TREE" "$(printf '%s\n' "$LISTED" | awk '{print $2}' | LC_ALL=C sort)"

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

assert_eq "the config is the trafficctl conffile" "/etc/config/trafficctl" \
    "$(awk '/^define Package\/trafficctl\/conffiles$/{f=1;next} f&&/^endef/{exit} f' "$BE_MK")"
assert_eq "luci-app-trafficctl has no conffiles any more" "0" \
    "$(grep -c 'conffiles' "$FE_MK")"

# ── luci-app-trafficctl keeps only the web interface ────────────────────────

FE_ROOT=$(cd "$REPO_ROOT/luci-app-trafficctl/root" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
assert_eq "luci-app-trafficctl/root holds only the rpcd plugin, the menu and the ACL" \
    "usr/libexec/rpcd/luci.trafficctl
usr/share/luci/menu.d/luci-app-trafficctl.json
usr/share/rpcd/acl.d/luci-app-trafficctl.json" "$FE_ROOT"

# ── Package relationships ────────────────────────────────────────────────────

# The web interface calls the helpers, so it depends on the backend.
assert_eq "LUCI_DEPENDS starts with +trafficctl" "1" \
    "$(grep -cE '^LUCI_DEPENDS:=\+trafficctl( |$)' "$FE_MK")"
# The backend's own dependencies are repeated on luci-app-trafficctl: without
# them opkg removes conntrack, curl, iw and hostapd-utils as orphans of the old
# single package in the same run that installs trafficctl.
BE_DEPS=$(sed -n 's/^[[:space:]]*DEPENDS:=//p' "$BE_MK")
FE_DEPS=$(sed -n 's/^LUCI_DEPENDS:=//p' "$FE_MK")
for d in $BE_DEPS; do
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

assert_eq "trafficctl is architecture independent" "1" "$(grep -cE '^[[:space:]]*PKGARCH:=all$' "$BE_MK")"
assert_eq "trafficctl ends with BuildPackage" \
    '$(eval $(call BuildPackage,trafficctl))' "$(grep -v '^[[:space:]]*$' "$BE_MK" | tail -1)"
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

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
