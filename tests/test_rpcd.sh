#!/bin/bash
# Tests for the rpcd/ubus backend (luci.trafficctl) — previously had NO test
# coverage beyond `sh -n` syntax checking, despite being the entire
# authenticated write surface (31 methods) reachable from LuCI/ubus.
#
# Drives the real script the way rpcd actually does: `luci.trafficctl call
# <method>` with the JSON argument object on stdin, and `list` with none.
# Fakes every sub-script it dispatches to (each of those has its own
# dedicated test file elsewhere) plus uci/jsonfilter/ubus, and asserts on
# both the JSON emitted and the exact arguments forwarded to the sub-scripts
# and to uci.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/local/bin"
ROOT="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root"

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

RPCD="$TMPDIR/rpcd.sh"
sed -e "s|/usr/local/bin/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" \
    -e "s|^SCRIPTS=\"/usr/local/bin\"|SCRIPTS=\"$MOCKBIN\"|" \
    "$ROOT/usr/libexec/rpcd/luci.trafficctl" > "$RPCD"

# ── mocks: uci, jsonfilter, ubus, plus every sub-script the backend calls ──

UCI_LOG="$TMPDIR/uci.log"
cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
echo "\$*" >> "$UCI_LOG"
case "\$*" in
    -q\ get\ trafficctl.main.enabled) echo "1" ;;
    -q\ get\ trafficctl.main.default_mode) echo "limiter" ;;
    -q\ get\ firewall.@defaults\[0\].flow_offloading) echo "1" ;;
    -q\ get\ firewall.@defaults\[0\].flow_offloading_hw) echo "0" ;;
    -q\ get\ trafficctl.telegram) exit 0 ;;
    -q\ get\ trafficctl.telegram.bot_token) echo "" ;;
    -q\ get\ trafficctl.logging.log_file) echo "/tmp/trafficctl/activity.log" ;;
    -q\ get\ trafficctl.logging.max_lines) echo "500" ;;
    commit\ *) exit 0 ;;
    set\ *) exit 0 ;;
    delete\ *) exit 0 ;;
    *) exit 1 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/uci"

# jsonfilter mock: given "-e '@.field'" against JSON on stdin, extract the
# value for that top-level field.
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
expr="$2"
key=$(printf '%s' "$expr" | sed "s/.*\.//;s/\[.*//")
input=$(cat)
val=$(printf '%s' "$input" | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p")
if [ -n "$val" ]; then printf '%s' "$val"; exit 0; fi
val=$(printf '%s' "$input" | sed -n "s/.*\"$key\":\([A-Za-z0-9_.-]*\).*/\1/p")
if [ -n "$val" ]; then printf '%s' "$val"; exit 0; fi
exit 1
MOCK
chmod +x "$MOCKBIN/jsonfilter"

cat > "$MOCKBIN/ubus" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/ubus"

# Every downstream script the backend shells out to: log its args and echo a
# recognisable stub reply so we can tell "the backend parsed input and
# dispatched" from "the sub-script actually did the work" (the latter is
# covered by that script's own dedicated test file).
DISPATCH_LOG="$TMPDIR/dispatch.log"
for sub in trafficctl-summary.sh trafficctl-device.sh trafficctl-bytes.sh \
           trafficctl-ifaces.sh trafficctl-block.sh trafficctl-unblock.sh \
           trafficctl-macfilter-add.sh trafficctl-macfilter-remove.sh \
           trafficctl-ratelimit.sh trafficctl-ratelimit-stats.sh \
           trafficctl-shape.sh trafficctl-shape-stats.sh \
           trafficctl-rdns.sh trafficctl-netify.sh trafficctl-names.sh \
           trafficctl-portfw.sh trafficctl-telegram-test.sh; do
    cat > "$MOCKBIN/$sub" <<MOCK
#!/bin/sh
echo "$sub \$*" >> "$DISPATCH_LOG"
echo '{"ok":true,"msg":"stub-$sub"}'
MOCK
    chmod +x "$MOCKBIN/$sub"
done

run_list() {
    PATH="$MOCKBIN:$PATH" sh "$RPCD" list 2>&1
}

run_call() {
    local method="$1" json="${2:-{}}"
    printf '%s' "$json" | PATH="$MOCKBIN:$PATH" sh "$RPCD" call "$method" 2>&1
}

# ════════════════════════════════════════════════════════════════════════════
# `list` enumerates all 31 methods with their expected argument schema
# ════════════════════════════════════════════════════════════════════════════

LIST_OUT=$(run_list)
for m in summary device bytes block unblock macfilter_add macfilter_remove \
         ratelimit ratelimit_stats shape_add shape_remove shape_status shape_stats \
         rdns netify_status netify_list netify_collect names_list name_set name_clear \
         portfw_list portfw_ctl config_get config_set telegram_config_get \
         ifaces \
         telegram_config_set telegram_test logging_config_get logging_config_set \
         activity_log version; do
    assert_contains "list: declares method $m" "\"$m\"" "$LIST_OUT"
done
assert_eq "list: is valid JSON (parses with python-free brace balance check)" \
    "0" "$(printf '%s' "$LIST_OUT" | tr -cd '{}' | awk '{o=gsub(/\{/,"");c=gsub(/\}/,"")} END{print (o==c)?0:1}')"

# ════════════════════════════════════════════════════════════════════════════
# Read-only formatting methods
# ════════════════════════════════════════════════════════════════════════════

OUT=$(run_call summary)
assert_contains "summary: wraps sub-script output under result" '{"result":' "$OUT"
assert_contains "summary: dispatches to trafficctl-summary.sh" '"ok":true,"msg":"stub-trafficctl-summary.sh"' "$OUT"

OUT=$(run_call ifaces)
assert_contains "ifaces: wraps sub-script output under result" '{"result":' "$OUT"
assert_contains "ifaces: dispatches to trafficctl-ifaces.sh" '"ok":true,"msg":"stub-trafficctl-ifaces.sh"' "$OUT"

OUT=$(run_call device '{"ip":"192.168.1.5"}')
assert_contains "device: forwards ip to trafficctl-device.sh" "trafficctl-device.sh 192.168.1.5" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call device '{}')
assert_contains "device: missing ip rejected without dispatching" '"ok":false' "$OUT"
assert_not_contains "device: missing ip — no dispatch happened" "trafficctl-device.sh" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call device '{"ip":"192.168.1.5","proto":"tcp"}')
assert_contains "device: proto tcp forwarded as --proto flag" "trafficctl-device.sh 192.168.1.5 --proto tcp" "$(cat "$DISPATCH_LOG")"

OUT=$(run_call version)
assert_contains "version: emits a version field" '"version":' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# Mutating methods — ip required, forwarded correctly, label sanitized
# ════════════════════════════════════════════════════════════════════════════

: > "$DISPATCH_LOG"
OUT=$(run_call block '{"ip":"192.168.1.9","label":"my label"}')
assert_contains "block: dispatches with ip" "trafficctl-block.sh 192.168.1.9" "$(cat "$DISPATCH_LOG")"
# sanitize_label strips everything but alnum/_.- , so a space-containing label
# must arrive at the sub-script WITHOUT the space.
assert_not_contains "block: label sanitized before reaching the sub-script (no space)" \
    "my label" "$(cat "$DISPATCH_LOG")"

OUT=$(run_call block '{}')
assert_contains "block: missing ip rejected" '"ok":false' "$OUT"

: > "$DISPATCH_LOG"
LABEL_INJECT='x"; rm -rf /'
OUT=$(run_call block "{\"ip\":\"192.168.1.9\",\"label\":\"$(printf '%s' "$LABEL_INJECT" | sed 's/"/\\"/g')\"}")
DISPATCHED=$(cat "$DISPATCH_LOG")
assert_not_contains "block: injected label metacharacters stripped before dispatch" ";" "$DISPATCHED"
assert_not_contains "block: injected label quote stripped before dispatch" '"' "$DISPATCHED"

: > "$DISPATCH_LOG"
OUT=$(run_call unblock '{"ip":"192.168.1.9"}')
assert_contains "unblock: dispatches with ip" "trafficctl-unblock.sh 192.168.1.9" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call macfilter_add '{"ip":"192.168.1.9"}')
assert_contains "macfilter_add: dispatches with ip" "trafficctl-macfilter-add.sh 192.168.1.9" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call macfilter_remove '{"ip":"192.168.1.9"}')
assert_contains "macfilter_remove: dispatches with ip" "trafficctl-macfilter-remove.sh 192.168.1.9" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call ratelimit '{"ip":"192.168.1.9","rate_kbit":5000,"mode":"each"}')
assert_contains "ratelimit: forwards ip, rate, mode" "trafficctl-ratelimit.sh 192.168.1.9 5000  each" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call ratelimit '{"ip":"192.168.1.9","rate_kbit":5000,"mode":"bogus"}')
assert_contains "ratelimit: an invalid mode is dropped, not passed through raw" \
    "trafficctl-ratelimit.sh 192.168.1.9 5000  " "$(cat "$DISPATCH_LOG")"
assert_not_contains "ratelimit: bogus mode string never reaches the sub-script" "bogus" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call shape_add '{"ip":"192.168.1.9","rate_kbit":5000}')
assert_contains "shape_add: dispatches add with ip and rate" "trafficctl-shape.sh add 192.168.1.9 5000" "$(cat "$DISPATCH_LOG")"

OUT=$(run_call shape_add '{"ip":"192.168.1.9"}')
assert_contains "shape_add: missing rate_kbit rejected" '"ok":false' "$OUT"

: > "$DISPATCH_LOG"
OUT=$(run_call shape_remove '{"ip":"192.168.1.9"}')
assert_contains "shape_remove: dispatches remove with ip" "trafficctl-shape.sh remove 192.168.1.9" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call shape_status '{"ip":"192.168.1.9"}')
assert_contains "shape_status: dispatches status with ip" "trafficctl-shape.sh status 192.168.1.9" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call name_set '{"ip":"192.168.1.9","name":"MyPhone"}')
assert_contains "name_set: dispatches set with ip and name" "trafficctl-names.sh set 192.168.1.9 MyPhone" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call name_set '{"ip":"192.168.1.9"}')
assert_contains "name_set: empty name means remove (clears the alias)" \
    "trafficctl-names.sh remove 192.168.1.9" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call name_clear '{"ip":"192.168.1.9"}')
assert_contains "name_clear: dispatches remove with ip" "trafficctl-names.sh remove 192.168.1.9" "$(cat "$DISPATCH_LOG")"

# ════════════════════════════════════════════════════════════════════════════
# portfw_ctl — action must be pause/resume/limit
# ════════════════════════════════════════════════════════════════════════════

: > "$DISPATCH_LOG"
OUT=$(run_call portfw_ctl '{"action":"pause","scope":"forward","proto":"tcp","ip":"192.168.1.9","port":"8080"}')
assert_contains "portfw_ctl pause: dispatches with scope/proto/ip/port" \
    "trafficctl-portfw.sh pause forward tcp 192.168.1.9 8080" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call portfw_ctl '{"action":"limit","scope":"forward","proto":"tcp","ip":"192.168.1.9","port":"8080","rate_kbit":5000}')
assert_contains "portfw_ctl limit: dispatches with rate" \
    "trafficctl-portfw.sh limit forward tcp 192.168.1.9 8080 5000" "$(cat "$DISPATCH_LOG")"

OUT=$(run_call portfw_ctl '{"action":"delete"}')
assert_contains "portfw_ctl: invalid action rejected" '"ok":false' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# config_get / config_set
# ════════════════════════════════════════════════════════════════════════════

OUT=$(run_call config_get)
assert_contains "config_get: reflects enabled=true" '"enabled":true' "$OUT"
assert_contains "config_get: reflects default_mode" '"default_mode":"limiter"' "$OUT"

: > "$UCI_LOG"
OUT=$(run_call config_set '{"enabled":false,"default_mode":"shaper"}')
assert_contains "config_set: reports ok" '"ok":true' "$OUT"
assert_contains "config_set: writes enabled=0" "trafficctl.main.enabled=0" "$(cat "$UCI_LOG")"
assert_contains "config_set: writes default_mode" "trafficctl.main.default_mode=shaper" "$(cat "$UCI_LOG")"

# ════════════════════════════════════════════════════════════════════════════
# telegram_config_get / set — bot_token must never leak in cleartext
# ════════════════════════════════════════════════════════════════════════════

cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
echo "\$*" >> "$UCI_LOG"
case "\$*" in
    -q\ get\ trafficctl.telegram) exit 0 ;;
    -q\ get\ trafficctl.telegram.bot_token) echo "999999:REALSECRETTOKEN" ;;
    -q\ get\ trafficctl.telegram.enabled) echo "1" ;;
    -q\ get\ trafficctl.telegram.chat_id) echo "12345" ;;
    *) exit 1 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/uci"

OUT=$(run_call telegram_config_get)
assert_contains "telegram_config_get: bot_token_set is true when a token exists" \
    '"bot_token_set":true' "$OUT"
assert_not_contains "telegram_config_get: the real token never appears in the response" \
    "REALSECRETTOKEN" "$OUT"
assert_contains "telegram_config_get: token displayed as a mask" '"bot_token":"***"' "$OUT"

cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
echo "\$*" >> "$UCI_LOG"
case "\$*" in
    -q\ get\ trafficctl.telegram) exit 1 ;;
    *) exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/uci"
: > "$UCI_LOG"
OUT=$(run_call telegram_config_set '{"bot_token":"999999:NEWTOKEN","chat_id":"54321"}')
assert_contains "telegram_config_set: reports ok" '"ok":true' "$OUT"
assert_contains "telegram_config_set: writes the new token" "trafficctl.telegram.bot_token=999999:NEWTOKEN" "$(cat "$UCI_LOG")"

: > "$UCI_LOG"
OUT=$(run_call telegram_config_set '{"bot_token":"***","chat_id":"54321"}')
assert_not_contains "telegram_config_set: the masked placeholder is never written back as the token" \
    "trafficctl.telegram.bot_token=***" "$(cat "$UCI_LOG")"

# ════════════════════════════════════════════════════════════════════════════
# logging_config_set — see test_regressions.sh for the log_file/max_lines
# validation itself; here we check the plumbing (dispatch + persist_rules).
# ════════════════════════════════════════════════════════════════════════════

cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
echo "\$*" >> "$UCI_LOG"
case "\$*" in
    -q\ get\ trafficctl.logging) exit 0 ;;
    *) exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/uci"
: > "$UCI_LOG"
OUT=$(run_call logging_config_set '{"enabled":true,"persist_rules":true}')
assert_contains "logging_config_set: reports ok" '"ok":true' "$OUT"
assert_contains "logging_config_set: writes persist_rules" "trafficctl.main.persist_rules=1" "$(cat "$UCI_LOG")"

# ════════════════════════════════════════════════════════════════════════════
# activity_log — lines param clamped to [0,1000]; see test_regressions.sh for
# the ACL side of this method.
# ════════════════════════════════════════════════════════════════════════════

# tctl_validate_log_file hard-requires the literal prefix /tmp/trafficctl/ or
# /var/log/ (see test_regressions.sh #1) — a path relocated under $TMPDIR
# would fail that check and silently fall back to the default, so this one
# case writes to the real /tmp/trafficctl/ (harmless in CI/sandbox — same
# directory the production default log lives under) and cleans up after.
REAL_LOG_DIR="/tmp/trafficctl"
LOG_FILE_STUB="$REAL_LOG_DIR/test_rpcd_activity.log.$$"
mkdir -p "$REAL_LOG_DIR"
for i in $(seq 1 5); do echo "line $i"; done > "$LOG_FILE_STUB"
trap 'rm -rf "$TMPDIR" "$LOG_FILE_STUB"' EXIT
cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
case "\$*" in
    -q\ get\ trafficctl.logging.log_file) echo "$LOG_FILE_STUB" ;;
    *) exit 1 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/uci"
run_call_logtest() {
    local method="$1" json="${2:-{}}"
    printf '%s' "$json" | PATH="$MOCKBIN:$PATH" sh "$RPCD" call "$method" 2>&1
}

OUT=$(run_call_logtest activity_log '{"lines":2}')
assert_contains "activity_log: returns the tail of the log" '"line 5"' "$OUT"
assert_not_contains "activity_log: respects the lines cap (line 1 excluded when lines=2)" '"line 1"' "$OUT"

OUT=$(run_call_logtest activity_log '{"lines":99999}')
assert_contains "activity_log: absurd lines value still returns valid output (clamped)" '"ok":true' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# Unknown method
# ════════════════════════════════════════════════════════════════════════════

OUT=$(run_call totally_bogus_method)
assert_contains "unknown method: returns an error, not a crash" '"error"' "$OUT"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
