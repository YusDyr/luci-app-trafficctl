#!/bin/bash
# Integration test: verify build-ipk.sh produces a valid ipk.

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

cd "$(dirname "$0")/.."

rm -rf dist/
# The last line is the main package; translation packages precede it.
IPK=$(./build-ipk.sh 0.0.1-test 1 | tail -1)

assert_eq "ipk file exists" "yes" "$([ -f "$IPK" ] && echo yes || echo no)"

# Verify tar structure (OpenWrt ipk = gzip-compressed tar, NOT ar)
TAR_CONTENTS=$(tar tzf "$IPK" 2>/dev/null)
assert_contains "has debian-binary" "$TAR_CONTENTS" "debian-binary"
assert_contains "has control.tar.gz" "$TAR_CONTENTS" "control.tar.gz"
assert_contains "has data.tar.gz" "$TAR_CONTENTS" "data.tar.gz"

# Extract and verify control
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"
tar xzf "$OLDPWD/$IPK"

assert_eq "debian-binary is 2.0" "2.0" "$(cat debian-binary)"

CTRL_FILES=$(tar tzf control.tar.gz)
assert_contains "control file present" "$CTRL_FILES" "control"
assert_contains "conffiles present" "$CTRL_FILES" "conffiles"
assert_contains "postinst present" "$CTRL_FILES" "postinst"

tar xzf control.tar.gz
assert_contains "package name" "$(cat control)" "Package: luci-app-trafficctl"
assert_contains "version in control" "$(cat control)" "Version: 0.0.1-test-1"
assert_contains "arch is all" "$(cat control)" "Architecture: all"

DATA_FILES=$(tar tzf data.tar.gz)
assert_contains "rpcd backend" "$DATA_FILES" "usr/libexec/rpcd/luci.trafficctl"
assert_contains "summary script" "$DATA_FILES" "usr/local/bin/trafficctl-summary.sh"
assert_contains "frontend js" "$DATA_FILES" "www/luci-static/resources/view/trafficctl/status.js"
assert_contains "hotplug script" "$DATA_FILES" "etc/hotplug.d/iface/99-trafficctl-shapes"
assert_contains "menu json" "$DATA_FILES" "usr/share/luci/menu.d/luci-app-trafficctl.json"
assert_contains "acl json" "$DATA_FILES" "usr/share/rpcd/acl.d/luci-app-trafficctl.json"

cd "$OLDPWD"
rm -rf dist/

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
