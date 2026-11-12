#!/bin/bash
# Security tests: validate input sanitization and injection resistance
# against the REAL functions, not local redefinitions.
#
# The previous version of this file defined its own sanitize_mac,
# sanitize_name, validate_cb_ip, validate_cb_param and json_escape and
# asserted against those copies. None of those names exist in trafficctl-fw.sh
# or trafficctl-telegram.sh — the real MAC/name sanitizer is add_known_mac()'s
# inline `tr -cd`, the real callback validation is inline in handle_callback(),
# and the real JSON escaping is tg_json_escape() — so a reviewer deleting the
# actual validation left this file 30/0 green. Everything below now sources
# or invokes the production scripts.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"

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

# ── MAC / name sanitization (real add_known_mac from the telegram bot) ────
# add_known_mac is the only place production code sanitizes a MAC/name pair
# before writing it to disk (`tr -cd 'a-fA-F0-9:'` / `tr -cd 'a-zA-Z0-9 _.-'`
# inline in trafficctl-telegram.sh). Drive it through the real function by
# sourcing a neutered copy of the daemon (main() suppressed) rather than
# re-typing the same tr expression here.

mkdir -p "$TMPDIR/lib"
cat > "$TMPDIR/lib/functions.sh" <<'MOCK'
config_load() { :; }
config_get() { eval "$2=\"\${4:-}\""; }
MOCK

NEUTERED="$TMPDIR/telegram_neutered.sh"
sed -e "s|\. /lib/functions\.sh|. $TMPDIR/lib/functions.sh|" \
    -e '$s|^main$|:|' \
    "$BIN/trafficctl-telegram.sh" > "$NEUTERED"
tail -1 "$NEUTERED" | grep -q '^main$' && {
    echo "FAIL: harness bug — could not neuter main(), refusing to run"
    exit 1
}

KNOWN_TEST="$TMPDIR/known.json"
echo '[]' > "$KNOWN_TEST"

sh -c "
. '$NEUTERED'
KNOWN_FILE='$KNOWN_TEST'
add_known_mac 'aa:bb:cc:dd:ee:ff' 'MyPhone' '192.168.0.1'
"
STORED=$(cat "$KNOWN_TEST")
assert_contains "mac/name sanitize: normal mac preserved" "$STORED" "aa:bb:cc:dd:ee:ff"
assert_contains "mac/name sanitize: normal name preserved" "$STORED" "MyPhone"

: > "$KNOWN_TEST"; echo '[]' > "$KNOWN_TEST"
sh -c "
. '$NEUTERED'
KNOWN_FILE='$KNOWN_TEST'
add_known_mac 'aa:bb:cc:dd:ee:ff\"; rm -rf /' 'evil\"};\$(rm -rf /);{\"' '192.168.0.1'
"
STORED=$(cat "$KNOWN_TEST")
# The stored record is itself JSON, so a naive `sed 's/.*"mac":"\([^"]*\)".*'`
# field-extraction would stop at the FIRST embedded quote in an unsanitized
# value and silently "pass" no matter what — which is exactly the injected
# payload here (the mac/name sanitizers strip quotes too, along with
# semicolons/parens/dollar-signs, so a correctly sanitized entry never
# contains those characters anywhere; an unsanitized one does). So check the
# raw stored document for characters that are never legitimate in this file's
# structure (only "{}":,. and alphanumerics ever appear in a clean entry).
assert_not_contains "sanitize: no semicolon reaches disk" "$STORED" ";"
assert_not_contains "sanitize: no dollar-paren reaches disk" "$STORED" '$('
assert_not_contains "sanitize: no closing-paren reaches disk" "$STORED" ")"
assert_not_contains "sanitize: no raw slash (from injected path) reaches disk" "$STORED" "/"

: > "$KNOWN_TEST"; echo '[]' > "$KNOWN_TEST"
sh -c "
. '$NEUTERED'
KNOWN_FILE='$KNOWN_TEST'
add_known_mac 'aa:bb:cc:dd:ee:ff' 'My Phone' '192.168.0.1'
"
STORED=$(cat "$KNOWN_TEST")
assert_contains "name sanitize: spaces preserved (allowed charset)" "$STORED" "My Phone"

# ── Callback data validation (real handle_callback in the telegram bot) ────
# Route through an unknown verb ("noop") so validation runs but no real
# sub-script is dispatched to.

cat > "$MOCKBIN/curl" <<MOCK
#!/bin/sh
echo "\$*" >> "$TMPDIR/curl.log"
cat > /dev/null
echo '{"ok":true}'
MOCK
chmod +x "$MOCKBIN/curl"

# handle_callback dispatches unknown sub-scripts by path when the verb
# matches a real action (block/unblock/etc); "noop"/"limit" never reach that,
# so no stub scripts are needed for these validation-only assertions.
cb_test() {
    : > "$TMPDIR/curl.log"
    PATH="$MOCKBIN:$PATH" sh -c "
    . '$NEUTERED'
    handle_callback 'cbid1' '$1' 'msg1'
    " >/dev/null 2>&1
    cat "$TMPDIR/curl.log"
}

OUT=$(cb_test 'act:noop:192.168.0.1')
assert_not_contains "cb ip: valid" "$OUT" "invalid IP"

OUT=$(cb_test 'act:noop:192.168.0.1;whoami')
assert_contains "cb ip: injection semicolon" "$OUT" "invalid IP"

OUT=$(cb_test 'act:noop:1.1.1.1|cat')
assert_contains "cb ip: injection pipe" "$OUT" "invalid IP"

OUT=$(cb_test 'act:noop:abc.def.ghi.jkl')
assert_contains "cb ip: letters" "$OUT" "invalid IP"

OUT=$(cb_test 'act:limit:192.168.0.1:10000')
assert_not_contains "cb param: valid rate" "$OUT" "invalid param"

OUT=$(cb_test 'act:limit:192.168.0.1:10000;rm')
assert_contains "cb param: injection" "$OUT" "invalid param"

OUT=$(cb_test 'act:limit:192.168.0.1:abc')
assert_contains "cb param: letters" "$OUT" "invalid param"

# ── JSON escaping (real tg_json_escape) ─────────────────────────────────────

ESCAPED=$(sh -c ". '$NEUTERED'; tg_json_escape 'he said \"hi\"'")
assert_not_contains "json escape: no raw quotes" "$ESCAPED" '"hi"'
assert_contains "json escape: quote is escaped" "$ESCAPED" '\"hi\"'

ESCAPED=$(sh -c ". '$NEUTERED'; tg_json_escape 'hello world'")
assert_eq "json escape: normal preserved" "hello world" "$ESCAPED"

# ── No secrets in output ────────────────────────────────────────────────────

assert_not_contains "no hardcoded tokens in scripts" "$(cat "$BIN"/trafficctl-telegram.sh)" "BOT_TOKEN_VALUE"
assert_not_contains "no test credentials" "$(cat "$BIN"/trafficctl-telegram.sh)" "123456:ABC"

# The bot token must reach curl via stdin (a --config file), never argv,
# because argv is world-readable via ps/proc. Verify against the real tg_api.
: > "$TMPDIR/curl.log"
CURL_ARGV_LOG="$TMPDIR/curl_argv.log"
cat > "$MOCKBIN/curl" <<MOCK
#!/bin/sh
echo "\$*" >> "$CURL_ARGV_LOG"
cat >> "$TMPDIR/curl.log"
echo '{"ok":true}'
MOCK
chmod +x "$MOCKBIN/curl"

PATH="$MOCKBIN:$PATH" sh -c "
. '$NEUTERED'
TG_TOKEN='123456:SUPERSECRETTOKEN'
TG_CHAT_ID='999'
tg_send 'hello'
" >/dev/null 2>&1

assert_not_contains "bot token never appears in curl argv" "$(cat "$CURL_ARGV_LOG")" "SUPERSECRETTOKEN"
assert_contains "bot token reaches curl via stdin instead" "$(cat "$TMPDIR/curl.log")" "SUPERSECRETTOKEN"

# ── ucode: one place builds shell command lines ─────────────────────────────
# lib.uc's run()/lines()/sh() are the only callers of popen() and system(),
# and every value in their command goes through q(): tests/lib/uc_cmd_lint.py.
UC_DIR="$BIN/../../share/ucode/trafficctl"
UC_FILES="$UC_DIR/*.uc $BIN/../../sbin/trafficctl $(dirname "$0")/../luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
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
