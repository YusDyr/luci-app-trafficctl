#!/bin/bash
# Port-forward / open-port traffic control: `trafficctl portfw`
# (trafficctl/files/usr/share/ucode/trafficctl/portfw.uc), run by the ucode CLI
# against a scratch TCTL_ROOT. nft and conntrack are tests/lib/netfake.sh, so
# a pause is a rule that lists back and a resume has to find it again.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

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

ROOT="$UC_TMP/root"
MOCKBIN="$UC_TMP/bin"
UBUSDIR="$UC_TMP/ubus"
export NETFAKE="$UC_TMP/net"
mkdir -p "$MOCKBIN" "$UBUSDIR" "$NETFAKE" "$ROOT/etc/config" "$ROOT/proc/net" "$ROOT/tmp/.uci"

for t in nft conntrack; do
    printf '#!/bin/sh\nexec sh "%s" %s "$@"\n' "$UC_TESTLIB/netfake.sh" "$t" > "$MOCKBIN/$t"
done
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/ip"
chmod +x "$MOCKBIN"/*

cat > "$UBUSDIR/network.interface@dump.json" <<'JSON'
{"interface":[
 {"interface":"lan","up":true,"device":"br-lan","l3_device":"br-lan","ipv4-address":[{"address":"192.168.0.1","mask":24}]},
 {"interface":"wan","up":true,"device":"eth1","l3_device":"eth1","ipv4-address":[{"address":"198.51.100.1","mask":24}]}
]}
JSON
ubus_start "$UBUSDIR"

cat > "$ROOT/etc/config/firewall" <<'UCI'
config zone
	option name 'lan'
	option network 'lan'

config zone
	option name 'wan'
	option network 'wan'

config redirect
	option name 'Web Server'
	option src 'wan'
	option src_dport '8080'
	option dest_ip '192.168.0.10'
	option dest_port '80'
	option proto 'tcp'

config redirect
	option name 'Game'
	option src 'wan'
	option src_dport '27015'
	option dest_ip '192.168.0.20'

config redirect
	option target 'SNAT'
	option src_dport '9999'
	option dest_ip '192.168.0.30'

config redirect
	option name 'Alt web'
	option src 'wan'
	option src_dport '8081'
	option dest_ip '192.168.0.10'
	option dest_port '8080'
	option proto 'tcp'

config rule
	option name 'WireGuard'
	option src 'wan'
	option dest_port '51820'
	option proto 'udp'
	option target 'ACCEPT'

config rule
	option name 'LAN thing'
	option src 'lan'
	option dest_port '22'
	option target 'ACCEPT'

config rule
	option name 'Zone fwd'
	option src 'wan'
	option dest 'lan'
	option dest_port '443'
	option target 'ACCEPT'
UCI
write_trafficctl() {   # write_trafficctl <persist_rules>
    printf "config trafficctl 'main'\n\toption persist_rules '%s'\n\nconfig logging 'logging'\n\toption enabled '0'\n" \
        "$1" > "$ROOT/etc/config/trafficctl"
}
write_trafficctl 0

cat > "$ROOT/proc/net/nf_conntrack" <<'EOF'
ipv4     2 tcp      6 431999 ESTABLISHED src=203.0.113.50 dst=198.51.100.1 sport=555 dport=8080 packets=10 bytes=1000 src=192.168.0.10 dst=203.0.113.50 sport=80 dport=555 packets=8 bytes=2000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 431999 ESTABLISHED src=203.0.113.60 dst=198.51.100.1 sport=666 dport=8080 packets=3 bytes=500 src=192.168.0.10 dst=203.0.113.60 sport=80 dport=666 packets=4 bytes=700 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.0.99 dst=192.168.0.10 sport=777 dport=80 packets=2 bytes=9999 src=192.168.0.10 dst=192.168.0.99 sport=80 dport=777 packets=2 bytes=9999 [ASSURED] mark=0 use=1
ipv4     2 udp      17 30 src=203.0.113.70 dst=198.51.100.1 sport=333 dport=51820 packets=1 bytes=400 src=198.51.100.1 dst=203.0.113.70 sport=51820 dport=333 packets=1 bytes=300 mark=0 use=1
ipv4     2 udp      17 30 src=192.168.0.55 dst=198.51.100.1 sport=444 dport=51820 packets=1 bytes=7777 src=198.51.100.1 dst=192.168.0.55 sport=51820 dport=444 packets=1 bytes=7777 mark=0 use=1
EOF

run_portfw() {
    TCTL_ROOT="$ROOT" PATH="$MOCKBIN:$PATH" tctl portfw "$@" 2>/dev/null
}
calls() { cat "$NETFAKE/calls" 2>/dev/null; }
reset_net() {
    rm -rf "$NETFAKE"
    mkdir -p "$NETFAKE"
    : > "$NETFAKE/calls"
}
# Rules as nft lists them, the way trafficctl-portfw.sh v1.30.0 wrote them.
seed() {   # seed <chain> <rule>...
    local chain="$1"
    shift
    [ -f "$NETFAKE/tctl_pfw" ] || PATH="$MOCKBIN:$PATH" nft add table inet tctl_pfw
    [ -f "$NETFAKE/pfw.$chain" ] || PATH="$MOCKBIN:$PATH" nft add chain inet tctl_pfw "$chain" x
    for r in "$@"; do
        # shellcheck disable=SC2086
        PATH="$MOCKBIN:$PATH" sh -c "nft add rule inet tctl_pfw $chain $r"
    done
    : > "$NETFAKE/calls"
}
entry() {   # entry <json array> <name>: that entry's object
    printf '%s' "$1" | sed 's/},{/}\n{/g' | grep -F "\"name\":\"$2\""
}

# ── list ─────────────────────────────────────────────────────────────────────

reset_net
seed pfw_forward \
    "ip daddr 192.168.0.10 tcp dport 80 counter drop comment '\"tctl_pfw_pause_tcp_192.168.0.10_80\"'" \
    "ip daddr 192.168.0.20 udp dport 27015 limit rate over 625000 bytes/second counter drop comment '\"tctl_pfw_limit_udp_192.168.0.20_27015\"'"
OUT=$(run_portfw list)

assert_contains "list: forward entry with name" '"name":"Web Server"' "$OUT"
assert_contains "list: forward dest ip/port" '"ip":"192.168.0.10","port":"80"' "$OUT"
assert_contains "list: forward ext port" '"ext_port":"8080"' "$OUT"
assert_contains "list: dest_port defaults to src_dport" '"ip":"192.168.0.20","port":"27015"' "$OUT"
assert_contains "list: proto defaults to tcp udp" '"proto":"tcp udp"' "$OUT"
assert_contains "list: open port entry" '"name":"WireGuard"' "$OUT"
assert_contains "list: open port kind" '"kind":"open"' "$OUT"
assert_not_contains "list: SNAT redirect skipped" '192.168.0.30' "$OUT"
assert_not_contains "list: lan-zone rule skipped" 'LAN thing' "$OUT"
assert_not_contains "list: zone-forward rule skipped" 'Zone fwd' "$OUT"
assert_eq "list: the whole first entry keeps v1.30's keys and order" \
    '{"id":"r0","kind":"forward","name":"Web Server","zone":"wan","proto":"tcp","ext_port":"8080","ip":"192.168.0.10","port":"80","enabled":true,"paused":true,"limit_kbit":0,"conns":2,"clients":2,"bytes_in":1500,"bytes_out":2700}' \
    "$(entry "$OUT" 'Web Server' | sed 's/^\[//; s/,$//')"

# stats: two external clients on the web forward, LAN-direct excluded
WEB=$(entry "$OUT" 'Web Server')
assert_contains "list: web forward conns=2" '"conns":2' "$WEB"
assert_contains "list: web forward clients=2" '"clients":2' "$WEB"
assert_contains "list: web forward bytes_in" '"bytes_in":1500' "$WEB"
assert_contains "list: web forward bytes_out" '"bytes_out":2700' "$WEB"
assert_not_contains "list: LAN-direct flow not counted" '9999' "$OUT"

# open port stats: the LAN client talking to the router's WAN address is not
# inbound traffic
WG=$(entry "$OUT" 'WireGuard')
assert_contains "list: wireguard bytes_in" '"bytes_in":400' "$WG"
assert_contains "list: wireguard counts one client, not the LAN one" '"clients":1' "$WG"

# control state from the live table
assert_contains "list: web forward paused" '"paused":true' "$WEB"
assert_contains "list: game forward limited to 5000 kbit" '"limit_kbit":5000' "$(entry "$OUT" 'Game')"

# GUARD: state is matched on the whole comment. v1.30 grepped for the
# comment as a substring, so pausing port 8080 also showed port 80... and
# the other way round here: 192.168.0.10 port 80 is paused, 8080 is not.
assert_contains "list: a paused port 80 does not make port 8080 read as paused" '"paused":false' \
    "$(entry "$OUT" 'Alt web')"

reset_net
seed pfw_forward "ip daddr 192.168.0.10 tcp dport 8080 counter drop comment '\"tctl_pfw_pause_tcp_192.168.0.10_8080\"'"
OUT=$(run_portfw list)
assert_contains "list: ...nor does a paused 8080 make port 80 read as paused" '"paused":false' \
    "$(entry "$OUT" 'Web Server')"

# nft lists a whole number of kbytes (1024) in that unit; 1024000 bytes/s is
# 8192 kbit/s, not 8000.
reset_net
seed pfw_forward "ip daddr 192.168.0.20 udp dport 27015 limit rate over 1000 kbytes/second counter drop comment '\"tctl_pfw_limit_udp_192.168.0.20_27015\"'"
assert_contains "list: a limit listed in kbytes converts as 1024 bytes" '"limit_kbit":8192' \
    "$(entry "$(run_portfw list)" 'Game')"

# No table at all is the normal state of a router nobody paused anything on.
reset_net
OUT=$(run_portfw list)
assert_contains "list: no table reads as nothing paused" '"paused":false,"limit_kbit":0' "$(entry "$OUT" 'Web Server')"

# ── pause ────────────────────────────────────────────────────────────────────

reset_net
OUT=$(run_portfw pause forward tcp 192.168.0.10 80)
assert_contains "pause: ok" '"ok":true' "$OUT"
assert_contains "pause: the reply" '{"ok":true,"msg":"paused tcp port 80"}' "$OUT"
NFT_CALLS=$(calls)
assert_contains "pause: creates the table" 'nft add table inet tctl_pfw' "$NFT_CALLS"
assert_contains "pause: its forward chain at -190" \
    'nft add chain inet tctl_pfw pfw_forward { type filter hook forward priority -190; policy accept; }' "$NFT_CALLS"
assert_contains "pause: inserts drop rule" \
    'insert rule inet tctl_pfw pfw_forward ip daddr 192.168.0.10 tcp dport 80 counter drop comment "tctl_pfw_pause_tcp_192.168.0.10_80"' "$NFT_CALLS"
assert_contains "pause: flushes the forward's connections" 'conntrack -D -p tcp --reply-src 192.168.0.10' "$NFT_CALLS"
assert_contains "pause: list reads it back" '"paused":true' "$(entry "$(run_portfw list)" 'Web Server')"

# Pausing twice leaves one rule, not two.
run_portfw pause forward tcp 192.168.0.10 80 >/dev/null
assert_eq "pause: a second pause replaces the rule" 1 "$(grep -c 'tctl_pfw_pause_tcp_192.168.0.10_80' "$NETFAKE/pfw.pfw_forward")"

OUT=$(run_portfw resume forward tcp 192.168.0.10 80)
assert_contains "resume: ok" '{"ok":true,"msg":"resumed tcp port 80"}' "$OUT"
assert_eq "resume: the rule is gone" 0 "$(grep -c . "$NETFAKE/pfw.pfw_forward")"
assert_contains "resume: list reads it as running" '"paused":false' "$(entry "$(run_portfw list)" 'Web Server')"

# GUARD: an open port's rules are commented `local`. v1.30 wrote the `-` it
# was handed (`tctl_pfw_pause_udp_-_51820`) and then looked for `local`, so a
# paused open port read as running and could never be resumed.
reset_net
OUT=$(run_portfw pause input udp - 51820)
assert_contains "pause input: ok" '"ok":true' "$OUT"
NFT_CALLS=$(calls)
assert_contains "pause input: rule in input chain without daddr" \
    'insert rule inet tctl_pfw pfw_input udp dport 51820 counter drop comment "tctl_pfw_pause_udp_local_51820"' "$NFT_CALLS"
assert_contains "pause input: flushes by destination port" 'conntrack -D -p udp --dport 51820' "$NFT_CALLS"
assert_contains "pause input: list reads it as paused" '"paused":true' "$(entry "$(run_portfw list)" 'WireGuard')"
run_portfw resume input udp - 51820 >/dev/null
assert_eq "resume input: the rule is gone" 0 "$(grep -c . "$NETFAKE/pfw.pfw_input")"

# A pause v1.30 left behind under `-` reads as paused and is resumable.
reset_net
seed pfw_input "udp dport 51820 counter drop comment '\"tctl_pfw_pause_udp_-_51820\"'"
assert_contains "v1.30 input pause: reads as paused" '"paused":true' "$(entry "$(run_portfw list)" 'WireGuard')"
run_portfw resume input udp - 51820 >/dev/null
assert_eq "v1.30 input pause: resume removes it" 0 "$(grep -c . "$NETFAKE/pfw.pfw_input")"

# tcpudp expands to both protocols
reset_net
run_portfw pause forward tcpudp 192.168.0.20 27015 >/dev/null
NFT_CALLS=$(calls)
assert_contains "pause tcpudp: tcp rule" 'tcp dport 27015' "$NFT_CALLS"
assert_contains "pause tcpudp: udp rule" 'udp dport 27015' "$NFT_CALLS"

# A port range on an open port flushes each port, up to 64 of them.
reset_net
run_portfw pause input tcp - 1000-1002 >/dev/null
assert_eq "pause range: one conntrack delete per port" 3 "$(grep -c 'conntrack -D -p tcp --dport 100[0-2]$' "$NETFAKE/calls")"

reset_net
: > "$NETFAKE/fail_rule"
OUT=$(run_portfw pause forward tcp 192.168.0.10 80)
assert_contains "pause: a rule nft refuses is reported" '{"ok":false,"msg":"failed to pause tcp port 80"}' "$OUT"

# ── limit ────────────────────────────────────────────────────────────────────

reset_net
OUT=$(run_portfw limit forward tcp 192.168.0.10 80 8000)
assert_contains "limit: ok" '{"ok":true,"msg":"limit 8000 kbit/s set for port 80"}' "$OUT"
assert_contains "limit: rate-over drop rule (8000 kbit = 1000000 bytes)" \
    'add rule inet tctl_pfw pfw_forward ip daddr 192.168.0.10 tcp dport 80 limit rate over 1000000 bytes/second counter drop comment "tctl_pfw_limit_tcp_192.168.0.10_80"' "$(calls)"
assert_contains "limit: list reads it back" '"limit_kbit":8000' "$(entry "$(run_portfw list)" 'Web Server')"

OUT=$(run_portfw limit forward tcp 192.168.0.10 80 0)
assert_contains "limit 0: removes" '{"ok":true,"msg":"limit removed for port 80"}' "$OUT"
assert_eq "limit 0: the rule is gone" 0 "$(grep -c . "$NETFAKE/pfw.pfw_forward")"

reset_net
run_portfw limit input udp - 51820 800 >/dev/null
assert_contains "limit input: commented local" 'comment "tctl_pfw_limit_udp_local_51820"' "$(calls)"
assert_contains "limit input: list reads it" '"limit_kbit":800' "$(entry "$(run_portfw list)" 'WireGuard')"

# "08" is all digits, but shell arithmetic reads it as (invalid) octal.
for bad in 08 0800 999999999999 100000001 abc ''; do
    reset_net
    OUT=$(run_portfw limit forward tcp 192.168.0.10 80 "$bad")
    assert_contains "limit '$bad': rejected" '{"ok":false,"msg":"invalid rate"}' "$OUT"
    assert_not_contains "limit '$bad': no rule written" 'limit rate over' "$(calls)"
done

# ── persistence (persist_rules) ──────────────────────────────────────────────

RULES="$ROOT/etc/trafficctl/rules.json"
reset_net
run_portfw pause forward tcp 192.168.0.10 80 >/dev/null
assert_eq "persist off: nothing saved" no "$([ -f "$RULES" ] && echo yes || echo no)"

write_trafficctl 1
mkdir -p "$(dirname "$RULES")"
echo '[{"type":"block","ip":"192.168.0.5","param":""}]' > "$RULES"
run_portfw pause input udp - 51820 >/dev/null
run_portfw limit forward tcp 192.168.0.10 80 8000 >/dev/null
assert_eq "persist: records keep v1.30's key, the other rules stay" \
    '[{"type":"block","ip":"192.168.0.5","param":""},{"type":"pfw_pause","ip":"input/udp/local/51820","param":"1"},{"type":"pfw_limit","ip":"forward/tcp/192.168.0.10/80","param":"8000"}]' \
    "$(cat "$RULES")"
run_portfw resume input udp - 51820 >/dev/null
run_portfw limit forward tcp 192.168.0.10 80 0 >/dev/null
assert_eq "persist: resume and limit 0 drop their records only" \
    '[{"type":"block","ip":"192.168.0.5","param":""}]' "$(cat "$RULES")"

# ── restore after a reboot (`trafficctl restore` runs portfw.restore) ────────
# Every record comes back once. v1.30.0's hook walked rules.json by index
# while each restored record moved itself to the end of the file, so with
# three records it applied one twice and skipped another.
LOGGER_LOG="$UC_TMP/logger.log"
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$LOGGER_LOG" > "$MOCKBIN/logger"
chmod +x "$MOCKBIN/logger"
restore() { TCTL_ROOT="$ROOT" PATH="$MOCKBIN:$PATH" tcall trafficctl.portfw restore 2>/dev/null; }
pfw_table() { PATH="$MOCKBIN:$PATH" nft list table inet tctl_pfw 2>/dev/null; }
reset_net
printf '%s' '[{"type":"pfw_pause","ip":"forward/tcp/192.168.0.10/80","param":"1"},{"type":"pfw_limit","ip":"forward/udp/192.168.0.11/27015-27030","param":"8000"},{"type":"pfw_pause","ip":"input/udp/local/51820","param":"1"}]' > "$RULES"
assert_eq "restore: all three records" '{ "ok": true, "restored": 3, "failed": 0 }' "$(restore)"
T=$(pfw_table)
for c in tctl_pfw_pause_tcp_192.168.0.10_80 tctl_pfw_limit_udp_192.168.0.11_27015-27030 tctl_pfw_pause_udp_local_51820; do
    assert_eq "restore: $c once" 1 "$(printf '%s\n' "$T" | grep -c "\"$c\"")"
done
reset_net
printf '%s' '[{"type":"pfw_limit","ip":"forward/tcp/192.168.0.10/80","param":"0"},{"type":"pfw_pause","ip":"forward/tcp/1.2.3/81","param":"1"}]' > "$RULES"
: > "$LOGGER_LOG"
assert_eq "restore: a rate 0 and a bad address fail" '{ "ok": false, "restored": 0, "failed": 2 }' "$(restore)"
assert_contains "restore: the rate 0 is logged, as v1.30's hook did" "Failed to restore port limit for 80" "$(cat "$LOGGER_LOG")"
assert_contains "restore: so is the bad address" "Failed to restore port pause for 81" "$(cat "$LOGGER_LOG")"
write_trafficctl 0
reset_net
printf '%s' '[{"type":"pfw_pause","ip":"forward/tcp/192.168.0.10/80","param":"1"}]' > "$RULES"
assert_eq "restore, persistence off: nothing" '{ "ok": true, "restored": 0, "failed": 0 }' "$(restore)"
printf '[]' > "$RULES"

# ── validation ───────────────────────────────────────────────────────────────

USAGE_PAUSE='{"ok":false,"msg":"usage: trafficctl-portfw.sh pause|resume <forward|input> <tcp|udp|tcpudp> <ip|-> <port>"}'
reset_net
OUT=$(run_portfw pause forward tcp 192.168.0.10 99999)
assert_eq "invalid port rejected" "$USAGE_PAUSE" "$OUT"
OUT=$(run_portfw pause forward tcp 192.168.0.10 2000-1000)
assert_eq "reversed port range rejected" "$USAGE_PAUSE" "$OUT"
OUT=$(run_portfw pause forward icmp 192.168.0.10 80)
assert_eq "invalid proto rejected" "$USAGE_PAUSE" "$OUT"
OUT=$(run_portfw pause forward tcp 'bad;ip' 80)
assert_eq "invalid ip rejected" "$USAGE_PAUSE" "$OUT"
OUT=$(run_portfw pause forward tcp - 80)
assert_eq "a forward needs its LAN host" "$USAGE_PAUSE" "$OUT"
OUT=$(run_portfw pause badscope tcp 192.168.0.10 80)
assert_eq "invalid scope rejected" "$USAGE_PAUSE" "$OUT"
assert_eq "rejected arguments touch nothing" "" "$(calls)"
OUT=$(run_portfw limit forward tcp 192.168.0.10)
assert_eq "limit usage" \
    '{"ok":false,"msg":"usage: trafficctl-portfw.sh limit <forward|input> <tcp|udp|tcpudp> <ip|-> <port> <rate_kbit>"}' "$OUT"
OUT=$(run_portfw bogus)
assert_eq "unknown subcommand" '{"ok":false,"msg":"usage: trafficctl-portfw.sh <list|pause|resume|limit> ..."}' "$OUT"
run_portfw bogus >/dev/null
assert_eq "unknown subcommand exits 1" 1 "$?"

OUT=$(run_portfw pause forward tcp 192.168.0.10 1000-2000)
assert_contains "port range accepted" '"ok":true' "$OUT"

# ── Results ──────────────────────────────────────────────────────────────────

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
