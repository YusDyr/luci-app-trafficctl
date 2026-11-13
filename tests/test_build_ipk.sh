#!/bin/bash
# Integration test: verify build-ipk.sh produces valid ipks for both packages,
# trafficctl (the backend) and luci-app-trafficctl (the web interface).

set -e

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  '%s' not found in output\n" "$desc" "$needle"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  '%s' unexpectedly found in output\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

cd "$(dirname "$0")/.."
REPO=$(pwd)

rm -rf dist/
# One path per line: trafficctl first, trafficctl-telegram second, the
# translation packages next, the luci-app-trafficctl package last.
OUT=$(./build-ipk.sh 0.0.1-test 1)
BE_IPK=$(echo "$OUT" | head -1)
TG_IPK=$(echo "$OUT" | sed -n 2p)
IPK=$(echo "$OUT" | tail -1)

assert_eq "first output is the trafficctl ipk" "trafficctl_0.0.1-test-1_all.ipk" "$(basename "$BE_IPK")"
assert_eq "second output is the trafficctl-telegram ipk" "trafficctl-telegram_0.0.1-test-1_all.ipk" "$(basename "$TG_IPK")"
assert_eq "last output is the luci-app ipk" "luci-app-trafficctl_0.0.1-test-1_all.ipk" "$(basename "$IPK")"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Unpack $1 into $TMPDIR/$2 (control files in ctrl/, the data file list in data.list).
unpack() {
    local ipk="$REPO/$1" d="$TMPDIR/$2"
    mkdir -p "$d/ctrl"
    assert_eq "$2: ipk file exists" "yes" "$([ -f "$ipk" ] && echo yes || echo no)"
    # OpenWrt ipk = gzip-compressed tar, NOT ar
    local outer
    outer=$(tar tzf "$ipk" 2>/dev/null)
    assert_contains "$2: has debian-binary" "$outer" "debian-binary"
    assert_contains "$2: has control.tar.gz" "$outer" "control.tar.gz"
    assert_contains "$2: has data.tar.gz" "$outer" "data.tar.gz"
    tar xzf "$ipk" -C "$d"
    assert_eq "$2: debian-binary is 2.0" "2.0" "$(cat "$d/debian-binary")"
    tar xzf "$d/control.tar.gz" -C "$d/ctrl"
    tar tzf "$d/data.tar.gz" > "$d/data.list"
}

# ── trafficctl ────────────────────────────────────────────────────────────────
unpack "$BE_IPK" be
CTRL=$(cat "$TMPDIR/be/ctrl/control")
DATA=$(cat "$TMPDIR/be/data.list")
assert_contains "be: package name" "$CTRL" "^Package: trafficctl$"
assert_contains "be: version" "$CTRL" "^Version: 0.0.1-test-1$"
assert_contains "be: arch is all" "$CTRL" "^Architecture: all$"
assert_contains "be: replaces the old single package" "$CTRL" "^Replaces: luci-app-trafficctl$"
assert_not_contains "be: no Conflicts (it breaks the upgrade from the single package)" "$CTRL" "^Conflicts:"
assert_contains "be: depends on conntrack" "$CTRL" "^Depends:.*conntrack"
assert_not_contains "be: no LuCI dependency" "$CTRL" "^Depends:.*luci-base"
# Optional, so the backend installs on wired-only builds without hostapd.
assert_not_contains "be: hostapd-utils is optional" "$CTRL" "^Depends:.*hostapd-utils"
assert_eq "be: conffiles" "/etc/config/trafficctl" "$(cat "$TMPDIR/be/ctrl/conffiles")"
for s in postinst prerm; do
    assert_eq "be: $s present" "yes" "$([ -f "$TMPDIR/be/ctrl/$s" ] && echo yes || echo no)"
done
assert_contains "be: postinst removes the opkg backup" "$(cat "$TMPDIR/be/ctrl/postinst")" "trafficctl-opkg.backup"
assert_contains "be: the CLI" "$DATA" "usr/sbin/trafficctl$"
assert_contains "be: its modules" "$DATA" "usr/share/ucode/trafficctl/report.uc"
assert_not_contains "be: no shell scripts in usr/libexec (gone in 2.0.0)" "$DATA" "usr/libexec/trafficctl/.*\.sh$"
assert_contains "be: hotplug script" "$DATA" "etc/hotplug.d/iface/99-trafficctl-shapes"
assert_contains "be: init script" "$DATA" "etc/init.d/trafficctl-notify"
assert_not_contains "be: no bot (trafficctl-telegram)" "$DATA" 'trafficctl-telegram\(\.sh\|\.uc\)*$'
assert_not_contains "be: no bot module" "$DATA" "telegram.uc"
assert_contains "be: config" "$DATA" "etc/config/trafficctl$"
assert_contains "be: keep.d" "$DATA" "lib/upgrade/keep.d/trafficctl$"
assert_contains "be: metrics cgi" "$DATA" "www/cgi-bin/trafficctl-metrics"
assert_not_contains "be: no rpcd plugin" "$DATA" "usr/libexec/rpcd/"
assert_not_contains "be: no frontend" "$DATA" "luci-static"
mkdir -p "$TMPDIR/be/data"
tar xzf "$TMPDIR/be/data.tar.gz" -C "$TMPDIR/be/data"
for f in usr/sbin/trafficctl www/cgi-bin/trafficctl-metrics etc/init.d/trafficctl-notify; do
    assert_eq "be: $f is executable" yes "$([ -x "$TMPDIR/be/data/$f" ] && echo yes || echo no)"
done

# ── trafficctl-telegram ───────────────────────────────────────────────────────
unpack "$TG_IPK" tg
CTRL=$(cat "$TMPDIR/tg/ctrl/control")
DATA=$(cat "$TMPDIR/tg/data.list")
assert_contains "tg: package name" "$CTRL" "^Package: trafficctl-telegram$"
assert_contains "tg: version" "$CTRL" "^Version: 0.0.1-test-1$"
assert_contains "tg: arch is all" "$CTRL" "^Architecture: all$"
assert_contains "tg: depends on the same trafficctl and curl" "$CTRL" "^Depends: trafficctl (= 0.0.1-test-1), curl$"
assert_contains "tg: replaces trafficctl, which carried the bot up to 1.30.x" "$CTRL" "^Replaces: trafficctl$"
assert_not_contains "tg: no Conflicts" "$CTRL" "^Conflicts:"
assert_eq "tg: no conffiles (the config is trafficctl's)" "no" "$([ -f "$TMPDIR/tg/ctrl/conffiles" ] && echo yes || echo no)"
for s in preinst postinst prerm; do
    assert_eq "tg: $s present" "yes" "$([ -f "$TMPDIR/tg/ctrl/$s" ] && echo yes || echo no)"
done
assert_eq "tg: the bot's files and their directories" \
    "./etc/init.d/trafficctl-telegram ./usr/libexec/trafficctl/trafficctl-telegram.uc ./usr/share/ucode/trafficctl/telegram.uc" \
    "$(grep -v '/$' "$TMPDIR/tg/data.list" | grep -vx '\.' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$TMPDIR/tg/data"
tar xzf "$TMPDIR/tg/data.tar.gz" -C "$TMPDIR/tg/data"
for f in etc/init.d/trafficctl-telegram usr/libexec/trafficctl/trafficctl-telegram.uc; do
    assert_eq "tg: $f is executable" yes "$([ -x "$TMPDIR/tg/data/$f" ] && echo yes || echo no)"
done

# ── luci-app-trafficctl ──────────────────────────────────────────────────────
unpack "$IPK" fe
CTRL=$(cat "$TMPDIR/fe/ctrl/control")
DATA=$(cat "$TMPDIR/fe/data.list")
assert_contains "fe: package name" "$CTRL" "^Package: luci-app-trafficctl$"
assert_contains "fe: version" "$CTRL" "^Version: 0.0.1-test-1$"
assert_contains "fe: arch is all" "$CTRL" "^Architecture: all$"
assert_contains "fe: depends on the same trafficctl" "$CTRL" "^Depends: trafficctl (= 0.0.1-test-1)"
assert_contains "fe: depends on the same trafficctl-telegram" "$CTRL" "^Depends:.* trafficctl-telegram (= 0.0.1-test-1),"
assert_contains "fe: depends on luci-base" "$CTRL" "^Depends:.*luci-base"
# Kept on the web interface so the upgrade from 1.28.0 does not orphan it.
assert_contains "fe: keeps hostapd-utils" "$CTRL" "^Depends:.*hostapd-utils"
assert_not_contains "fe: no Conflicts" "$CTRL" "^Conflicts:"
assert_eq "fe: no conffiles" "no" "$([ -f "$TMPDIR/fe/ctrl/conffiles" ] && echo yes || echo no)"
assert_contains "fe: postinst restarts rpcd" "$(cat "$TMPDIR/fe/ctrl/postinst")" "rpcd restart"
assert_contains "fe: rpcd backend" "$DATA" "usr/libexec/rpcd/luci.trafficctl"
assert_contains "fe: frontend js" "$DATA" "www/luci-static/resources/view/trafficctl/status.js"
assert_contains "fe: menu json" "$DATA" "usr/share/luci/menu.d/luci-app-trafficctl.json"
assert_contains "fe: acl json" "$DATA" "usr/share/rpcd/acl.d/luci-app-trafficctl.json"
assert_not_contains "fe: no helper scripts" "$DATA" "usr/libexec/trafficctl/"
assert_not_contains "fe: no config" "$DATA" "etc/config/"
assert_not_contains "fe: no keep.d" "$DATA" "lib/upgrade/"
assert_not_contains "fe: no cgi" "$DATA" "cgi-bin"

rm -rf dist/

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
