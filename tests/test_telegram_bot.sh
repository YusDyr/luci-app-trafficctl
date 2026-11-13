#!/bin/bash
# The Telegram bot (trafficctl.telegram, package trafficctl-telegram): what it
# sends for each command and callback, what it runs, and what v1.30.0's shell
# bot got wrong. tests/equiv.sh compares it with that bot request by request;
# this file covers what the comparison cannot: the token off curl's argv, the
# device cache, HTML-escaped names, the toast cut on a character boundary, the
# callback validation, the offset file, `trafficctl telegram`, the packaging.
#
# The bot runs from trafficctl-telegram.uc against a scratch TCTL_ROOT. curl
# is a PATH mock that serves getUpdates from a queue and ends the bot's process
# group when the queue runs out; the CLI under the root is a stub that logs
# what the bot runs and prints the device list. Moved here from
# test_telegram.sh, test_telegram_mock.sh, test_telegram_e2e.sh and the bot
# part of test_security.sh.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PASS=0
FAIL=0

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}

assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: '%s'\n" "$1" "$2" "$3"
    fi
}

assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  did not expect: '%s'\n  in: '%s'\n" "$1" "$2" "$3"
    else
        PASS=$((PASS + 1))
    fi
}

command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }

export TCTL_ROOT="$UC_TMP/root"
export NLOG="$UC_TMP/log"
export TCTL_UBUS_SOCKET="$UC_TMP/no-ubus.sock"
FILES="$UC_REPO/trafficctl/files"
ENTRY="$FILES/usr/libexec/trafficctl/trafficctl-telegram.uc"
TOKEN='7412345678:AAF_test-token_for_bot_tests'

# ── mocks ────────────────────────────────────────────────────────────────────
MOCKBIN="$UC_TMP/bin"
mkdir -p "$MOCKBIN"
# Each request goes to $NLOG/req as "<method> <valid utf-8 0/1> <body>", its
# argv to $NLOG/argv and its config to $NLOG/cfg. getUpdates answers with the
# next line of $NLOG/updates; past the last, the process group is ended.
cat > "$MOCKBIN/curl" <<'MOCK'
#!/usr/bin/env python3
import json, os, re, signal, sys
log = os.environ['NLOG']
cfg = sys.stdin.buffer.read()
with open(log + '/argv', 'a') as f:
    f.write(' '.join(sys.argv[1:]) + '\n')
with open(log + '/cfg', 'ab') as f:
    f.write(cfg)
url, body = '', b''
for line in cfg.split(b'\n'):
    m = re.match(rb'^(\S+) = "(.*)"$', line)
    if not m:
        continue
    v = re.sub(rb'\\(.)', lambda c: {b'n': b'\n', b'r': b'\r', b't': b'\t'}.get(c.group(1), c.group(1)), m.group(2))
    if m.group(1) == b'url':
        url = v.decode()
    elif m.group(1) == b'data-raw':
        body = v
try:
    text, valid = body.decode('utf-8'), 1
except UnicodeDecodeError:
    text, valid = body.decode('utf-8', 'replace'), 0
try:
    text = json.dumps(json.loads(text), sort_keys=True, ensure_ascii=False)
except ValueError:
    pass
method = url.rsplit('/', 1)[-1]
with open(log + '/req', 'a') as f:
    f.write('%s %d %s\n' % (method, valid, text))
if method == 'getUpdates':
    n = int(open(log + '/updates.n').read()) if os.path.exists(log + '/updates.n') else 0
    q = open(log + '/updates').read().splitlines() if os.path.exists(log + '/updates') else []
    if n >= len(q):
        os.killpg(os.getpgrp(), signal.SIGTERM)
    open(log + '/updates.n', 'w').write(str(n + 1))
    sys.stdout.write(q[n])
else:
    sys.stdout.write('{"ok":true,"result":{}}')
MOCK
cat > "$MOCKBIN/logger" <<'MOCK'
#!/bin/sh
echo "$*" >> "$NLOG/logger"
MOCK
chmod +x "$MOCKBIN"/*
export PATH="$MOCKBIN:$PATH"

# The CLI the bot runs: the summary prints $NLOG/summary (and counts the
# calls), anything else is logged with the caller variables and answers
# $NLOG/reply.<command> or {"ok":true,"msg":"<command> done"}.
mkdir -p "$TCTL_ROOT/usr/sbin"
cat > "$TCTL_ROOT/usr/sbin/trafficctl" <<'MOCK'
#!/bin/sh
if [ "$1" = summary ]; then
    echo x >> "$NLOG/summary.calls"
    cat "$NLOG/summary"
    exit 0
fi
printf '%s via=%s src=%s user=%s\n' "$*" "$TCTL_VIA" "$TCTL_SRC" "$TCTL_USER" >> "$NLOG/cli"
if [ -f "$NLOG/reply.$1" ]; then cat "$NLOG/reply.$1"; else printf '{"ok":true,"msg":"%s done"}\n' "$1"; fi
MOCK
chmod +x "$TCTL_ROOT/usr/sbin/trafficctl"

DEVS='[{"ip":"192.168.1.10","name":"<b>Evil</b> & co","conn_type":"5G","blocked":true,"wifi_blocked":false,"rate_limit_kbit":0,"shape_kbit":0},{"ip":"192.168.1.11","name":"back\\nslash","conn_type":"lan1","blocked":false,"wifi_blocked":false,"rate_limit_kbit":2000,"shape_kbit":0},{"ip":"255.255.255.255","name":"Пётр","conn_type":"wifi","blocked":false,"wifi_blocked":true,"rate_limit_kbit":0,"shape_kbit":0}]'

reset() {   # reset [uci option=value...]: a fresh root, the bot on, chat 4242
    local o k
    local -A opt=([enabled]=1 [bot_token]="$TOKEN" [chat_id]=4242)
    for o in "$@"; do opt[${o%%=*}]=${o#*=}; done
    rm -rf "${NLOG:?}" "${TCTL_ROOT:?}/etc" "${TCTL_ROOT:?}/tmp"
    mkdir -p "$NLOG" "$TCTL_ROOT/etc/config" "$TCTL_ROOT/tmp/.uci"
    {
        echo "config telegram 'telegram'"
        for k in "${!opt[@]}"; do [ -z "${opt[$k]}" ] || echo "	option $k '${opt[$k]}'"; done
    } > "$TCTL_ROOT/etc/config/trafficctl"
    printf '%s\n' "$DEVS" > "$NLOG/summary"
}
upd() { local r; for r in "$@"; do printf '{"ok":true,"result":[%s]}\n' "$r"; done >> "$NLOG/updates"; }
msg() { printf '{"update_id":%s,"message":{"message_id":5,"chat":{"id":4242},"text":"%s"}}' "$1" "$2"; }
cbq() { jq -cn --arg id "$1" --arg d "$2" '{update_id: ($id | tonumber), callback_query: {id: ("cb" + $id), data: $d, message: {message_id: 77, chat: {id: 4242}}}}'; }
bot() {   # the bot until the queue runs out; its exit status
    # In a subshell with stderr closed: bash reports a job killed by a signal.
    ( timeout 60 setsid "$UCODE" -S -L "$UC_LIB" "$ENTRY" > "$NLOG/out" 2>&1; exit $? ) 2>/dev/null
    echo $?
}
req() { grep "^$1 " "$NLOG/req" | cut -d' ' -f3-; }   # req <method>: the bodies

# ── start ────────────────────────────────────────────────────────────────────
reset enabled=0
assert_eq "disabled: exits 0" 0 "$(bot)"
assert_eq "disabled: says so" "-t trafficctl-tg Telegram bot disabled" "$(cat "$NLOG/logger")"
assert_eq "disabled: no request" "" "$(cat "$NLOG/req" 2>/dev/null)"

reset chat_id=
assert_eq "no chat: exits 1" 1 "$(bot)"
assert_eq "no chat: says so" "-t trafficctl-tg Missing bot_token or chat_id" "$(cat "$NLOG/logger")"

reset
upd "$(msg 1 /help)"
assert_eq "runs until killed" 143 "$(bot)"
assert_eq "start: logged" "-t trafficctl-tg Bot started, chat_id=4242" "$(cat "$NLOG/logger")"
assert_eq "no output on stdout or stderr" "" "$(cat "$NLOG/out")"
# The token is in the URL: only in the config on stdin, never in argv.
assert_not_contains "token never in curl's argv" "$TOKEN" "$(cat "$NLOG/argv")"
assert_contains "token in the config on stdin" "url = \"https://api.telegram.org/bot$TOKEN/sendMessage\"" "$(cat "$NLOG/cfg")"
assert_eq "argv: a 30 s timeout, the config from stdin" "-s -m 30 -X POST --config -" "$(head -1 "$NLOG/argv")"
assert_contains "the body is JSON" 'header = "Content-Type: application/json"' "$(cat "$NLOG/cfg")"
assert_eq "getUpdates: offset, poll timeout, the two update kinds" \
    '{"allowed_updates": ["message", "callback_query"], "offset": 0, "timeout": 3}' "$(req getUpdates | head -1)"
assert_eq "offset file: the last update_id + 1" 2 "$(cat "$TCTL_ROOT/tmp/trafficctl_tg_offset")"

# A garbage or empty offset file is offset 0 (v1.30.0 put it in the JSON as
# it was, and Telegram refused every poll).
for o in abc '' '-5' '1e3'; do
    reset
    printf '%s\n' "$o" > "$TCTL_ROOT/tmp/trafficctl_tg_offset"
    upd ""
    bot > /dev/null
    assert_eq "offset file '$o': polls from 0" 0 "$(req getUpdates | head -1 | jq .offset)"
done
reset
echo 41 > "$TCTL_ROOT/tmp/trafficctl_tg_offset"
upd ""
bot > /dev/null
assert_eq "offset file 41: polls from 41" 41 "$(req getUpdates | head -1 | jq .offset)"

# A refused poll waits 5 s before the next.
reset
echo '{"ok":false,"error_code":409}' > "$NLOG/updates"
t0=$(date +%s)
bot > /dev/null
assert_eq "refused poll: retried once" 2 "$(req getUpdates | wc -l | tr -d ' ')"
assert_eq "refused poll: after 5 s" 1 "$(( $(date +%s) - t0 >= 5 ))"
assert_eq "refused poll: logged" "-t trafficctl-tg Bot started, chat_id=4242
-t trafficctl-tg getUpdates failed (409), retrying every 5 s" "$(cat "$NLOG/logger")"
# An outage is logged when it starts and when it ends, not at every retry.
reset
{ echo 'not json'; echo '{"ok":false,"error_code":502}'; echo '{"ok":true,"result":[]}'; } > "$NLOG/updates"
bot > /dev/null
assert_eq "outage: logged once, and its end" "-t trafficctl-tg Bot started, chat_id=4242
-t trafficctl-tg getUpdates failed: no answer from api.telegram.org, retrying every 5 s
-t trafficctl-tg getUpdates works again" "$(cat "$NLOG/logger")"
# The long poll stays under curl's 30 s.
reset poll_interval=300
upd ""
bot > /dev/null
assert_eq "poll_interval: capped at 25" 25 "$(req getUpdates | head -1 | jq .timeout)"

# ── commands ─────────────────────────────────────────────────────────────────
reset
upd "$(msg 1 /status),$(msg 2 /devices)"
bot > /dev/null
ST=$(req sendMessage | sed -n 1p | jq -r .text)
assert_contains "status: a name is HTML-escaped" "&lt;b&gt;Evil&lt;/b&gt; &amp; co (192.168.1.10): 🚫inet" "$ST"
assert_contains "status: a backslash stays as it is" 'back\nslash (192.168.1.11): ⚡2000k' "$ST"
assert_contains "status: wifi block" "Пётр (255.255.255.255): 📵wifi" "$ST"
KB=$(req sendMessage | sed -n 2p | jq -c .reply_markup)
assert_eq "devices keyboard: labels ASCII-only, 12 bytes, two per row" \
    '[["bEvilb  co 192.168.1.10","backnslash 192.168.1.11"],["255.255.255. 255.255.255.255"]]' \
    "$(printf '%s' "$KB" | jq -c '.inline_keyboard | map(map(.text))')"
assert_eq "summary: one run for both commands (5 s cache)" 1 "$(wc -l < "$NLOG/summary.calls" | tr -d ' ')"
assert_eq "cache: the summary as it printed it" "$DEVS" "$(cat "$TCTL_ROOT/tmp/trafficctl_tg_devices.json")"

reset
printf '%s\n' "$DEVS" > "$TCTL_ROOT/tmp/trafficctl_tg_devices.json"
touch -d '1 minute ago' "$TCTL_ROOT/tmp/trafficctl_tg_devices.json"
upd "$(msg 1 /status)"
bot > /dev/null
assert_eq "cache: an old one is refreshed" 1 "$(wc -l < "$NLOG/summary.calls" | tr -d ' ')"

reset control_enabled=0
upd "$(msg 1 /devices)"
bot > /dev/null
assert_eq "devices, control off: a list, names escaped" \
    "$(printf '<b>Active devices: 3</b>\n• &lt;b&gt;Evil&lt;/b&gt; &amp; co (192.168.1.10)\n• back\\nslash (192.168.1.11)\n• Пётр (255.255.255.255)')" \
    "$(req sendMessage | jq -r .text)"

reset
printf 'not json\n' > "$NLOG/summary"
upd "$(msg 1 /devices),$(cbq 2 act:back)"
bot > /dev/null
assert_eq "summary not JSON: no devices" "No active devices" "$(req sendMessage | jq -r .text)"
# v1.30.0 built "[]]}" for an empty list, which Telegram refused.
assert_eq "back with no devices: an empty keyboard that is JSON" '{"inline_keyboard":[]}' \
    "$(req editMessageText | jq -c .reply_markup)"

# ── callbacks ────────────────────────────────────────────────────────────────
reset
upd "$(cbq 1 act:menu:192.168.1.10),$(cbq 2 act:block:192.168.1.11),$(cbq 3 act:limit:192.168.1.11:10000)"
bot > /dev/null
assert_eq "menu: the header escaped" "$(printf '<b>&lt;b&gt;Evil&lt;/b&gt; &amp; co</b> (192.168.1.10)\n🚫 Internet blocked')" \
    "$(req editMessageText | sed -n 1p | jq -r .text)"
assert_eq "actions: the CLI with the caller variables" \
    "$(printf 'block 192.168.1.11 tg via=telegram src=telegram:4242 user=telegram-bot\nratelimit 192.168.1.11 10000 tg via=telegram src=telegram:4242 user=telegram-bot')" \
    "$(cat "$NLOG/cli")"
assert_eq "summary: the menu always reads it afresh" 3 "$(wc -l < "$NLOG/summary.calls" | tr -d ' ')"
assert_eq "toast: the action's msg" "block done" "$(req answerCallbackQuery | sed -n 2p | jq -r .text)"

# Every callback_data a keyboard can carry fits Telegram's 64 bytes, the
# widest address included.
reset
upd "$(cbq 1 act:menu:255.255.255.255),$(cbq 2 act:menu:192.168.1.11),$(msg 3 /devices)"
bot > /dev/null
assert_eq "callback_data: within 64 bytes" "" \
    "$(grep -hE '^(sendMessage|editMessageText) ' "$NLOG/req" | cut -d' ' -f3- |
        jq -r '.reply_markup.inline_keyboard[]?[]?.callback_data' | awk 'length($0) > 64')"

# The toast: Telegram refuses one over 200 bytes. v1.30.0 cut at 196 bytes,
# through a character if it had to.
reset
LONG=$(printf 'Ж%.0s' $(seq 150))
printf '{"ok":false,"msg":"%s"}\n' "$LONG" > "$NLOG/reply.block"
printf '{"ok":false,"msg":"%s"}\n' "$(printf 'x%.0s' $(seq 200))" > "$NLOG/reply.unblock"
upd "$(cbq 1 act:block:192.168.1.11),$(cbq 2 act:unblock:192.168.1.10)"
bot > /dev/null
T1=$(req answerCallbackQuery | sed -n 1p | jq -r .text)
assert_eq "toast: valid UTF-8" 0 "$(grep -c '^answerCallbackQuery 0 ' "$NLOG/req")"
assert_eq "toast: cut on a character, then ..." "$(printf 'Ж%.0s' $(seq 98))..." "$T1"
assert_eq "toast: 200 bytes are sent whole" 200 "$(req answerCallbackQuery | sed -n 3p | jq -r .text | tr -d '\n' | wc -c | tr -d ' ')"

reset
printf '{"ok":true}\n' > "$NLOG/reply.block"
upd "$(cbq 1 act:block:192.168.1.11)"
bot > /dev/null
assert_eq "toast: no msg is done" 'done' "$(req answerCallbackQuery | sed -n 1p | jq -r .text)"

# Validation: the address and the rate land in a command line.
check_cb() {   # check_cb <name> <data> <toast>
    reset
    upd "$(cbq 1 "$2")"
    bot > /dev/null
    assert_eq "callback $1: '$3'" "$3" "$(req answerCallbackQuery | sed -n 1p | jq -r .text)"
    assert_eq "callback $1: nothing run" "" "$(cat "$NLOG/cli" 2>/dev/null)"
}
check_cb "semicolon" 'act:block:192.168.0.1;whoami' 'invalid IP'
check_cb "pipe" 'act:block:1.1.1.1|cat' 'invalid IP'
check_cb "letters" 'act:block:abc.def.ghi.jkl' 'invalid IP'
check_cb "newline" "$(printf 'act:block:192.168.0.1\nreboot')" 'invalid IP'
check_cb "control character" "$(printf 'act:block:192.168.0.1\x01')" 'invalid IP'
check_cb "rate injection" 'act:limit:192.168.0.1:10000;rm' 'invalid param'
check_cb "rate letters" 'act:limit:192.168.0.1:abc' 'invalid param'
check_cb "unknown verb" 'act:reboot:192.168.0.1' 'Unknown action'
check_cb "no colon" 'garbage' 'invalid IP'

reset control_enabled=0
upd "$(cbq 1 act:block:192.168.1.11)"
bot > /dev/null
assert_eq "control off: refused" "Control disabled" "$(req answerCallbackQuery | jq -r .text)"
assert_eq "control off: nothing run" "" "$(cat "$NLOG/cli" 2>/dev/null)"

reset
upd "$(cbq 1 act:shape:192.168.1.11:5000),$(cbq 2 act:unshape:192.168.1.11),$(cbq 3 act:wblock:192.168.1.11),$(cbq 4 act:wunblock:192.168.1.11),$(cbq 5 act:unlimit:192.168.1.11),$(cbq 6 act:unblock:192.168.1.11)"
bot > /dev/null
assert_eq "actions: each verb's command" \
    "$(printf '%s\n' 'shape add 192.168.1.11 5000 tg' 'shape remove 192.168.1.11' 'macfilter-add 192.168.1.11' \
        'macfilter-remove 192.168.1.11' 'ratelimit 192.168.1.11 0 tg' 'unblock 192.168.1.11 tg')" \
    "$(sed 's/ via=.*//' "$NLOG/cli")"

# ── the CLI, the shim, the init script ──────────────────────────────────────
reset
OUT=$(tctl telegram); RC=$?
assert_eq "trafficctl telegram without the package" '{"ok":false,"msg":"trafficctl-telegram is not installed"}' "$OUT"
assert_eq "trafficctl telegram without the package: exit 1" 1 "$RC"
mkdir -p "$TCTL_ROOT/usr/libexec/trafficctl"
printf '#!/bin/sh\necho "bot $*"\nexit 3\n' > "$TCTL_ROOT/usr/libexec/trafficctl/trafficctl-telegram.uc"
chmod +x "$TCTL_ROOT/usr/libexec/trafficctl/trafficctl-telegram.uc"
OUT=$(tctl telegram x y); RC=$?
assert_eq "trafficctl telegram runs the bot" "bot x y" "$OUT"
assert_eq "trafficctl telegram: the bot's exit status" 3 "$RC"
assert_eq "shim: the CLI command" 'exec /usr/sbin/trafficctl telegram "$@"' \
    "$(sed -n 2p "$FILES/usr/libexec/trafficctl/trafficctl-telegram.sh")"
assert_contains "init script runs the bot itself" "procd_set_param command /usr/libexec/trafficctl/trafficctl-telegram.uc" \
    "$(cat "$FILES/etc/init.d/trafficctl-telegram")"
assert_eq "entry: executable" yes "$([ -x "$ENTRY" ] && echo yes)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
