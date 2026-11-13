#!/bin/bash
# Tests for the optional netifyd (DPI) integration (`trafficctl netify`).
# Feeds recorded agent output via TCTL_NETIFY_FEED, and a socket served by a
# local process, and verifies the integration stays inert when netifyd is
# absent.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PASS=0
FAIL=0

TMPDIR="$UC_TMP/netify"
ROOT="$TMPDIR/root"
mkdir -p "$ROOT/etc/config" "$ROOT/tmp/.uci" "$ROOT/var/run/netifyd"
: > "$ROOT/etc/config/trafficctl"

CACHE="$ROOT/tmp/trafficctl_netify.json"
LOCK="$ROOT/tmp/trafficctl_netify.lock"

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected NOT to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}

main_config() {   # main_config <option value>...: the main section
    {
        printf "config trafficctl 'main'\n"
        while [ $# -gt 1 ]; do printf "\toption %s '%s'\n" "$1" "$2"; shift 2; done
    } > "$ROOT/etc/config/trafficctl"
}

# Recorded agent output: a flow that is later updated (same digest), a second
# app for the same device, a routed device, an unclassified flow, and a
# hostile host_server_name.
FEED="$TMPDIR/feed.jsonl"
cat > "$FEED" <<'EOF'
{"type":"agent_hello","version":"5.0.1"}
{"type":"flow","interface":"br-lan","flow":{"digest":"aaa111","local_ip":"192.168.1.50","other_ip":"45.57.0.1","detected_protocol_name":"TLS","detected_application_name":"netify.netflix","host_server_name":"www.netflix.com","total_bytes":1500}}
{"type":"flow_dpi_update","interface":"br-lan","flow":{"digest":"aaa111","local_ip":"192.168.1.50","other_ip":"45.57.0.1","detected_application_name":"netify.netflix","total_bytes":900000}}
{"type":"flow","interface":"br-lan","flow":{"digest":"bbb222","local_ip":"192.168.1.50","other_ip":"142.250.1.1","detected_protocol_name":"QUIC","detected_application_name":"netify.youtube","total_bytes":250000}}
{"type":"flow","interface":"br-lan","flow":{"digest":"ccc333","local_ip":"10.0.0.55","other_ip":"5.5.5.5","detected_protocol_name":"BitTorrent","detected_application_name":"","total_bytes":7000000}}
{"type":"flow","interface":"br-lan","flow":{"digest":"ddd444","local_ip":"10.0.0.55","other_ip":"9.9.9.9","detected_protocol_name":"Unknown","detected_application_name":"unknown","host_server_name":"evil\"host;rm -rf /","total_bytes":42}}
{"type":"agent_status","flows":1234}
EOF

run_netify() { TCTL_ROOT="$ROOT" tctl netify "$@" 2>/dev/null; }

# ── collect ──────────────────────────────────────────────────────────────────

OUT=$(TCTL_NETIFY_FEED="$FEED" run_netify collect 2)
assert_contains "collect: ok" '"ok":true' "$OUT"
assert_contains "collect: counted both devices" '"devices":2' "$OUT"

CACHED=$(cat "$CACHE")
assert_contains "cache: valid JSON" "VALID" \
    "$(python3 -c "import json,sys; json.load(sys.stdin); print('VALID')" < "$CACHE" 2>/dev/null)"

# The "netify." catalogue prefix is noise in a table.
assert_contains "parse: app prefix stripped" '"name":"netflix"' "$CACHED"
assert_not_contains "parse: no netify. prefix leaks" 'netify.netflix' "$CACHED"

# A flow re-emitted with growing counters must not be double-counted:
# 1500 then 900000 for digest aaa111 means 900000, not 901500.
assert_contains "parse: digest updates replace, not accumulate" '"bytes":900000' "$CACHED"
assert_not_contains "parse: no accumulated total" '901500' "$CACHED"

# Falls back to the protocol name when the application is unknown.
assert_contains "parse: protocol fallback for unnamed app" '"name":"BitTorrent"' "$CACHED"

# Highest-byte app becomes the device's headline label.
assert_contains "parse: top app for LAN device" '"ip":"192.168.1.50","top":"netflix"' "$CACHED"
assert_contains "parse: top app for routed device" '"ip":"10.0.0.55","top":"BitTorrent"' "$CACHED"

# Hostile hostnames must not break the JSON or reach the output verbatim.
assert_not_contains "sanitize: no injected quotes" 'evil"host' "$CACHED"
assert_not_contains "sanitize: no shell metacharacters" 'rm -rf /' "$CACHED"

# ── list ─────────────────────────────────────────────────────────────────────

OUT=$(run_netify list)
assert_contains "list: returns cached data" '"top":"netflix"' "$OUT"

# ── Agent v5 aggregator payload ──────────────────────────────────────────────
# Real shape from netify-sink-socket: one object holding a "stats" array, with
# "<id>.netify.<app>" names and separate download/upload counters.
FEED5="$TMPDIR/feed_v5.json"
cat > "$FEED5" <<'EOF'
{"log_time_end":1787138795,"log_time_start":1787138780,"stats":[{"application_id":"10472.netify.amazon-alexa","download":4230,"local_ip":"10.0.20.142","local_mac":"74:4d:28:c3:29:6c","packets":11,"protocol_id":196,"upload":1477},{"application_id":"11800.netify.claude","download":1357,"local_ip":"10.0.20.190","packets":4,"protocol_id":188,"upload":146},{"application_id":"10002.netify.github","download":196,"local_ip":"10.0.20.190","packets":2,"protocol_id":196,"upload":52},{"application_id":"10307.netify.qnap","download":83,"local_ip":"192.168.2.153","packets":3,"protocol_id":196,"upload":143}]}
EOF

rm -f "$CACHE"
OUT=$(TCTL_NETIFY_FEED="$FEED5" run_netify collect 2)
assert_contains "v5: collected" '"ok":true' "$OUT"
assert_contains "v5: every device in the stats array" '"devices":3' "$OUT"

CACHED=$(cat "$CACHE")
assert_contains "v5: valid JSON" "VALID" \
    "$(python3 -c "import json,sys; json.load(sys.stdin); print('VALID')" < "$CACHE" 2>/dev/null)"

# "<numeric id>.netify.<name>" must reduce to the bare app name.
assert_contains "v5: numeric id prefix stripped" '"name":"amazon-alexa"' "$CACHED"
assert_not_contains "v5: no raw application_id leaks" '10472' "$CACHED"

# bytes = download + upload (1357 + 146 = 1503, 196 + 52 = 248)
assert_contains "v5: download+upload summed" '"bytes":1503' "$CACHED"
assert_contains "v5: top app is the biggest by bytes" '"ip":"10.0.20.190","top":"claude"' "$CACHED"

# Routed devices must be represented, not just LAN ones.
assert_contains "v5: routed device present" '"ip":"10.0.20.142"' "$CACHED"

# ── graceful degradation ─────────────────────────────────────────────────────

OUT=$(run_netify status)
assert_contains "status: reports not installed" '"installed":false' "$OUT"
assert_contains "status: reports not running" '"running":false' "$OUT"
assert_contains "status: valid JSON" "VALID" \
    "$(printf '%s' "$OUT" | python3 -c "import json,sys; json.load(sys.stdin); print('VALID')" 2>/dev/null)"

# No socket and no feed: must fail soft, never hang or emit garbage.
OUT=$(run_netify collect 1)
assert_contains "collect: fails soft without netifyd" '"ok":false' "$OUT"

rm -f "$CACHE"
OUT=$(run_netify list)
assert_contains "list: empty array when no cache" '[]' "$OUT"

# Disabled by config → inert even if data is available.
main_config netify_enabled 0
OUT=$(TCTL_NETIFY_FEED="$FEED" run_netify collect 2)
assert_contains "collect: respects netify_enabled=0" 'disabled' "$OUT"
main_config

# ── one collector at a time ─────────────────────────────────────────────────
mkdir "$LOCK"
OUT=$(TCTL_NETIFY_FEED="$FEED" run_netify collect 2)
assert_contains "collect: a held lock refuses a second collector" 'collection already running' "$OUT"
# A collector killed mid-run left its lock behind, and the shell one never
# took such a lock over: every later collection failed until a reboot.
touch -d '2020-01-01' "$LOCK"
OUT=$(TCTL_NETIFY_FEED="$FEED" run_netify collect 2)
assert_contains "collect: a lock left by a dead collector is taken over" '"ok":true' "$OUT"
[ -e "$LOCK" ] && { FAIL=$((FAIL + 1)); echo "FAIL: collect: the lock is released"; } || PASS=$((PASS + 1))
OUT=$(run_netify collect 1)
[ -e "$LOCK" ] && { FAIL=$((FAIL + 1)); echo "FAIL: collect: the lock is released on failure too"; } || PASS=$((PASS + 1))

# ── the socket, read for a bounded time ─────────────────────────────────────
# The agent keeps the connection open, so the read only ends when its time is
# up: collect must come back after secs with what arrived, through either
# reader.
SOCK="$ROOT/var/run/netifyd/netifyd.sock"
python3 - "$SOCK" "$FEED5" <<'PY' &
import socket, sys, threading, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(4)
data = open(sys.argv[2], 'rb').read()
def serve(c):
    c.sendall(data)
    time.sleep(8)
    c.close()
while True:
    threading.Thread(target=serve, args=(s.accept()[0],), daemon=True).start()
PY
SERVER=$!
for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.1; done
rm -f "$CACHE"
for reader in socat nc; do
    command -v "$reader" >/dev/null || { FAIL=$((FAIL + 1)); echo "FAIL: $reader is required"; continue; }
    # Only this reader on PATH: the CLI prefers socat when both are there.
    mkdir -p "$TMPDIR/only-$reader"
    ln -sf "$(command -v "$reader")" "$TMPDIR/only-$reader/$reader"
    start=$(date +%s)
    OUT=$(PATH="$TMPDIR/only-$reader" TCTL_ROOT="$ROOT" "$UCODE" -S -L "$UC_LIB" -- \
        "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" netify collect 2 2>&1)
    took=$(( $(date +%s) - start ))
    assert_contains "socket ($reader): collected" '"ok":true,"msg":"collected 2s","devices":3' "$OUT"
    if [ "$took" -ge 1 ] && [ "$took" -le 5 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo "FAIL: socket ($reader): the read took ${took}s for a 2 s window"; fi
    STATUS=$(PATH="$TMPDIR/only-$reader" TCTL_ROOT="$ROOT" "$UCODE" -S -L "$UC_LIB" -- \
        "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" netify status 2>&1)
    assert_contains "status ($reader): running with a socket" '"running":true' "$STATUS"
    assert_contains "status ($reader): names the reader" "\"reader\":\"$reader\"" "$STATUS"
    # `raw 0`: a zero window still ends (v1.30.0's `timeout 0` stopped the
    # reader after about a second); no timeout would read until the agent
    # hangs up, 8 s here and never on a router.
    start=$(date +%s)
    OUT=$(PATH="$TMPDIR/only-$reader" TCTL_ROOT="$ROOT" "$UCODE" -S -L "$UC_LIB" -- \
        "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" netify raw 0 2>&1)
    took=$(( $(date +%s) - start ))
    if [ "$took" -le 4 ]; then PASS=$((PASS + 1)); else
        FAIL=$((FAIL + 1)); echo "FAIL: raw 0 ($reader): the read took ${took}s"; fi
    assert_contains "raw 0 ($reader): what arrived in that second" '10.0.20.190' "$OUT"
done
kill "$SERVER" 2>/dev/null
assert_contains "socket: the cache holds what the socket sent" '"ip":"10.0.20.190","top":"claude"' "$(cat "$CACHE" 2>/dev/null)"

# No reader at all: nothing to read with, said so rather than hanging.
mkdir -p "$TMPDIR/none"
OUT=$(PATH="$TMPDIR/none" TCTL_ROOT="$ROOT" "$UCODE" -S -L "$UC_LIB" -- \
    "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" netify status 2>&1)
assert_contains "status: no reader" '"reader":"none","readable":false' "$OUT"

# ── the endpoint ────────────────────────────────────────────────────────────
mkdir -p "$ROOT/etc/netifyd"
printf '{\n  "channels": { "default": { "bind_address": "tcp://127.0.0.1:1780", "enabled": true } }\n}\n' \
    > "$ROOT/etc/netifyd/netify-sink-socket.json"
OUT=$(run_netify status)
assert_contains "endpoint: the agent's socket sink" '"endpoint":"tcp://127.0.0.1:1780"' "$OUT"
main_config netify_endpoint 'unix:///tmp/other.sock'
OUT=$(run_netify status)
assert_contains "endpoint: the uci override wins" '"endpoint":"unix:///tmp/other.sock"' "$OUT"
main_config

# ── usage ───────────────────────────────────────────────────────────────────
TCTL_ROOT="$ROOT" tctl netify bogus > "$TMPDIR/out" 2>/dev/null
rc=$?
assert_contains "usage: unknown subcommand" '"msg":"usage: trafficctl-netify.sh status|collect [secs]|list|raw [secs]"' "$(cat "$TMPDIR/out")"
[ "$rc" = 1 ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: usage exits 1 (got $rc)"; }

# ── Results ──────────────────────────────────────────────────────────────────

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
