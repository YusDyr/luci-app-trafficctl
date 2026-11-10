#!/bin/bash
# The Rules tab's backend, trafficctl-rules.sh (#128).
#
# The device table is built from conntrack, so a device that goes offline loses
# its row, and with it the only way to see or lift its block, limit or shape —
# while the rule keeps applying. The list built here must therefore come from
# where the restrictions LIVE (nft, tc, the radio) and from where they
# are SAVED (rules.json, shapes.json, the uci maclist), never from the set of
# devices currently online, and it must say which of the two each was found in.
#
# Runs the real scripts with fake nft/tc/ip/uci/hostapd_cli on PATH
# (test_direction.sh's pattern). The second half runs
# the existing removal scripts the tab calls against an OFFLINE device, since
# "listed but cannot be removed" would be the same bug one step later.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
STATE="$TMPDIR/state"
mkdir -p "$MOCKBIN" "$STATE"

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
        printf "FAIL: %s\n  expected to find: '%s'\n  in: %s\n" "$1" "$2" "$3"
    fi
}

LEASES="$TMPDIR/dhcp.leases"
RULES="$TMPDIR/rules.json"
SHAPES="$TMPDIR/shapes.json"
NAMES="$TMPDIR/names"
RDNS="$TMPDIR/rdns_cache"
CT="$TMPDIR/nf_conntrack"

FW="$TMPDIR/fw.sh"
sed -e "s|TCTL_LEASES_FILE=\"/tmp/dhcp.leases\"|TCTL_LEASES_FILE=\"$LEASES\"|" \
    -e "s|TCTL_RULES_FILE=\"/etc/trafficctl/rules.json\"|TCTL_RULES_FILE=\"$RULES\"|" \
    -e "s|TCTL_SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|TCTL_SHAPES_FILE=\"$SHAPES\"|" \
    "$BIN/trafficctl-fw.sh" > "$FW"
patch_script() {
    sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FW|" \
        -e "s|^SCRIPTS=\"/usr/libexec/trafficctl\"|SCRIPTS=\"$TMPDIR\"|" \
        -e "s|^NAMES_FILE=\"/etc/trafficctl/names\"|NAMES_FILE=\"$NAMES\"|" \
        -e "s|^RDNS_CACHE_FILE=\"/tmp/trafficctl_rdns_cache\"|RDNS_CACHE_FILE=\"$RDNS\"|" \
        -e "s|^CONNTRACK_FILE=\"/proc/net/nf_conntrack\"|CONNTRACK_FILE=\"$CT\"|" \
        -e "s|/tmp/dhcp.leases|$LEASES|g" \
        "$1" > "$2"
}
patch_script "$BIN/trafficctl-rules.sh"            "$TMPDIR/rules.sh"
patch_script "$BIN/trafficctl-ratelimit-stats.sh"  "$TMPDIR/trafficctl-ratelimit-stats.sh"
patch_script "$BIN/trafficctl-ratelimit.sh"        "$TMPDIR/ratelimit.sh"
patch_script "$BIN/trafficctl-unblock.sh"          "$TMPDIR/unblock.sh"
patch_script "$BIN/trafficctl-macfilter-remove.sh" "$TMPDIR/macfilter-remove.sh"
chmod +x "$TMPDIR"/*.sh

# ── fakes ──────────────────────────────────────────────────────────────────
# Each listing is a fixture file, so a scenario is "write the kernel state,
# then run".
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
S="$STATE"
echo "\$*" >> "\$S/nft.log"
case "\$*" in
    "list chain inet fw4 forward"|"-a list chain inet fw4 forward") cat "\$S/fw4_forward" 2>/dev/null ;;
    "list table netdev tm_ratelimit"|"-a list table netdev tm_ratelimit") cat "\$S/tm_ratelimit" 2>/dev/null ;;
    # A real nft exits 1 for a set that does not exist.
    delete\ set*) exit 1 ;;
esac
exit 0
MOCK
cat > "$MOCKBIN/tc" <<MOCK
#!/bin/sh
case "\$*" in
    "class show dev br-lan") cat "$STATE/tc_lan" 2>/dev/null ;;
    "class show dev tctl-ifb0") cat "$STATE/tc_ifb" 2>/dev/null ;;
esac
exit 0
MOCK
cat > "$MOCKBIN/ip" <<MOCK
#!/bin/sh
case "\$*" in
    "neigh show") cat "$STATE/neigh" 2>/dev/null ;;
    "neigh show "*) grep "^\${3} " "$STATE/neigh" 2>/dev/null ;;
    "route show") : ;;
esac
exit 0
MOCK
# uci: persist flag and a wireless config with one deny-mode radio. Writes are
# logged so the removal test can see the maclist edit.
cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
S="$STATE"
echo "\$*" >> "\$S/uci.log"
while [ "\$1" = "-q" ]; do shift; done
case "\$1 \$2" in
    "get trafficctl.main.persist_rules") cat "\$S/persist" ;;
    "get network.lan.device") echo "br-lan" ;;
    "get network.wan.device") echo "eth1" ;;
    "get wireless.default_radio0.macfilter") cat "\$S/wifi_mode" ;;
    "get wireless.default_radio0.maclist") cat "\$S/maclist" ;;
    "show wireless") echo "wireless.default_radio0=wifi-iface" ;;
    get\ *) exit 1 ;;
esac
exit 0
MOCK
cat > "$MOCKBIN/ubus" <<MOCK
#!/bin/sh
case "\$*" in
    list) echo "hostapd.phy0-ap0" ;;
    *list_bans*) echo '{"clients":[]}' ;;
esac
exit 0
MOCK
cat > "$MOCKBIN/hostapd_cli" <<MOCK
#!/bin/sh
shift 2
case "\$1 \$2" in
    "ping "*) echo PONG ;;
    "deny_acl SHOW") cat "$STATE/acl" 2>/dev/null ;;
esac
exit 0
MOCK
# The limiter checks its devices against sysfs (see test_direction.sh).
mkdir -p "$TMPDIR/sys/class/net/eth1" "$TMPDIR/sys/class/net/br-lan/brif/lan1"
export TCTL_SYSFS_NET="$TMPDIR/sys/class/net"
for t in conntrack logger; do printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/$t"; done
chmod +x "$MOCKBIN"/*

run() { PATH="$MOCKBIN:$PATH" sh "$@" 2>/dev/null; }

# A field of the record of one type and target, via python so the test never
# depends on the key order the script happens to print.
rec() {
    python3 -c '
import json, sys
d = json.loads(sys.argv[1])
for r in d["rules"]:
    if r["type"] == sys.argv[2] and r["target"] == sys.argv[3]:
        v = r.get(sys.argv[4], "<absent>")
        print(json.dumps(v) if not isinstance(v, str) else v)
        break
else:
    print("<none>")
' "$1" "$2" "$3" "$4"
}
top() { python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])[sys.argv[2]]))' "$1" "$2"; }
count() { python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["rules"]))' "$1"; }

TAB=$(printf '\t')

# ── the LAN ────────────────────────────────────────────────────────────────
# .50 is offline and blocked; .60 is online and limited; .70 is shaped but its
# class is gone from the kernel; .80 is shaped and live; .90 is a saved block
# the kernel does not have; the WiFi deny lists a MAC with no lease left.
cat > "$LEASES" <<'EOF'
1700000000 aa:aa:aa:aa:aa:50 192.168.1.50 kid-tablet *
1700000000 aa:aa:aa:aa:aa:60 192.168.1.60 tv *
1700000000 aa:aa:aa:aa:aa:70 192.168.1.70 * *
EOF
echo '192.168.1.70 Console "X"' > "$NAMES"
printf '192.168.1.80 printer.lan 1700000000\n' > "$RDNS"
cat > "$CT" <<'EOF'
ipv4     2 tcp      6 300 ESTABLISHED src=192.168.1.60 dst=1.1.1.1 sport=1 dport=443 packets=1 bytes=100 src=1.1.1.1 dst=203.0.113.2 sport=443 dport=1 packets=1 bytes=100 mark=0 use=1
EOF
cat > "$STATE/neigh" <<'EOF'
192.168.1.50 dev br-lan lladdr aa:aa:aa:aa:aa:50 STALE
192.168.1.80 dev br-lan lladdr aa:aa:aa:aa:aa:80 REACHABLE
EOF

echo 1 > "$STATE/persist"
echo deny > "$STATE/wifi_mode"
echo "AA:AA:AA:AA:AA:99 aa:aa:aa:aa:aa:50" > "$STATE/maclist"
echo "aa:aa:aa:aa:aa:50" > "$STATE/acl"

cat > "$STATE/fw4_forward" <<EOF
table inet fw4 {
${TAB}chain forward {
${TAB}${TAB}meta nfproto ipv6 ether saddr aa:aa:aa:aa:aa:50 counter packets 0 bytes 0 drop comment "tctl_block_192_168_1_50_mac" # handle 41
${TAB}${TAB}ip saddr 192.168.1.50 counter packets 3 bytes 180 drop comment "tctl_block_192_168_1_50" # handle 40
${TAB}${TAB}ip saddr 192.168.1.33 counter packets 0 bytes 0 drop comment "someone_else" # handle 39
${TAB}}
}
EOF
cat > "$STATE/tm_ratelimit" <<EOF
table netdev tm_ratelimit {
${TAB}chain dl_br_lan {
${TAB}${TAB}ip daddr 192.168.1.60 limit rate over 625000 bytes/second counter packets 7 bytes 900 drop comment "rl_ratelimit_192_168_1_60" # handle 5
${TAB}${TAB}ip daddr 10.0.20.0/24 meter tctl_d_10_0_20_0_24 { ip daddr limit rate over 250000 bytes/second } counter packets 0 bytes 0 drop comment "rl_ratelimit_10_0_20_0_24" # handle 6
${TAB}}
${TAB}chain ul_lan1 {
${TAB}${TAB}ip saddr 192.168.1.60 limit rate over 125000 bytes/second counter packets 0 bytes 0 drop comment "rl_ratelimit_192_168_1_60_ul" # handle 7
${TAB}${TAB}ip saddr 10.0.20.0/24 meter tctl_u_10_0_20_0_24 { ip saddr limit rate over 250000 bytes/second } counter packets 0 bytes 0 drop comment "rl_ratelimit_10_0_20_0_24_ul" # handle 8
${TAB}}
}
EOF
cat > "$RULES" <<'EOF'
[{"type":"block","ip":"192.168.1.50","param":"block_192.168.1.50"},{"type":"block","ip":"192.168.1.90","param":"block_192.168.1.90"},{"type":"ratelimit","ip":"192.168.1.60","param":"5000","mode":"shared","param_up":"1000"},{"type":"ratelimit","ip":"192.168.1.66","param":"2000"},{"type":"pfw_pause","ip":"forward/tcp/192.168.1.5/22","param":""}]
EOF
cat > "$SHAPES" <<'EOF'
[{"ip":"192.168.1.70","rate_kbit":3000,"classid":"1:2"},{"ip":"192.168.1.80","rate_kbit":8000,"classid":"1:3","rate_kbit_up":2000}]
EOF
cat > "$STATE/tc_lan" <<'EOF'
class htb 1:1 root rate 1Gbit ceil 1Gbit burst 1375b cburst 1375b
class htb 1:3 parent 1:1 leaf 30: prio 0 rate 8Mbit ceil 8Mbit burst 1600b cburst 1600b
class htb 1:fffe parent 1:1 prio 0 rate 1Gbit ceil 1Gbit burst 1375b cburst 1375b
EOF
cat > "$STATE/tc_ifb" <<'EOF'
class htb 1:3 parent 1:1 leaf 30: prio 0 rate 2Mbit ceil 2Mbit burst 1600b cburst 1600b
EOF

OUT=$(run "$TMPDIR/rules.sh" list)
if python3 -c 'import json,sys; json.loads(sys.argv[1])' "$OUT" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1)); printf "FAIL: output is not valid JSON:\n%s\n" "$OUT"
fi
assert_eq "nft: firewall reported" '"nft"' "$(top "$OUT" fw)"
assert_eq "nft: persist_rules reported" 'true' "$(top "$OUT" persist_rules)"

# An offline device's block is listed — the point of the feature.
assert_eq "offline block: listed" "192.168.1.50" "$(rec "$OUT" block 192.168.1.50 ip)"
assert_eq "offline block: device is offline" "false" "$(rec "$OUT" block 192.168.1.50 online)"
assert_eq "offline block: applied" "true" "$(rec "$OUT" block 192.168.1.50 applied)"
assert_eq "offline block: persisted" "true" "$(rec "$OUT" block 192.168.1.50 persisted)"
assert_eq "offline block: hostname from the lease" "kid-tablet" "$(rec "$OUT" block 192.168.1.50 name)"
assert_eq "offline block: MAC" "aa:aa:aa:aa:aa:50" "$(rec "$OUT" block 192.168.1.50 mac)"
# The v4 rule and the v6 one are one restriction, not two rows.
assert_eq "offline block: v4 and v6 halves are one record" "1" \
    "$(python3 -c 'import json,sys; print(sum(1 for r in json.loads(sys.argv[1])["rules"] if r["type"]=="block" and r["target"]=="192.168.1.50"))' "$OUT")"
assert_eq "a drop rule this app did not write is not listed" "<none>" "$(rec "$OUT" block 192.168.1.33 ip)"

# Saved but missing from the kernel: shown, and shown as not applied.
assert_eq "saved-only block: listed" "192.168.1.90" "$(rec "$OUT" block 192.168.1.90 target)"
assert_eq "saved-only block: not applied" "false" "$(rec "$OUT" block 192.168.1.90 applied)"
assert_eq "saved-only block: persisted" "true" "$(rec "$OUT" block 192.168.1.90 persisted)"
assert_eq "saved-only block: no lease, no name" "" "$(rec "$OUT" block 192.168.1.90 name)"

# Limits: live values win over saved ones; both directions are reported.
assert_eq "online limit: online" "true" "$(rec "$OUT" ratelimit 192.168.1.60 online)"
assert_eq "online limit: download from the kernel" "5000" "$(rec "$OUT" ratelimit 192.168.1.60 rate_kbit)"
assert_eq "online limit: upload from the kernel" "1000" "$(rec "$OUT" ratelimit 192.168.1.60 rate_kbit_up)"
assert_eq "online limit: applied + persisted" "true true" \
    "$(rec "$OUT" ratelimit 192.168.1.60 applied) $(rec "$OUT" ratelimit 192.168.1.60 persisted)"
assert_eq "subnet limit: listed with its CIDR" "10.0.20.0/24" "$(rec "$OUT" ratelimit 10.0.20.0/24 target)"
assert_eq "subnet limit: per-device mode" "each" "$(rec "$OUT" ratelimit 10.0.20.0/24 mode)"
assert_eq "subnet limit: 2000 kbit/s" "2000" "$(rec "$OUT" ratelimit 10.0.20.0/24 rate_kbit)"
assert_eq "subnet limit: no single online state" "null" "$(rec "$OUT" ratelimit 10.0.20.0/24 online)"
assert_eq "subnet limit: live, not saved (lost on reboot)" "true false" \
    "$(rec "$OUT" ratelimit 10.0.20.0/24 applied) $(rec "$OUT" ratelimit 10.0.20.0/24 persisted)"
# A record from before modes were stored gets the default the restore hook
# gives it, and a symmetric one reports upload = download.
assert_eq "saved-only limit: rate from rules.json" "2000" "$(rec "$OUT" ratelimit 192.168.1.66 rate_kbit)"
assert_eq "saved-only limit: symmetric upload" "2000" "$(rec "$OUT" ratelimit 192.168.1.66 rate_kbit_up)"
assert_eq "saved-only limit: default mode for a host" "shared" "$(rec "$OUT" ratelimit 192.168.1.66 mode)"
assert_eq "saved-only limit: not applied" "false" "$(rec "$OUT" ratelimit 192.168.1.66 applied)"
assert_eq "port-forward records belong to their own tab" "0" \
    "$(python3 -c 'import json,sys; print(sum(1 for r in json.loads(sys.argv[1])["rules"] if "/22" in r["target"]))' "$OUT")"

# Shapes: shapes.json is always written, so it is the list.
assert_eq "shape without a live class: listed" "3000" "$(rec "$OUT" shape 192.168.1.70 rate_kbit)"
assert_eq "shape without a live class: not applied" "false" "$(rec "$OUT" shape 192.168.1.70 applied)"
assert_eq "shape: alias beats the lease, quotes escaped" 'Console "X"' "$(rec "$OUT" shape 192.168.1.70 name)"
assert_eq "live shape: applied" "true" "$(rec "$OUT" shape 192.168.1.80 applied)"
assert_eq "live shape: download from tc" "8000" "$(rec "$OUT" shape 192.168.1.80 rate_kbit)"
assert_eq "live shape: upload from the IFB" "2000" "$(rec "$OUT" shape 192.168.1.80 rate_kbit_up)"
assert_eq "live shape: name from the PTR cache" "printer.lan" "$(rec "$OUT" shape 192.168.1.80 name)"
assert_eq "live shape: online from a reachable neighbour" "true" "$(rec "$OUT" shape 192.168.1.80 online)"

# WiFi: keyed on the MAC; one with no lease still listed, with no address.
assert_eq "wifi deny: MAC with a lease maps to its IP" "192.168.1.50" "$(rec "$OUT" wifi aa:aa:aa:aa:aa:50 ip)"
assert_eq "wifi deny: in the running ACL" "acl" "$(rec "$OUT" wifi aa:aa:aa:aa:aa:50 enforcement)"
assert_eq "wifi deny: applied" "true" "$(rec "$OUT" wifi aa:aa:aa:aa:aa:50 applied)"
assert_eq "wifi deny without a lease: listed, MAC lowercased" "" "$(rec "$OUT" wifi aa:aa:aa:aa:aa:99 ip)"
assert_eq "wifi deny missing from the radio: not applied" "false" "$(rec "$OUT" wifi aa:aa:aa:aa:aa:99 applied)"
assert_eq "everything above and nothing else" "9" "$(count "$OUT")"

# ── persist_rules off: rules.json restricts nothing ────────────────────────
# The restore hook skips the file then, so its records are not restrictions.
echo 0 > "$STATE/persist"
OUT=$(run "$TMPDIR/rules.sh" list)
assert_eq "persist off: reported" "false" "$(top "$OUT" persist_rules)"
assert_eq "persist off: saved-only block not listed" "<none>" "$(rec "$OUT" block 192.168.1.90 target)"
assert_eq "persist off: live block still listed, not persisted" "false" "$(rec "$OUT" block 192.168.1.50 persisted)"
assert_eq "persist off: shapes are still saved" "true" "$(rec "$OUT" shape 192.168.1.70 persisted)"
echo 1 > "$STATE/persist"

# ── whitelist radio: nothing to enumerate, and it says so ──────────────────
echo allow > "$STATE/wifi_mode"
OUT=$(run "$TMPDIR/rules.sh" list)
assert_eq "allow-mode radio: counted" "1" "$(top "$OUT" wifi_allow_ifaces)"
assert_eq "allow-mode radio: its maclist is not read as a deny list" "<none>" "$(rec "$OUT" wifi aa:aa:aa:aa:aa:50 mac)"
echo deny > "$STATE/wifi_mode"

# ── removing what the tab lists, for an offline device ─────────────────────
# Saved-only block: nothing in the kernel to delete, the record must still go.
OUT=$(run "$TMPDIR/unblock.sh" 192.168.1.90)
assert_contains "unblock of a saved-only block reports ok" '"ok":true' "$OUT"
OUT=$(run "$TMPDIR/rules.sh" list)
assert_eq "unblock: the saved-only block is gone from the list" "<none>" "$(rec "$OUT" block 192.168.1.90 target)"

# A limit on a target that never had an IPv6 set (any subnet, any host with no
# known MAC). nft exits 1 deleting the missing set; that used to be reported as
# a failed removal and kept the rules.json record, so the limit came back at
# the next boot.
OUT=$(run "$TMPDIR/ratelimit.sh" 192.168.1.66 0)
assert_contains "removing a limit with no v6 set reports ok" '"ok":true' "$OUT"
assert_eq "rules.json no longer holds the removed limit" "0" "$(grep -c '"ip":"192.168.1.66"' "$RULES")"
OUT=$(run "$TMPDIR/ratelimit.sh" 10.0.20.0/24 0)
assert_contains "removing a subnet limit reports ok" '"ok":true' "$OUT"

# Editing a saved-only limit goes through the same script with a new rate.
: > "$STATE/nft.log"
OUT=$(run "$TMPDIR/ratelimit.sh" 192.168.1.66 3000 "" shared 1500)
assert_contains "editing a limit on an offline host is accepted" '"ok":true' "$OUT"
assert_contains "edit: the new upload ceiling is saved" '"param_up":"1500"' "$(cat "$RULES")"
assert_contains "edit: the new download ceiling is saved" '"ip":"192.168.1.66","param":"3000"' "$(cat "$RULES")"

# WiFi deny of a MAC with no lease and no neighbour entry: removable by MAC.
: > "$STATE/uci.log"
OUT=$(run "$TMPDIR/macfilter-remove.sh" AA:AA:AA:AA:AA:99)
assert_contains "macfilter-remove by MAC: the maclist entry is deleted" \
    "del_list wireless.default_radio0.maclist=aa:aa:aa:aa:aa:99" "$(cat "$STATE/uci.log")"
assert_contains "macfilter-remove by MAC: names the MAC" "aa:aa:aa:aa:aa:99" "$OUT"
OUT=$(run "$TMPDIR/macfilter-remove.sh" 192.168.1.99)
assert_contains "macfilter-remove by IP with no lease still fails as before" "cannot find MAC" "$OUT"
OUT=$(run "$TMPDIR/macfilter-remove.sh" 'aa:bb;reboot')
assert_contains "macfilter-remove: a malformed MAC is rejected" '"ok":false' "$OUT"
OUT=$(run "$TMPDIR/macfilter-remove.sh" "$(printf 'aa:aa:aa:aa:aa:99\nx')")
assert_contains "macfilter-remove: a MAC followed by a second line is rejected" '"ok":false' "$OUT"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
