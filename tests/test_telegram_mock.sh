#!/bin/bash
# Level 2: Mock tests for Telegram bot — exercises the REAL functions in
# trafficctl-telegram.sh with external commands (curl, iw, uci, /proc) stubbed
# out, instead of running hand-copied reimplementations against synthetic
# input.
#
# The previous version of this file redefined format_new_device_msg,
# validate_ip_cb, validate_rate_param, route_command and the escaping logic
# as local shell functions and asserted against those copies — none of which
# exist under those names in trafficctl-telegram.sh, so a change (or removal)
# of the real logic was invisible here. IP/rate-param validation and JSON
# escaping are covered against the real handle_callback()/tg_json_escape() in
# test_telegram.sh; this file covers the parts that need the fuller mock
# environment (message formatting, keyboard builders, control-enabled gating).

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

BIN="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/libexec/trafficctl"
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
    if echo "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to contain: '%s'\n  actual: '%s'\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

# ── mock environment ────────────────────────────────────────────────────────

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$*" in
    *"system.@system"*"hostname"*) echo "OpenWrt" ;;
    *) echo "" ;;
esac
MOCK
chmod +x "$MOCKBIN/uci"

# No wifi devices — get_wifi_info()/get_hostapd_ifaces() degrade to empty.
cat > "$MOCKBIN/iw" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/iw"

CURL_LOG="$TMPDIR/curl.log"
cat > "$MOCKBIN/curl" <<MOCK
#!/bin/sh
echo "\$@" >> "$CURL_LOG"
cat > /dev/null
echo '{"ok":true,"result":{"message_id":1}}'
MOCK
chmod +x "$MOCKBIN/curl"

# jsonfilter mock: extract the value for the trailing path key from stdin.
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
expr="$2"
key=$(printf '%s' "$expr" | sed "s/.*\.//;s/\[.*//;s/=.*//")
input=$(cat)
if [ "$expr" = "@[*].ip" ]; then
    printf '%s' "$input" | grep -o '"ip":"[^"]*"' | sed 's/.*:"//;s/"$//'
    exit 0
fi
val=$(printf '%s' "$input" | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p")
if [ -n "$val" ]; then printf '%s' "$val"; exit 0; fi
printf '%s' "$input" | sed -n "s/.*\"$key\":\([A-Za-z0-9_.-]*\).*/\1/p"
MOCK
chmod +x "$MOCKBIN/jsonfilter"

cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/ip"

# Fake /proc + /tmp state that get_router_vars()/get_device_conns() read.
mkdir -p "$TMPDIR/proc" "$TMPDIR/tmp"
echo "3661.00 7200.00" > "$TMPDIR/proc/uptime"
echo "0.50 0.30 0.10 1/100 12345" > "$TMPDIR/proc/loadavg"
echo "OpenWrt" > "$TMPDIR/proc/hostname"
: > "$TMPDIR/proc/nf_conntrack"
: > "$TMPDIR/tmp/dhcp.leases"

mkdir -p "$TMPDIR/lib/functions"
cat > "$TMPDIR/lib/functions.sh" <<'MOCK'
config_load() { :; }
config_get() { eval "$2=\"\${4:-}\""; }
MOCK
cat > "$TMPDIR/lib/functions/network.sh" <<'MOCK'
network_get_ipaddr() { eval "$1='1.2.3.4'"; }
MOCK

# Real script, with only its literal absolute source/data paths redirected
# into the temp dir and the trailing main() call neutered so sourcing it
# never enters the poll loop. Every function body is untouched.
NEUTERED="$TMPDIR/telegram_neutered.sh"
sed \
    -e "s|\. /lib/functions\.sh|. $TMPDIR/lib/functions.sh|" \
    -e "s|/lib/functions/network\.sh|$TMPDIR/lib/functions/network.sh|" \
    -e "s|/proc/uptime|$TMPDIR/proc/uptime|" \
    -e "s|/proc/loadavg|$TMPDIR/proc/loadavg|" \
    -e "s|/proc/sys/kernel/hostname|$TMPDIR/proc/hostname|" \
    -e "s|/proc/net/nf_conntrack|$TMPDIR/proc/nf_conntrack|" \
    -e "s|/tmp/dhcp\.leases|$TMPDIR/tmp/dhcp.leases|g" \
    -e '$s|^main$|:|' \
    "$BIN/trafficctl-telegram.sh" > "$NEUTERED"

tail -1 "$NEUTERED" | grep -q '^main$' && {
    echo "FAIL: harness bug — could not neuter main(), refusing to run"
    exit 1
}

run() {
    PATH="$MOCKBIN:$PATH" sh -c ". '$NEUTERED'; $1"
}

# ── format_new_device_msg: default template (real function) ────────────────

test_format_default() {
    local result
    result=$(run "format_new_device_msg 'MacBook' '192.168.0.50' 'aa:bb:cc:dd:ee:ff' '5G'")
    assert_contains "default msg has name" "MacBook" "$result"
    assert_contains "default msg has IP" "192.168.0.50" "$result"
    assert_contains "default msg has MAC" "aa:bb:cc:dd:ee:ff" "$result"
    assert_contains "default msg has link" "5G" "$result"
    assert_contains "default msg has emoji" "🆕" "$result"
    assert_contains "default msg has HTML bold" "<b>" "$result"
}

# ── format_new_device_msg: custom template (real function + real helpers) ──
# Exercises get_router_vars, get_wifi_info and get_device_conns for real —
# the previous version faked format_new_device_msg's body with its own awk
# gsub script and never called any of those.

test_format_custom() {
    local result
    result=$(run "
        TG_NOTIFY_TEMPLATE='{{name}} joined at {{time}} via {{link}} (clients={{clients}}, wan={{wan_ip}})'
        format_new_device_msg 'iPhone' '192.168.0.99' '11:22:33:44:55:66' 'wifi'
    ")
    assert_contains "custom template: name substituted" "iPhone" "$result"
    assert_contains "custom template: link substituted" "wifi" "$result"
    assert_contains "custom template: clients count substituted (fake dhcp.leases is empty)" "clients=" "$result"
    assert_not_contains "custom template: clients placeholder actually resolved, not left literal" "{{clients}}" "$result"
    assert_contains "custom template: wan_ip from real network_get_ipaddr stub" "wan=1.2.3.4" "$result"
    assert_not_contains "custom template: unresolved placeholder left behind" "{{" "$result"
}

# ── build_device_keyboard / build_action_keyboard (real functions) ─────────

test_keyboard_structure() {
    local devices='[{"ip":"192.168.0.1","name":"Router-Client","blocked":false,"wifi_blocked":false,"rate_limit_kbit":0,"shape_kbit":0,"conn_type":"ethernet"}]'
    local kb
    kb=$(run "build_device_keyboard '$devices'")
    assert_contains "device kb has inline_keyboard" "inline_keyboard" "$kb"
    assert_contains "device kb has menu action for the device" "act:menu:192.168.0.1" "$kb"

    local akb
    akb=$(run "build_action_keyboard '192.168.0.1' '$devices'")
    assert_contains "action kb has block action" "act:block:192.168.0.1" "$akb"
    assert_contains "action kb has back" "act:back" "$akb"
    assert_contains "action kb has limiter presets" "act:limit:192.168.0.1:1000" "$akb"

    # Blocked device gets the unblock button instead, not both.
    local blocked_devices='[{"ip":"192.168.0.1","name":"x","blocked":true,"wifi_blocked":false,"rate_limit_kbit":0,"shape_kbit":0,"conn_type":"ethernet"}]'
    local bkb
    bkb=$(run "build_action_keyboard '192.168.0.1' '$blocked_devices'")
    assert_contains "blocked device: unblock button present" "act:unblock:192.168.0.1" "$bkb"
    assert_not_contains "blocked device: block button absent" "act:block:192.168.0.1" "$bkb"

    # A split ceiling names both figures on its Remove button (#66).
    local split_devices='[{"ip":"192.168.0.1","name":"x","blocked":false,"wifi_blocked":false,"rate_limit_kbit":8000,"rate_limit_kbit_up":2000,"shape_kbit":0,"shape_kbit_up":0,"conn_type":"ethernet"}]'
    local skb
    skb=$(run "build_action_keyboard '192.168.0.1' '$split_devices'")
    assert_contains "split limit: both figures on the Remove button" "Limit: 8000↓ / 2000↑ kbit/s — Remove" "$skb"
    local sym_devices='[{"ip":"192.168.0.1","name":"x","blocked":false,"wifi_blocked":false,"rate_limit_kbit":8000,"rate_limit_kbit_up":8000,"shape_kbit":0,"shape_kbit_up":0,"conn_type":"ethernet"}]'
    skb=$(run "build_action_keyboard '192.168.0.1' '$sym_devices'")
    assert_contains "symmetric limit: one figure" "Limit: 8000 kbit/s — Remove" "$skb"
    assert_eq "short form, split" "8000/2000k" "$(run "tg_ceiling_short 8000 2000")"
    assert_eq "short form, no upload figure" "8000k" "$(run "tg_ceiling_short 8000 0")"
}

# ── control_enabled gating on the REAL handlers ─────────────────────────────
# TG_CONTROL is read directly by handle_help() and handle_callback(); this
# used to be faked as a standalone handle_callback_guard().

test_control_guard() {
    : > "$CURL_LOG"
    run "TG_CONTROL=0; handle_help"
    assert_contains "help: control disabled shows notifications-only text" \
        "notifications only" "$(cat "$CURL_LOG" | tr -d '\n')"

    : > "$CURL_LOG"
    run "TG_CONTROL=1; handle_help"
    OUTPUT=$(cat "$CURL_LOG" | tr -d '\n')
    assert_not_contains "help: control enabled omits notifications-only text" \
        "notifications only" "$OUTPUT"

    : > "$CURL_LOG"
    run "TG_CONTROL=0; SCRIPTS='$MOCKBIN'; handle_callback cbid1 'act:block:192.168.0.1' msg1"
    assert_contains "callback: control disabled blocks the action" \
        "Control disabled" "$(cat "$CURL_LOG")"
}

# ── Run all tests ────────────────────────────────────────────────────────────

test_format_default
test_format_custom
test_keyboard_structure
test_control_guard

# NOTE: command routing (the `/start*|/help*) handle_help ;; ...` case
# statement) lives inline inside main()'s poll loop, not in a standalone
# function — reaching it directly would require driving the real getUpdates
# loop, which is heroics for a unit test (see harness notes). Each handler it
# dispatches TO (handle_help, handle_devices, handle_status) is exercised
# directly above and in test_telegram.sh instead.

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
