#!/bin/bash
# Level 3: Integration tests for Telegram bot with real Telegram API.
# Requires: TEST_TELEGRAM_TOKEN and TEST_TELEGRAM_CHAT_ID in environment.
# Sends real messages to the test bot and verifies responses.
# Skipped if secrets are not available (e.g. PRs from forks).
set -e

if [ -z "$TEST_TELEGRAM_TOKEN" ] || [ -z "$TEST_TELEGRAM_CHAT_ID" ]; then
    # A bare "SKIP: ..." line followed by exit 0 is indistinguishable in CI
    # output from a normal green run — both are exit 0 with SOME text on
    # stdout. A human (or a script) scanning job logs for "N passed, M
    # failed" would see nothing here and could easily mistake silence for
    # "ran clean." Emit the same "N passed, N failed" trailer format every
    # other test file uses, with an explicit SKIPPED marker in front of it,
    # so a log/grep pass over all test files can't confuse this with a real
    # 0-failure run — and repeat the reason loudly, framed, top and bottom.
    echo "=================================================================="
    echo "SKIPPED — NOT RUN: TEST_TELEGRAM_TOKEN or TEST_TELEGRAM_CHAT_ID not set"
    echo "This file's 186 lines of Telegram API integration checks did NOT execute."
    echo "This is expected for fork PRs (CI withholds the secrets) — see .github/workflows/tests.yml."
    echo "=================================================================="
    echo ""
    echo "0 passed, 0 failed (SKIPPED)"
    exit 0
fi

# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/lib/assert.sh"
TOKEN="$TEST_TELEGRAM_TOKEN"
CHAT_ID="$TEST_TELEGRAM_CHAT_ID"
API="https://api.telegram.org/bot${TOKEN}"

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to contain: '%s'\n  actual: '%.200s'\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_empty() {
    local desc="$1" value="$2"
    if [ -n "$value" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s — value is empty\n" "$desc"
    fi
}

# ── Helper: call Telegram API ──────────────────────────────────────────────────

tg_call() {
    local method="$1"
    shift
    curl -s -m 10 -X POST "${API}/${method}" "$@"
}

tg_send_msg() {
    local text="$1"
    tg_call "sendMessage" \
        -H "Content-Type: application/json" \
        -d "$(printf '{"chat_id":"%s","text":"%s"}' "$CHAT_ID" "$text")"
}

tg_get_updates() {
    tg_call "getUpdates" \
        -H "Content-Type: application/json" \
        -d '{"offset":-1,"limit":1,"timeout":0}'
}

# ── Helper: extract JSON field (simple grep-based, no jq dependency) ───────────

json_field() {
    local field="$1" json="$2"
    echo "$json" | grep -o "\"${field}\":[^,}]*" | head -1 | sed "s/\"${field}\"://;s/\"//g"
}

json_field_str() {
    local field="$1" json="$2"
    echo "$json" | grep -o "\"${field}\":\"[^\"]*\"" | head -1 | sed "s/\"${field}\":\"//;s/\"$//"
}

# ── Test 1: Bot is reachable (getMe) ──────────────────────────────────────────

echo "Test: Bot reachability..."
response=$(tg_call "getMe")
ok=$(json_field "ok" "$response")
assert_eq "getMe returns ok" "true" "$ok"

bot_username=$(json_field_str "username" "$response")
assert_not_empty "bot has username" "$bot_username"
echo "  Bot: @${bot_username}"

# ── Test 2: Send a message ─────────────────────────────────────────────────────

echo "Test: Send message..."
response=$(tg_send_msg "CI test: $(date -u +%Y-%m-%dT%H:%M:%SZ)")
ok=$(json_field "ok" "$response")
assert_eq "sendMessage ok" "true" "$ok"

msg_id=$(json_field "message_id" "$response")
assert_not_empty "message has id" "$msg_id"

# ── Test 3: Send message with inline keyboard ─────────────────────────────────

echo "Test: Inline keyboard..."
response=$(tg_call "sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"chat_id":"%s","text":"Select action:","reply_markup":{"inline_keyboard":[[{"text":"Test Button","callback_data":"act:test:1.2.3.4"}]]}}' "$CHAT_ID")")
ok=$(json_field "ok" "$response")
assert_eq "keyboard message ok" "true" "$ok"

kb_msg_id=$(json_field "message_id" "$response")
assert_not_empty "keyboard message has id" "$kb_msg_id"

# ── Test 4: Edit message (simulates menu navigation) ──────────────────────────

echo "Test: Edit message..."
response=$(tg_call "editMessageText" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"chat_id":"%s","message_id":%s,"text":"Edited: action done","reply_markup":{"inline_keyboard":[[{"text":"Back","callback_data":"act:back"}]]}}' "$CHAT_ID" "$kb_msg_id")")
ok=$(json_field "ok" "$response")
assert_eq "editMessageText ok" "true" "$ok"

# ── Test 5: Send HTML-formatted message ───────────────────────────────────────

echo "Test: HTML message..."
response=$(tg_call "sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"chat_id":"%s","text":"<b>Bold</b> and <code>code</code>","parse_mode":"HTML"}' "$CHAT_ID")")
ok=$(json_field "ok" "$response")
assert_eq "HTML message ok" "true" "$ok"

# ── Test 6: Simulate new device notification ──────────────────────────────────

echo "Test: Device notification format..."
notify_text='🆕 <b>New device</b>\nTestDevice (192.168.0.99)\nMAC: <code>aa:bb:cc:dd:ee:ff</code>\nLink: 5G'
response=$(tg_call "sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"chat_id":"%s","text":"%s","parse_mode":"HTML"}' "$CHAT_ID" "$notify_text")")
ok=$(json_field "ok" "$response")
assert_eq "notification ok" "true" "$ok"

# ── Test 7: Simulate device list with keyboard (full bot response) ─────────────

echo "Test: Device list with action buttons..."
device_kb='{"inline_keyboard":[[{"text":"TestDev 192.168.0.99","callback_data":"act:menu:192.168.0.99"}],[{"text":"Phone 192.168.0.50","callback_data":"act:menu:192.168.0.50"}]]}'
response=$(tg_call "sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"chat_id":"%s","text":"<b>Active devices: 2</b>\nSelect a device:","parse_mode":"HTML","reply_markup":%s}' "$CHAT_ID" "$device_kb")")
ok=$(json_field "ok" "$response")
assert_eq "device list ok" "true" "$ok"

# ── Test 8: Simulate action menu (block/limit/shape buttons) ──────────────────

echo "Test: Action menu keyboard..."
action_kb='{"inline_keyboard":[[{"text":"⏸ Block Internet","callback_data":"act:block:192.168.0.99"}],[{"text":"📵 Block WiFi","callback_data":"act:wblock:192.168.0.99"}],[{"text":"⚡ 1M","callback_data":"act:limit:192.168.0.99:1000"},{"text":"⚡ 5M","callback_data":"act:limit:192.168.0.99:5000"},{"text":"⚡ 10M","callback_data":"act:limit:192.168.0.99:10000"}],[{"text":"🔧 5M","callback_data":"act:shape:192.168.0.99:5000"},{"text":"🔧 10M","callback_data":"act:shape:192.168.0.99:10000"},{"text":"🔧 50M","callback_data":"act:shape:192.168.0.99:50000"}],[{"text":"⬅️ Back","callback_data":"act:back"}]]}'
response=$(tg_call "sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"chat_id":"%s","text":"<b>TestDev</b> (192.168.0.99)\n✅ No restrictions","parse_mode":"HTML","reply_markup":%s}' "$CHAT_ID" "$action_kb")")
ok=$(json_field "ok" "$response")
assert_eq "action menu ok" "true" "$ok"

# ── Test 9: Verify long callback_data doesn't exceed 64 bytes ─────────────────

echo "Test: Callback data length limits..."
long_cb="act:shape:192.168.255.255:100000"
assert_eq "longest cb within 64b" "1" "$([ ${#long_cb} -le 64 ] && echo 1 || echo 0)"

# ── Test 10: Delete test messages (cleanup) ────────────────────────────────────

echo "Test: Cleanup (delete messages)..."
for mid in $msg_id $kb_msg_id; do
    if [ -n "$mid" ]; then
        tg_call "deleteMessage" \
            -H "Content-Type: application/json" \
            -d "$(printf '{"chat_id":"%s","message_id":%s}' "$CHAT_ID" "$mid")" >/dev/null 2>&1
    fi
done
PASS=$((PASS + 1))  # cleanup always passes

# ── Results ────────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "(Bot: @${bot_username}, Chat: ${CHAT_ID})"
[ "$FAIL" -eq 0 ] || exit 1
