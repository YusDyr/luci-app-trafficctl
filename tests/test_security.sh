#!/bin/bash
# Security tests: validate input sanitization and injection resistance
# against the REAL functions, not local redefinitions.
#
# An earlier version of this file defined its own sanitizers and asserted
# against those copies, so deleting the real validation left it green.
# Everything below sources or invokes the production code.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    fi
}

# ── IP validation ───────────────────────────────────────────────────────────
# lib.valid_ip, valid_target and cidr_spec, with the injection and
# leading-zero cases this file ran against v1.30's tctl_validate_ip:
# tests/test_ucode_lib.sh.

# ── MAC / name sanitization ─────────────────────────────────────────────────
# The known-device ledger, the one place a MAC/name pair from a DHCP client is
# written to disk, moved to trafficctl.notify: tests/test_notify.sh drives it
# with an injected name.

# ── The Telegram bot ───────────────────────────────────────────────────────
# Callback validation, the token off curl's argv and the JSON bodies moved to
# tests/test_telegram_bot.sh with the bot (trafficctl.telegram).

# ── ucode: one place builds shell command lines ─────────────────────────────
# lib.uc's run()/lines()/sh() are the only callers of popen() and system(),
# and every value in their command goes through q(): tests/lib/uc_cmd_lint.py.
UC_DIR="$BIN/../../share/ucode/trafficctl"
UC_FILES="$UC_DIR/*.uc $BIN/*.uc $BIN/../../sbin/trafficctl $(dirname "$0")/../luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
LINT="$(dirname "$0")/lib/uc_cmd_lint.py"
# shellcheck disable=SC2086 # a glob on purpose
assert_eq "ucode: commands quoted, popen/system only in lib.uc" "" \
    "$(python3 "$LINT" "$UC_DIR/lib.uc" $UC_FILES)"

# The lint must see what it is for.
cat > "$TMPDIR/bad.uc" <<'UC'
'use strict';
import { popen as p } from 'fs';
import * as fs from 'fs';
fs.system('true');
print('popen system');
match(x, /"/);
lib.run('ip link show ' + dev);
lib.lines('nslookup ' + (srv ? srv : ''));
lib.sh(cmd, 100);
lib.run('ip ' + lib.q(dev) + (v6 ? ' -6' : '') + ' route');
lib.pipe('read -r x; ' + lib.qv([ 'a', b ]), secret);
lib.pipe('cat ' + file, '');
// lib.run('commented ' + out);
UC
OUT=$(python3 "$LINT" "$UC_DIR/lib.uc" "$TMPDIR/bad.uc")
assert_contains "lint: an aliased popen import" "$OUT" "bad.uc:2: popen outside lib.uc"
assert_contains "lint: system through a namespace import" "$OUT" "bad.uc:4: system outside lib.uc"
assert_contains "lint: a concatenated variable" "$OUT" "bad.uc:7: unquoted"
assert_contains "lint: a variable in a ternary branch" "$OUT" "bad.uc:8: unquoted"
assert_contains "lint: a bare variable" "$OUT" "bad.uc:9: unquoted"
assert_contains "lint: a variable in a pipe() command" "$OUT" "bad.uc:12: unquoted"
assert_eq "lint: nothing else (strings, regexes, q(), qv(), comments)" "6" "$(printf '%s\n' "$OUT" | grep -c .)"
# shellcheck disable=SC2086
assert_eq "ucode: every file starts strict" "" \
    "$(for f in $UC_FILES; do grep -q "^'use strict';$" "$f" || echo "$f"; done)"

# ── Results ─────────────────────────────────────────────────────────────────

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
