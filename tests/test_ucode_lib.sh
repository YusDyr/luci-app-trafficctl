#!/bin/bash
# Unit tests for the ucode library (trafficctl.lib) and the subnet half of
# trafficctl.net, through tests/lib/call.uc and the CLI. The shell copies of
# the same helpers are covered by test_fw.sh; tests/equiv.sh keeps the two
# equal on a real router's state.

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
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}

R="$UC_TMP/root"
export TCTL_ROOT="$R"
export TCTL_UBUS_SOCKET="$UC_TMP/no-ubus.sock"
mkdir -p "$R/etc/config" "$R/tmp/.uci"
lib() { tcall trafficctl.lib "$@"; }
net() { tcall trafficctl.net "$@"; }
js() { printf '%s' "$1" | jq -Rs .; }   # a shell string as a JSON argument

# ── validation (tctl_validate_ip and friends) ───────────────────────────────

for ip in 192.168.1.1 10.0.0.1 255.255.255.255 0.0.0.0; do
    assert_eq "valid IP $ip" "true" "$(lib valid_ip "$(js "$ip")")"
done
for ip in '' abc.def.ghi.jkl 256.1.1.1 1.1.1.999 192.168.1 '192.168.1.1 ; rm -rf /' \
          192.168.1.0/24 192.168.1.1. 1.2.3.4.5 1111.1.1.1 ' 1.2.3.4' '1.2.3.4
'; do
    assert_eq "invalid IP '$ip'" "false" "$(lib valid_ip "$(js "$ip")")"
done
assert_eq "valid_ip: a number is not an address" "false" "$(lib valid_ip 1)"

assert_eq "valid_int: in range" "42" "$(lib valid_int '"42"' 1 100)"
assert_eq "valid_int: below min" "" "$(lib valid_int '"0"' 1 100)"
assert_eq "valid_int: above max" "" "$(lib valid_int '"101"' 1 100)"
assert_eq "valid_int: trailing junk" "" "$(lib valid_int '"12abc"')"
assert_eq "valid_int: sign" "" "$(lib valid_int '"-1"')"
assert_eq "valid_int: past int64" "" "$(lib valid_int '"99999999999999999999"')"
assert_eq "valid_int: a JSON int" "7" "$(lib valid_int 7 0 9)"

assert_eq "norm_mac: lower-cased" "aa:bb:cc:dd:ee:0f" "$(lib norm_mac '"AA:BB:CC:DD:EE:0F"')"
assert_eq "norm_mac: dashes refused" "" "$(lib norm_mac '"aa-bb-cc-dd-ee-ff"')"

assert_eq "cidr_spec: normalised to the base" '{ "base": 167773440, "block": 256, "mask": 24 }' \
    "$(lib cidr_spec '"10.0.5.77/24"')"
assert_eq "cidr_spec: a bare host is /32" '{ "base": 167773961, "block": 1, "mask": 32 }' \
    "$(lib cidr_spec '"10.0.7.9"')"
assert_eq "cidr_spec: /1 is the widest" '{ "base": 0, "block": 2147483648, "mask": 1 }' \
    "$(lib cidr_spec '"10.0.0.0/1"')"
for c in 10.0.0.0/0 10.0.0.0/33 10.0.0.0/ 10.0.0.0/2x 10.0.0/24 10.0.0.0/24/1 bogus; do
    assert_eq "cidr_spec: '$c' refused" "" "$(lib cidr_spec "$(js "$c")")"
done

assert_eq "valid_target: all" "0.0.0.0/0" "$(lib valid_target '"all"')"
assert_eq "valid_target: any" "0.0.0.0/0" "$(lib valid_target '"any"')"
assert_eq "valid_target: host" "10.0.0.5" "$(lib valid_target '"10.0.0.5"')"
assert_eq "valid_target: CIDR kept as given" "10.0.0.5/24" "$(lib valid_target '"10.0.0.5/24"')"
assert_eq "valid_target: /0 allowed" "10.0.0.0/0" "$(lib valid_target '"10.0.0.0/0"')"
assert_eq "valid_target: /33 refused" "" "$(lib valid_target '"10.0.0.0/33"')"

assert_eq "ip2int/int2ip round trip" "192.168.0.1" "$(lib int2ip "$(lib ip2int '"192.168.0.1"')")"

# ── JSON in the shell backend's byte format ─────────────────────────────────

assert_eq "to_json: compact, insertion order, '/' unescaped" \
    '{"z":1,"a":[true,false,null,"x/y"],"o":{}}' \
    "$(lib to_json '{"z":1,"a":[true,false,null,"x/y"],"o":{}}')"
assert_eq "to_json: quotes, backslashes and controls escaped" \
    '"q\"b\\s\nt\tc\u0001"' "$(lib to_json '"q\"b\\s\nt\tc\u0001"')"
assert_eq "to_json: a double is never emitted" '[1,-2,0]' "$(lib to_json '[1.75,-2.5,0.0]')"
assert_eq "to_json: int64 intact" '9223372036854775807' "$(lib to_json 9223372036854775807)"
assert_eq "to_json: UTF-8 passes through" '"Кухня"' "$(lib to_json '"Кухня"')"

# ── external commands ───────────────────────────────────────────────────────

NASTY="it's \$(touch $UC_TMP/pwned) \`touch $UC_TMP/pwned\`; \"x\" \\ * ?"
Q=$(lib q "$(js "$NASTY")")
assert_eq "q: survives a round trip through sh" "$NASTY" "$(eval "printf '%s' $Q")"
assert_eq "q: nothing executed" "no" "$([ -e "$UC_TMP/pwned" ] && echo yes || echo no)"
assert_eq "run: stdout, stderr dropped" "out" "$(lib run '"echo out; echo err >&2"')"
assert_eq "run: a failing command is just empty" "" "$(lib run '"exit 3"')"
assert_eq "lines: split, final empty line dropped" '[ "a", "b" ]' "$(lib lines '"printf \"a\\nb\\n\""')"
assert_eq "sh: exit status" "3" "$(lib sh '"exit 3"')"
START=$(date +%s)
OUT=$(lib run '"sleep 20"' 300)
assert_eq "run with a timeout: killed" "" "$OUT"
assert_eq "run with a timeout: returns early" "yes" "$([ $(( $(date +%s) - START )) -lt 10 ] && echo yes || echo no)"
assert_eq "run with a timeout: output still captured" "hi" "$(lib run '"echo hi"' 2000)"
assert_eq "run with a timeout: no temp file left" "" "$(ls -A "$R/tmp" | grep trafficctl_run)"

# ── files ───────────────────────────────────────────────────────────────────

mkdir -p "$R/etc/trafficctl"
assert_eq "write_atomic: ok" "true" "$(lib write_atomic '"/etc/trafficctl/x"' '"data\n"' 384)"
assert_eq "write_atomic: content" "data" "$(cat "$R/etc/trafficctl/x" 2>/dev/null)"
assert_eq "write_atomic: mode" "600" "$(stat -c %a "$R/etc/trafficctl/x" 2>/dev/null)"
assert_eq "write_atomic: no temp file left" "x" "$(ls -A "$R/etc/trafficctl")"
assert_eq "write_atomic: missing directory fails" "false" "$(lib write_atomic '"/nope/x"' '"d"')"
assert_eq "mkdir_p: nested" "true" "$(lib mkdir_p '"/a/b/c"')"
assert_eq "mkdir_p: made" "yes" "$([ -d "$R/a/b/c" ] && echo yes || echo no)"
assert_eq "file_lines: missing file" "[ ]" "$(lib file_lines '"/none"')"
assert_eq "field: awk-style split" "b" "$(lib field '"  a \t b  c"' 1)"

assert_eq "lock: taken" "true" "$(lib lock '"/tmp/t.lock"' 0 300)"
assert_eq "lock: held, one attempt" "false" "$(lib lock '"/tmp/t.lock"' 0 300)"
assert_eq "lock: held, retries then steals" "true" "$(lib lock '"/tmp/t.lock"' 2)"
touch -d "@$(( $(date +%s) - 400 ))" "$R/tmp/t.lock"
assert_eq "lock: stale, taken over even with one attempt" "true" "$(lib lock '"/tmp/t.lock"' 0 300)"
lib unlock '"/tmp/t.lock"'
assert_eq "unlock: gone" "no" "$([ -d "$R/tmp/t.lock" ] && echo yes || echo no)"

# ── activity log (tctl_log) ─────────────────────────────────────────────────

cat > "$R/etc/config/trafficctl" <<'EOF'
config logging 'logging'
	option enabled '1'
	option max_lines '20'
	option log_blocks '0'
EOF
LOG="$R/tmp/trafficctl/activity.log"
TCTL_USER=tester lib log '"config_change"' '"10.0.0.5"' '"name=x"' '"luci"' '"192.168.1.20"'
assert_eq "log: the tctl_log line" "1" \
    "$(grep -cE '^\[trafficctl\] [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} src=192.168.1.20 user=tester via=luci action=config_change target=10.0.0.5 detail=name=x$' "$LOG")"
TCTL_USER=tester lib log '"shape"' '"10.0.0.6"'
assert_eq "log: defaults, no empty detail" "1" \
    "$(grep -cE ' src=local user=tester via=cli action=shape target=10.0.0.6$' "$LOG")"
lib log '"block"' '"10.0.0.7"'
assert_not_contains "log: a category switched off" "10.0.0.7" "$(cat "$LOG")"
for i in $(seq 18); do echo "[trafficctl] filler $i"; done >> "$LOG"
assert_eq "log: 20 lines, at the cap" "20" "$(wc -l < "$LOG" | tr -d ' ')"
lib log '"shape"' '"10.1.0.1"'
assert_eq "log: past the cap, rotation keeps 3/5 of max_lines" "12" "$(wc -l < "$LOG" | tr -d ' ')"
assert_contains "log: the newest line survives" "target=10.1.0.1" "$(tail -1 "$LOG")"
assert_contains "log: the oldest go first" "filler 8" "$(head -1 "$LOG")"
printf "config logging 'logging'\n\toption enabled '1'\n\toption log_file '/etc/passwd'\n" > "$R/etc/config/trafficctl"
lib log '"shape"' '"10.2.0.1"'
assert_contains "log: a path outside the log dirs falls back to the default" "10.2.0.1" "$(cat "$LOG")"
for f in /etc/passwd /tmp/trafficctl/../x /tmp/trafficctl/ '/var/log/a b' /var/log/x/..; do
    assert_eq "valid_log_file: '$f' refused" "false" "$(lib valid_log_file "$(js "$f")")"
done
assert_eq "valid_log_file: /var/log/x.log" "true" "$(lib valid_log_file '"/var/log/x.log"')"
rm -f "$R/etc/config/trafficctl"
lib log '"shape"' '"10.3.0.1"'
assert_not_contains "log: off unless enabled" "10.3.0.1" "$(cat "$LOG")"

# ── new-device ledger ───────────────────────────────────────────────────────

MOCKBIN="$UC_TMP/bin"
mkdir -p "$MOCKBIN"
printf '#!/bin/sh\n[ "$*" = "neigh show" ] && printf "192.168.1.7 dev br-lan lladdr AA:00:00:00:00:07 REACHABLE\\n192.168.1.8 dev br-lan FAILED\\n"\n' > "$MOCKBIN/ip"
chmod +x "$MOCKBIN/ip"
printf '1 aa:00:00:00:00:01 192.168.1.1 a *\n1 aa:00:00:00:00:02 192.168.1.2 b *\n' > "$R/tmp/dhcp.leases"
SEEN="$R/etc/trafficctl/seen_macs"
assert_eq "seen: a missing ledger says known" "true" "$(lib seen_known '"aa:00:00:00:00:99"')"
assert_eq "seen: not ready" "false" "$(lib seen_ready)"
PATH="$MOCKBIN:$PATH" lib seen_seed
assert_eq "seen_seed: leases and neighbours, lower case, sorted" \
    "aa:00:00:00:00:01 aa:00:00:00:00:02 aa:00:00:00:00:07" "$(paste -sd ' ' "$SEEN")"
assert_eq "seen: unknown MAC" "false" "$(lib seen_known '"aa:00:00:00:00:99"')"
assert_eq "seen: case-insensitive" "true" "$(lib seen_known '"AA:00:00:00:00:07"')"
lib seen_mark '"AA:00:00:00:00:99"'
lib seen_mark '"aa:00:00:00:00:99"'
assert_eq "seen_mark: added once" "1" "$(grep -c '^aa:00:00:00:00:99$' "$SEEN")"
PATH="$MOCKBIN:$PATH" lib seen_seed
assert_eq "seen_seed: never rewrites an existing ledger" "4" "$(lib seen_count)"
for i in $(seq 1000 1997); do printf 'bb:00:00:00:%02x:%02x\n' $((i / 256)) $((i % 256)); done >> "$SEEN"
lib seen_mark '"cc:00:00:00:00:01"'
assert_eq "seen_mark: trimmed to 800 past 1000" "800" "$(lib seen_count)"
assert_eq "seen_mark: the newest kept" "cc:00:00:00:00:01" "$(tail -1 "$SEEN")"

# ── subnets ─────────────────────────────────────────────────────────────────
# lan, a guest VLAN that may masquerade (#64), and wan. A /25 because the CIDR
# is rebuilt from a packed integer and a block size: a non-octet boundary is
# what catches a wrong mask.

cat > "$R/etc/config/network" <<'EOF'
config interface 'lan'
	option device 'br-lan'
EOF
write_firewall() {   # write_firewall <guest masq 0|1>
    cat > "$R/etc/config/firewall" <<EOF
config zone
	option name 'lan'
	list network 'lan'

config zone
	option name 'guest'
	option network 'guest'
	option masq '$1'

config zone
	option name 'wan'
	list network 'wan'
	list network 'wan6'
EOF
}
mkdir -p "$UC_TMP/ubus"
cat > "$UC_TMP/ubus/network.interface@dump.json" <<'EOF'
{"interface":[
 {"interface":"wan","l3_device":"eth1","ipv4-address":[{"address":"203.0.113.9","mask":24}]},
 {"interface":"guest","l3_device":"br-guest","ipv4-address":[{"address":"192.168.20.1","mask":24}]},
 {"interface":"lan","l3_device":"br-lan","ipv4-address":[{"address":"10.10.4.130","mask":25}]}
]}
EOF
printf '#!/bin/sh\n[ "$*" = "route show" ] && printf "default via 203.0.113.1 dev eth1\\n10.0.5.0/24 via 10.10.4.200 dev br-lan proto static\\n10.0.9.0/24 via 203.0.113.1 dev eth1\\n10.10.4.128/25 dev br-lan scope link\\n"\nexit 0\n' > "$MOCKBIN/ip"
unset TCTL_UBUS_SOCKET
ubus_start "$UC_TMP/ubus"

write_firewall 0
OUT=$(PATH="$MOCKBIN:$PATH" tctl subnets)
assert_contains "subnets: a connected LAN is offered, with its device" \
    '{"cidr":"10.10.4.128/25","device":"br-lan","kind":"lan"}' "$OUT"
assert_contains "subnets: a guest VLAN without masq is offered" \
    '{"cidr":"192.168.20.0/24","device":"br-guest","kind":"lan"}' "$OUT"
assert_contains "subnets: a downstream routed subnet is offered too" \
    '{"cidr":"10.0.5.0/24","device":"br-lan","kind":"routed"}' "$OUT"
assert_not_contains "subnets: the wan zone is never offered" '"eth1"' "$OUT"
assert_not_contains "subnets: a route via the WAN is not downstream" '10.0.9.0' "$OUT"

# The #64 case: masq on a non-lan zone takes it out of the LAN set, so no
# netdev hook is ever attached to br-guest and a limit there matches nothing.
write_firewall 1
OUT=$(PATH="$MOCKBIN:$PATH" tctl subnets)
assert_not_contains "subnets: a masquerading guest VLAN is NOT offered" '192.168.20.0/24' "$OUT"
assert_contains "subnets: the other LANs are unaffected" '10.10.4.128/25' "$OUT"

printf "config trafficctl 'main'\n\toption extra_subnets '10.9.0.0/16 bogus 10.10.4.200/25 172.16.1.1'\n" > "$R/etc/config/trafficctl"
OUT=$(PATH="$MOCKBIN:$PATH" net monitored_subnets | jq -c '[.[] | [.dev, .base, .block, .router]]')
assert_eq "monitored: LAN first, routed, extras; duplicates and junk dropped" \
    '[["br-lan",168428672,128,168428674],["br-lan",167773440,256,0],["br-lan",168361984,65536,0],["br-lan",2886729985,1,0]]' "$OUT"
ubus_stop

# No ubus at all: no LAN, so no route counts as downstream, but the extras do.
export TCTL_UBUS_SOCKET="$UC_TMP/no-ubus.sock"
OUT=$(PATH="$MOCKBIN:$PATH" tctl subnets)
assert_eq "subnets: without ubus only the extras are left" \
    '[{"cidr":"10.9.0.0/16","device":"br-lan","kind":"routed"},{"cidr":"10.10.4.128/25","device":"br-lan","kind":"routed"},{"cidr":"172.16.1.1/32","device":"br-lan","kind":"routed"}]' "$OUT"

# tctl_get_lan_device: network.lan.device, then the pre-DSA ifname, then br-lan.
assert_eq "lan_device: network.lan.device" "br-lan" "$(net lan_device)"
printf "config interface 'lan'\n\toption ifname 'eth0.1'\n" > "$R/etc/config/network"
assert_eq "lan_device: ifname on old configs" "eth0.1" "$(net lan_device)"
rm -f "$R/etc/config/network"
assert_eq "lan_device: fallback" "br-lan" "$(net lan_device)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
