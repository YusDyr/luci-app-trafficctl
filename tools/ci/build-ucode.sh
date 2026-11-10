#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Build ucode (with the fs, uci and ubus modules) and the OpenWrt userland it
# talks to -- libubox, ubus/ubusd, uci, jsonfilter -- at the revisions a given
# OpenWrt release ships, so the ucode tests run against that release's
# interpreter rather than whatever happens to be current.
#
# Usage: tools/ci/build-ucode.sh <label> [prefix]
#   label   2022-12-02 (OpenWrt 22.03, ucode's date) | 25.12
#   prefix  install root, default ~/.cache/trafficctl-ucode/<label>
#
# The revisions are the PKG_SOURCE_VERSION values of the v22.03.7 and v25.12.4
# package Makefiles, the releases the compat job runs. json-c comes from the
# distro: libubox and ucode only use its stable API.
set -euo pipefail

label="${1:?usage: $0 <label> [prefix]}"
prefix="${2:-$HOME/.cache/trafficctl-ucode/$label}"

case "$label" in
    2022-12-02)
        libubox=d2223ef9da7172a84d1508733dc58840e1381e3c   # 2022-05-15
        ubus=2bebf93cd3343fe49f22a05ef935e460d2d44f67      # 2022-06-01
        uci=f84f49f00fb70364f58b4cce72f1796a7190d370       # 2021-10-22
        jsonpath=594cfa86469c005972ba750614f5b3f1af84d0f6  # 2024-01-23
        ucode=46d93c9cc5da6fce581df86159bd0fc4357de41c     # 2022-12-02
        ;;
    25.12)
        libubox=815633847cd32ffe6da28943cbeb37edc88265c8   # 2026-03-13
        ubus=3cc98db1a422dcf560f2d6347fd410f17565a89d      # 2025-12-02
        uci=66127cd76c5d0bd46d5a90302cc6110f53a4e2f8       # 2025-12-02
        jsonpath=b9034210bd331749673416c6bf389cccd4e23610  # 2026-03-16
        ucode=85922056ef7abeace3cca3ab28bc1ac2d88e31b1     # 2026-01-16
        ;;
    *) echo "unknown label: $label" >&2; exit 2 ;;
esac

# Also on a cache hit: the cached binaries link against the distro's json-c.
if ! pkg-config --exists json-c 2>/dev/null || ! command -v cmake >/dev/null; then
    sudo=""; [ "$(id -u)" = 0 ] || sudo=sudo
    $sudo apt-get update -qq
    $sudo apt-get install -y --no-install-recommends build-essential cmake pkg-config libjson-c-dev curl
fi

if [ -x "$prefix/bin/ucode" ] && [ -x "$prefix/sbin/ubusd" ]; then
    echo "ucode $label already built in $prefix"
    exit 0
fi

# Some of these link -lubox by name instead of through find_library. gnu17:
# gcc 15 defaults to C23, where lemon's `void f();` prototypes take no args.
export CFLAGS="-std=gnu17 -I$prefix/include" LDFLAGS="-L$prefix/lib"

src=$(mktemp -d)
trap 'rm -rf "$src"' EXIT

# git.openwrt.org serves no tarballs for arbitrary commits; the GitHub mirrors
# do, and a fetch by SHA cannot drift.
fetch() {   # fetch <name> <owner/repo> <sha>
    mkdir -p "$src/$1"
    curl -fsSL --retry 3 "https://codeload.github.com/$2/tar.gz/$3" \
        | tar -xz -C "$src/$1" --strip-components=1
}

build() {   # build <name> [cmake options...]
    local name="$1" bdir="$src/$1/build"; shift
    # jsonpath runs lemon on a path relative to the build directory.
    [ "$name" = jsonpath ] && bdir="$src/$name"
    cmake -S "$src/$name" -B "$bdir" \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" \
        -DCMAKE_INSTALL_RPATH="$prefix/lib" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        "$@" >/dev/null
    cmake --build "$bdir" -j "$(nproc)" >/dev/null
    cmake --install "$bdir" >/dev/null
}

fetch libubox openwrt/libubox "$libubox"
fetch ubus openwrt/ubus "$ubus"
fetch uci openwrt/uci "$uci"
fetch jsonpath openwrt/jsonpath "$jsonpath"
fetch ucode jow-/ucode "$ucode"

# Old trees under a current gcc trip -Werror on warnings that did not exist
# when they were written; the code itself is what the router runs.
sed -i 's/-Werror/-Wno-error/g' "$src"/*/CMakeLists.txt
# The older jsonpath compiles lemon with a bare `gcc`, outside CFLAGS.
sed -i 's|COMMAND gcc -o|COMMAND gcc -std=gnu17 -o|' "$src/jsonpath/CMakeLists.txt"
# ubusd applies ACLs to every non-root client and only reads root-owned ACL
# files. On the router the backend runs as root; the CI user is not.
sed -i 's/if (!cl || !cl->uid || !obj)/if (1)/' "$src/ubus/ubusd_acl.c"
grep -q 'if (1)' "$src/ubus/ubusd_acl.c" || { echo "ubusd ACL patch did not apply" >&2; exit 1; }

build libubox -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF -DUNIT_TESTING=OFF
build ubus -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF -DENABLE_SYSTEMD=OFF
build uci -DBUILD_LUA=OFF -DBUILD_TESTS=OFF
build jsonpath
ln -sf jsonpath "$prefix/bin/jsonfilter"
build ucode -DFS_SUPPORT=ON -DUCI_SUPPORT=ON -DUBUS_SUPPORT=ON \
    -DMATH_SUPPORT=ON -DSTRUCT_SUPPORT=ON -DULOOP_SUPPORT=ON \
    -DNL80211_SUPPORT=OFF -DRTNL_SUPPORT=OFF -DRESOLV_SUPPORT=OFF \
    -DSOCKET_SUPPORT=OFF -DZLIB_SUPPORT=OFF -DDIGEST_SUPPORT=OFF \
    -DLOG_SUPPORT=OFF -DDEBUG_SUPPORT=OFF

for b in bin/ucode bin/ubus sbin/ubusd bin/uci bin/jsonfilter lib/ucode/fs.so lib/ucode/uci.so lib/ucode/ubus.so; do
    [ -e "$prefix/$b" ] || { echo "missing after build: $prefix/$b" >&2; exit 1; }
done
# ucode has no -v; loading the modules is the useful check.
"$prefix/bin/ucode" -S -e "require('fs'); require('uci'); require('ubus'); print('ucode $label: ok\\n')"
