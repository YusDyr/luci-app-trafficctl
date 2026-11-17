#!/bin/bash
# Tests for `trafficctl ifaces`: the per-interface counter source behind the
# global (bmon-style) overview.
#
# The CLI runs against a scratch TCTL_ROOT (proc/net/dev, sys/class/net, the
# role cache), its uci config, and a ubus-mock serving the network.interface
# dump. `ip` is mocked on PATH; it and the mock log every call, which is what
# lets the memoization tests assert that the HOT path forks nothing at all.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PASS=0
FAIL=0

export TCTL_ROOT="$UC_TMP/root"
MOCKBIN="$UC_TMP/bin"
UB="$UC_TMP/ubus"
SYSFS="$TCTL_ROOT/sys/class/net"
CACHE="$TCTL_ROOT/tmp/trafficctl_ifroles"
PROC="$TCTL_ROOT/proc/net/dev"
FORKLOG="$UC_TMP/forks.log"
mkdir -p "$MOCKBIN" "$UB" "$SYSFS" "$TCTL_ROOT/proc/net" "$TCTL_ROOT/etc/config" "$TCTL_ROOT/tmp/.uci"

# The LAN is whatever the lan zone's networks resolve to in the dump.
cat > "$TCTL_ROOT/etc/config/firewall" <<'EOF'
config zone
	option name 'lan'
	list network 'lan'

config zone
	option name 'wan'
	option masq '1'
	list network 'wan'
EOF

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

# ── fixtures ────────────────────────────────────────────────────────────────

write_ip() {   # write_ip "<v4 default route line>" "<v6 default route line>"
    cat > "$MOCKBIN/ip" <<MOCK
#!/bin/sh
echo "ip \$*" >> "$FORKLOG"
case "\$*" in
    "-4 route show default") printf '%s\n' "$1" ;;
    "-6 route show default") printf '%s\n' "$2" ;;
esac
exit 0
MOCK
    chmod +x "$MOCKBIN/ip"
}

# `ubus call network.interface dump`, in the order given: whichever entry the
# dump ends with must not decide a label. "lan" gets an address, which is what
# makes its device the LAN.
write_ubus() {   # write_ubus "<iface>=<l3dev>" ...
    local pair name dev sep="" addr
    {
        printf '{"interface":['
        for pair in "$@"; do
            name="${pair%%=*}"; dev="${pair#*=}"; addr=""
            [ "$name" = lan ] && addr=',"ipv4-address":[{"address":"192.168.1.1","mask":24}]'
            printf '%s{"interface":"%s","up":true,"l3_device":"%s"%s}' "$sep" "$name" "$dev" "$addr"
            sep=","
        done
        printf ']}\n'
    } > "$UB/network.interface@dump.json"
}

write_operstate() {   # write_operstate <dev> <state>
    mkdir -p "$SYSFS/$1"
    printf '%s\n' "$2" > "$SYSFS/$1/operstate"
}

# Enslavement, as the kernel exposes it: /sys/class/net/<port>/master is a
# symlink to the bridge's directory, so master/ifindex is readable exactly when
# the device is a bridge port.
write_master() {   # write_master <port> <bridge-ifindex>
    mkdir -p "$SYSFS/$1/master"
    printf '%s\n' "$2" > "$SYSFS/$1/master/ifindex"
}

# /proc/net/dev: two header lines, then "<name>: <16 counters>".
# Column 1 after the colon is rx_bytes, column 9 is tx_bytes.
netdev_header() {
    printf 'Inter-|   Receive                                                |  Transmit\n'
    printf ' face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n'
}
netdev_row() {   # netdev_row <name> <rx_bytes> <tx_bytes>
    printf '%6s: %s 10 0 0 0 0 0 0 %s 20 0 0 0 0 0 0\n' "$1" "$2" "$3"
}

# The mock reads its replies at start, so each run gets a fresh one; its call
# log goes to the same FORKLOG as ip.
run_ifaces() {
    ubus_start "$UB" "$FORKLOG"
    PATH="$MOCKBIN:$PATH" tctl ifaces 2>/dev/null
    ubus_stop
}

reset_state() {
    rm -f "$CACHE"
    : > "$FORKLOG"
}

# ════════════════════════════════════════════════════════════════════════════
# 0. A REAL router, not a tidy fixture.
#
#    OpenWrt 24.10 with four AmneziaWG tunnels, a DSA switch (lan2/lan3/lan4 +
#    wan), two APs bridged into br-lan, and a dual-stack uplink where three uci
#    interfaces — wan, wan6 and wan6_alias0 — share the l3_device "wan".
#
#    Every earlier fixture in this file was tidy enough that three separate
#    defects survived it: defroute true on every "other" device, the uplink
#    titled "wan6_alias0", and bridge ports listed alongside the bridge that
#    already counts their bytes. This section exists so that cannot recur.
# ════════════════════════════════════════════════════════════════════════════

{
    netdev_header
    netdev_row lo 1234 1234
    netdev_row eth0 380322298613 40000000000   # DSA conduit, carries everything
    netdev_row wan  373121091511 30000000000   # DSA user port, the uplink
    netdev_row lan2 9000 8000                  # bridge port
    netdev_row lan3 7000 6000                  # bridge port
    netdev_row lan4 0 0                        # bridge port, down
    netdev_row phy0-ap0 5000 4000              # AP, bridge port
    netdev_row phy1-ap0 3000 2000              # AP, bridge port
    netdev_row br-lan 26008166902 20000000000
    netdev_row awg0 100 200
    netdev_row awg1 300 400
    netdev_row awg2 500 600
    netdev_row awg3 700 800
    # This package's own shaper ifb. Not enslaved, not a LAN, not a tunnel, so
    # it reaches the WAN branch of the role chain — which is what makes it a
    # second, independent witness for the auto-vivification bug below, instead
    # of relying on eth0 alone.
    netdev_row tctl-ifb0 1000 2000
} > "$PROC"

write_ip "default via 188.242.0.1 dev wan proto static" ""
# Three uci interfaces on one l3_device, emitted worst-name-last on purpose:
# whichever the dump happens to end with must NOT be the one that wins.
write_ubus "wan=wan" "wan6=wan" "wan6_alias0=wan" "lan=br-lan" \
           "awg0=awg0" "awg1=awg1" "awg2=awg2" "awg3=awg3"
for d in eth0 wan lan2 lan3 phy0-ap0 phy1-ap0 br-lan awg0 awg1 awg2 awg3 tctl-ifb0; do
    write_operstate "$d" up
done
write_operstate lan4 down
for p in lan2 lan3 lan4 phy0-ap0 phy1-ap0; do
    write_master "$p" 7
done
reset_state

OUT=$(run_ifaces)
ROWS=$(printf '%s' "$OUT" | sed 's/},{/}\n{/g')

# ── defect 1: awk auto-vivification made defroute true almost everywhere ────
# Referencing isdef[d] in a condition CREATES the element, so a later `d in
# isdef` test was true for every device that merely reached that condition.
assert_eq "exactly one device carries the default route" "1" \
    "$(printf '%s' "$OUT" | grep -o '"defroute":true' | wc -l | tr -d ' ')"
assert_eq "…and it is the uplink" "1" \
    "$(printf '%s' "$ROWS" | grep -c '"dev":"wan".*"defroute":true')"
# eth0 and tctl-ifb0 both reach the WAN branch of the role chain, so both are
# witnesses independent of the enslavement fix short-circuiting the others.
for d in eth0 tctl-ifb0 lan2 lan3 lan4 phy0-ap0 phy1-ap0 br-lan awg0; do
    assert_eq "defroute is false on $d" "1" \
        "$(printf '%s' "$ROWS" | grep -c "\"dev\":\"$d\".*\"defroute\":false")"
done

# ── defect 2: the last uci name on a shared l3_device won ───────────────────
assert_eq "a dual-stack uplink is titled 'wan', not the v6 alias" "1" \
    "$(printf '%s' "$ROWS" | grep -c '"dev":"wan","label":"wan"')"
assert_not_contains "the alias name never becomes the label" '"label":"wan6_alias0"' "$OUT"
assert_not_contains "nor does the v6 name" '"label":"wan6"' "$OUT"

# ── defect 3: bridge ports counted the same bytes as their bridge ───────────
for p in lan2 lan3 lan4 phy0-ap0 phy1-ap0; do
    assert_eq "$p is marked enslaved" "1" \
        "$(printf '%s' "$ROWS" | grep -c "\"dev\":\"$p\".*\"enslaved\":true")"
    # role "other" is what puts it behind the UI's collapsed expander instead
    # of in the top-level list next to the bridge.
    assert_eq "$p is demoted out of the top-level list" "1" \
        "$(printf '%s' "$ROWS" | grep -c "\"dev\":\"$p\",\"label\":\"$p\",\"role\":\"other\"")"
done
assert_eq "the bridge itself is NOT enslaved" "1" \
    "$(printf '%s' "$ROWS" | grep -c '"dev":"br-lan".*"enslaved":false')"
assert_eq "the uplink is NOT enslaved" "1" \
    "$(printf '%s' "$ROWS" | grep -c '"dev":"wan".*"enslaved":false')"
# The DSA conduit beneath the uplink carries the same bytes again. It is not a
# bridge port, so it lands in "other" on role rather than enslavement — either
# way it must not appear as a second WAN.
assert_eq "the DSA conduit is not a second WAN" "1" \
    "$(printf '%s' "$ROWS" | grep -c '"dev":"eth0","label":"eth0","role":"other"')"
assert_eq "exactly one device has role wan" "1" \
    "$(printf '%s' "$OUT" | grep -o '"role":"wan"' | wc -l | tr -d ' ')"
assert_eq "exactly one device is primary" "1" \
    "$(printf '%s' "$OUT" | grep -o '"primary":true' | wc -l | tr -d ' ')"

# ── the rest of the topology still classifies correctly ─────────────────────
assert_eq "the bridge is the LAN" "1" \
    "$(printf '%s' "$ROWS" | grep -c '"dev":"br-lan","label":"lan","role":"lan"')"
assert_eq "all four tunnels are VPNs" "4" \
    "$(printf '%s' "$OUT" | grep -o '"role":"vpn"' | wc -l | tr -d ' ')"
assert_contains "a tunnel keeps its uci name" '"dev":"awg2","label":"awg2","role":"vpn"' "$OUT"
assert_eq "the down bridge port reports down" "1" \
    "$(printf '%s' "$ROWS" | grep -c '"dev":"lan4".*"up":false')"
assert_contains "the uplink's 373 GB counter is intact" '"rx_bytes":373121091511' "$OUT"
assert_eq "output is brace-balanced JSON" "0" \
    "$(printf '%s' "$OUT" | tr -cd '{}' | awk '{o=gsub(/\{/,"");c=gsub(/\}/,"")} END{print (o==c)?0:1}')"

# Label preference must not depend on the order ubus happened to emit. Same
# three interfaces, reversed.
write_ubus "wan6_alias0=wan" "wan6=wan" "wan=wan" "lan=br-lan"
reset_state
OUT=$(run_ifaces)
assert_eq "label choice is independent of dump order" "1" \
    "$(printf '%s' "$OUT" | sed 's/},{/}\n{/g' | grep -c '"dev":"wan","label":"wan"')"

# And with ONLY the v6 alias present, the device still gets a usable name and is
# still recognised as the uplink rather than falling through to "other".
write_ubus "wan6_alias0=wan" "lan=br-lan"
reset_state
OUT=$(run_ifaces)
assert_contains "an alias-only uplink is still a WAN" '"dev":"wan","label":"wan6_alias0","role":"wan"' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# 1. Roles on a full-tunnel router — the configuration this has to get right.
#
#    The default route is via awg0, but the encapsulated bytes still cross the
#    physical uplink. Calling awg0 "the WAN" would hide eth1 under "other" AND
#    count the same traffic twice in any WAN total.
# ════════════════════════════════════════════════════════════════════════════

BIG=5368709120          # 5 GiB, past the 32-bit %d clamp
HUGE=9007199254740991   # 2^53-1, the largest integer a double holds exactly

{
    netdev_header
    netdev_row lo 1234 1234
    netdev_row eth1 "$BIG" "$HUGE"
    netdev_row br-lan 111 222
    netdev_row awg0 333 444
    netdev_row eth0 555 666
} > "$PROC"

write_ip "default via 10.8.0.1 dev awg0 proto static" ""
write_ubus "wan=eth1" "lan=br-lan" "vpn_fi=awg0"
write_operstate eth1 up
write_operstate br-lan up
write_operstate awg0 down
write_operstate eth0 down
reset_state

OUT=$(run_ifaces)

assert_contains "physical uplink is the WAN even when a tunnel holds the default route" \
    '"dev":"eth1","label":"wan","role":"wan","tunnel":false,"primary":true,"defroute":false' "$OUT"
assert_contains "the default-route tunnel stays a tunnel, and says so" \
    '"dev":"awg0","label":"vpn_fi","role":"vpn","tunnel":true,"primary":false,"defroute":true' "$OUT"
assert_contains "monitored L3 device is the LAN" \
    '"dev":"br-lan","label":"lan","role":"lan"' "$OUT"
assert_contains "an unclassified device falls through to other" \
    '"dev":"eth0","label":"eth0","role":"other"' "$OUT"
assert_not_contains "loopback is excluded" '"dev":"lo"' "$OUT"
assert_not_contains "the #MISS sentinel never reaches stdout" '#MISS' "$OUT"
assert_eq "output is brace-balanced JSON" "0" \
    "$(printf '%s' "$OUT" | tr -cd '{}' | awk '{o=gsub(/\{/,"");c=gsub(/\}/,"")} END{print (o==c)?0:1}')"

# Exactly one primary, or the headline graph has nothing to pick.
assert_eq "exactly one interface is flagged primary" "1" \
    "$(printf '%s' "$OUT" | grep -o '"primary":true' | wc -l | tr -d ' ')"

# ── 64-bit counters ─────────────────────────────────────────────────────────
# /proc/net/dev counters are the worst case for the %d bug (#56): an interface
# on a router that has been up for days is past 2 GiB by definition.
assert_contains "rx_bytes past 2 GiB is emitted intact" "\"rx_bytes\":$BIG" "$OUT"
assert_contains "tx_bytes at 2^53-1 is emitted intact" "\"tx_bytes\":$HUGE" "$OUT"
assert_not_contains "no 32-bit clamp in the output" '2147483647' "$OUT"
assert_not_contains "no 32-bit wrap in the output" '-2147483648' "$OUT"

# ── operstate ───────────────────────────────────────────────────────────────
assert_contains "an interface that is up reports up:true" '"dev":"eth1"' "$OUT"
assert_eq "operstate down is reported, not hidden" "1" \
    "$(printf '%s' "$OUT" | sed 's/},{/}\n{/g' | grep -c '"dev":"awg0".*"up":false')"

# ════════════════════════════════════════════════════════════════════════════
# 2. The colon split.
#
#    The kernel pads the name field to a fixed width, so a name long enough to
#    fill it leaves NO space before rx_bytes. Splitting on whitespace shifts
#    every counter by one column and reports rx_bytes as the packet count.
# ════════════════════════════════════════════════════════════════════════════

{
    netdev_header
    printf 'enp0s31f6:%s 10 0 0 0 0 0 0 4242 20 0 0 0 0 0 0\n' "$BIG"
} > "$PROC"
write_ip "" ""
write_ubus
reset_state

OUT=$(run_ifaces)
assert_contains "a name that fills the pad leaves no space, and still parses" \
    '"dev":"enp0s31f6"' "$OUT"
assert_contains "…with rx_bytes taken from the right column" "\"rx_bytes\":$BIG" "$OUT"
assert_contains "…and tx_bytes from the right column" '"tx_bytes":4242' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# 3. PPPoE is an uplink, not a VPN.
#
#    `ppp*` looks tunnel-shaped but pppoe-wan is the standard OpenWrt DSL
#    uplink; badging it as a VPN would be wrong on every PPPoE line.
# ════════════════════════════════════════════════════════════════════════════

{
    netdev_header
    netdev_row pppoe-wan 900 800
    netdev_row br-lan 1 2
} > "$PROC"
write_ip "default via 1.2.3.4 dev pppoe-wan proto static" ""
write_ubus "wan=pppoe-wan" "lan=br-lan"
reset_state

OUT=$(run_ifaces)
assert_contains "pppoe-wan is a WAN, not a tunnel" \
    '"dev":"pppoe-wan","label":"wan","role":"wan","tunnel":false,"primary":true' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# 4. Tunnel-only router: nothing would be a WAN, so the route holder is
#    promoted rather than leaving the overview headline blank.
# ════════════════════════════════════════════════════════════════════════════

{
    netdev_header
    netdev_row wg0 10 20
    netdev_row br-lan 1 2
} > "$PROC"
write_ip "default via 10.9.0.1 dev wg0 proto static" ""
write_ubus "lan=br-lan" "vpn=wg0"
reset_state

OUT=$(run_ifaces)
assert_contains "with no uplink at all, the default-route tunnel is promoted to WAN" \
    '"dev":"wg0","label":"vpn","role":"wan","tunnel":true,"primary":true' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# 5. Memoization — the reason this is cheap enough to poll every 2 s.
#
#    Asserted from BOTH sides: a fresh cache must be believed even when it is
#    wrong (proving the hot path never rebuilds), and an expired one must be
#    rebuilt.
# ════════════════════════════════════════════════════════════════════════════

{
    netdev_header
    netdev_row eth1 10 20
    netdev_row br-lan 1 2
} > "$PROC"
write_ip "default via 1.2.3.4 dev eth1 proto static" ""
write_ubus "wan=eth1" "lan=br-lan"
reset_state

# Deliberately wrong roles, stamped with the current time.
{
    printf '# %s\n' "$(date +%s)"
    printf 'eth1 other 0 0 0 0 bogus-label\n'
    printf 'br-lan other 0 0 0 0 bogus-lan\n'
} > "$CACHE"

OUT=$(run_ifaces)
assert_contains "a fresh cache is believed verbatim — the hot path does not reclassify" \
    '"label":"bogus-label","role":"other"' "$OUT"
assert_eq "…and calls neither ip nor ubus" "0" "$(wc -l < "$FORKLOG" | tr -d ' ')"

# Same cache, now older than the TTL.
{
    printf '# %s\n' "$(( $(date +%s) - 3600 ))"
    printf 'eth1 other 0 0 0 0 bogus-label\n'
    printf 'br-lan other 0 0 0 0 bogus-lan\n'
} > "$CACHE"
: > "$FORKLOG"

OUT=$(run_ifaces)
assert_contains "an expired cache is rebuilt" '"label":"wan","role":"wan"' "$OUT"
assert_contains "…which is what forks ubus" "network.interface dump" "$(cat "$FORKLOG")"

# ════════════════════════════════════════════════════════════════════════════
# 6. A brand-new interface does not wait out the TTL.
#
#    A tunnel coming up or a USB modem being plugged in must be classified on
#    the very next poll, not up to 60 s later, so a cache miss triggers one
#    rebuild and a re-emit inside the same invocation.
# ════════════════════════════════════════════════════════════════════════════

{
    netdev_header
    netdev_row eth1 10 20
    netdev_row br-lan 1 2
    netdev_row awg3 30 40
} > "$PROC"
write_ubus "wan=eth1" "lan=br-lan" "vpn_by=awg3"
: > "$FORKLOG"

# Fresh cache — but it predates awg3, so believing it blindly would park the
# new tunnel in "other" until the TTL expired.
{
    printf '# %s\n' "$(date +%s)"
    printf 'eth1 wan 0 1 1 0 wan\n'
    printf 'br-lan lan 0 0 0 0 lan\n'
} > "$CACHE"

OUT=$(run_ifaces)
assert_contains "an interface absent from a FRESH cache is reclassified immediately" \
    '"dev":"awg3","label":"vpn_by","role":"vpn","tunnel":true' "$OUT"
assert_not_contains "…and the sentinel that triggered it is stripped" '#MISS' "$OUT"
assert_contains "…by exactly one rebuild" "network.interface dump" "$(cat "$FORKLOG")"
assert_eq "…not a rebuild loop" "1" \
    "$(grep -c 'network.interface dump' "$FORKLOG" | tr -d ' ')"

# ════════════════════════════════════════════════════════════════════════════
# 7. Degenerate inputs yield an empty array, never a syntax error the frontend
#    would surface as a broken panel.
# ════════════════════════════════════════════════════════════════════════════

rm -f "$PROC"
reset_state
OUT=$(run_ifaces)
assert_eq "a missing /proc/net/dev yields []" "[]" "$OUT"

netdev_header > "$PROC"
reset_state
OUT=$(run_ifaces)
assert_eq "headers with no interfaces yield []" "[]" "$OUT"

{
    netdev_header
    printf 'garbage without a colon\n'
    printf 'short: 1 2 3\n'
} > "$PROC"
reset_state
OUT=$(run_ifaces)
assert_eq "malformed rows are skipped rather than emitted half-parsed" "[]" "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# 8. Counters are 64-bit integers end to end (#56): never clamped, wrapped,
#    rounded through a double, or printed with a decimal point.
# ════════════════════════════════════════════════════════════════════════════

MAX=9223372036854775807   # 2^63-1, past what a double holds exactly
{
    netdev_header
    netdev_row eth1 "$BIG" "$MAX"
} > "$PROC"
write_ip "" ""
write_ubus
reset_state
OUT=$(run_ifaces)
assert_contains "rx_bytes past 2 GiB is exact" "\"rx_bytes\":$BIG" "$OUT"
assert_contains "tx_bytes at 2^63-1 is exact" "\"tx_bytes\":$MAX" "$OUT"
assert_not_contains "no decimal point in a byte field" '.0,' "$OUT"
assert_not_contains "no exponent in a byte field" 'e+' "$OUT"

# ── the role cache keeps the format `trafficctl device` reads ──────────────
{
    netdev_header
    netdev_row wan 1 2
    netdev_row br-lan 3 4
    netdev_row awg0 5 6
} > "$PROC"
write_ip "default via 1.2.3.4 dev wan proto static" ""
write_ubus "wan=wan" "lan=br-lan"
reset_state
run_ifaces >/dev/null
assert_eq "cache: '# <epoch>' header" "1" "$(head -1 "$CACHE" | grep -cE '^# [0-9]+$')"
assert_eq "cache: one 'dev role tun prim dfl ens label' line per device" \
    "wan wan 0 1 1 0 wan|br-lan lan 0 0 0 0 lan|awg0 vpn 1 0 0 0 -" \
    "$(tail -n +2 "$CACHE" | paste -sd '|')"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
