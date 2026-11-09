#!/bin/bash
# Build a signed package feed from a release's dist/ directory:
#
#   <out>/opkg/  *.ipk, Packages, Packages.gz, Packages.sig  (OpenWrt 21.02-24.10)
#   <out>/apk/   *.apk, packages.adb                         (OpenWrt 25.12+)
#   <out>/keys/  the public keys a router needs to trust the feed
#   <out>/index.html
#
# Usage: tools/build-feed.sh <dist dir> <out dir>
#
# Without a feed every upgrade means looking up the release, wget-ing the file
# and installing it with --allow-untrusted on apk. With one, the router trusts
# our key once and `opkg upgrade` / `apk upgrade` pick up new releases like any
# other package, with the index signature checked on every update.
#
# The index is built with the tools of the same SDK image tools/sdk-build.sh
# builds the APK with, and the same way the SDK's own package/Makefile does it
# (targets merge-index and index): ipkg-make-index.sh, the Packages field
# filter, the usign SHA-512 padding workaround and `usign -S` for opkg;
# `apk mkndx --sign` for apk. Writing our own index generator would mean
# matching opkg's and apk-tools' parsers by hand.
#
# Nothing is mounted. dist/ goes into the container as a tar on stdin and the
# feed comes back as a tar on stdout, so the script needs no uid juggling
# (sdk-build.sh has to chown the workspace to the image's buildbot user) and
# works where Docker Desktop refuses to share the directory.
#
# Env:
#   USIGN_PRIVATE_KEY  usign secret key (signs Packages)          required
#   APK_PRIVATE_KEY    EC P-256 PEM private key (signs packages.adb) required
#   USIGN_PUBLIC_KEY   path to the matching usign public key, default keys/usign-*.pub
#   APK_PUBLIC_KEY     path to the matching PEM public key, default keys/apk-signing.pub
#   FEED_URL           base URL the feed is served from (only used in index.html)
#   ARCH               SDK image tag, default x86_64-25.12.4
#
# The private keys reach the container by NAME (`docker run --env VAR`), never
# on a command line, and are written only to the container's tmpfs-backed
# work directory, which `--rm` discards. Each one is checked against the public
# key we publish before anything is signed: a feed signed with a key the
# routers do not have fails on every `opkg update`, which is worse than no feed.
#
# Only the packages of this release go in (the versioned file names, which
# cover trafficctl, luci-app-trafficctl and the translations; the
# <name>.ipk / _all / .apk / _noarch aliases are the same bytes).
# That is all an upgrade needs.
set -euo pipefail

DIST=${1:?usage: build-feed.sh <dist dir> <out dir>}
OUT=${2:?usage: build-feed.sh <dist dir> <out dir>}
: "${USIGN_PRIVATE_KEY:?USIGN_PRIVATE_KEY is required}"
: "${APK_PRIVATE_KEY:?APK_PRIVATE_KEY is required}"
export USIGN_PRIVATE_KEY APK_PRIVATE_KEY

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
IMAGE="${CONTAINER:-ghcr.io/openwrt/sdk}:${ARCH:-x86_64-25.12.4}"
FEED_URL=${FEED_URL:-https://yusdyr.github.io/luci-app-trafficctl}

if [ -z "${USIGN_PUBLIC_KEY:-}" ]; then
	USIGN_PUBLIC_KEY=$(find "$REPO/keys" -maxdepth 1 -name 'usign-*.pub' | head -1)
fi
APK_PUBLIC_KEY=${APK_PUBLIC_KEY:-$REPO/keys/apk-signing.pub}
[ -f "$USIGN_PUBLIC_KEY" ] || { echo "usign public key not found: '$USIGN_PUBLIC_KEY'" >&2; exit 1; }
[ -f "$APK_PUBLIC_KEY" ] || { echo "apk public key not found: $APK_PUBLIC_KEY" >&2; exit 1; }

shopt -s nullglob
# The version always starts with a digit; the aliases have none there.
IPKS=("$DIST"/*_[0-9]*_all.ipk)
APKS=("$DIST"/*_[0-9]*_noarch.apk)
shopt -u nullglob
[ "${#IPKS[@]}" -gt 0 ] || { echo "no versioned *.ipk in $DIST" >&2; exit 1; }
[ "${#APKS[@]}" -gt 0 ] || { echo "no versioned *.apk in $DIST" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/ipk" "$STAGE/apk" "$STAGE/keys"
cp "${IPKS[@]}" "$STAGE/ipk/"
cp "${APKS[@]}" "$STAGE/apk/"
cp "$USIGN_PUBLIC_KEY" "$STAGE/keys/usign.pub"
cp "$APK_PUBLIC_KEY" "$STAGE/keys/apk.pem"

# Runs inside the SDK image as buildbot. stdout carries the result tar, so
# everything else goes to stderr.
# shellcheck disable=SC2016  # expanded by the container's bash, not here
INNER='
set -euo pipefail
exec 3>&1 1>&2
B=/builder/staging_dir/host/bin
W=$(mktemp -d)
cd "$W"
tar -xf -

umask 077
printf "%s\n" "$USIGN_PRIVATE_KEY" > usign.key
printf "%s\n" "$APK_PRIVATE_KEY" > apk.key
unset USIGN_PRIVATE_KEY APK_PRIVATE_KEY
umask 022

USIGN_ID=$("$B/usign" -F -p keys/usign.pub)
[ "$("$B/usign" -F -s usign.key)" = "$USIGN_ID" ] \
	|| { echo "USIGN_PRIVATE_KEY does not match the usign public key $USIGN_ID"; exit 1; }
cmp -s <(openssl pkey -pubin -in keys/apk.pem -outform DER) \
	<(openssl pkey -in apk.key -pubout -outform DER) \
	|| { echo "APK_PRIVATE_KEY does not match the apk public key"; exit 1; }

mkdir -p out/opkg out/apk out/keys

# opkg: package/Makefile, target index
cp ipk/*.ipk out/opkg/
(
	cd out/opkg
	MKHASH="$B/mkhash" /builder/scripts/ipkg-make-index.sh . > Packages.manifest
	grep -vE "^(Maintainer|LicenseFiles|Source|SourceName|Require|SourceDateEpoch)" Packages.manifest > Packages
	rm Packages.manifest
	case "$(((64 + $(stat -L -c%s Packages)) % 128))" in 110|111)
		echo "Applying padding to Packages to work around the usign SHA-512 bug"
		{ echo ""; echo ""; } >> Packages;;
	esac
	gzip -9nc Packages > Packages.gz
	"$B/usign" -S -m Packages -s "$W/usign.key"
	"$B/usign" -V -m Packages -p "$W/keys/usign.pub"
)

# apk: apk-tools 3 fetches ${name}-${version}.apk from the directory that holds
# packages.adb, so the files are named after their own metadata. The release
# names do not fit that, and the translations carry the SDK date version.
for f in apk/*.apk; do
	nv=$("$B/apk" adbdump --format json "$f" | python3 -c "import json,sys; i=json.load(sys.stdin)[\"info\"]; print(i[\"name\"] + \"-\" + i[\"version\"])")
	cp "$f" "out/apk/$nv.apk"
done
(
	cd out/apk
	"$B/apk" mkndx --root /builder --keys-dir "$W/keys" --allow-untrusted \
		--sign "$W/apk.key" --output packages.adb ./*.apk
	"$B/apk" adbdump --format json packages.adb | python3 -c "
import json, sys
for p in json.load(sys.stdin)[\"packages\"]:
    print(\"  indexed\", p[\"name\"], p[\"version\"])"
)

# Key files named the way each package manager expects them: opkg looks a key
# up by its fingerprint in /etc/opkg/keys/, apk loads any *.pem in /etc/apk/keys/.
cp keys/usign.pub "out/keys/$USIGN_ID"
cp keys/usign.pub "out/keys/usign-$USIGN_ID.pub"
cp keys/apk.pem out/keys/trafficctl.pem

tar -C out -cf - . >&3
'

for i in 1 2 3; do
	docker pull -q "$IMAGE" >/dev/null && break
	[ "$i" = 3 ] && exit 1
	sleep 15
done

mkdir -p "$OUT"
rm -rf "$OUT/opkg" "$OUT/apk" "$OUT/keys" "$OUT/index.html"
(cd "$STAGE" && COPYFILE_DISABLE=1 tar --no-xattrs -cf - ipk apk keys) |
	docker run --rm -i \
		--env USIGN_PRIVATE_KEY \
		--env APK_PRIVATE_KEY \
		--entrypoint /bin/bash \
		"$IMAGE" -c "$INNER" |
	tar -C "$OUT" -xf -

USIGN_ID=$(find "$OUT/keys" -name 'usign-*.pub' -exec basename {} .pub \; | sed 's/^usign-//')
cat > "$OUT/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>luci-app-trafficctl package feed</title>
<style>body{font-family:sans-serif;max-width:52em;margin:2em auto;padding:0 1em}pre{background:#f4f4f4;padding:1em;overflow-x:auto}</style>
</head>
<body>
<h1>luci-app-trafficctl package feed</h1>
<p>Signed package feed for <a href="https://github.com/YusDyr/luci-app-trafficctl">luci-app-trafficctl</a>.
Add it once, then install and upgrade with the router's own package manager.</p>

<h2>OpenWrt 21.02 &ndash; 24.10 (opkg)</h2>
<pre>wget -O /tmp/trafficctl.pub ${FEED_URL}/keys/usign-${USIGN_ID}.pub
opkg-key add /tmp/trafficctl.pub
echo 'src/gz trafficctl ${FEED_URL}/opkg' &gt;&gt; /etc/opkg/customfeeds.conf
opkg update
opkg install luci-app-trafficctl
/etc/init.d/rpcd restart</pre>

<h2>OpenWrt 25.12+ (apk)</h2>
<pre>wget -O /etc/apk/keys/trafficctl.pem ${FEED_URL}/keys/trafficctl.pem
echo '${FEED_URL}/apk/packages.adb' &gt;&gt; /etc/apk/repositories.d/customfeeds.list
apk update
apk add luci-app-trafficctl
/etc/init.d/rpcd restart</pre>

<p>luci-app-trafficctl is the web interface; it pulls in trafficctl, the backend.</p>
<p>Upgrades: <code>opkg update &amp;&amp; opkg upgrade trafficctl luci-app-trafficctl</code>, or
<code>apk update &amp;&amp; apk upgrade trafficctl luci-app-trafficctl</code>.
Upgrading from 1.28.x or earlier, when the backend was part of luci-app-trafficctl, is
<code>opkg upgrade luci-app-trafficctl</code> / <code>apk upgrade luci-app-trafficctl</code>:
it installs trafficctl on the way and keeps the configuration.</p>
<p>Indexes: <a href="opkg/Packages">opkg/Packages</a>, <a href="apk/packages.adb">apk/packages.adb</a>.
Keys: <a href="keys/usign-${USIGN_ID}.pub">usign-${USIGN_ID}.pub</a>, <a href="keys/trafficctl.pem">trafficctl.pem</a>.</p>
</body>
</html>
EOF

echo "feed written to $OUT (usign key $USIGN_ID)" >&2
find "$OUT" -type f | sort >&2
