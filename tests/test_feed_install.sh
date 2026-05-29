#!/bin/sh
# Reproduces the user-facing feed install workflow inside an OpenWrt SDK container.
# Usage:  sh /tests/test_feed_install.sh /src
# Where:  /src is the repo root (mounted from host)
#
# This is what users do:
#   echo "src-git trafficctl https://github.com/YusDyr/luci-app-trafficctl.git" >> feeds.conf
#   ./scripts/feeds update trafficctl
#   ./scripts/feeds install -p trafficctl luci-app-trafficctl
#   make package/luci-app-trafficctl/compile V=s
#
# We use `src-link` instead of `src-git` to point at the locally-mounted repo,
# but the feed scanner code path is identical — if feeds update fails on the
# real repo, it fails here too.
set -eu

SRC="${1:-/src}"
[ -d "$SRC" ] || { echo "ERROR: source dir $SRC missing"; exit 1; }

# Detect the SDK buildroot — its location varies across openwrt/sdk image versions
BUILDROOT=""
for candidate in /builder /home/build/openwrt /home/build; do
    if [ -d "$candidate" ] && [ -d "$candidate/scripts" ] && \
       [ -f "$candidate/feeds.conf.default" ]; then
        BUILDROOT="$candidate"
        break
    fi
done
if [ -z "$BUILDROOT" ]; then
    echo "ERROR: SDK buildroot not found (tried /builder, /home/build/openwrt, /home/build)"
    ls -la /builder /home/build /home/build/openwrt 2>/dev/null
    exit 1
fi
echo "Using SDK buildroot: $BUILDROOT"
cd "$BUILDROOT"

# Ensure the LuCI feed is enabled (our Makefile includes feeds/luci/luci.mk)
echo "Configuring feeds..."
if ! grep -q "^src-.*luci" feeds.conf.default 2>/dev/null; then
    echo "src-git luci https://github.com/openwrt/luci.git" > feeds.conf
else
    cp feeds.conf.default feeds.conf
fi
echo "src-link trafficctl $SRC" >> feeds.conf

echo "--- feeds.conf ---"
cat feeds.conf
echo "------------------"

echo "Running scripts/feeds update -a (need all feeds so liblua headers stage for lucihttp-lua)..."
./scripts/feeds update -a

echo "Running scripts/feeds install -p trafficctl luci-app-trafficctl..."
./scripts/feeds install -p trafficctl luci-app-trafficctl

echo "Listing trafficctl feed contents..."
ls -la package/feeds/trafficctl/ || {
    echo "ERROR: feed install did not create symlinks"; exit 1; }

# Install all feed packages so transitive deps (lua headers for lucihttp-lua,
# ucode headers for lucihttp-ucode) are staged. Without this, the lucihttp
# compile step explodes with "lua.h: No such file or directory".
echo "Running scripts/feeds install -a..."
./scripts/feeds install -a

# Verify the package was registered with the buildroot
echo "Verifying package is known to buildroot..."
make defconfig V=s 2>&1 | tail -20
if ! grep -q "luci-app-trafficctl" .config 2>/dev/null; then
    echo "Enabling package in .config..."
    echo 'CONFIG_PACKAGE_luci-app-trafficctl=m' >> .config
fi
# luci-app-trafficctl doesn't need lucihttp's lua/ucode bindings — disable them
# so we don't have to compile bindings we don't use.
echo 'CONFIG_PACKAGE_liblucihttp-lua=n' >> .config
echo 'CONFIG_PACKAGE_liblucihttp-ucode=n' >> .config
make defconfig

echo "Building package..."
make package/luci-app-trafficctl/compile V=s -j"$(nproc)" 2>&1 | tail -50

# Verify build artifact exists
FOUND=$(find bin/ -name "luci-app-trafficctl*" \( -name "*.ipk" -o -name "*.apk" \) 2>/dev/null | head -1)
if [ -z "$FOUND" ]; then
    echo "ERROR: no package artifact found in bin/"
    find bin/ -type f 2>/dev/null | head -20
    exit 1
fi

echo "Feed install + build succeeded: $FOUND"
