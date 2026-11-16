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

# ── IP validation (real tctl_validate_ip from trafficctl-fw.sh) ────────────

uci() { echo ""; }
nft() { return 1; }
command() { return 1; }
export -f uci nft command

. "$BIN/trafficctl-fw.sh"

# Command injection attempts via IP
assert_eq "injection: semicolon" 1 "$(tctl_validate_ip '192.168.1.1; rm -rf /' && echo 0 || echo 1)"
assert_eq "injection: pipe" 1 "$(tctl_validate_ip '192.168.1.1|cat /etc/passwd' && echo 0 || echo 1)"
assert_eq "injection: backtick" 1 "$(tctl_validate_ip '$(whoami).168.1.1' && echo 0 || echo 1)"
assert_eq "injection: newline" 1 "$(tctl_validate_ip "192.168.1.1
rm -rf /" && echo 0 || echo 1)"
assert_eq "injection: ampersand" 1 "$(tctl_validate_ip '192.168.1.1&& cat /etc/shadow' && echo 0 || echo 1)"
assert_eq "injection: redirect" 1 "$(tctl_validate_ip '192.168.1.1>/tmp/hacked' && echo 0 || echo 1)"

# Leading zeros: $(( )) reads 010 as octal, so 010.0.0.0 was 8.0.0.0.
for ip in 010.0.5.0 1.02.3.4 1.2.3.00; do
    assert_eq "leading zero in '$ip' refused" 1 "$(tctl_validate_ip "$ip" && echo 0 || echo 1)"
done
assert_eq "0.0.0.0 is still an address" 0 "$(tctl_validate_ip 0.0.0.0 && echo 0 || echo 1)"
assert_eq "target: a leading-zero prefix refused" 1 "$(tctl_validate_target 10.0.0.0/08 >/dev/null && echo 0 || echo 1)"
assert_eq "target: /0 allowed" "10.0.0.0/0" "$(tctl_validate_target 10.0.0.0/0)"
assert_eq "cidr_spec: a leading-zero prefix refused" 1 "$(tctl_cidr_spec 10.0.0.0/08 >/dev/null && echo 0 || echo 1)"
assert_eq "cidr_spec: a leading-zero octet refused" 1 "$(tctl_cidr_spec 010.0.0.0/8 >/dev/null && echo 0 || echo 1)"

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
UC_FILES="$UC_DIR/*.uc $BIN/*.uc $BIN/../../sbin/trafficctl $(dirname "$0")/../luci-app-trafficctl/root/usr/share/rpcd/ucode/luci.trafficctl.uc"
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
