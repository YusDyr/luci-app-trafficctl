#!/bin/bash
# Egress interface of policy-routed connections is reported by its uci name,
# not only by the kernel device it resolved to (#10): mwan3 sends a flow out of
# "awg3", the user calls that network "Finland".
#
# Runs `trafficctl device` end to end against a recorded conntrack table, a
# mocked `ip route get` and the role map `trafficctl ifaces` memoizes, in a
# scratch root (tests/lib/bytes_env.sh).

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/bytes_env.sh
. "$(dirname "$0")/lib/bytes_env.sh"

PASS=0
FAIL=0

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    fi
}

ROLES="$BE_ROOT/tmp/trafficctl_ifroles"

# mark=256 -> awg3 (has a uci name), mark=512 -> usb0 (no uci interface),
# mark=0 -> not policy-routed, left blank.
cat > "$BE_CT" <<'CT'
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.37 dst=17.248.239.10 sport=54195 dport=443 packets=10 bytes=1000 src=17.248.239.10 dst=10.8.0.2 sport=443 dport=54195 packets=10 bytes=5000 [ASSURED] mark=256 zone=0 use=2
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.37 dst=198.41.200.43 sport=40853 dport=443 packets=10 bytes=1000 src=198.41.200.43 dst=100.64.0.2 sport=443 dport=40853 packets=10 bytes=5000 [ASSURED] mark=512 zone=0 use=2
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.37 dst=1.1.1.1 sport=40000 dport=443 packets=10 bytes=1000 src=1.1.1.1 dst=203.0.113.2 sport=443 dport=40000 packets=10 bytes=5000 [ASSURED] mark=0 zone=0 use=2
CT

# The ip mock of bytes_env.sh, plus the routing decisions per mark.
cat > "$BE_BIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    "-4 addr show")
        echo "    inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan"
        echo "    inet 203.0.113.2/24 brd 203.0.113.255 scope global wan" ;;
    "route get "*)
        case "$5" in
            256) echo "$3 dev awg3 table 1 src 10.8.0.2 uid 0" ;;
            512) echo "$3 dev usb0 table 2 src 100.64.0.2 uid 0" ;;
            *)   echo "$3 via 203.0.113.1 dev wan src 203.0.113.2 uid 0" ;;
        esac ;;
esac
exit 0
MOCK
# The uci interface "Finland" is the one on awg3.
printf '{"interface":[{"interface":"lan","up":true,"l3_device":"br-lan","ipv4-address":[{"address":"192.168.1.1","mask":24}]},{"interface":"wan","up":true,"l3_device":"wan","ipv4-address":[{"address":"203.0.113.2","mask":24}]},{"interface":"Finland","up":true,"l3_device":"awg3","ipv4-address":[{"address":"10.8.0.2","mask":32}]}]}\n' \
    > "$BE_UBUS/network.interface@dump.json"
# The devices the role map classifies.
cat > "$BE_ROOT/proc/net/dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
br-lan:    1000      10    0    0    0     0          0         0     2000      20    0    0    0     0       0          0
   wan:    3000      30    0    0    0     0          0         0     4000      40    0    0    0     0       0          0
  awg3:    5000      50    0    0    0     0          0         0     6000      60    0    0    0     0       0          0
  usb0:    7000      70    0    0    0     0          0         0     8000      80    0    0    0     0       0          0
EOF

run_device() { be_run device 192.168.1.37; }

# ── cold: no role map yet, so the device report has it built once ───────────
rm -f "$ROLES"
OUT=$(run_device)
assert_contains "cold: role map built when missing" "yes" "$([ -s "$ROLES" ] && echo yes)"
assert_contains "policy-routed flow present" '"dst":"17.248.239.10"' "$OUT"
assert_contains "awg3 reported as Finland" '"oif":"Finland","oif_dev":"awg3"' "$OUT"
assert_contains "device without a uci name keeps the device" '"oif":"usb0","oif_dev":"usb0"' "$OUT"
assert_contains "mark=0 stays blank" '"dst":"1.1.1.1","host":"","port":443,"service":"https","bytes":1000,"state":"ESTABLISHED","oif":"","oif_dev":""' "$OUT"

# ── warm: an existing map is used as is, never rebuilt from the device poll ──
printf '# 1\nawg3 wan 1 0 0 0 Riga\n' > "$ROLES"
OUT=$(run_device)
assert_contains "warm: role map not rebuilt" "Riga" "$(cat "$ROLES")"
assert_contains "warm: label read from the existing map" '"oif":"Riga","oif_dev":"awg3"' "$OUT"

# TCTL_IFROLE_CACHE points the reader at another map.
printf '# 1\nawg3 wan 1 0 0 0 Oslo\n' > "$UC_TMP/roles.alt"
OUT=$(TCTL_IFROLE_CACHE="$UC_TMP/roles.alt" run_device)
assert_contains "TCTL_IFROLE_CACHE: the map named there" '"oif":"Oslo","oif_dev":"awg3"' "$OUT"

# ── no policy-routed flows: nothing to label, nothing built ──────────────────
rm -f "$ROLES"
sed -i.bak 's/mark=[0-9]*/mark=0/' "$BE_CT"
OUT=$(run_device)
assert_contains "no marks: role map not built" "no" "$([ -f "$ROLES" ] && echo yes || echo no)"
assert_contains "no marks: no egress named" '"oif":"","oif_dev":""' "$OUT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
