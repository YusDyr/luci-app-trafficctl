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
# The feed holds two packages, trafficctl (the backend) and luci-app-trafficctl
# (the web interface, which depends on it). Users still install only the
# latter by name; `scripts/feeds install` must follow the dependency and link
# trafficctl too, so this checks both links and builds both packages.
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

# CI only (feed-install.yml): SDK_CACHE_DIR carries the official feed
# checkouts and the compiled dependencies between runs, see
# tools/sdk-cache.sh. Our feed is never in it, so everything below still runs
# against this checkout: the src-link feed is scanned, installed and both
# packages are compiled from scratch. CONFIG_AUTOREMOVE=y (what
# openwrt/gh-action-sdk passes too) then trims each dependency's build tree
# to its stamps, which keeps the cache small; it does not change what is
# built. Unset (a developer's run), nothing changes.
CACHE_MAKEARGS=
if [ -n "${SDK_CACHE_DIR:-}" ]; then
    bash "$SRC/tools/sdk-cache.sh" restore "$SDK_CACHE_DIR"
    CACHE_MAKEARGS=CONFIG_AUTOREMOVE=y
fi

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
for pkg in trafficctl luci-app-trafficctl; do
    [ -e "package/feeds/trafficctl/$pkg/Makefile" ] || {
        echo "ERROR: scripts/feeds install did not link $pkg"; exit 1; }
done

# Install all feed packages so transitive deps (lua headers for lucihttp-lua,
# ucode headers for lucihttp-ucode) are staged. Without this, the lucihttp
# compile step explodes with "lua.h: No such file or directory".
echo "Running scripts/feeds install -a..."
./scripts/feeds install -a

# Verify the package was registered with the buildroot
echo "Verifying package is known to buildroot..."
make defconfig V=s > /tmp/tctl_defconfig.log 2>&1 || {
    tail -20 /tmp/tctl_defconfig.log; echo "ERROR: make defconfig failed"; exit 1
}
tail -20 /tmp/tctl_defconfig.log
for pkg in trafficctl luci-app-trafficctl; do
    if ! grep -q "^CONFIG_PACKAGE_$pkg=" .config 2>/dev/null; then
        echo "Enabling $pkg in .config..."
        echo "CONFIG_PACKAGE_$pkg=m" >> .config
    fi
done
# luci-app-trafficctl doesn't need lucihttp's lua/ucode bindings — disable them
# so we don't have to compile bindings we don't use.
echo 'CONFIG_PACKAGE_liblucihttp-lua=n' >> .config
echo 'CONFIG_PACKAGE_liblucihttp-ucode=n' >> .config
make defconfig

FOUND=
for pkg in trafficctl luci-app-trafficctl; do
    echo "Building $pkg..."
    # Capture make's real exit code — a `make … | tail` pipeline returns tail's
    # status (0), which under set -e would silently hide a genuine build failure.
    # This matters now that the feed-install job is blocking (no continue-on-error).
    # shellcheck disable=SC2086 # CACHE_MAKEARGS is empty or one word
    if ! make $CACHE_MAKEARGS "package/$pkg/compile" V=s -j"$(nproc)" > "/tmp/tctl_compile_$pkg.log" 2>&1; then
        tail -80 "/tmp/tctl_compile_$pkg.log"
        echo "ERROR: make compile of $pkg failed"
        exit 1
    fi
    tail -30 "/tmp/tctl_compile_$pkg.log"

    # Verify the build artifact exists. "<name>_<ver>" for ipk, "<name>-<ver>"
    # for apk: a bare "trafficctl*" would also match luci-app-trafficctl.
    art=$(find bin/ \( -name "${pkg}_[0-9]*.ipk" -o -name "${pkg}-[0-9]*.apk" \) 2>/dev/null | head -1)
    if [ -z "$art" ]; then
        echo "ERROR: no $pkg package artifact found in bin/"
        find bin/ -type f 2>/dev/null | head -20
        exit 1
    fi
    FOUND="$FOUND $art"
done

echo "Feed install + build succeeded:$FOUND"

if [ -n "${SDK_CACHE_DIR:-}" ] && [ "${SDK_CACHE_SAVE:-1}" != 0 ]; then
    bash "$SRC/tools/sdk-cache.sh" save "$SDK_CACHE_DIR"
fi
