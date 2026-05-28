#!/bin/bash
# Security tests: validate input sanitization and injection resistance.

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

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

# ── IP validation (from trafficctl-fw.sh) ──────────────────────────────────

uci() { echo ""; }
nft() { return 1; }
command() { return 1; }
export -f uci nft command

. "$(dirname "$0")/../luci-app-trafficctl/root/usr/local/bin/trafficctl-fw.sh"

# Command injection attempts via IP
assert_eq "injection: semicolon" 1 "$(tctl_validate_ip '192.168.1.1; rm -rf /' && echo 0 || echo 1)"
assert_eq "injection: pipe" 1 "$(tctl_validate_ip '192.168.1.1|cat /etc/passwd' && echo 0 || echo 1)"
assert_eq "injection: backtick" 1 "$(tctl_validate_ip '$(whoami).168.1.1' && echo 0 || echo 1)"
assert_eq "injection: newline" 1 "$(tctl_validate_ip "192.168.1.1
rm -rf /" && echo 0 || echo 1)"
assert_eq "injection: ampersand" 1 "$(tctl_validate_ip '192.168.1.1&& cat /etc/shadow' && echo 0 || echo 1)"
assert_eq "injection: redirect" 1 "$(tctl_validate_ip '192.168.1.1>/tmp/hacked' && echo 0 || echo 1)"
assert_eq "injection: null byte" 1 "$(printf '192.168.1.1\x00rm' | xargs -0 -I{} sh -c 'echo "{}" | grep -qE "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"' && echo 0 || echo 1)"

# ── MAC sanitization (from telegram bot) ───────────────────────────────────

sanitize_mac() { printf '%s' "$1" | tr -cd 'a-fA-F0-9:'; }
sanitize_name() { printf '%s' "$1" | tr -cd 'a-zA-Z0-9 _.-'; }

assert_eq "mac sanitize: normal" "aa:bb:cc:dd:ee:ff" "$(sanitize_mac 'aa:bb:cc:dd:ee:ff')"
# Sanitize keeps hex + colon only — dangerous chars are stripped
INJECTED_MAC=$(sanitize_mac 'aa:bb:cc:dd:ee:ff"; rm -rf /')
assert_not_contains "mac sanitize: no semicolons" "$INJECTED_MAC" ";"
assert_not_contains "mac sanitize: no quotes" "$INJECTED_MAC" '"'
assert_not_contains "mac sanitize: no slash" "$INJECTED_MAC" "/"

assert_eq "name sanitize: normal" "MyPhone" "$(sanitize_name 'MyPhone')"
assert_eq "name sanitize: with spaces" "My Phone" "$(sanitize_name 'My Phone')"
# Sanitize strips everything that's not [a-zA-Z0-9 _.-]
INJECTED_NAME=$(sanitize_name 'evil"};$(rm -rf /);{"')
assert_not_contains "name sanitize: no quotes" "$INJECTED_NAME" '"'
assert_not_contains "name sanitize: no dollar" "$INJECTED_NAME" '$'
assert_not_contains "name sanitize: no parens" "$INJECTED_NAME" '('
assert_not_contains "name sanitize: no semicolons" "$INJECTED_NAME" ';'
assert_not_contains "name sanitize: no braces" "$INJECTED_NAME" '{'

# ── Callback data validation ───────────────────────────────────────────────

validate_cb_ip() {
    echo "$1" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' && echo 0 || echo 1
}

validate_cb_param() {
    case "$1" in *[!0-9]*) echo 1 ;; *) echo 0 ;; esac
}

assert_eq "cb ip: valid" "0" "$(validate_cb_ip '192.168.0.1')"
assert_eq "cb ip: injection semicolon" "1" "$(validate_cb_ip '192.168.0.1;whoami')"
assert_eq "cb ip: injection pipe" "1" "$(validate_cb_ip '1.1.1.1|cat')"
assert_eq "cb ip: letters" "1" "$(validate_cb_ip 'abc.def.ghi.jkl')"

assert_eq "cb param: valid rate" "0" "$(validate_cb_param '10000')"
assert_eq "cb param: injection" "1" "$(validate_cb_param '10000;rm')"
assert_eq "cb param: letters" "1" "$(validate_cb_param 'abc')"
assert_eq "cb param: empty is valid" "0" "$(validate_cb_param '')"

# ── JSON escaping ──────────────────────────────────────────────────────────

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }

ESCAPED=$(json_escape 'he said "hi"')
assert_not_contains "json escape: no raw quotes" "$ESCAPED" '"hi"'
assert_eq "json escape: normal preserved" "hello world" "$(json_escape 'hello world')"

# ── No secrets in output ───────────────────────────────────────────────────

SCRIPTS_DIR="$(dirname "$0")/../luci-app-trafficctl/root/usr/local/bin"
assert_not_contains "no hardcoded tokens in scripts" "$(cat "$SCRIPTS_DIR"/trafficctl-telegram.sh)" "BOT_TOKEN_VALUE"
assert_not_contains "no test credentials" "$(cat "$SCRIPTS_DIR"/trafficctl-telegram.sh)" "123456:ABC"

# ── Results ────────────────────────────────────────────────────────────────

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
