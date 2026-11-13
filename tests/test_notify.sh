#!/bin/bash
# Notifications (trafficctl.notify): the events, their three outlets (ubus,
# /etc/hotplug.d/trafficctl, the senders), each sender's request, the device
# scan and its ledger, the migration of the bot's old options, the settings
# behind the LuCI tab, and `trafficctl telegram-test`.
#
# Runs the ucode CLI and the rpcd plugin against a scratch TCTL_ROOT. curl,
# logger, ip and iw are PATH mocks; msmtp and hotplug-call sit under the root.
# The device scan and the template cases moved here from test_telegram_e2e.sh,
# the ledger and sanitising cases from test_telegram.sh and test_security.sh,
# the telegram-test cases from test_telegram.sh and test_regressions.sh: the
# bot no longer does any of it.

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

export TZ=UTC
export TCTL_ROOT="$UC_TMP/root"
export NLOG="$UC_TMP/log"
export TCTL_NOTIFY_SYNC=1
# No ubusd unless a case starts one.
export TCTL_UBUS_SOCKET="$UC_TMP/no-ubus.sock"
PLUGIN="$UC_REPO/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
KNOWN="$TCTL_ROOT/etc/trafficctl/telegram_known.json"
ONLINE="$TCTL_ROOT/tmp/trafficctl_tg_online"
LEASES="$TCTL_ROOT/tmp/dhcp.leases"
TOKEN='7412345678:AAF_test-token_for_notify_tests'

# ── mocks ────────────────────────────────────────────────────────────────────
MOCKBIN="$UC_TMP/bin"
mkdir -p "$MOCKBIN"
# Each request: argv, the config read from stdin, and a canned reply.
cat > "$MOCKBIN/curl" <<'MOCK'
#!/bin/sh
n=$(( $(cat "$NLOG/curl.n" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$NLOG/curl.n"
printf '%s\n' "$*" > "$NLOG/curl.$n.argv"
cat > "$NLOG/curl.$n.cfg"
case "$*" in
    *http_code*) cat "$NLOG/curl.code" 2>/dev/null || printf 200 ;;
    *) cat "$NLOG/curl.reply" 2>/dev/null || printf '{"ok":true,"result":{}}' ;;
esac
MOCK
cat > "$MOCKBIN/logger" <<'MOCK'
#!/bin/sh
echo "$*" >> "$NLOG/logger"
MOCK
cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    "neigh show") cat "$NLOG/neigh" 2>/dev/null ;;
    *) exit 1 ;;
esac
MOCK
# Interfaces from $NLOG/iw.dev; a station is "on" an interface when it is
# listed in $NLOG/iw.<iface>.
cat > "$MOCKBIN/iw" <<'MOCK'
#!/bin/sh
[ "$1" = dev ] || exit 1
[ $# -eq 1 ] && { cat "$NLOG/iw.dev" 2>/dev/null; exit 0; }
f="$NLOG/iw.$2"
case "$3 $4" in
    "station dump") [ -f "$f" ] && sed 's/^/Station /; s/$/ (on '"$2"')/' "$f" ;;
    "station get") grep -qx "$5" "$f" 2>/dev/null || exit 1
        printf 'Station %s (on %s)\n\tsignal:  \t-42 dBm\n' "$5" "$2" ;;
    "info ") cat "$NLOG/iw.$2.info" 2>/dev/null ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN"/*
export PATH="$MOCKBIN:$PATH"

# The CLI where the code under test spawns it (emit's dispatch, notify_test).
mkdir -p "$TCTL_ROOT/usr/sbin" "$TCTL_ROOT/sbin" "$TCTL_ROOT/usr/bin"
cat > "$TCTL_ROOT/usr/sbin/trafficctl" <<EOF
#!/bin/sh
exec "$UCODE" -S -L "$UC_LIB" -- "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" "\$@"
EOF
cat > "$TCTL_ROOT/sbin/hotplug-call" <<'MOCK'
#!/bin/sh
{ echo "args=$*"; env | grep -E '^(ACTION|TIME|IP|MAC|NAME|LINK|KIND|MODE|RATE_KBIT|RATE_KBIT_UP|DURATION|PERSIST|VIA|SRC)=' | sort; } >> "$NLOG/hotplug"
MOCK
chmod +x "$TCTL_ROOT/usr/sbin/trafficctl" "$TCTL_ROOT/sbin/hotplug-call"

msmtp_mock() {   # msmtp_mock <exit status>
    cat > "$TCTL_ROOT/usr/bin/msmtp" <<MOCK
#!/bin/sh
printf '%s\n' "\$*" > "$NLOG/msmtp.argv"
cat > "$NLOG/msmtp.stdin"
exit $1
MOCK
    chmod +x "$TCTL_ROOT/usr/bin/msmtp"
}

# A fresh case: empty logs and state, the given config.
reset() {   # reset <config text>
    rm -rf "${NLOG:?}" "${TCTL_ROOT:?}/etc" "${TCTL_ROOT:?}/tmp" "${TCTL_ROOT:?}/proc"
    mkdir -p "$NLOG" "$TCTL_ROOT/etc/config" "$TCTL_ROOT/etc/trafficctl" "$TCTL_ROOT/tmp/.uci" \
        "$TCTL_ROOT/proc/net"
    rm -f "$TCTL_ROOT/usr/bin/msmtp"
    printf '%s\n' "$1" > "$TCTL_ROOT/etc/config/trafficctl"
    printf "config system\n\toption hostname 'OpenWrt'\n" > "$TCTL_ROOT/etc/config/system"
}

curls() { cat "$NLOG/curl.n" 2>/dev/null || echo 0; }

# A value from the curl config of request n, unescaped.
cfgval() {   # cfgval <n> <key>
    python3 - "$NLOG/curl.$1.cfg" "$2" <<'PY'
import re, sys
for line in open(sys.argv[1]):
    m = re.match(r'^(\S+) = "(.*)"$', line.rstrip('\n'))
    if not m or m.group(1) != sys.argv[2]:
        continue
    s, out, i = m.group(2), '', 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            out += {'n': '\n', 'r': '\r', 't': '\t'}.get(s[i + 1], s[i + 1])
            i += 2
        else:
            out += s[i]
            i += 1
    print(out)
PY
}

# One key of the JSON body of request n.
body() {   # body <n> <key>
    cfgval "$1" data-raw 2>/dev/null | python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); print(json.dumps(v, ensure_ascii=False) if not isinstance(v, str) else v)' "$2" 2>/dev/null
}

rpc() {   # rpc <method> [json]
    printf '%s' "${2:-}" | "$UCODE" -S -L "$UC_LIB" "$PLUGIN" call "$1" 2>&1
}

uciget() { uci -c "$TCTL_ROOT/etc/config" -q get "trafficctl.$1"; }

BOT="config telegram 'telegram'
	option enabled '1'
	option bot_token '$TOKEN'
	option chat_id '285437102'"

# ── the CLI ──────────────────────────────────────────────────────────────────

reset "config notify 'notify'"
OUT=$(tctl notify bogus); RC=$?
assert_contains "notify: an unknown subcommand prints the usage" '"ok":false' "$OUT"
assert_eq "notify: an unknown subcommand fails" 1 "$RC"
OUT=$(tctl notify emit no_such_event ip=1.2.3.4)
assert_eq "emit: an unknown event is refused" '{"ok":false,"msg":"unknown event: no_such_event"}' "$OUT"
OUT=$(tctl notify emit block_applied ip=192.168.1.9)
assert_eq "emit: nothing listening is still a sent event" '{"ok":true,"msg":"event sent"}' "$OUT"
assert_eq "emit: nothing listening, no request" 0 "$(curls)"

# ── ubus ─────────────────────────────────────────────────────────────────────

reset "config notify 'notify'
	option enabled '0'"
mkdir -p "$UC_TMP/ubus-empty"
unset TCTL_UBUS_SOCKET
ubus_start "$UC_TMP/ubus-empty"
( timeout 3 ubus -s "$TCTL_UBUS_SOCKET" listen trafficctl.notify > "$NLOG/listen" 2>&1 & )
sleep 0.5
tctl notify emit block_applied ip=192.168.0.9 kind=internet via=luci junk=1 rate_kbit=x \
    name="$(printf 'two\nlines')" mode="$(printf 'x%.0s' $(seq 257))" src=192.168.1.2 >/dev/null
sleep 0.5
EV=$(tr -d ' \n\t' < "$NLOG/listen")
assert_contains "ubus: the event is sent, senders off or not" '"event":"block_applied"' "$EV"
assert_contains "ubus: with its fields" '"ip":"192.168.0.9","kind":"internet","via":"luci"' "$EV"
assert_not_contains "ubus: unknown fields are dropped" 'junk' "$EV"
assert_not_contains "ubus: a field that is not a number is dropped" 'rate_kbit' "$EV"
assert_not_contains "ubus: a field with a control character is dropped" '"name"' "$EV"
assert_not_contains "ubus: a field over 256 bytes is dropped" '"mode"' "$EV"
assert_contains "ubus: the other text fields stay" '"src":"192.168.1.2"' "$EV"
ubus_stop
export TCTL_UBUS_SOCKET="$UC_TMP/no-ubus.sock"

# ── hotplug ──────────────────────────────────────────────────────────────────

reset "config notify 'notify'
	option enabled '0'"
mkdir -p "$TCTL_ROOT/etc/hotplug.d/trafficctl"
OUT=$(tctl notify emit limit_applied ip=192.168.1.9 rate_kbit=5000 mode=limiter)
assert_eq "hotplug: no scripts, hotplug-call is not run" "no" "$([ -f "$NLOG/hotplug" ] && echo yes || echo no)"
: > "$TCTL_ROOT/etc/hotplug.d/trafficctl/50-mine"
TCTL_NOW=1780000000 tctl notify emit limit_applied ip=192.168.1.9 rate_kbit=5000 mode=limiter via=cli >/dev/null
HP=$(cat "$NLOG/hotplug" 2>/dev/null)
assert_contains "hotplug: run for the trafficctl subsystem" "args=trafficctl" "$HP"
assert_contains "hotplug: ACTION is the event" "ACTION=limit_applied" "$HP"
assert_contains "hotplug: TIME" "TIME=1780000000" "$HP"
assert_contains "hotplug: fields upper-cased" "RATE_KBIT=5000" "$HP"
assert_contains "hotplug: IP" "IP=192.168.1.9" "$HP"
assert_contains "hotplug: VIA" "VIA=cli" "$HP"
assert_eq "hotplug: senders off, no request" 0 "$(curls)"

# ── Telegram ─────────────────────────────────────────────────────────────────

TG="config notify 'notify'
$BOT
config notify_telegram 'notify_telegram'
	option enabled '1'
	list events 'block_applied'
	list events 'cut_engaged'"
reset "$TG"
OUT=$(tctl notify emit block_applied ip=192.168.1.9 name=Pixel kind=internet via=telegram)
assert_contains "telegram: delivered" '"results":[{"sender":"notify_telegram","type":"telegram","ok":true,"msg":"sent"}]' "$OUT"
assert_eq "telegram: one request" 1 "$(curls)"
assert_eq "telegram: sendMessage with the bot's token" "https://api.telegram.org/bot$TOKEN/sendMessage" "$(cfgval 1 url)"
assert_not_contains "telegram: the token is not in curl's argv" "$TOKEN" "$(cat "$NLOG/curl.1.argv")"
assert_eq "telegram: the bot's chat" 285437102 "$(body 1 chat_id)"
assert_eq "telegram: HTML" HTML "$(body 1 parse_mode)"
assert_eq "telegram: the block message" "$(printf '🚫 <b>Internet blocked</b>\nPixel (192.168.1.9)\nVia: telegram')" "$(body 1 text)"
tctl notify emit cut_engaged duration=5400 persist=1 >/dev/null
assert_eq "telegram: the cut message" "$(printf '⛔ <b>Internet cut</b>\nAll devices, for 90 min, kept after reboot')" "$(body 2 text)"
tctl notify emit limit_applied ip=192.168.1.9 rate_kbit=5000 >/dev/null
assert_eq "telegram: an event it does not take is not sent" 2 "$(curls)"

printf '{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}' > "$NLOG/curl.reply"
OUT=$(tctl notify emit block_applied ip=192.168.1.9)
assert_contains "telegram: the API's error is the result" '"msg":"API error: Bad Request: chat not found"' "$OUT"
assert_contains "telegram: a failure goes to syslog" "block_applied via notify_telegram failed: API error" "$(cat "$NLOG/logger")"
rm -f "$NLOG/curl.reply"

reset "${TG/option enabled \'1\'
	list/option enabled \'0\'
	list}"
tctl notify emit block_applied ip=192.168.1.9 >/dev/null
assert_eq "telegram: a disabled sender sends nothing" 0 "$(curls)"
reset "${TG/config notify \'notify\'/config notify \'notify\'
	option enabled \'0\'}"
tctl notify emit block_applied ip=192.168.1.9 >/dev/null
assert_eq "telegram: notify.enabled 0 sends nothing" 0 "$(curls)"
reset "config notify 'notify'
config telegram 'telegram'
	option enabled '1'
config notify_telegram 'notify_telegram'
	list events 'block_applied'"
OUT=$(tctl notify emit block_applied ip=192.168.1.9)
assert_eq "telegram: no token, no request" 0 "$(curls)"
assert_contains "telegram: no token, not a subscriber" '"msg":"event sent"}' "$OUT"

# ── ntfy ─────────────────────────────────────────────────────────────────────

NTFY="config notify 'notify'
config notify_ntfy 'notify_ntfy'
	option server 'http://ntfy.lan:8080/'
	option topic 'home-router'
	option token 'tk_SECRETNTFY'
	option priority '4'"
reset "$NTFY"
OUT=$(tctl notify emit new_device mac=aa:bb:cc:dd:ee:ff ip=192.168.1.50 name=TV link=wifi)
assert_contains "ntfy: delivered" '"ok":true,"msg":"sent"' "$OUT"
assert_eq "ntfy: JSON publish to the server root" "http://ntfy.lan:8080/" "$(cfgval 1 url)"
assert_contains "ntfy: the access token as a bearer header" "Authorization: Bearer tk_SECRETNTFY" "$(cfgval 1 header)"
assert_not_contains "ntfy: the token is not in curl's argv" "SECRETNTFY" "$(cat "$NLOG/curl.1.argv")"
assert_eq "ntfy: topic" home-router "$(body 1 topic)"
assert_eq "ntfy: title" "OpenWrt: New device" "$(body 1 title)"
assert_eq "ntfy: plain text" "$(printf '🆕 New device\nTV (192.168.1.50)\nMAC: aa:bb:cc:dd:ee:ff\nLink: wifi')" "$(body 1 message)"
assert_eq "ntfy: priority" 4 "$(body 1 priority)"
assert_eq "ntfy: tag" '["new"]' "$(body 1 tags)"
printf 500 > "$NLOG/curl.code"
OUT=$(tctl notify emit new_device mac=aa:bb:cc:dd:ee:ff)
assert_contains "ntfy: an HTTP error is the result" '"ok":false,"msg":"HTTP 500"' "$OUT"
reset "${NTFY/home-router/home router}"
OUT=$(tctl notify emit new_device mac=aa:bb:cc:dd:ee:ff)
assert_contains "ntfy: an invalid topic is refused" '"msg":"invalid topic"' "$OUT"
assert_eq "ntfy: an invalid topic, no request" 0 "$(curls)"

# ── webhook ──────────────────────────────────────────────────────────────────

HOOK="config notify 'notify'
config notify_webhook 'notify_webhook'
	option url 'https://hooks.example.com/t/SECRETPATH'
	option auth 'Bearer SECRETHOOK'
	list events 'cut_engaged'"
reset "$HOOK"
TCTL_NOW=1780000000 tctl notify emit cut_engaged duration=0 persist=0 via=luci src=192.168.1.2 >/dev/null
assert_eq "webhook: the configured URL" "https://hooks.example.com/t/SECRETPATH" "$(cfgval 1 url)"
assert_not_contains "webhook: the URL is not in curl's argv" "SECRETPATH" "$(cat "$NLOG/curl.1.argv")"
assert_contains "webhook: the Authorization value" "Authorization: Bearer SECRETHOOK" "$(cfgval 1 header)"
assert_eq "webhook: event" cut_engaged "$(body 1 event)"
assert_eq "webhook: time" 1780000000 "$(body 1 time)"
assert_eq "webhook: router" OpenWrt "$(body 1 router)"
assert_eq "webhook: fields at the top level" 0 "$(body 1 duration)"
assert_eq "webhook: persist is a boolean" false "$(body 1 persist)"
assert_eq "webhook: src" 192.168.1.2 "$(body 1 src)"
assert_eq "webhook: text" "$(printf '⛔ Internet cut\nAll devices, until released\nVia: luci')" "$(body 1 text)"
reset "${HOOK/https:\/\/hooks.example.com\/t\/SECRETPATH/file:\/\/\/etc\/shadow}"
OUT=$(tctl notify emit cut_engaged)
assert_contains "webhook: only http(s) URLs" '"msg":"invalid URL"' "$OUT"
assert_eq "webhook: an invalid URL, no request" 0 "$(curls)"

# ── mail ─────────────────────────────────────────────────────────────────────

MAIL="config notify 'notify'
config notify_mail 'notify_mail'
	option to 'me@example.com, you@example.com'
	option from 'router@example.com'
	option account 'gmail'"
reset "$MAIL"
OUT=$(tctl notify emit block_applied ip=192.168.1.9 kind=wifi mac=aa:bb:cc:dd:ee:ff)
assert_contains "mail: no msmtp, said so" '"msg":"msmtp is not installed"' "$OUT"
msmtp_mock 0
TCTL_NOW=1780000000 tctl notify emit block_applied ip=192.168.1.9 kind=wifi mac=aa:bb:cc:dd:ee:ff >/dev/null
assert_eq "mail: msmtp argv" "--timeout=10 -a gmail -f router@example.com -- me@example.com you@example.com" "$(cat "$NLOG/msmtp.argv")"
M=$(cat "$NLOG/msmtp.stdin")
assert_contains "mail: To" "To: me@example.com, you@example.com" "$M"
assert_contains "mail: Subject" "Subject: OpenWrt: WiFi blocked" "$M"
assert_contains "mail: Date" "Date: Thu, 28 May 2026 20:26:40 +0000" "$M"
assert_contains "mail: plain-text body" "$(printf '📵 WiFi blocked\n192.168.1.9\nMAC: aa:bb:cc:dd:ee:ff')" "$M"
msmtp_mock 75
OUT=$(tctl notify emit block_applied ip=192.168.1.9)
assert_contains "mail: msmtp's exit status is the result" '"msg":"msmtp failed (exit 75)"' "$OUT"
reset "${MAIL/me@example.com, /x;id@example.com }"
msmtp_mock 0
OUT=$(tctl notify emit block_applied ip=192.168.1.9)
assert_contains "mail: an invalid recipient is refused" '"msg":"invalid recipient"' "$OUT"

# ── dispatch, and emit in the background ─────────────────────────────────────

reset "$HOOK"
OUT=$(tctl notify dispatch cut_engaged time=1700000000 duration=60)
assert_eq "dispatch: the results" '[{"sender":"notify_webhook","type":"webhook","ok":true,"msg":"sent"}]' "$OUT"
assert_eq "dispatch: the time it was given" 1700000000 "$(body 1 time)"
OUT=$(TCTL_NOTIFY_SYNC=0 tctl notify emit cut_engaged duration=60)
assert_eq "emit: returns before the sender runs" '{"ok":true,"msg":"event sent"}' "$OUT"
for _ in $(seq 50); do [ "$(curls)" = 2 ] && break; sleep 0.1; done
assert_eq "emit: the detached dispatch delivered" 2 "$(curls)"

# ── the device scan ──────────────────────────────────────────────────────────

SCAN="config notify 'notify'
$BOT
config notify_telegram 'notify_telegram'
	list events 'new_device'
	list events 'known_device'"
P8='192.168.1.88 dev br-lan lladdr e6:f8:0a:1b:2c:3d REACHABLE'
P8LEASE='1716811200 e6:f8:0a:1b:2c:3d 192.168.1.88 Pixel-8 01:e6:f8:0a:1b:2c:3d'
OTHER='[{"mac":"a2:b4:c6:d8:e0:12","name":"iPhone-Denis","ip":"192.168.1.45","first_seen":1716200000}]'

reset "$SCAN"
echo "$P8LEASE" > "$LEASES"; echo "$P8" > "$NLOG/neigh"; echo "$OTHER" > "$KNOWN"
OUT=$(TCTL_NOW=1780000000 tctl notify scan)
assert_eq "scan: one new device" '{"ok":true,"new":1,"online":0,"devices":1}' "$OUT"
assert_eq "scan: new device message" "$(printf '🆕 <b>New device</b>\nPixel-8 (192.168.1.88)\nMAC: <code>e6:f8:0a:1b:2c:3d</code>\nLink: ethernet')" "$(body 1 text)"
assert_eq "scan: the ledger gains it" "$OTHER
"'[{"mac":"a2:b4:c6:d8:e0:12","name":"iPhone-Denis","ip":"192.168.1.45","first_seen":1716200000},{"mac":"e6:f8:0a:1b:2c:3d","name":"Pixel-8","ip":"192.168.1.88","first_seen":1780000000}]' \
    "$OTHER
$(cat "$KNOWN")"
assert_eq "scan: the online list" e6:f8:0a:1b:2c:3d "$(cat "$ONLINE")"
tctl notify scan >/dev/null
assert_eq "scan: a device seen and still online is not repeated" 1 "$(curls)"
: > "$NLOG/neigh"; : > "$LEASES"
tctl notify scan >/dev/null
echo "$P8" > "$NLOG/neigh"; echo "$P8LEASE" > "$LEASES"
OUT=$(tctl notify scan)
assert_eq "scan: back online" '{"ok":true,"new":0,"online":1,"devices":1}' "$OUT"
assert_eq "scan: device online message" "$(printf '📱 <b>Device online</b>\nPixel-8 (192.168.1.88)\nLink: ethernet')" "$(body 2 text)"

# A WiFi station with no lease and no neighbour entry.
reset "$SCAN"
echo "$OTHER" > "$KNOWN"
echo 'Interface wlan0' > "$NLOG/iw.dev"; echo 'f2:04:16:28:3a:4c' > "$NLOG/iw.wlan0"
tctl notify scan >/dev/null
assert_eq "scan: a station seen only on WiFi" "$(printf '🆕 <b>New device</b>\nunknown (?)\nMAC: <code>f2:04:16:28:3a:4c</code>\nLink: wifi')" "$(body 1 text)"

# No ledger: the devices present are seeded, not announced.
reset "$SCAN"
echo "$P8LEASE" > "$LEASES"; echo "$P8" > "$NLOG/neigh"
OUT=$(tctl notify scan)
assert_eq "scan: no ledger, the present devices are seeded" '{"ok":true,"new":0,"online":0,"devices":1}' "$OUT"
assert_contains "scan: seeded" '"mac":"e6:f8:0a:1b:2c:3d"' "$(cat "$KNOWN")"
assert_eq "scan: seeding sends nothing" 0 "$(curls)"

# new_device not taken: the ledger still learns, nothing is sent.
reset "${SCAN/	list events \'new_device\'
/}"
echo "$P8LEASE" > "$LEASES"; echo "$P8" > "$NLOG/neigh"; echo "$OTHER" > "$KNOWN"
tctl notify scan >/dev/null
assert_eq "scan: new_device not subscribed, nothing sent" 0 "$(curls)"
assert_contains "scan: new_device not subscribed, still recorded" e6:f8:0a:1b:2c:3d "$(cat "$KNOWN")"

# The ledger entry is sanitised: the name comes from a DHCP client.
reset "$SCAN"
echo "$OTHER" > "$KNOWN"
tctl notify dhcp 'AA:BB:CC:DD:EE:FF' 192.168.1.66 'evil"};$(rm -rf /);{"' >/dev/null
L=$(cat "$KNOWN")
assert_contains "ledger: the MAC is lower-cased" '"mac":"aa:bb:cc:dd:ee:ff"' "$L"
assert_not_contains "ledger: no semicolon reaches disk" ";" "$L"
assert_not_contains "ledger: no dollar-paren reaches disk" '$(' "$L"
assert_not_contains "ledger: no slash reaches disk" "/" "$L"
assert_not_contains "ledger: no closing paren reaches disk" ")" "$L"
assert_eq "ledger: still JSON" ok "$(python3 -c 'import json,sys; json.load(open(sys.argv[1])); print("ok")' "$KNOWN" 2>&1)"
tctl notify dhcp 11:22:33:44:55:66 192.168.1.67 'My Phone' >/dev/null
assert_contains "ledger: spaces in a name are kept" '"name":"My Phone"' "$(cat "$KNOWN")"
assert_contains "dhcp: link is dhcp" 'Link: dhcp' "$(body 1 text)"
tctl notify dhcp aa:bb:cc:dd:ee:ff 192.168.1.66 x >/dev/null
assert_eq "dhcp: a known MAC is not announced again" 2 "$(curls)"
reset "config notify 'notify'"
echo "$OTHER" > "$KNOWN"
OUT=$(tctl notify dhcp aa:bb:cc:dd:ee:ff 192.168.1.66 x)
assert_eq "dhcp: nothing watching, the ledger is left alone" '{"ok":true,"msg":"not watching for devices"}' "$OUT"

# ── the new device template ──────────────────────────────────────────────────

ALLTAGS='{{name}}|{{ip}}|{{mac}}|{{link}}|{{date}}|{{time}}|{{datetime}}|{{router}}|{{ssid}}|{{signal}}|{{freq}}|{{iface}}|{{clients}}|{{uptime}}|{{wan_ip}}|{{load}}|{{conns}}|{{ name }}'
reset "config notify 'notify'
$BOT
config notify_telegram 'notify_telegram'
	list events 'new_device'
	list events 'known_device'
	option template '$ALLTAGS'"
mkdir -p "$UC_TMP/ubus-wan"
cp "$UC_REPO/tests/fixtures/router-24.10/ubus/network.interface.wan@status.json" "$UC_TMP/ubus-wan/"
unset TCTL_UBUS_SOCKET
ubus_start "$UC_TMP/ubus-wan"
WAN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ipv4-address"][0]["address"])' "$UC_TMP/ubus-wan/network.interface.wan@status.json")
printf 'src=192.168.1.92 dst=17.253.144.10 \nsrc=192.168.1.92 dst=8.8.8.8 \nsrc=192.168.1.92 dst=142.250.74.46 \nsrc=192.168.1.45 dst=8.8.8.8 \n' \
    > "$TCTL_ROOT/proc/net/nf_conntrack"
printf '%s\n' '1716811200 f2:04:16:28:3a:4c 192.168.1.92 iPad<Air> *' '1 a2:b4:c6:d8:e0:12 192.168.1.45 iPhone-Denis *' \
    '1 b6:78:9a:bc:de:f0 192.168.1.67 Galaxy *' '1 d4:e6:f8:0a:1b:2c 192.168.1.15 Vacuum *' > "$LEASES"
echo '190800.12 1000.00' > "$TCTL_ROOT/proc/uptime"
echo '0.12 0.30 0.25 1/90 1234' > "$TCTL_ROOT/proc/loadavg"
echo "$OTHER" > "$KNOWN"
echo 'Interface wlan0' > "$NLOG/iw.dev"; echo 'f2:04:16:28:3a:4c' > "$NLOG/iw.wlan0"
printf '\tssid MyHomeWiFi-5G\n\tchannel 36 (5180 MHz), width: 80 MHz, center1: 5210 MHz\n' > "$NLOG/iw.wlan0.info"
OUT=$(TCTL_NOW=1779892200 tctl notify dhcp f2:04:16:28:3a:4c 192.168.1.92 'iPad<Air>')
ubus_stop
export TCTL_UBUS_SOCKET="$UC_TMP/no-ubus.sock"
assert_eq "template: every variable" \
    "iPad&lt;Air&gt;|192.168.1.92|f2:04:16:28:3a:4c|dhcp|2026-05-27|14:30|2026-05-27 14:30|OpenWrt|MyHomeWiFi-5G|-42|5GHz|wlan0|4|2d 5h|$WAN|0.12|3|iPad&lt;Air&gt;" \
    "$(body 1 text)"
tctl notify dispatch known_device name=x >/dev/null
assert_eq "template: only for new_device" "$(printf '📱 <b>Device online</b>\nx (?)\nLink: ?')" "$(body 2 text)"

# ── settings: migration ──────────────────────────────────────────────────────

LEGACY="config telegram 'telegram'
	option enabled '1'
	option bot_token '$TOKEN'
	option chat_id '285437102'
	option notify_new_device '1'
	option notify_known_device '1'
	option notify_template '{{name}} joined'"
reset "$LEGACY"
OUT=$(tctl notify migrate)
assert_eq "migrate: done" '{"ok":true,"msg":"migrated"}' "$OUT"
assert_eq "migrate: notify on" 1 "$(uciget notify.enabled)"
assert_eq "migrate: scan auto" auto "$(uciget notify.scan)"
assert_eq "migrate: the sender keeps the bot's flag" 1 "$(uciget notify_telegram.enabled)"
assert_eq "migrate: and its events" "new_device known_device" "$(uciget notify_telegram.events)"
assert_eq "migrate: and its template" "{{name}} joined" "$(uciget notify_telegram.template)"
assert_eq "migrate: the old options are gone" "" "$(uciget telegram.notify_new_device)$(uciget telegram.notify_known_device)$(uciget telegram.notify_template)"
assert_eq "migrate: the token stays with the bot" "$TOKEN" "$(uciget telegram.bot_token)"
uci -c "$TCTL_ROOT/etc/config" set trafficctl.notify_telegram.enabled=0
uci -c "$TCTL_ROOT/etc/config" commit trafficctl
OUT=$(tctl notify migrate)
assert_eq "migrate: once" '{"ok":true,"msg":"nothing to migrate"}' "$OUT"
assert_eq "migrate: a second run changes nothing" 0 "$(uciget notify_telegram.enabled)"

reset "${LEGACY/enabled \'1\'/enabled \'0\'}"
tctl notify migrate >/dev/null
assert_eq "migrate: a bot that was off keeps notifications off" 0 "$(uciget notify_telegram.enabled)"
reset "config telegram 'telegram'
	option enabled '1'
	option notify_new_device '0'"
tctl notify migrate >/dev/null
assert_eq "migrate: no event was on, the sender is off" 0 "$(uciget notify_telegram.enabled)"
assert_eq "migrate: with the default event" new_device "$(uciget notify_telegram.events)"
reset "config telegram 'telegram'
	option enabled '1'"
tctl notify migrate >/dev/null
assert_eq "migrate: unset options meant new devices only" "1 new_device" "$(uciget notify_telegram.enabled) $(uciget notify_telegram.events)"

# Before the migration the bot's options act as the sender.
reset "$LEGACY"
tctl notify emit new_device mac=aa:bb:cc:dd:ee:ff ip=1.2.3.4 name=TV >/dev/null
assert_eq "legacy: the bot's options deliver before the migration" "TV joined" "$(body 1 text)"

# ── settings: when the scan runs ─────────────────────────────────────────────

reset "$(cat "$UC_REPO/trafficctl/files/etc/config/trafficctl")"
tctl notify wanted >/dev/null
assert_eq "wanted: the shipped config, no bot set up: no scan" 1 "$?"
uci -c "$TCTL_ROOT/etc/config" set trafficctl.telegram.bot_token="$TOKEN"
uci -c "$TCTL_ROOT/etc/config" set trafficctl.telegram.chat_id=1
uci -c "$TCTL_ROOT/etc/config" commit trafficctl
tctl notify wanted >/dev/null
assert_eq "wanted: the shipped config with a bot: new devices are watched" 0 "$?"
uci -c "$TCTL_ROOT/etc/config" set trafficctl.notify.scan=0; uci -c "$TCTL_ROOT/etc/config" commit trafficctl
tctl notify wanted >/dev/null
assert_eq "wanted: scan 0" 1 "$?"
reset "config notify 'notify'
	option scan '1'"
tctl notify wanted >/dev/null
assert_eq "wanted: scan 1 with no sender" 0 "$?"
reset "config notify 'notify'"
mkdir -p "$TCTL_ROOT/etc/hotplug.d/trafficctl"; : > "$TCTL_ROOT/etc/hotplug.d/trafficctl/10-x"
tctl notify wanted >/dev/null
assert_eq "wanted: a hotplug script wants the events" 0 "$?"
rm -rf "$TCTL_ROOT/etc/hotplug.d"
reset "config notify 'notify'
	option scan '1'
	option scan_interval '0'"
tctl notify wanted >/dev/null
assert_eq "wanted: interval 0 is off" 1 "$?"

# ── settings: the rpcd methods ───────────────────────────────────────────────

reset "config notify 'notify'
$BOT
config notify_telegram 'notify_telegram'
	list events 'new_device'"
OUT=$(rpc notify_config_get)
assert_contains "config_get: the senders" '"name":"notify_telegram","type":"telegram","legacy":false,"enabled":true,"events":["new_device"]' "$OUT"
assert_contains "config_get: the bot's token is never handed out" '"bot_token_set":true' "$OUT"
assert_not_contains "config_get: no token in the reply" "$TOKEN" "$OUT"
OUT=$(rpc notify_config_set '{"sender":"ntfy","enabled":true,"events":"block_applied cut_engaged","server":"https://ntfy.sh","topic":"t1","token":"tk_SECRET","priority":5}')
assert_eq "config_set: a new ntfy sender" '{"ok":true}' "$OUT"
assert_eq "config_set: its events" "block_applied cut_engaged" "$(uciget notify_ntfy.events)"
assert_eq "config_set: its token" tk_SECRET "$(uciget notify_ntfy.token)"
OUT=$(rpc notify_config_get)
assert_contains "config_get: the ntfy token masked" '"token":"***","token_set":true' "$OUT"
OUT=$(rpc notify_config_set '{"sender":"ntfy","enabled":true,"events":"block_applied","topic":"t2","token":"***","priority":0}')
assert_eq "config_set: the mask keeps the token" "tk_SECRET t2" "$(uciget notify_ntfy.token) $(uciget notify_ntfy.topic)"
assert_eq "config_set: priority 0 is the default" "" "$(uciget notify_ntfy.priority)"
CONF_BEFORE=$(cat "$TCTL_ROOT/etc/config/trafficctl")
OUT=$(rpc notify_config_set '{"sender":"ntfy","enabled":true,"topic":"a b"}')
assert_eq "config_set: an invalid topic" '{"ok":false,"msg":"invalid topic"}' "$OUT"
OUT=$(rpc notify_config_set '{"sender":"webhook","enabled":true,"auth":"x\r\nX-Evil: 1","url":"https://h.example/x"}')
assert_eq "config_set: a header with a line break" '{"ok":false,"msg":"invalid auth"}' "$OUT"
OUT=$(rpc notify_config_set '{"sender":"webhook","enabled":true}')
assert_eq "config_set: a webhook needs its URL" '{"ok":false,"msg":"webhook needs a URL"}' "$OUT"
OUT=$(rpc notify_config_set '{"sender":"mail","enabled":true,"to":"me@example.com"}')
assert_eq "config_set: mail needs msmtp" '{"ok":false,"msg":"mail needs msmtp (opkg install msmtp)"}' "$OUT"
OUT=$(rpc notify_config_set '{"sender":"ntfy","events":"block_applied reboot"}')
assert_eq "config_set: an unknown event" '{"ok":false,"msg":"invalid events"}' "$OUT"
OUT=$(rpc notify_config_set '{"sender":"main","enabled":true}')
assert_eq "config_set: not a sender section" '{"ok":false,"msg":"no such sender"}' "$OUT"
OUT=$(rpc notify_config_set '{"scan":"sometimes"}')
assert_eq "config_set: an invalid scan mode" '{"ok":false,"msg":"invalid scan"}' "$OUT"
OUT=$(rpc notify_config_set '{"scan_interval":5}')
assert_eq "config_set: an interval under 10 s" '{"ok":false,"msg":"invalid scan_interval"}' "$OUT"
assert_eq "config_set: a refused change writes nothing" "$CONF_BEFORE" "$(cat "$TCTL_ROOT/etc/config/trafficctl")"
OUT=$(rpc notify_config_set '{"enabled":false,"scan":"1","scan_interval":60}')
assert_eq "config_set: the globals" '{"ok":true} 0 1 60' "$OUT $(uciget notify.enabled) $(uciget notify.scan) $(uciget notify.scan_interval)"
OUT=$(rpc notify_config_set '{"sender":"telegram","enabled":true,"events":"new_device known_device","template":"{{name}}\\n{{ip}}"}')
assert_eq "config_set: the Telegram sender and its template" '{"ok":true} {{name}}\n{{ip}}' "$OUT $(uciget notify_telegram.template)"

# telegram_config_get/set read and write the sender once it exists.
OUT=$(rpc telegram_config_get)
assert_contains "telegram_config_get: notify_known_device from the sender" '"notify_known_device":true' "$OUT"
assert_contains "telegram_config_get: the template from the sender" '"notify_template":"{{name}}\\n{{ip}}"' "$OUT"
rpc telegram_config_set '{"bot_token":"***","notify_new_device":false,"notify_known_device":true}' >/dev/null
assert_eq "telegram_config_set: the events of the sender" known_device "$(uciget notify_telegram.events)"
assert_eq "telegram_config_set: nothing written back to the bot" "" "$(uciget telegram.notify_new_device)"

OUT=$(rpc notify_test '{"sender":"telegram"}')
assert_eq "notify_test: through the sender" '{"ok":true,"msg":"test message sent"}' "$OUT"
assert_contains "notify_test: the test text" "notifications work on OpenWrt" "$(body 1 text)"
OUT=$(rpc notify_test '{"sender":"nope"}')
assert_eq "notify_test: an unknown sender" '{"ok":false,"msg":"no such sender: nope"}' "$OUT"

# ── telegram-test ────────────────────────────────────────────────────────────

reset "$BOT"
tgt() { tctl telegram-test "$@" 2>/dev/null; }
assert_contains "telegram-test: special characters in the token" "invalid token format" "$(tgt '123456:ABC!@#' 999)"
assert_contains "telegram-test: no bot id" "invalid token format" "$(tgt ':ABCdef' 999)"
assert_contains "telegram-test: no colon" "invalid token format" "$(tgt '123456ABCdef' 999)"
assert_contains "telegram-test: shell in the token" "invalid token format" "$(tgt '123; rm -rf /' 999)"
assert_contains "telegram-test: letters in the chat" "chat_id must be numeric" "$(tgt '123456:ABCdef' abc123)"
assert_contains "telegram-test: shell in the chat" "chat_id must be numeric" "$(tgt '123456:ABCdef' '123;whoami')"
assert_contains "telegram-test: an empty token" "required" "$(tgt '' 999)"
assert_eq "telegram-test: refused before any request" 0 "$(curls)"
OUT=$(tgt '7104583920:AAF_x9k-Lm2NpQ3rS5tU7vW' '-100123456789')
assert_contains "telegram-test: a valid pair reaches the API" '"ok":true' "$OUT"
assert_eq "telegram-test: one request" 1 "$(curls)"
assert_not_contains "telegram-test: the token is not in curl's argv" "AAF_x9k" "$(cat "$NLOG/curl.1.argv")"
assert_contains "telegram-test: the token is on curl's stdin" "AAF_x9k" "$(cat "$NLOG/curl.1.cfg")"
OUT=$(TCTL_TG_TOKEN='999999:SECRETTOKENVALUE' tgt - 12345)
assert_not_contains "telegram-test: '-' reads the token from the environment" "invalid token" "$OUT"
assert_contains "telegram-test: that token is used" "SECRETTOKENVALUE" "$(cat "$NLOG/curl.2.cfg")"
OUT=$(tgt "$TOKEN" 1 'Hi {{ name }} on {{router}}')
assert_eq "telegram-test: a custom message gets the sample values" "Hi TestDevice on OpenWrt" "$(body 3 text)"

# ── the call sites ───────────────────────────────────────────────────────────
# Each event is raised by the code that does the action, shell or ucode. A
# port of that code that drops the call would lose the event silently, so the
# action code (not notify.uc, not comments) must still carry every call site.
ACT_SRC="$UC_REPO/trafficctl/files"
call_site() {   # call_site <name> <ERE>
    local hits f files=()
    for f in "$ACT_SRC"/usr/libexec/trafficctl/*.sh "$ACT_SRC"/usr/share/ucode/trafficctl/*.uc \
        "$ACT_SRC"/etc/hotplug.d/dhcp/99-trafficctl-newdevice; do
        [ "$(basename "$f")" = notify.uc ] || files+=("$f")
    done
    hits=$(grep -hE -- "$2" "${files[@]}" 2>/dev/null | grep -vE '^[[:space:]]*(#|//)')
    if [ -n "$hits" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: call site: %s\n  no line in the action code matches: %s\n" "$1" "$2"
    fi
}
call_site "an internet block raises block_applied" "block_applied.*internet"
call_site "a WiFi deny raises block_applied" "block_applied.*wifi"
call_site "a limiter raises limit_applied" "limit_applied.*limiter"
call_site "a shaper raises limit_applied" "limit_applied.*shaper"
call_site "an engaged cut raises cut_engaged" "cut_engaged"
call_site "a DHCP event reaches the device scan" "notify dhcp|notify\.dhcp\("
# The shell call sites through tctl_notify reach the CLI (TCTL_NOTIFY_CLI).
CALLS="$UC_TMP/notify_cli.log"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$CALLS" > "$MOCKBIN/notify-cli"
chmod +x "$MOCKBIN/notify-cli"
TCTL_NOTIFY_CLI="$MOCKBIN/notify-cli" TCTL_VIA=luci TCTL_SRC=192.168.1.2 \
    sh -c '. "$1"; tctl_notify block_applied ip=192.168.1.9 kind=internet' _ \
    "$ACT_SRC/usr/libexec/trafficctl/trafficctl-fw.sh" 2>/dev/null
assert_eq "tctl_notify: hands the event to notify emit with the caller" \
    "notify emit block_applied ip=192.168.1.9 kind=internet via=luci src=192.168.1.2" "$(cat "$CALLS" 2>/dev/null)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
