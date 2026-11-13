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

# ── Syntax check with a REAL POSIX shell (dash or busybox ash) ─────────────
#
# The whole point of this check is that ash/dash reject bashisms ([[, arrays,
# `function` keyword) that a plain `sh -n` on a system where /bin/sh IS bash
# (renamed/invoked as sh — true on macOS, and on some Linux distros) will
# silently accept: bash-as-sh still parses `[[ ... ]]` and `arr=(1 2 3)` fine.
# Falling back to plain "sh" on such a host makes every "no bashisms"
# assertion below a false positive that verifies nothing (confirmed: `arr=(1
# 2 3)` + `[[ a == a ]]` syntax-checks CLEAN under macOS /bin/sh -n, and FAILS
# under dash -n as it must). So: only accept dash or ash as SHELL_CMD, and
# make the absence of either LOUD (a visible SKIP, not a silent, wrong pass).
SHELL_CMD=""
for candidate in dash ash busybox; do
    if command -v "$candidate" >/dev/null 2>&1; then
        if [ "$candidate" = "busybox" ]; then
            # only useful if this busybox actually provides an ash applet
            busybox ash -c 'exit 0' >/dev/null 2>&1 && SHELL_CMD="busybox ash"
        else
            SHELL_CMD="$candidate"
        fi
        [ -n "$SHELL_CMD" ] && break
    fi
done

if [ -z "$SHELL_CMD" ]; then
    echo "SKIP: no real dash/ash on this host — refusing to fall back to plain 'sh'" >&2
    echo "SKIP: (on macOS, sh IS bash-renamed and silently accepts [[ / arrays / bashisms — that fallback previously made every 'no bashisms' check here a no-op false pass)" >&2
    echo ""
    echo "0 passed, 0 failed (SKIPPED — install dash: brew install dash / apt-get install dash)"
    exit 0
fi
echo "Using POSIX shell for syntax/bashism checks: $SHELL_CMD"

# The shell left in 2.0.0: hotplug hooks, init scripts, uci-defaults and the
# metrics CGI. The backend itself is ucode (tests/test_install.sh compiles it).
F="$REPO_ROOT/trafficctl/files"
SH_SCRIPTS="$F/etc/hotplug.d/iface/99-trafficctl-shapes $F/etc/hotplug.d/dhcp/99-trafficctl-newdevice
$(ls "$F"/etc/init.d/* "$F"/etc/uci-defaults/*) $F/www/cgi-bin/trafficctl-metrics"
for script in $SH_SCRIPTS; do
    name=${script#"$F"/}
    # shellcheck disable=SC2086 # SHELL_CMD may be "busybox ash", intentionally split
    assert_ok "syntax: $name" $SHELL_CMD -n "$script"
done

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

for script in $SH_SCRIPTS; do
    check_bashism "$script"
done
# The rpcd plugin is ucode, not a shell script: tests/test_rpcd.sh runs it.

# ── IPK build and structure ────────────────────────────────────────────────

cd "$REPO_ROOT" || exit 1
# One path per line: trafficctl first, trafficctl-telegram second,
# luci-app-trafficctl last.
IPK_OUT=$(./build-ipk.sh 0.0.0-test 1 2>/dev/null)
BE_IPK=$(printf '%s\n' "$IPK_OUT" | head -1)
TG_IPK=$(printf '%s\n' "$IPK_OUT" | sed -n 2p)
IPK=$(printf '%s\n' "$IPK_OUT" | tail -1)
assert_eq "trafficctl ipk builds" "yes" "$([ -f "$BE_IPK" ] && echo yes || echo no)"
assert_eq "trafficctl-telegram ipk builds" "yes" "$([ -f "$TG_IPK" ] && echo yes || echo no)"
assert_eq "luci-app-trafficctl ipk builds" "yes" "$([ -f "$IPK" ] && echo yes || echo no)"

if [ -f "$BE_IPK" ] && [ -f "$TG_IPK" ] && [ -f "$IPK" ]; then
    TMPDIR=$(mktemp -d)
    mkdir -p "$TMPDIR/be" "$TMPDIR/tg" "$TMPDIR/fe"
    tar xzf "$REPO_ROOT/$BE_IPK" -C "$TMPDIR/be"
    tar xzf "$REPO_ROOT/$TG_IPK" -C "$TMPDIR/tg"
    tar xzf "$REPO_ROOT/$IPK" -C "$TMPDIR/fe"

    # Verify all critical files, each in the package that owns it
    BE_FILES=$(tar tzf "$TMPDIR/be/data.tar.gz")
    TG_FILES=$(tar tzf "$TMPDIR/tg/data.tar.gz")
    FE_FILES=$(tar tzf "$TMPDIR/fe/data.tar.gz")
    for expected in \
        "be usr/sbin/trafficctl" \
        "be usr/share/ucode/trafficctl/lib.uc" \
        "be usr/share/ucode/trafficctl/report.uc" \
        "tg usr/libexec/trafficctl/trafficctl-telegram.uc" \
        "tg usr/share/ucode/trafficctl/telegram.uc" \
        "be etc/hotplug.d/iface/99-trafficctl-shapes" \
        "tg etc/init.d/trafficctl-telegram" \
        "be etc/config/trafficctl" \
        "be www/cgi-bin/trafficctl-metrics" \
        "fe usr/libexec/rpcd/luci.trafficctl" \
        "fe www/luci-static/resources/view/trafficctl/status.js" \
        "fe usr/share/luci/menu.d/luci-app-trafficctl.json" \
        "fe usr/share/rpcd/acl.d/luci-app-trafficctl.json"; do
        pkg=${expected%% *} path=${expected#* }
        case "$pkg" in
            be) files=$BE_FILES; name=trafficctl ;;
            tg) files=$TG_FILES; name=trafficctl-telegram ;;
            *) files=$FE_FILES; name=luci-app-trafficctl ;;
        esac
        if echo "$files" | grep -q "$path"; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            printf "FAIL: %s ipk missing: %s\n" "$name" "$path"
        fi
    done

    # Verify control metadata
    tar xzf "$TMPDIR/be/control.tar.gz" -C "$TMPDIR/be"
    tar xzf "$TMPDIR/fe/control.tar.gz" -C "$TMPDIR/fe"
    assert_ok "trafficctl control has Depends" grep -q "Depends:" "$TMPDIR/be/control"
    assert_ok "trafficctl control has curl dep" grep -q "curl" "$TMPDIR/be/control"
    assert_ok "trafficctl conffiles has trafficctl" grep -q "/etc/config/trafficctl" "$TMPDIR/be/conffiles"
    assert_ok "trafficctl postinst is executable" test -x "$TMPDIR/be/postinst"
    assert_ok "luci-app control depends on trafficctl" grep -q "^Depends: trafficctl " "$TMPDIR/fe/control"
    tar xzf "$TMPDIR/tg/control.tar.gz" -C "$TMPDIR/tg"
    assert_ok "trafficctl-telegram control depends on trafficctl" grep -q "^Depends: trafficctl " "$TMPDIR/tg/control"
    assert_ok "trafficctl-telegram postinst is executable" test -x "$TMPDIR/tg/postinst"
    assert_ok "luci-app postinst is executable" test -x "$TMPDIR/fe/postinst"

    cd "$REPO_ROOT" || exit 1
    rm -rf "$TMPDIR" dist/
fi

# ── Script permissions ─────────────────────────────────────────────────────

# The hotplug hooks are sourced by hotplug-call, not run, and are installed
# with INSTALL_DATA: no exec bit to check there.
for script in $(ls "$F"/etc/init.d/* "$F"/etc/uci-defaults/*) "$F/www/cgi-bin/trafficctl-metrics" \
              "$F/usr/sbin/trafficctl" "$F/usr/libexec/trafficctl/trafficctl-telegram.uc"; do
    assert_ok "executable: ${script#"$F"/}" test -x "$script"
done
assert_ok "executable: rpcd" test -x "$REPO_ROOT/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
assert_ok "executable: init.d" test -x "$REPO_ROOT/trafficctl/files/etc/init.d/trafficctl-telegram"

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
