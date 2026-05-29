#!/bin/bash
# Level 2.5: End-to-end bot logic tests.
# Runs the REAL telegram bot script with mocked externals (curl, backend scripts,
# uci, jsonfilter, iw, ip) and verifies the bot processes commands and callbacks
# correctly by inspecting the API calls it makes.
set -e

PASS=0
FAIL=0
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOT_SCRIPT="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin/trafficctl-telegram.sh"

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to contain: '%s'\n  in: '%.300s'\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! echo "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n  in: '%.300s'\n" "$desc" "$needle" "$haystack"
    fi
}

assert_file_contains() {
    local desc="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected '%s' in %s\n" "$desc" "$needle" "$file"
    fi
}

# ── Setup mock environment ─────────────────────────────────────────────────────

setup_env() {
    local testname="$1"
    MOCKDIR=$(mktemp -d)
    MOCKBIN="$MOCKDIR/bin"
    MOCKDATA="$MOCKDIR/data"
    mkdir -p "$MOCKBIN" "$MOCKDATA" "$MOCKDIR/tmp" "$MOCKDIR/etc/trafficctl" \
             "$MOCKDIR/etc/config" "$MOCKDIR/proc" "$MOCKDIR/lib/functions" \
             "$MOCKDIR/etc/init.d" "$MOCKDIR/sys/class/net"

    # State files — realistic values as from a Keenetic/OpenWrt home router
    echo '[]' > "$MOCKDIR/etc/trafficctl/telegram_known.json"
    echo "" > "$MOCKDIR/tmp/dhcp.leases"
    # Uptime: 2 days, 5 hours, 17 minutes (= 192220 sec)
    echo "192220.45 384440.90" > "$MOCKDIR/proc/uptime"
    echo "0.12 0.08 0.03 2/87 4521" > "$MOCKDIR/proc/loadavg"
    : > "$MOCKDIR/proc/nf_conntrack"

    # API call log (what the bot sends to Telegram)
    API_LOG="$MOCKDIR/api_calls.log"
    : > "$API_LOG"

    # Action log (which backend scripts the bot invokes)
    ACTION_LOG="$MOCKDIR/actions.log"
    : > "$ACTION_LOG"

    # network.sh stub — WAN IP replaced with RFC 5737 documentation range
    cat > "$MOCKDIR/lib/functions/network.sh" <<'MOCK'
network_get_ipaddr() { eval "$1='198.51.100.42'"; }
MOCK

    # uci mock — realistic chat_id and token format (test values, not real)
    cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$*" in
    *"trafficctl.telegram.enabled"*) echo 1 ;;
    *"trafficctl.telegram.bot_token"*) echo "7412345678:AAF_test-token_for_e2e_tests_only" ;;
    *"trafficctl.telegram.chat_id"*) echo "285437102" ;;
    *"trafficctl.telegram.poll_interval"*) echo 5 ;;
    *"trafficctl.telegram.notify_new_device"*) echo 1 ;;
    *"trafficctl.telegram.notify_known_device"*) echo 0 ;;
    *"trafficctl.telegram.control_enabled"*) echo 1 ;;
    *"trafficctl.telegram.notify_template"*) echo "" ;;
    *"trafficctl.telegram.btn_block_inet"*) echo 1 ;;
    *"trafficctl.telegram.btn_block_wifi"*) echo 1 ;;
    *"trafficctl.telegram.btn_limiter"*) echo 1 ;;
    *"trafficctl.telegram.btn_shaper"*) echo 1 ;;
    *"system.@system"*"hostname"*) echo "OpenWrt" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/uci"

    # logger mock (no-op)
    cat > "$MOCKBIN/logger" <<'MOCK'
#!/bin/sh
:
MOCK
    chmod +x "$MOCKBIN/logger"

    # ip mock (empty arp by default)
    cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
echo ""
MOCK
    chmod +x "$MOCKBIN/ip"

    # iw mock (no wifi by default)
    cat > "$MOCKBIN/iw" <<'MOCK'
#!/bin/sh
exit 1
MOCK
    chmod +x "$MOCKBIN/iw"

    # date mock
    cat > "$MOCKBIN/date" <<'MOCK'
#!/bin/sh
case "$*" in
    *%s*) echo "1716811200" ;;
    *%Y-%m-%d*%H:%M*) echo "2026-05-27 14:30" ;;
    *%Y-%m-%d*) echo "2026-05-27" ;;
    *%H:%M*) echo "14:30" ;;
    *) /bin/date "$@" ;;
esac
MOCK
    chmod +x "$MOCKBIN/date"

    # wc — use real wc
    ln -sf /usr/bin/wc "$MOCKBIN/wc" 2>/dev/null || cat > "$MOCKBIN/wc" <<'MOCK'
#!/bin/sh
/usr/bin/wc "$@"
MOCK
    chmod +x "$MOCKBIN/wc" 2>/dev/null || true

    # Backend script mocks (block, unblock, ratelimit, shape, macfilter)
    for script in trafficctl-block.sh trafficctl-unblock.sh trafficctl-ratelimit.sh \
                  trafficctl-shape.sh trafficctl-macfilter-add.sh trafficctl-macfilter-remove.sh; do
        cat > "$MOCKBIN/$script" <<MOCK
#!/bin/sh
echo "\$0 \$*" >> "$ACTION_LOG"
echo '{"ok":true,"msg":"done"}'
MOCK
        chmod +x "$MOCKBIN/$script"
    done

    # Summary script mock — realistic device list (MACs anonymized with locally-administered bit)
    cat > "$MOCKBIN/trafficctl-summary.sh" <<'MOCK'
#!/bin/sh
cat <<'JSON'
[{"ip":"192.168.1.45","name":"iPhone-Denis","mac":"a2:b4:c6:d8:e0:12","conns":23,"blocked":false,"wifi_blocked":false,"rate_limit_kbit":0,"shape_kbit":0,"conn_type":"wifi-5G"},{"ip":"192.168.1.67","name":"Galaxy-A54","mac":"b6:78:9a:bc:de:f0","conns":8,"blocked":false,"wifi_blocked":false,"rate_limit_kbit":0,"shape_kbit":0,"conn_type":"wifi-2.4G"},{"ip":"192.168.1.120","name":"MacBook-Pro","mac":"c2:d4:e6:f8:01:23","conns":47,"blocked":true,"wifi_blocked":false,"rate_limit_kbit":0,"shape_kbit":0,"conn_type":"ethernet"},{"ip":"192.168.1.15","name":"Xiaomi-Vacuum","mac":"d4:e6:f8:0a:1b:2c","conns":2,"blocked":false,"wifi_blocked":false,"rate_limit_kbit":5000,"shape_kbit":0,"conn_type":"wifi-2.4G"}]
JSON
MOCK
    chmod +x "$MOCKBIN/trafficctl-summary.sh"

    # jsonfilter mock — Python-based, supports nested dot-notation like OpenWrt jsonfilter
    cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/bash
input=$(cat)
expr=""
count_mode=0
while [ $# -gt 0 ]; do
    case "$1" in
        -e) shift; expr="$1" ;;
        -l) count_mode=1 ;;
    esac
    shift
done
echo "$input" | python3 -c "
import json,sys,re

data=json.load(sys.stdin)
expr='''$expr'''
count_mode=$count_mode

def resolve_path(obj, path):
    '''Resolve dot-separated path like callback_query.message.chat.id'''
    parts = path.split('.')
    cur = obj
    for p in parts:
        if isinstance(cur, dict):
            cur = cur.get(p)
        else:
            return None
        if cur is None:
            return None
    return cur

def fmt(val):
    if val is None:
        return ''
    if isinstance(val, bool):
        return str(val).lower()
    if isinstance(val, (dict, list)):
        return json.dumps(val)
    return str(val)

if count_mode:
    # -l: count array length
    if isinstance(data, list):
        print(len(data))
    elif isinstance(data, dict):
        # @.result or similar
        path = expr.lstrip('@').lstrip('.')
        if path:
            arr = resolve_path(data, path)
            print(len(arr) if isinstance(arr, list) else 0)
        elif 'result' in data and isinstance(data['result'], list):
            print(len(data['result']))
        else:
            print(0)
    else:
        print(0)
elif expr:
    # @.field.subfield -> nested access
    if expr.startswith('@.') and '[' not in expr:
        path = expr[2:]
        val = resolve_path(data, path)
        print(fmt(val))
    # @[*].field -> list all values
    elif '[*].' in expr:
        field = expr.split('[*].')[-1]
        arr = data if isinstance(data, list) else data.get('result', [])
        if isinstance(arr, list):
            for item in arr:
                if isinstance(item, dict):
                    val = resolve_path(item, field)
                    if val is not None:
                        print(fmt(val))
    # @[@.key='val'].field
    elif '[@.' in expr:
        m = re.match(r\"@\[@\.(\w+)='([^']+)'\]\.(.+)\", expr)
        if m:
            key, val, field = m.groups()
            arr = data if isinstance(data, list) else data.get('result', [])
            for item in arr:
                if isinstance(item, dict) and str(item.get(key, '')) == val:
                    print(fmt(resolve_path(item, field)))
                    break
    # @.result[N] or @[N]
    elif re.search(r'\[\d+\]', expr):
        m = re.match(r'@(?:\.(\w+))?\[(\d+)\](\.(.+))?', expr)
        if m:
            container = m.group(1)
            idx = int(m.group(2))
            subpath = m.group(4)
            if container:
                arr = data.get(container, [])
            else:
                arr = data if isinstance(data, list) else []
            if idx < len(arr):
                if subpath:
                    print(fmt(resolve_path(arr[idx], subpath)))
                else:
                    print(json.dumps(arr[idx]))
    else:
        print('')
" 2>/dev/null || echo ""
MOCK
    chmod +x "$MOCKBIN/jsonfilter"
}

# ── Mock curl that serves scripted responses ───────────────────────────────────

setup_curl_responses() {
    local responses_file="$MOCKDIR/curl_responses.txt"
    CURL_CALL_NUM="$MOCKDIR/curl_call_num"
    echo "0" > "$CURL_CALL_NUM"

    # Write responses (one JSON per line, served in order)
    cat > "$responses_file" <<'RESPONSES'
RESPONSES

    # curl mock
    cat > "$MOCKBIN/curl" <<MOCK
#!/bin/bash
# Log the call
NUM=\$(cat "$CURL_CALL_NUM")
NUM=\$((NUM + 1))
echo "\$NUM" > "$CURL_CALL_NUM"

# Extract method from URL (compatible with macOS and Linux grep)
METHOD=\$(echo "\$@" | sed -n 's|.*bot[^/]*/\([^" ]*\).*|\1|p')
# Extract -d body
BODY=""
CAPTURE=0
for arg in "\$@"; do
    if [ "\$CAPTURE" = "1" ]; then
        BODY="\$arg"
        break
    fi
    [ "\$arg" = "-d" ] && CAPTURE=1
done

echo "CALL#\$NUM \$METHOD \$BODY" >> "$API_LOG"

# Respond based on method
case "\$METHOD" in
    getUpdates)
        cat "$MOCKDIR/getUpdates_response.json"
        ;;
    sendMessage|editMessageText|answerCallbackQuery|deleteMessage)
        echo '{"ok":true,"result":{"message_id":100}}'
        ;;
    *)
        echo '{"ok":true,"result":{}}'
        ;;
esac
MOCK
    chmod +x "$MOCKBIN/curl"
}

# ── Helper: run bot for one iteration ──────────────────────────────────────────

run_bot_once() {
    local modified="$MOCKDIR/bot_once.sh"

    # Patch the bot: replace while-true with single iteration, redirect paths
    sed \
        -e 's|while true; do|for __iter in 1; do|' \
        -e 's|sleep 5; continue|break|g' \
        -e 's|sleep "$TG_POLL"|:|g' \
        -e 's|sleep 0.1|:|g' \
        -e 's|SCRIPTS="/usr/local/bin"|SCRIPTS="'"$MOCKBIN"'"|' \
        -e 's|KNOWN_FILE="/etc/trafficctl/telegram_known.json"|KNOWN_FILE="'"$MOCKDIR"'/etc/trafficctl/telegram_known.json"|' \
        -e 's|OFFSET_FILE="/tmp/trafficctl_tg_offset"|OFFSET_FILE="'"$MOCKDIR"'/tmp/offset"|' \
        -e 's|CACHE_FILE="/tmp/trafficctl_tg_devices.json"|CACHE_FILE="'"$MOCKDIR"'/tmp/cache.json"|' \
        -e 's|ONLINE_STATE_FILE="/tmp/trafficctl_tg_online"|ONLINE_STATE_FILE="'"$MOCKDIR"'/tmp/online"|' \
        -e 's|DHCP_TRIGGER_FILE="/tmp/trafficctl_tg_newdev"|DHCP_TRIGGER_FILE="'"$MOCKDIR"'/tmp/newdev"|' \
        -e 's|/tmp/dhcp.leases|'"$MOCKDIR"'/tmp/dhcp.leases|g' \
        -e 's|/proc/uptime|'"$MOCKDIR"'/proc/uptime|g' \
        -e 's|/proc/loadavg|'"$MOCKDIR"'/proc/loadavg|g' \
        -e 's|/proc/net/nf_conntrack|'"$MOCKDIR"'/proc/nf_conntrack|g' \
        -e 's|\. /lib/functions/network.sh|. '"$MOCKDIR"'/lib/functions/network.sh|' \
        -e 's|/tmp/trafficctl_tg_seen.tmp|'"$MOCKDIR"'/tmp/seen.tmp|' \
        -e 's|/tmp/trafficctl_tg_cur.tmp|'"$MOCKDIR"'/tmp/cur.tmp|' \
        -e 's|/tmp/.trafficctl_known.lock|'"$MOCKDIR"'/tmp/.lock|g' \
        -e 's|/sys/class/net|'"$MOCKDIR"'/sys/class/net|g' \
        "$BOT_SCRIPT" > "$modified"

    chmod +x "$modified"
    export PATH="$MOCKBIN:$PATH"
    timeout 15 bash "$modified" 2>/dev/null || true
}

cleanup() {
    rm -rf "$MOCKDIR"
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: /devices command sends device list with inline keyboard
# ══════════════════════════════════════════════════════════════════════════════

test_cmd_devices() {
    setup_env "cmd_devices"
    setup_curl_responses

    # Fake getUpdates response: user sends /devices
    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":1,"message":{"message_id":1,"chat":{"id":285437102},"text":"/devices"}}]}
JSON

    run_bot_once

    # Verify: bot sent a sendMessage with inline_keyboard
    assert_file_contains "devices: calls sendMessage" "sendMessage" "$API_LOG"
    assert_file_contains "devices: mentions 'Active devices'" "Active devices" "$API_LOG"
    assert_file_contains "devices: keyboard has iPhone-Denis" "iPhone-Denis" "$API_LOG"
    assert_file_contains "devices: keyboard has act:menu" "act:menu" "$API_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: /status command shows blocked device
# ══════════════════════════════════════════════════════════════════════════════

test_cmd_status() {
    setup_env "cmd_status"
    setup_curl_responses

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":2,"message":{"message_id":2,"chat":{"id":285437102},"text":"/status"}}]}
JSON

    run_bot_once

    assert_file_contains "status: calls sendMessage" "sendMessage" "$API_LOG"
    assert_file_contains "status: shows MacBook-Pro blocked" "MacBook-Pro" "$API_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: /help command
# ══════════════════════════════════════════════════════════════════════════════

test_cmd_help() {
    setup_env "cmd_help"
    setup_curl_responses

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":3,"message":{"message_id":3,"chat":{"id":285437102},"text":"/help"}}]}
JSON

    run_bot_once

    assert_file_contains "help: calls sendMessage" "sendMessage" "$API_LOG"
    assert_file_contains "help: mentions /devices" "/devices" "$API_LOG"
    assert_file_contains "help: mentions /status" "/status" "$API_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: callback block action calls trafficctl-block.sh
# ══════════════════════════════════════════════════════════════════════════════

test_cb_block() {
    setup_env "cb_block"
    setup_curl_responses

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":4,"callback_query":{"id":"cb1","message":{"message_id":10,"chat":{"id":285437102}},"data":"act:block:192.168.1.45"}}]}
JSON

    run_bot_once

    assert_file_contains "block: calls block script" "trafficctl-block.sh" "$ACTION_LOG"
    assert_file_contains "block: passes IP" "192.168.1.45" "$ACTION_LOG"
    assert_file_contains "block: answers callback" "answerCallbackQuery" "$API_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: callback unblock action
# ══════════════════════════════════════════════════════════════════════════════

test_cb_unblock() {
    setup_env "cb_unblock"
    setup_curl_responses

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":5,"callback_query":{"id":"cb2","message":{"message_id":11,"chat":{"id":285437102}},"data":"act:unblock:192.168.1.120"}}]}
JSON

    run_bot_once

    assert_file_contains "unblock: calls unblock script" "trafficctl-unblock.sh" "$ACTION_LOG"
    assert_file_contains "unblock: passes IP" "192.168.1.120" "$ACTION_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: callback rate-limit action with rate param
# ══════════════════════════════════════════════════════════════════════════════

test_cb_limit() {
    setup_env "cb_limit"
    setup_curl_responses

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":6,"callback_query":{"id":"cb3","message":{"message_id":12,"chat":{"id":285437102}},"data":"act:limit:192.168.1.45:5000"}}]}
JSON

    run_bot_once

    assert_file_contains "limit: calls ratelimit script" "trafficctl-ratelimit.sh" "$ACTION_LOG"
    assert_file_contains "limit: passes IP" "192.168.1.45" "$ACTION_LOG"
    assert_file_contains "limit: passes rate 5000" "5000" "$ACTION_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: callback shape action
# ══════════════════════════════════════════════════════════════════════════════

test_cb_shape() {
    setup_env "cb_shape"
    setup_curl_responses

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":7,"callback_query":{"id":"cb4","message":{"message_id":13,"chat":{"id":285437102}},"data":"act:shape:192.168.1.45:10000"}}]}
JSON

    run_bot_once

    assert_file_contains "shape: calls shape script" "trafficctl-shape.sh" "$ACTION_LOG"
    assert_file_contains "shape: passes IP" "192.168.1.45" "$ACTION_LOG"
    assert_file_contains "shape: passes rate 10000" "10000" "$ACTION_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: callback with control_enabled=0 is rejected
# ══════════════════════════════════════════════════════════════════════════════

test_cb_control_disabled() {
    setup_env "cb_control_disabled"
    setup_curl_responses

    # Override uci to return control_enabled=0
    cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$*" in
    *"trafficctl.telegram.enabled"*) echo 1 ;;
    *"trafficctl.telegram.bot_token"*) echo "7412345678:AAF_test-token_for_e2e_tests_only" ;;
    *"trafficctl.telegram.chat_id"*) echo "285437102" ;;
    *"trafficctl.telegram.poll_interval"*) echo 5 ;;
    *"trafficctl.telegram.notify_new_device"*) echo 1 ;;
    *"trafficctl.telegram.notify_known_device"*) echo 0 ;;
    *"trafficctl.telegram.control_enabled"*) echo 0 ;;
    *"trafficctl.telegram.notify_template"*) echo "" ;;
    *"trafficctl.telegram.btn_block_inet"*) echo 1 ;;
    *"trafficctl.telegram.btn_block_wifi"*) echo 1 ;;
    *"trafficctl.telegram.btn_limiter"*) echo 1 ;;
    *"trafficctl.telegram.btn_shaper"*) echo 1 ;;
    *"system.@system"*"hostname"*) echo "OpenWrt" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/uci"

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":8,"callback_query":{"id":"cb5","message":{"message_id":14,"chat":{"id":285437102}},"data":"act:block:192.168.1.45"}}]}
JSON

    run_bot_once

    # Should NOT call block script
    if [ -s "$ACTION_LOG" ]; then
        FAIL=$((FAIL + 1))
        printf "FAIL: control_disabled: action log should be empty but contains: %s\n" "$(cat "$ACTION_LOG")"
    else
        PASS=$((PASS + 1))
    fi
    # Should answer with "Control disabled"
    assert_file_contains "control_disabled: answers callback" "answerCallbackQuery" "$API_LOG"
    assert_file_contains "control_disabled: says disabled" "Control disabled" "$API_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: unauthorized chat_id is ignored
# ══════════════════════════════════════════════════════════════════════════════

test_unauthorized_chat() {
    setup_env "unauthorized"
    setup_curl_responses

    # Message from wrong chat_id (1234567 instead of 285437102)
    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":9,"message":{"message_id":5,"chat":{"id":1234567},"text":"/devices"}}]}
JSON

    run_bot_once

    # Should NOT send any message (only getUpdates call in log)
    if grep -q "sendMessage" "$API_LOG" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        printf "FAIL: unauthorized: bot should not respond to wrong chat_id\n"
    else
        PASS=$((PASS + 1))
    fi

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: invalid IP in callback is rejected
# ══════════════════════════════════════════════════════════════════════════════

test_cb_invalid_ip() {
    setup_env "invalid_ip"
    setup_curl_responses

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":10,"callback_query":{"id":"cb6","message":{"message_id":15,"chat":{"id":285437102}},"data":"act:block:192.168.1;rm -rf /"}}]}
JSON

    run_bot_once

    # Should NOT call any action script
    if [ -s "$ACTION_LOG" ]; then
        FAIL=$((FAIL + 1))
        printf "FAIL: invalid_ip: action log should be empty but contains: %s\n" "$(cat "$ACTION_LOG")"
    else
        PASS=$((PASS + 1))
    fi
    # Should answer with "invalid IP"
    assert_file_contains "invalid_ip: answers callback" "answerCallbackQuery" "$API_LOG"
    assert_file_contains "invalid_ip: says invalid" "invalid" "$API_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: WiFi block callback
# ══════════════════════════════════════════════════════════════════════════════

test_cb_wifi_block() {
    setup_env "cb_wblock"
    setup_curl_responses

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[{"update_id":11,"callback_query":{"id":"cb7","message":{"message_id":16,"chat":{"id":285437102}},"data":"act:wblock:192.168.1.45"}}]}
JSON

    run_bot_once

    assert_file_contains "wblock: calls macfilter-add" "trafficctl-macfilter-add.sh" "$ACTION_LOG"
    assert_file_contains "wblock: passes IP" "192.168.1.45" "$ACTION_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: New device notification (default template)
# ══════════════════════════════════════════════════════════════════════════════

test_new_device_default() {
    setup_env "new_device_default"
    setup_curl_responses

    # Put a MAC in dhcp.leases so discover_macs finds it
    printf '1716811200 e6:f8:0a:1b:2c:3d 192.168.1.88 Pixel-8 01:e6:f8:0a:1b:2c:3d\n' \
        > "$MOCKDIR/tmp/dhcp.leases"

    # ip mock returns the MAC in ARP
    cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    *neigh*) echo "192.168.1.88 dev br-lan lladdr e6:f8:0a:1b:2c:3d REACHABLE" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/ip"

    # Known file has a dummy entry (not empty) so seed_known() is skipped,
    # but does NOT contain our target MAC — so it will be detected as new
    cat > "$MOCKDIR/etc/trafficctl/telegram_known.json" <<'JSON'
[{"mac":"a2:b4:c6:d8:e0:12","name":"iPhone-Denis","ip":"192.168.1.45","first_seen":1716200000}]
JSON

    # No getUpdates results (just device scan)
    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[]}
JSON

    run_bot_once

    assert_file_contains "new_device: sends notification" "sendMessage" "$API_LOG"
    assert_file_contains "new_device: contains 'New device'" "New device" "$API_LOG"
    assert_file_contains "new_device: shows name" "Pixel-8" "$API_LOG"
    assert_file_contains "new_device: shows IP" "192.168.1.88" "$API_LOG"
    assert_file_contains "new_device: shows MAC" "e6:f8:0a:1b:2c:3d" "$API_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: Known device comes back online
# ══════════════════════════════════════════════════════════════════════════════

test_known_device_online() {
    setup_env "known_device_online"
    setup_curl_responses

    # Override uci: enable known device notifications
    cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$*" in
    *"trafficctl.telegram.enabled"*) echo 1 ;;
    *"trafficctl.telegram.bot_token"*) echo "7412345678:AAF_test-token_for_e2e_tests_only" ;;
    *"trafficctl.telegram.chat_id"*) echo "285437102" ;;
    *"trafficctl.telegram.poll_interval"*) echo 5 ;;
    *"trafficctl.telegram.notify_new_device"*) echo 1 ;;
    *"trafficctl.telegram.notify_known_device"*) echo 1 ;;
    *"trafficctl.telegram.control_enabled"*) echo 1 ;;
    *"trafficctl.telegram.notify_template"*) echo "" ;;
    *"trafficctl.telegram.btn_block_inet"*) echo 1 ;;
    *"trafficctl.telegram.btn_block_wifi"*) echo 1 ;;
    *"trafficctl.telegram.btn_limiter"*) echo 1 ;;
    *"trafficctl.telegram.btn_shaper"*) echo 1 ;;
    *"system.@system"*"hostname"*) echo "OpenWrt" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/uci"

    # Device is in known list (not new)
    cat > "$MOCKDIR/etc/trafficctl/telegram_known.json" <<'JSON'
[{"mac":"e6:f8:0a:1b:2c:3d","name":"Pixel-8","ip":"192.168.1.88","first_seen":"2026-05-01"}]
JSON

    # Device is in ARP + DHCP (currently online)
    printf '1716811200 e6:f8:0a:1b:2c:3d 192.168.1.88 Pixel-8 01:e6:f8:0a:1b:2c:3d\n' \
        > "$MOCKDIR/tmp/dhcp.leases"
    cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    *neigh*) echo "192.168.1.88 dev br-lan lladdr e6:f8:0a:1b:2c:3d REACHABLE" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/ip"

    # Online state file exists but does NOT contain this MAC (= device was offline)
    echo "a2:b4:c6:d8:e0:12" > "$MOCKDIR/tmp/online"

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[]}
JSON

    run_bot_once

    assert_file_contains "known_online: sends notification" "sendMessage" "$API_LOG"
    assert_file_contains "known_online: contains 'Device online'" "Device online" "$API_LOG"
    assert_file_contains "known_online: shows name" "Pixel-8" "$API_LOG"
    assert_file_contains "known_online: shows IP" "192.168.1.88" "$API_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: Known device already online — no duplicate notification
# ══════════════════════════════════════════════════════════════════════════════

test_known_device_no_duplicate() {
    setup_env "known_no_dup"
    setup_curl_responses

    # Enable known device notifications
    cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$*" in
    *"trafficctl.telegram.enabled"*) echo 1 ;;
    *"trafficctl.telegram.bot_token"*) echo "7412345678:AAF_test-token_for_e2e_tests_only" ;;
    *"trafficctl.telegram.chat_id"*) echo "285437102" ;;
    *"trafficctl.telegram.poll_interval"*) echo 5 ;;
    *"trafficctl.telegram.notify_new_device"*) echo 1 ;;
    *"trafficctl.telegram.notify_known_device"*) echo 1 ;;
    *"trafficctl.telegram.control_enabled"*) echo 1 ;;
    *"trafficctl.telegram.notify_template"*) echo "" ;;
    *"trafficctl.telegram.btn_block_inet"*) echo 1 ;;
    *"trafficctl.telegram.btn_block_wifi"*) echo 1 ;;
    *"trafficctl.telegram.btn_limiter"*) echo 1 ;;
    *"trafficctl.telegram.btn_shaper"*) echo 1 ;;
    *"system.@system"*"hostname"*) echo "OpenWrt" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/uci"

    cat > "$MOCKDIR/etc/trafficctl/telegram_known.json" <<'JSON'
[{"mac":"e6:f8:0a:1b:2c:3d","name":"Pixel-8","ip":"192.168.1.88","first_seen":"2026-05-01"}]
JSON

    printf '1716811200 e6:f8:0a:1b:2c:3d 192.168.1.88 Pixel-8 01:e6:f8:0a:1b:2c:3d\n' \
        > "$MOCKDIR/tmp/dhcp.leases"
    cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    *neigh*) echo "192.168.1.88 dev br-lan lladdr e6:f8:0a:1b:2c:3d REACHABLE" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/ip"

    # Device is ALREADY in online state file (was online last check)
    echo "e6:f8:0a:1b:2c:3d" > "$MOCKDIR/tmp/online"

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[]}
JSON

    run_bot_once

    # Should NOT send any notification (device was already online)
    if grep -q "sendMessage" "$API_LOG" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        printf "FAIL: known_no_dup: should not notify when device was already online\n"
    else
        PASS=$((PASS + 1))
    fi

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: DHCP trigger file sends new device notification
# ══════════════════════════════════════════════════════════════════════════════

test_dhcp_trigger() {
    setup_env "dhcp_trigger"
    setup_curl_responses

    # DHCP trigger file: tab-separated mac/ip/name (Samsung TV joining WiFi)
    printf '8a:bc:de:f0:12:34\t192.168.1.201\tSamsung-TV\n' > "$MOCKDIR/tmp/newdev"

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[]}
JSON

    run_bot_once

    assert_file_contains "dhcp_trigger: sends notification" "sendMessage" "$API_LOG"
    assert_file_contains "dhcp_trigger: shows name" "Samsung-TV" "$API_LOG"
    assert_file_contains "dhcp_trigger: shows IP" "192.168.1.201" "$API_LOG"
    assert_file_contains "dhcp_trigger: shows MAC" "8a:bc:de:f0:12:34" "$API_LOG"
    assert_file_contains "dhcp_trigger: shows link type dhcp" "dhcp" "$API_LOG"

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: Custom template with all tags substituted
# ══════════════════════════════════════════════════════════════════════════════

test_template_all_tags() {
    setup_env "template_all_tags"
    setup_curl_responses

    # Override uci to return a template using ALL available tags
    cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$*" in
    *"trafficctl.telegram.enabled"*) echo 1 ;;
    *"trafficctl.telegram.bot_token"*) echo "7412345678:AAF_test-token_for_e2e_tests_only" ;;
    *"trafficctl.telegram.chat_id"*) echo "285437102" ;;
    *"trafficctl.telegram.poll_interval"*) echo 5 ;;
    *"trafficctl.telegram.notify_new_device"*) echo 1 ;;
    *"trafficctl.telegram.notify_known_device"*) echo 0 ;;
    *"trafficctl.telegram.control_enabled"*) echo 1 ;;
    *"trafficctl.telegram.notify_template"*) echo '{{name}}|{{ip}}|{{mac}}|{{link}}|{{date}}|{{time}}|{{datetime}}|{{router}}|{{ssid}}|{{signal}}|{{freq}}|{{iface}}|{{clients}}|{{uptime}}|{{wan_ip}}|{{load}}|{{conns}}' ;;
    *"trafficctl.telegram.btn_block_inet"*) echo 1 ;;
    *"trafficctl.telegram.btn_block_wifi"*) echo 1 ;;
    *"trafficctl.telegram.btn_limiter"*) echo 1 ;;
    *"trafficctl.telegram.btn_shaper"*) echo 1 ;;
    *"system.@system"*"hostname"*) echo "OpenWrt" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/uci"

    # Set up conntrack entries for the device (iPad browsing)
    echo "src=192.168.1.92 dst=17.253.144.10" > "$MOCKDIR/proc/nf_conntrack"
    echo "src=192.168.1.92 dst=8.8.8.8" >> "$MOCKDIR/proc/nf_conntrack"
    echo "src=192.168.1.92 dst=142.250.74.46" >> "$MOCKDIR/proc/nf_conntrack"

    # 4 clients in DHCP leases (realistic home network)
    printf '1716811200 f2:04:16:28:3a:4c 192.168.1.92 iPad-Air 01:f2:04:16:28:3a:4c\n' \
        > "$MOCKDIR/tmp/dhcp.leases"
    printf '1716810000 a2:b4:c6:d8:e0:12 192.168.1.45 iPhone-Denis 01:a2:b4:c6:d8:e0:12\n' \
        >> "$MOCKDIR/tmp/dhcp.leases"
    printf '1716809000 b6:78:9a:bc:de:f0 192.168.1.67 Galaxy-A54 01:b6:78:9a:bc:de:f0\n' \
        >> "$MOCKDIR/tmp/dhcp.leases"
    printf '1716800000 d4:e6:f8:0a:1b:2c 192.168.1.15 Xiaomi-Vacuum 01:d4:e6:f8:0a:1b:2c\n' \
        >> "$MOCKDIR/tmp/dhcp.leases"

    # Create mock sysfs for wlan0 (5GHz radio) so get_wifi_info finds it
    mkdir -p "$MOCKDIR/sys/class/net/wlan0/phy80211"

    # iw mock returns wifi info for this MAC (iPad on 5GHz)
    cat > "$MOCKBIN/iw" <<'MOCK'
#!/bin/sh
case "$*" in
    *station*get*f2:04:16:28:3a:4c*)
        printf 'Station f2:04:16:28:3a:4c (on wlan0)\n\tsignal: -42 dBm\n'
    ;;
    *station*get*) exit 1 ;;
    *station*dump*)
        echo "Station f2:04:16:28:3a:4c (on wlan0)"
    ;;
    *info*)
        printf '\tchannel 36 width 5180\n\tssid MyHomeWiFi-5G\n'
    ;;
    *)
        echo "Interface wlan0"
    ;;
esac
MOCK
    chmod +x "$MOCKBIN/iw"

    # ip mock: device in ARP
    cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    *neigh*) echo "192.168.1.92 dev br-lan lladdr f2:04:16:28:3a:4c REACHABLE" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/ip"

    # Known file has existing devices so seed_known() is skipped
    cat > "$MOCKDIR/etc/trafficctl/telegram_known.json" <<'JSON'
[{"mac":"a2:b4:c6:d8:e0:12","name":"iPhone-Denis","ip":"192.168.1.45","first_seen":1716200000}]
JSON

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[]}
JSON

    run_bot_once

    # Verify all template tags were substituted
    assert_file_contains "tags: {{name}} resolved" "iPad-Air" "$API_LOG"
    assert_file_contains "tags: {{ip}} resolved" "192.168.1.92" "$API_LOG"
    assert_file_contains "tags: {{mac}} resolved" "f2:04:16:28:3a:4c" "$API_LOG"
    assert_file_contains "tags: {{date}} resolved" "2026-05-27" "$API_LOG"
    assert_file_contains "tags: {{time}} resolved" "14:30" "$API_LOG"
    assert_file_contains "tags: {{datetime}} resolved" "2026-05-27 14:30" "$API_LOG"
    assert_file_contains "tags: {{router}} resolved" "OpenWrt" "$API_LOG"
    assert_file_contains "tags: {{wan_ip}} resolved" "198.51.100.42" "$API_LOG"
    assert_file_contains "tags: {{load}} resolved" "0.12" "$API_LOG"
    assert_file_contains "tags: {{uptime}} resolved" "2d 5h" "$API_LOG"
    assert_file_contains "tags: {{clients}} resolved" "4" "$API_LOG"
    assert_file_contains "tags: {{conns}} resolved" "3" "$API_LOG"
    assert_file_contains "tags: {{ssid}} resolved" "MyHomeWiFi-5G" "$API_LOG"
    assert_file_contains "tags: {{signal}} resolved" "-42" "$API_LOG"
    assert_file_contains "tags: {{freq}} resolved" "5GHz" "$API_LOG"

    # Verify no unresolved tags remain
    if grep -q '{{' "$API_LOG" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        printf "FAIL: tags: unresolved template tags remain in output\n"
        grep -o '{{[^}]*}}' "$API_LOG" | sort -u
    else
        PASS=$((PASS + 1))
    fi

    cleanup
}

# ══════════════════════════════════════════════════════════════════════════════
# TEST: notify_new_device=0 suppresses new device notifications
# ══════════════════════════════════════════════════════════════════════════════

test_new_device_disabled() {
    setup_env "new_device_disabled"
    setup_curl_responses

    # Override uci: disable new device notifications
    cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$*" in
    *"trafficctl.telegram.enabled"*) echo 1 ;;
    *"trafficctl.telegram.bot_token"*) echo "7412345678:AAF_test-token_for_e2e_tests_only" ;;
    *"trafficctl.telegram.chat_id"*) echo "285437102" ;;
    *"trafficctl.telegram.poll_interval"*) echo 5 ;;
    *"trafficctl.telegram.notify_new_device"*) echo 0 ;;
    *"trafficctl.telegram.notify_known_device"*) echo 0 ;;
    *"trafficctl.telegram.control_enabled"*) echo 1 ;;
    *"trafficctl.telegram.notify_template"*) echo "" ;;
    *"trafficctl.telegram.btn_block_inet"*) echo 1 ;;
    *"trafficctl.telegram.btn_block_wifi"*) echo 1 ;;
    *"trafficctl.telegram.btn_limiter"*) echo 1 ;;
    *"trafficctl.telegram.btn_shaper"*) echo 1 ;;
    *"system.@system"*"hostname"*) echo "OpenWrt" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/uci"

    printf '1716811200 e6:f8:0a:1b:2c:3d 192.168.1.88 Pixel-8 01:e6:f8:0a:1b:2c:3d\n' \
        > "$MOCKDIR/tmp/dhcp.leases"
    cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    *neigh*) echo "192.168.1.88 dev br-lan lladdr e6:f8:0a:1b:2c:3d REACHABLE" ;;
    *) echo "" ;;
esac
MOCK
    chmod +x "$MOCKBIN/ip"
    # Known file has existing device so seed_known() won't absorb our target MAC
    cat > "$MOCKDIR/etc/trafficctl/telegram_known.json" <<'JSON'
[{"mac":"a2:b4:c6:d8:e0:12","name":"iPhone-Denis","ip":"192.168.1.45","first_seen":1716200000}]
JSON

    cat > "$MOCKDIR/getUpdates_response.json" <<'JSON'
{"ok":true,"result":[]}
JSON

    run_bot_once

    # Should NOT send any notification
    if grep -q "sendMessage" "$API_LOG" 2>/dev/null; then
        FAIL=$((FAIL + 1))
        printf "FAIL: new_device_disabled: should not notify when notify_new_device=0\n"
    else
        PASS=$((PASS + 1))
    fi

    cleanup
}

# ── Run all tests ──────────────────────────────────────────────────────────────

echo "Running E2E bot tests..."
echo ""

test_cmd_devices
test_cmd_status
test_cmd_help
test_cb_block
test_cb_unblock
test_cb_limit
test_cb_shape
test_cb_control_disabled
test_unauthorized_chat
test_cb_invalid_ip
test_cb_wifi_block
test_new_device_default
test_known_device_online
test_known_device_no_duplicate
test_dhcp_trigger
test_template_all_tags
test_new_device_disabled

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
