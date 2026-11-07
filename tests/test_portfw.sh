#!/bin/bash
# Tests for trafficctl-portfw.sh (port-forward / open-port traffic control).
# Mocks uci/nft/ip as PATH executables (the script runs under /bin/sh, so
# exported bash functions would not reach it) and feeds a conntrack fixture
# via TCTL_CT_FILE.

PASS=0
FAIL=0

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/libexec/trafficctl/trafficctl-portfw.sh"
FWLIB="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/libexec/trafficctl/trafficctl-fw.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN" "$TMPDIR/usr/libexec/trafficctl"

# The script sources /usr/libexec/trafficctl/trafficctl-fw.sh by absolute path; give the
# mocks a copy at a location we control via a wrapper that rewrites the source.
sed "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FWLIB|" "$SCRIPT" > "$TMPDIR/portfw.sh"
chmod +x "$TMPDIR/portfw.sh"

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
        printf "FAIL: %s\n  expected NOT to find: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

# ── mock uci ─────────────────────────────────────────────────────────────────
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
# args: -q get <key>
key="$3"
case "$key" in
    "firewall.@redirect[0]") echo redirect ;;
    "firewall.@redirect[0].name") echo "Web Server" ;;
    "firewall.@redirect[0].src") echo wan ;;
    "firewall.@redirect[0].src_dport") echo 8080 ;;
    "firewall.@redirect[0].dest_ip") echo 192.168.0.10 ;;
    "firewall.@redirect[0].dest_port") echo 80 ;;
    "firewall.@redirect[0].proto") echo tcp ;;
    "firewall.@redirect[1]") echo redirect ;;
    "firewall.@redirect[1].name") echo "Game" ;;
    "firewall.@redirect[1].src") echo wan ;;
    "firewall.@redirect[1].src_dport") echo 27015 ;;
    "firewall.@redirect[1].dest_ip") echo 192.168.0.20 ;;
    "firewall.@redirect[2]") echo redirect ;;
    "firewall.@redirect[2].target") echo SNAT ;;
    "firewall.@redirect[2].src_dport") echo 9999 ;;
    "firewall.@redirect[2].dest_ip") echo 192.168.0.30 ;;
    "firewall.@rule[0]") echo rule ;;
    "firewall.@rule[0].name") echo "WireGuard" ;;
    "firewall.@rule[0].src") echo wan ;;
    "firewall.@rule[0].dest_port") echo 51820 ;;
    "firewall.@rule[0].proto") echo udp ;;
    "firewall.@rule[0].target") echo ACCEPT ;;
    "firewall.@rule[1]") echo rule ;;
    "firewall.@rule[1].name") echo "LAN thing" ;;
    "firewall.@rule[1].src") echo lan ;;
    "firewall.@rule[1].dest_port") echo 22 ;;
    "firewall.@rule[1].target") echo ACCEPT ;;
    "firewall.@rule[2]") echo rule ;;
    "firewall.@rule[2].name") echo "Zone fwd" ;;
    "firewall.@rule[2].src") echo wan ;;
    "firewall.@rule[2].dest") echo lan ;;
    "firewall.@rule[2].dest_port") echo 443 ;;
    "firewall.@rule[2].target") echo ACCEPT ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/uci"

# ── mock nft (logs invocations, serves canned dumps) ────────────────────────
NFT_LOG="$TMPDIR/nft.log"
: > "$NFT_LOG"
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
echo "\$*" >> "$NFT_LOG"
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    "list table inet tctl_pfw")
        cat <<'DUMP'
table inet tctl_pfw {
	chain pfw_forward {
		type filter hook forward priority -190; policy accept;
		ip daddr 192.168.0.10 tcp dport 80 counter packets 5 bytes 500 drop comment "tctl_pfw_pause_tcp_192.168.0.10_80"
		ip daddr 192.168.0.20 udp dport 27015 limit rate over 625000 bytes/second counter drop comment "tctl_pfw_limit_udp_192.168.0.20_27015"
	}
	chain pfw_input {
		type filter hook input priority -190; policy accept;
	}
}
DUMP
        ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/nft"

# ── mock ip (no routes, no addresses) ────────────────────────────────────────
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/ip"
chmod +x "$MOCKBIN/ip"

# ── conntrack fixture ────────────────────────────────────────────────────────
CT_FILE="$TMPDIR/nf_conntrack"
cat > "$CT_FILE" <<'EOF'
ipv4     2 tcp      6 431999 ESTABLISHED src=203.0.113.50 dst=198.51.100.1 sport=555 dport=8080 packets=10 bytes=1000 src=192.168.0.10 dst=203.0.113.50 sport=80 dport=555 packets=8 bytes=2000 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 431999 ESTABLISHED src=203.0.113.60 dst=198.51.100.1 sport=666 dport=8080 packets=3 bytes=500 src=192.168.0.10 dst=203.0.113.60 sport=80 dport=666 packets=4 bytes=700 [ASSURED] mark=0 use=1
ipv4     2 tcp      6 100 ESTABLISHED src=192.168.0.99 dst=192.168.0.10 sport=777 dport=80 packets=2 bytes=9999 src=192.168.0.10 dst=192.168.0.99 sport=80 dport=777 packets=2 bytes=9999 [ASSURED] mark=0 use=1
ipv4     2 udp      17 30 src=203.0.113.70 dst=198.51.100.1 sport=333 dport=51820 packets=1 bytes=400 src=198.51.100.1 dst=203.0.113.70 sport=51820 dport=333 packets=1 bytes=300 mark=0 use=1
EOF

run_portfw() {
    PATH="$MOCKBIN:$PATH" TCTL_CT_FILE="$CT_FILE" sh "$TMPDIR/portfw.sh" "$@" 2>/dev/null
}

# ── list ─────────────────────────────────────────────────────────────────────

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

# stats: two external clients on the web forward, LAN-direct excluded
assert_contains "list: web forward conns=2" '"conns":2' "$OUT"
assert_contains "list: web forward clients=2" '"clients":2' "$OUT"
assert_contains "list: web forward bytes_in" '"bytes_in":1500' "$OUT"
assert_contains "list: web forward bytes_out" '"bytes_out":2700' "$OUT"
assert_not_contains "list: LAN-direct flow not counted" '9999' "$OUT"

# open port stats
assert_contains "list: wireguard bytes_in" '"bytes_in":400' "$OUT"

# control state from nft dump
assert_contains "list: web forward paused" '"paused":true' "$OUT"
assert_contains "list: game forward limited to 5000 kbit" '"limit_kbit":5000' "$OUT"

# ── pause ────────────────────────────────────────────────────────────────────

: > "$NFT_LOG"
OUT=$(run_portfw pause forward tcp 192.168.0.10 80)
assert_contains "pause: ok" '"ok":true' "$OUT"
NFT_CALLS=$(cat "$NFT_LOG")
assert_contains "pause: inserts drop rule" \
    'insert rule inet tctl_pfw pfw_forward ip daddr 192.168.0.10 tcp dport 80 counter drop' "$NFT_CALLS"
assert_contains "pause: rule carries comment" 'tctl_pfw_pause_tcp_192.168.0.10_80' "$NFT_CALLS"

: > "$NFT_LOG"
OUT=$(run_portfw pause input udp - 51820)
assert_contains "pause input: ok" '"ok":true' "$OUT"
NFT_CALLS=$(cat "$NFT_LOG")
assert_contains "pause input: rule in input chain without daddr" \
    'insert rule inet tctl_pfw pfw_input udp dport 51820 counter drop' "$NFT_CALLS"

# tcpudp expands to both protocols
: > "$NFT_LOG"
OUT=$(run_portfw pause forward tcpudp 192.168.0.20 27015)
NFT_CALLS=$(cat "$NFT_LOG")
assert_contains "pause tcpudp: tcp rule" 'tcp dport 27015' "$NFT_CALLS"
assert_contains "pause tcpudp: udp rule" 'udp dport 27015' "$NFT_CALLS"

# ── resume ───────────────────────────────────────────────────────────────────

OUT=$(run_portfw resume forward tcp 192.168.0.10 80)
assert_contains "resume: ok" '"ok":true' "$OUT"

# ── limit ────────────────────────────────────────────────────────────────────

: > "$NFT_LOG"
OUT=$(run_portfw limit forward tcp 192.168.0.10 80 8000)
assert_contains "limit: ok" '"ok":true' "$OUT"
NFT_CALLS=$(cat "$NFT_LOG")
assert_contains "limit: rate-over drop rule (8000 kbit = 1000000 bytes)" \
    'limit rate over 1000000 bytes/second counter drop' "$NFT_CALLS"

OUT=$(run_portfw limit forward tcp 192.168.0.10 80 0)
assert_contains "limit 0: removes" '"ok":true' "$OUT"

# ── validation ───────────────────────────────────────────────────────────────

OUT=$(run_portfw pause forward tcp 192.168.0.10 99999)
assert_contains "invalid port rejected" '"ok":false' "$OUT"

OUT=$(run_portfw pause forward icmp 192.168.0.10 80)
assert_contains "invalid proto rejected" '"ok":false' "$OUT"

OUT=$(run_portfw pause forward tcp 'bad;ip' 80)
assert_contains "invalid ip rejected" '"ok":false' "$OUT"

OUT=$(run_portfw pause badscope tcp 192.168.0.10 80)
assert_contains "invalid scope rejected" '"ok":false' "$OUT"

OUT=$(run_portfw pause forward tcp 192.168.0.10 1000-2000)
assert_contains "port range accepted" '"ok":true' "$OUT"

# ── Results ──────────────────────────────────────────────────────────────────

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
