#!/bin/bash
# Build PACKAGES from this feed with the OpenWrt SDK image, the way
# openwrt/gh-action-sdk v11 does, minus the SDK re-download.
#
# The release SDK images already hold the extracted SDK in /builder, but they
# still ship setup.sh, and the action's entrypoint runs it whenever it exists.
# setup.sh then downloads the 285 MB SDK tarball again from FILE_HOST, which the
# image pins to mirror-03.infra.openwrt.org. At 55-410 KB/s that alone ran past
# the 60 min step limit three times on 2026-11-07. Deleting setup.sh in the
# container makes the entrypoint use the SDK the image already has.
#
# Env: ARCH (image tag, e.g. x86_64-25.12.4), FEEDNAME, PACKAGES, V,
# PRIVATE_KEY, KEY_BUILD, plus the other variables the action passes through.
# The package lands in ./bin, as with the action.
#
# SDK_CACHE (optional): a host directory, outside the workspace, that
# tools/sdk-cache.sh restores the SDK's downloads, feeds and built
# dependencies from before the build and saves them back to after a
# successful one (unless SDK_CACHE_SAVE=0). The workflows keep it with
# actions/cache; see sdk-cache.sh for what is in it and why our own packages
# never are.
set -euo pipefail

IMAGE="${CONTAINER:-ghcr.io/openwrt/sdk}:${ARCH:?ARCH is required}"
HERE=$(cd "$(dirname "$0")" && pwd)
WS=$(pwd)

for i in 1 2 3; do
	docker pull -q "$IMAGE" && break
	[ "$i" = 3 ] && exit 1
	sleep 15
done

# The image runs as buildbot (uid 1000), which must be able to write bin/.
sudo chown -R 1000:1000 "$WS"

RUN='rm -f setup.sh && exec bash /entrypoint.sh'
CACHE_ARGS=()
if [ -n "${SDK_CACHE:-}" ]; then
	mkdir -p "$SDK_CACHE"
	sudo chown -R 1000:1000 "$SDK_CACHE"
	CACHE_ARGS=(
		--env SDK_CACHE_SAVE
		-v "$SDK_CACHE:/sdk-cache"
		-v "$HERE/sdk-cache.sh:/sdk-cache.sh:ro"
	)
	# The entrypoint moves bin/ to /artifacts, so that is where save finds it.
	RUN='rm -f setup.sh && bash /sdk-cache.sh restore /sdk-cache && {
		ret=0; bash /entrypoint.sh || ret=$?
		if [ "$ret" = 0 ] && [ "${SDK_CACHE_SAVE:-1}" != 0 ]; then
			bash /sdk-cache.sh save /sdk-cache /artifacts
		fi
		exit "$ret"; }'
fi

RET=0
docker run --rm \
	--env BUILD \
	--env BUILD_LOG \
	--env EXTRA_FEEDS \
	--env FEEDNAME \
	--env IGNORE_ERRORS \
	--env KEY_BUILD \
	--env PRIVATE_KEY \
	--env NO_DEFAULT_FEEDS \
	--env NO_REFRESH_CHECK \
	--env NO_SHFMT_CHECK \
	--env PACKAGES \
	--env INDEX \
	--env V \
	-v "$WS:/artifacts" \
	-v "$WS:/feed" \
	-v "$HERE/sdk-entrypoint.sh:/entrypoint.sh:ro" \
	"${CACHE_ARGS[@]}" \
	--entrypoint /bin/bash \
	"$IMAGE" -c "$RUN" || RET=$?
sudo chown -R --reference="$WS/.." "$WS"
if [ -n "${SDK_CACHE:-}" ]; then
	sudo chown -R --reference="$WS/.." "$SDK_CACHE"
fi
exit "$RET"
