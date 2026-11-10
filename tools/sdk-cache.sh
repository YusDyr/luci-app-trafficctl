#!/bin/bash
# Carry the OpenWrt SDK's downloads, feed checkouts and built dependencies
# between CI runs, so a run only compiles this feed's own packages.
#
# Measured on release run 42627103653: 28 of the 30 minutes in the SDK step
# went to compiling dependencies that never change between runs (hostapd in
# ~30 variants for hostapd-utils alone took 13 min, iproute2 for tc 3 min,
# curl, openssl, wolfssl, luci-base...). Our two packages took seconds.
#
#   sdk-cache.sh key <image> <driver>         host: print "<key> <restore-prefix>"
#   sdk-cache.sh restore <cache-dir>          container, cwd = SDK buildroot
#   sdk-cache.sh save <cache-dir> [bin-root]  container, cwd = SDK buildroot
#
# restore extracts <cache-dir>/sdk-tree.tar over the buildroot and drops a
# marker first; save archives every file under dl/ feeds/ build_dir/
# staging_dir/ whose ctime is newer than that marker (written by this run or
# restored into it), plus <bin-root>/bin/ (default: the buildroot). Files the
# image already ships and the run did not touch stay out of the archive.
#
# What keeps a stale package of OURS from ever shipping: every path that
# contains one of SDK_CACHE_EXCLUDE (default: "trafficctl", which every
# package in this feed, its build dir, pkginfo, stamps, bin/ subdir and feed
# index carry) is left out of the archive on save AND skipped on extract. Our
# packages therefore have no build state at all when the build starts and are
# compiled from scratch every time.
#
# Timestamps matter. OpenWrt decides whether to rebuild a dependency from the
# mtimes of its package directory against its stamps (and, without
# CONFIG_AUTOREMOVE, from a hash over "%p%T@", i.e. path plus mtime to the
# nanosecond). --format=posix keeps nanosecond mtimes, which the default GNU
# format rounds to the second. Feed checkouts are restored too: with the
# checkout present and the commit pinned in feeds.conf, `scripts/feeds update`
# leaves it alone instead of cloning fresh files with new mtimes, which would
# make every dependency look out of date.
#
# Not avoidable this way: the SDK repackages all ~480 kmods on every
# `package/<pkg>/compile`, warm or cold (~3 min per package), and walks the
# ~30 hostapd variants (~1 min of no-op make calls). That is most of what a
# warm build still spends.
set -euo pipefail

MARKER=/tmp/.sdk-cache-marker
TARBALL=sdk-tree.tar
read -r -a EXCLUDE <<< "${SDK_CACHE_EXCLUDE:-trafficctl}"

# Bump to drop every existing cache entry.
SALT=v3

excluded() {
	local args=() p
	for p in "${EXCLUDE[@]}"; do args+=(-e "$p"); done
	grep -v -F "${args[@]}" || true
}

# Feed checkouts that `scripts/feeds update` cannot update in place, as an
# ERE over buildroot-relative paths. A feed pinned to a commit (`url^sha`) is
# left alone, and one on a branch (23.05's `base ...;openwrt-23.05`) gets a
# `git pull --ff-only`. One pinned to a TAG (24.10's `src-git-full base
# ...;v24.10.6`) is a detached checkout, and that pull fails the update. So a
# feed without a commit pin whose HEAD is detached is not archived and is
# cloned fresh every run.
unpinned_detached() {
	local re='^$' name dir
	for name in $(awk '/^src-/ { i = 2; while ($i ~ /^--/) i++; if ($(i + 1) !~ /\^/) print $i }' \
		feeds.conf 2>/dev/null); do
		for dir in "feeds/$name" "feeds/${name}_root"; do
			if [ -d "$dir/.git" ] && ! (cd "$dir" && git symbolic-ref -q HEAD >/dev/null 2>&1); then
				re="$re|^feeds/${name}(_root)?(/|\\.|\$)"
			fi
		done
	done
	grep -v -E "$re" || true
}

case "${1:-}" in
key)
	image=${2:?image}
	driver=${3:?the script that drives the build in the container}
	digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image")
	digest=${digest##*@sha256:}
	tag=${image##*:}
	# One namespace per driver: sdk-entrypoint.sh (sdk-build.sh, the release
	# and compat builds) and test_feed_install.sh write different feeds.conf
	# files, and a tree restored under the other's feeds.conf re-clones every
	# feed and rebuilds everything. The same image is used by both.
	flavour=$(basename "$driver" .sh)
	here=$(cd "$(dirname "$0")" && pwd)
	# The packages' dependency lists decide which dependencies get built, and
	# the helpers decide the archive's layout. A change in either makes a new
	# entry, seeded from the closest older one through the restore prefix.
	inputs=$(cat "$here/sdk-cache.sh" "$driver" &&
		grep -h 'DEPENDS' "$here"/../*/Makefile)
	prefix="sdk-$SALT-$flavour-$tag-${digest:0:16}-"
	echo "$prefix$(printf '%s' "$inputs" | sha256sum | cut -c1-12)" "$prefix"
	;;
restore)
	dir=${2:?cache dir}
	touch "$MARKER"
	if [ ! -f "$dir/$TARBALL" ]; then
		echo "sdk-cache: no archive in $dir, cold build"
		exit 0
	fi
	args=()
	for p in "${EXCLUDE[@]}"; do args+=("--exclude=*$p*"); done
	start=$SECONDS
	tar -xf "$dir/$TARBALL" "${args[@]}"
	echo "sdk-cache: restored $(du -sh "$dir/$TARBALL" | cut -f1) in $((SECONDS - start))s"
	;;
save)
	dir=${2:?cache dir}
	binroot=${3:-$PWD}
	[ -f "$MARKER" ] || { echo "sdk-cache: no marker, restore never ran" >&2; exit 1; }
	start=$SECONDS
	tree=$(mktemp)
	bins=$(mktemp)
	roots=()
	for d in dl feeds build_dir staging_dir; do [ -e "$d" ] && roots+=("$d"); done
	[ "${#roots[@]}" -gt 0 ] || { echo "sdk-cache: $PWD is not an SDK buildroot" >&2; exit 1; }
	find "${roots[@]}" -cnewer "$MARKER" \( -type f -o -type l -o -type d \) -print | excluded | unpinned_detached > "$tree"
	if [ -d "$binroot/bin" ]; then
		(cd "$binroot" && find bin \( -type f -o -type l -o -type d \) -print) | excluded | unpinned_detached > "$bins"
	fi
	# The entrypoint writes the signing keys (key-build, private-key.pem) to
	# the buildroot's top level, outside every archived directory. Refuse to
	# save if the key material turns up in an archived file anyway: caches
	# are readable by every later run that can restore them.
	keys=$(mktemp)
	cat key-build private-key.pem 2>/dev/null |
		grep -v -e '^-----' -e '^untrusted comment' | awk 'length >= 20' > "$keys" || true
	leaks=$(mktemp)
	if [ -s "$keys" ]; then
		tr '\n' '\0' < "$tree" | xargs -0 -r grep -l -s -F -f "$keys" -- >> "$leaks" || true
		(cd "$binroot" && tr '\n' '\0' < "$bins" | xargs -0 -r grep -l -s -F -f "$keys" -- >> "$leaks") || true
	fi
	if [ -s "$leaks" ]; then
		echo "::warning::sdk-cache: signing key material in $(head -3 "$leaks" | tr '\n' ' '), not saving"
		rm -f "$keys" "$leaks" "$tree" "$bins"
		exit 0
	fi
	rm -f "$keys" "$leaks"
	tar --format=posix --no-recursion -cf "$dir/$TARBALL.new" -T "$tree"
	if [ -s "$bins" ]; then
		tar --format=posix --no-recursion -rf "$dir/$TARBALL.new" -C "$binroot" -T "$bins"
	fi
	mv -f "$dir/$TARBALL.new" "$dir/$TARBALL"
	# What the space goes to, by the first four path components.
	(tr '\n' '\0' < "$tree" | xargs -0 -r stat -c '%s %n' -- 2>/dev/null
		cd "$binroot" && tr '\n' '\0' < "$bins" | xargs -0 -r stat -c '%s %n' -- 2>/dev/null) |
		awk '{ split($2, p, "/"); k = p[1] "/" p[2] "/" p[3] "/" p[4]; s[k] += $1 }
			END { for (k in s) printf "%8.1f MB  %s\n", s[k] / 1048576, k }' |
		sort -rn | head -15 || true
	echo "sdk-cache: saved $(wc -l < "$tree") + $(wc -l < "$bins") entries," \
		"$(du -sh "$dir/$TARBALL" | cut -f1), in $((SECONDS - start))s"
	rm -f "$tree" "$bins"
	;;
*)
	echo "usage: $0 key <image> <driver> | restore <cache-dir> | save <cache-dir> [bin-root]" >&2
	exit 2
	;;
esac
