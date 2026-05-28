#!/bin/bash
# OpenWrt compatibility test.
# Runs on self-hosted runner — validates scripts parse correctly with ash/dash,
# checks that the ipk installs cleanly, and verifies script structure.

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

assert_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  command failed: %s\n" "$desc" "$*"
    fi
}

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Syntax check with dash (closest to ash) ───────────────────────────────

SHELL_CMD="dash"
if ! command -v dash >/dev/null 2>&1; then
    SHELL_CMD="sh"
fi

for script in "$REPO_ROOT"/luci-app-trafficctl/root/usr/local/bin/trafficctl-*.sh; do
    name=$(basename "$script")
    assert_ok "syntax: $name" $SHELL_CMD -n "$script"
done

assert_ok "syntax: rpcd/trafficctl" $SHELL_CMD -n "$REPO_ROOT/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
assert_ok "syntax: hotplug" $SHELL_CMD -n "$REPO_ROOT/luci-app-trafficctl/root/etc/hotplug.d/iface/99-trafficctl-shapes"
assert_ok "syntax: init.d/trafficctl-telegram" $SHELL_CMD -n "$REPO_ROOT/luci-app-trafficctl/root/etc/init.d/trafficctl-telegram"

# ── No bashisms (check common ones) ───────────────────────────────────────

check_bashism() {
    local file="$1" name
    name=$(basename "$file")
    # arrays: var=(...)
    if grep -nE '^\s*[a-zA-Z_]+\s*=\s*\(' "$file" | grep -v '^\s*#' | grep -qv 'shellcheck'; then
        FAIL=$((FAIL + 1))
        printf "FAIL: bashism in %s — array assignment\n" "$name"
        return
    fi
    # [[ double brackets
    if grep -nE '\[\[' "$file" | grep -qv '^\s*#'; then
        FAIL=$((FAIL + 1))
        printf "FAIL: bashism in %s — [[ double brackets\n" "$name"
        return
    fi
    # function keyword (shell, not inside awk blocks)
    if grep -nE '^\s*function\s+\w+\s*\(\)' "$file" | grep -qv '^\s*#'; then
        FAIL=$((FAIL + 1))
        printf "FAIL: bashism in %s — function keyword\n" "$name"
        return
    fi
    PASS=$((PASS + 1))
}

for script in "$REPO_ROOT"/luci-app-trafficctl/root/usr/local/bin/trafficctl-*.sh; do
    check_bashism "$script"
done
check_bashism "$REPO_ROOT/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"

# ── IPK build and structure ────────────────────────────────────────────────

cd "$REPO_ROOT"
IPK=$(./build-ipk.sh 0.0.0-test 1 2>/dev/null)
assert_eq "ipk builds" "yes" "$([ -f "$IPK" ] && echo yes || echo no)"

if [ -f "$IPK" ]; then
    TMPDIR=$(mktemp -d)
    cd "$TMPDIR"
    tar xzf "$REPO_ROOT/$IPK"

    # Verify all critical files in data.tar.gz
    DATA_FILES=$(tar tzf data.tar.gz)
    for expected in \
        "usr/libexec/rpcd/luci.trafficctl" \
        "usr/local/bin/trafficctl-summary.sh" \
        "usr/local/bin/trafficctl-device.sh" \
        "usr/local/bin/trafficctl-fw.sh" \
        "usr/local/bin/trafficctl-telegram.sh" \
        "www/luci-static/resources/view/trafficctl/status.js" \
        "usr/share/luci/menu.d/luci-app-trafficctl.json" \
        "usr/share/rpcd/acl.d/luci-app-trafficctl.json" \
        "etc/hotplug.d/iface/99-trafficctl-shapes" \
        "etc/init.d/trafficctl-telegram" \
        "etc/config/trafficctl"; do
        if echo "$DATA_FILES" | grep -q "$expected"; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            printf "FAIL: ipk missing: %s\n" "$expected"
        fi
    done

    # Verify control metadata
    tar xzf control.tar.gz
    assert_ok "control has Depends" grep -q "Depends:" control
    assert_ok "control has curl dep" grep -q "curl" control
    assert_ok "conffiles has trafficctl" grep -q "/etc/config/trafficctl" conffiles
    assert_ok "postinst is executable" test -x postinst

    cd "$REPO_ROOT"
    rm -rf "$TMPDIR" dist/
fi

# ── Script permissions ─────────────────────────────────────────────────────

for script in "$REPO_ROOT"/luci-app-trafficctl/root/usr/local/bin/trafficctl-*.sh; do
    assert_ok "executable: $(basename "$script")" test -x "$script"
done
assert_ok "executable: rpcd" test -x "$REPO_ROOT/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
assert_ok "executable: init.d" test -x "$REPO_ROOT/luci-app-trafficctl/root/etc/init.d/trafficctl-telegram"

# ── JSON validity ──────────────────────────────────────────────────────────

for json_file in \
    "$REPO_ROOT/luci-app-trafficctl/root/usr/share/luci/menu.d/luci-app-trafficctl.json" \
    "$REPO_ROOT/luci-app-trafficctl/root/usr/share/rpcd/acl.d/luci-app-trafficctl.json"; do
    name=$(basename "$json_file")
    if python3 -c "import json; json.load(open('$json_file'))" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: invalid JSON: %s\n" "$name"
    fi
done

# ── Results ────────────────────────────────────────────────────────────────

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
