#!/bin/bash
# The read-only reports, `trafficctl summary` (the LuCI poll) and `trafficctl
# device`: how each device's row is put together from the nft, tc, uci and
# WiFi state, and that the refreshes the summary starts never hold it up.
# tests/equiv.sh compares both with the shell scripts they replaced; this
# pins the rules themselves, in a scratch root (tests/lib/bytes_env.sh).

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/bytes_env.sh
. "$(dirname "$0")/lib/bytes_env.sh"

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
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    fi
}

T="$UC_TMP/report"
mkdir -p "$T/tc" "$BE_ROOT/etc/trafficctl" "$BE_ROOT/usr/libexec/trafficctl" \
    "$BE_ROOT/usr/sbin" "$BE_ROOT/var/run/netifyd"

# The reports read the limiter and shaper state through trafficctl-fw.sh
# (until the ctl.uc readers land), which names shapes.json by absolute path.
FW_SRC="$UC_REPO/trafficctl/files/usr/libexec/trafficctl/trafficctl-fw.sh"
sed "s|/etc/trafficctl/|$BE_ROOT/etc/trafficctl/|g" "$FW_SRC" \
    > "$BE_ROOT/usr/libexec/trafficctl/trafficctl-fw.sh"
grep -qF "$BE_ROOT/etc/trafficctl/shapes.json" "$BE_ROOT/usr/libexec/trafficctl/trafficctl-fw.sh" ||
    { echo "FAIL: fw.sh was not pointed at the scratch shapes.json"; exit 1; }

cat > "$BE_BIN/tc" <<MOCK
#!/bin/sh
f="$T/tc/\$*"
[ -f "\$f" ] || exit 1
cat "\$f"
MOCK
printf '#!/bin/sh\nexit 1\n' > "$BE_BIN/uci"
# The CLI the summary spawns: records the call, then takes its time, as a
# real reverse-DNS refresh or DPI collection does.
cat > "$BE_ROOT/usr/sbin/trafficctl" <<MOCK
#!/bin/sh
echo "\$*" >> "$T/spawn.log"
sleep "\${SPAWN_SLEEP:-0}"
MOCK
chmod +x "$BE_BIN/tc" "$BE_BIN/uci" "$BE_ROOT/usr/sbin/trafficctl"

ct() {   # ct <src> [reply dst]: one TCP flow from a device
    printf 'ipv4     2 tcp      6 100 ESTABLISHED src=%s dst=203.0.113.9 sport=40000 dport=443 packets=1 bytes=100 src=203.0.113.9 dst=%s sport=443 dport=40000 packets=1 bytes=200 [ASSURED] mark=0 use=2\n' \
        "$1" "${2:-$1}" >> "$BE_CT"
}
for ip in 192.168.1.4 192.168.1.5 192.168.1.7 192.168.1.8 192.168.1.9 192.168.1.14 \
          192.168.1.50 192.168.1.60 192.168.1.100 192.168.1.101 192.168.1.140; do
    ct "$ip"
done
# A NAT client from another subnet; the derived classid of 192.168.0.2 is
# 1:2, which belongs to 192.168.1.100.
ct 192.168.0.2 203.0.113.2

# Every device is named, so no reverse-DNS refresh is started unless a case
# asks for one.
: > "$BE_ROOT/tmp/dhcp.leases"
for ip in 192.168.1.4 192.168.1.5 192.168.1.7 192.168.1.8 192.168.1.9 192.168.1.14 \
          192.168.1.50 192.168.1.60 192.168.1.100 192.168.1.101 192.168.1.140 192.168.0.2; do
    o=${ip##*.}
    printf '0 aa:bb:cc:dd:ee:%02x %s host-%s *\n' "$o" "$ip" "$o" >> "$BE_ROOT/tmp/dhcp.leases"
done

# ── the firewall state ──────────────────────────────────────────────────────
cat > "$BE_NFT/list chain inet fw4 forward" <<'EOF'
table inet fw4 {
	chain forward {
		ip saddr 192.168.1.140 counter packets 12 bytes 3456 drop comment "tctl_block_192_168_1_140"
		meta nfproto ipv6 ether saddr aa:bb:cc:dd:ee:8c counter packets 3 bytes 240 drop comment "tctl_block_192_168_1_140_mac"
		meta nfproto ipv6 ether saddr aa:bb:cc:dd:ee:32 counter packets 3 bytes 300 drop comment "tctl_block_192_168_1_50_mac"
		ip saddr 192.168.1.1400 counter packets 1 bytes 7 drop
	}
}
EOF
cat > "$BE_NFT/list table netdev tm_ratelimit" <<'EOF'
table netdev tm_ratelimit {
	chain dl_br-lan {
		ip daddr 192.168.1.5 limit rate over 625000 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5"
		ip daddr 192.168.1.7/32 limit rate over 1000 kbytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_7"
		ip daddr 192.168.1.8 meter tctl_d_192_168_1_8 { ip daddr limit rate over 2000 kbytes/second } counter packets 0 bytes 0 drop
		ip daddr 192.168.1.4 limit rate over 1 mbytes/second counter packets 0 bytes 0 drop
		ip daddr 192.168.1.9 limit rate over 512 bytes/second counter packets 0 bytes 0 drop
	}
	chain ul_lan1 {
		ip saddr 192.168.1.5 limit rate over 125000 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_5_ul"
		ip saddr 192.168.1.8 meter tctl_u_192_168_1_8 { ip saddr limit rate over 250000 bytes/second } counter packets 0 bytes 0 drop
		ip saddr 192.168.1.60 limit rate over 128000 bytes/second counter packets 0 bytes 0 drop
	}
}
EOF
# Shapes: an allocated classid, one with its own upload ceiling, and a record
# from before classids were allocated (derived: 1:105).
printf '[{"ip":"192.168.1.100","rate_kbit":10000,"classid":"1:2"},{"ip":"192.168.1.101","rate_kbit":5000,"classid":"1:3","rate_kbit_up":1000},{"ip":"192.168.1.5","rate_kbit":2000}]\n' \
    > "$BE_ROOT/etc/trafficctl/shapes.json"
printf 'class htb 1:1 root rate 1Gbit ceil 1Gbit burst 1600b cburst 1600b\nclass htb 1:2 parent 1:1 prio 0 rate 10Mbit ceil 10Mbit burst 1600b cburst 1600b\nclass htb 1:3 parent 1:1 prio 0 rate 5Mbit ceil 5Mbit burst 1600b cburst 1600b\nclass htb 1:105 parent 1:1 prio 0 rate 2Mbit ceil 2Mbit burst 1600b cburst 1600b\nclass htb 1:fffe parent 1:1 prio 0 rate 1Gbit ceil 1Gbit burst 1600b cburst 1600b\n' \
    > "$T/tc/class show dev br-lan"
printf 'class htb 1:2 parent 1:1 prio 0 rate 10Mbit ceil 10Mbit burst 1600b cburst 1600b\nclass htb 1:3 parent 1:1 prio 0 rate 1Mbit ceil 1Mbit burst 1600b cburst 1600b\n' \
    > "$T/tc/class show dev tctl-ifb0"

SUM=$(be_run summary)
row() { printf '%s' "$SUM" | jq -c --arg ip "$1" '.[] | select(.ip == $ip)'; }
sfield() { printf '%s' "$SUM" | jq -r --arg ip "$1" ".[] | select(.ip == \$ip) | .$2"; }
dfield() { be_run device "$1" | jq -r ".$2"; }
assert_eq "summary: every device has a row" "12" "$(printf '%s' "$SUM" | jq length)"

# ── blocks ──────────────────────────────────────────────────────────────────
for f in sfield dfield; do
    assert_eq "$f block: the v4 rule" "true" "$($f 192.168.1.140 blocked)"
    # Either half of the block: counting only the v4 rule would make a
    # dual-stack device's dropped bytes read low.
    assert_eq "$f block: bytes of both halves" "3696" "$($f 192.168.1.140 block_bytes)"
    assert_eq "$f block: only the IPv6 (MAC) rule left" "true" "$($f 192.168.1.50 blocked)"
    assert_eq "$f block: its bytes" "300" "$($f 192.168.1.50 block_bytes)"
    assert_eq "$f block: .5 is not blocked by .50's MAC rule" "false" "$($f 192.168.1.5 blocked)"
    # The shell device report matched "ip saddr $IP.*drop": 192.168.1.14
    # read blocked by 192.168.1.140's rule, and .140 by a rule for .1400.
    assert_eq "$f block: .14 is not blocked by .140's rule" "false" "$($f 192.168.1.14 blocked)"
    assert_eq "$f block: nor are its bytes counted" "0" "$($f 192.168.1.14 block_bytes)"
done

# ── rate limits, read back from what nft lists ──────────────────────────────
for f in sfield dfield; do
    assert_eq "$f limit: bytes/second, SI kbit" "5000" "$($f 192.168.1.5 rate_limit_kbit)"
    # nft lists 1024000 bytes/second as 1000 kbytes: 8192, not 8000 or 0.
    assert_eq "$f limit: kbytes, a /32 target" "8192" "$($f 192.168.1.7 rate_limit_kbit)"
    assert_eq "$f limit: a per-address meter" "16384" "$($f 192.168.1.8 rate_limit_kbit)"
    assert_eq "$f limit: mbytes" "8389" "$($f 192.168.1.4 rate_limit_kbit)"
    assert_eq "$f limit: bytes scale by 1024 like nft's other units" "4" "$($f 192.168.1.9 rate_limit_kbit)"
    assert_eq "$f limit up: its own upload ceiling" "1000" "$($f 192.168.1.5 rate_limit_kbit_up)"
    assert_eq "$f limit up: a per-address meter" "2000" "$($f 192.168.1.8 rate_limit_kbit_up)"
    assert_eq "$f limit: an upload-only rule is not a download ceiling" "0" "$($f 192.168.1.60 rate_limit_kbit)"
    assert_eq "$f limit up: an upload-only rule" "1024" "$($f 192.168.1.60 rate_limit_kbit_up)"
    assert_eq "$f limit up: a download-only rule is not an upload ceiling" "0" "$($f 192.168.1.7 rate_limit_kbit_up)"
    assert_eq "$f limit: an unlimited device reads 0" "0" "$($f 192.168.1.50 rate_limit_kbit)"
done

# ── shapes: the classid comes from shapes.json, never from the address ──────
for f in sfield dfield; do
    assert_eq "$f shape: an allocated classid" "10000" "$($f 192.168.1.100 shape_kbit)"
    assert_eq "$f shape up: a symmetric shape reads the same both ways" "10000" "$($f 192.168.1.100 shape_kbit_up)"
    assert_eq "$f shape: an asymmetric shape's download" "5000" "$($f 192.168.1.101 shape_kbit)"
    assert_eq "$f shape up: its upload, from the IFB" "1000" "$($f 192.168.1.101 shape_kbit_up)"
    assert_eq "$f shape: a pre-allocation record" "2000" "$($f 192.168.1.5 shape_kbit)"
    assert_eq "$f shape up: no IFB class reads 0" "0" "$($f 192.168.1.5 shape_kbit_up)"
    assert_eq "$f shape: an unshaped device does not borrow another's class" "0" "$($f 192.168.0.2 shape_kbit)"
done
assert_eq "summary: the NAT client is routed" "routed" "$(sfield 192.168.0.2 conn_type)"

# ── WiFi ────────────────────────────────────────────────────────────────────
assert_eq "device: no wifi-iface, no WiFi filter" "none" "$(dfield 192.168.1.50 wifi_filter)"
printf "config wifi-iface 'ap0'\n\toption macfilter 'deny'\n\tlist maclist 'AA:BB:CC:DD:EE:32'\n\tlist maclist 'aa:bb:cc:dd:ee:07'\n" \
    > "$BE_ROOT/etc/config/wireless"
cat > "$BE_BIN/iw" <<'MOCK'
#!/bin/sh
case "$*" in
    dev) printf 'phy#0\n\tInterface phy0-ap0\n' ;;
    "dev phy0-ap0 info") printf 'Interface phy0-ap0\n\tchannel 36 (5180 MHz), width: 80 MHz\n' ;;
    "dev phy0-ap0 station dump") printf 'Station aa:bb:cc:dd:ee:32 (on phy0-ap0)\n' ;;
esac
MOCK
chmod +x "$BE_BIN/iw"
assert_eq "device: WiFi, no hostapd_cli: a temporary ban" "temporary" "$(dfield 192.168.1.50 wifi_filter)"
mkdir -p "$T/hostapd"
printf '#!/bin/sh\nexit 0\n' > "$T/hostapd/hostapd_cli"
chmod +x "$T/hostapd/hostapd_cli"
assert_eq "device: WiFi and hostapd_cli: the ACL" "full" \
    "$(PATH="$T/hostapd:$PATH" be_run device 192.168.1.50 | jq -r .wifi_filter)"
SUM=$(be_run summary)
for f in sfield dfield; do
    # Listed (in either case) and still associated: denied, not yet off.
    assert_eq "$f wifi: a listed MAC is denied" "true" "$($f 192.168.1.50 wifi_blocked)"
    assert_eq "$f wifi: still associated, so pending" "true" "$($f 192.168.1.50 wifi_block_pending)"
    assert_eq "$f wifi: listed but wired is not pending" "false" "$($f 192.168.1.7 wifi_block_pending)"
    assert_eq "$f wifi: listed but wired is denied all the same" "true" "$($f 192.168.1.7 wifi_blocked)"
    assert_eq "$f wifi: unlisted" "false" "$($f 192.168.1.5 wifi_blocked)"
done
assert_eq "summary: the station's band" "5G" "$(sfield 192.168.1.50 conn_type)"
: > "$BE_ROOT/etc/config/wireless"
rm -f "$BE_BIN/iw"
assert_eq "summary: no refresh started while every device is named" "" "$(cat "$T/spawn.log" 2>/dev/null)"

# ── the detached refreshes ──────────────────────────────────────────────────
# The summary is the 2-second LuCI poll: the reverse-DNS refresh it starts for
# unnamed devices and the DPI collection it starts for a stale cache must run
# detached, or every poll waits for them.
: > "$BE_ROOT/tmp/dhcp.leases"
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' \
    "$BE_ROOT/var/run/netifyd/netifyd.sock"
start=$(date +%s)
SUM=$(SPAWN_SLEEP=6 be_run summary)
took=$(( $(date +%s) - start ))
if [ "$took" -le 3 ]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); echo "FAIL: the summary waited ${took}s for the refreshes it started"; fi
assert_eq "spawn: the summary itself is complete" "12" "$(printf '%s' "$SUM" | jq length)"
for _ in $(seq 50); do [ "$(wc -l < "$T/spawn.log" 2>/dev/null)" -ge 2 ] && break; sleep 0.1; done
SPAWNED=$(cat "$T/spawn.log" 2>/dev/null)
assert_contains "spawn: a DPI collection for the stale cache" "netify collect" "$SPAWNED"
# At most 8 per poll, the last ones in address order; the rest go next time.
assert_contains "spawn: a capped reverse-DNS refresh" \
    "rdns-refresh 192.168.1.8 192.168.1.9 192.168.1.14 192.168.1.50 192.168.1.60 192.168.1.100 192.168.1.101 192.168.1.140" \
    "$SPAWNED"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
