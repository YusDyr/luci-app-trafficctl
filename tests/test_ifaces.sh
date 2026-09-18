#!/bin/bash
# Tests for trafficctl-ifaces.sh — the per-interface counter source behind the
# global (bmon-style) overview.
#
# Everything the script touches is behind an env seam (TCTL_PROC_NET_DEV,
# TCTL_SYSFS_NET, TCTL_IFROLE_CACHE, TCTL_IFROLE_TTL), so the whole thing runs
# unprivileged against fixtures. The two external commands it forks on the cold
# path — `ip route` and `ubus call` — are mocked on PATH, and each invocation is
# logged, which is what lets the memoization tests assert that the HOT path
# forks nothing at all.
#
# `. /usr/local/bin/trafficctl-fw.sh` is an absolute path in the shipped
# script, so a copy with that prefix rewritten to the stub dir is what actually
# runs here — the same trick tests/test_byte_overflow.sh uses for metrics.sh.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MOCKBIN="$TMP/bin"
STUBLIB="$TMP/lib"
SYSFS="$TMP/sys"
CACHE="$TMP/ifroles"
PROC="$TMP/net_dev"
FORKLOG="$TMP/forks.log"
mkdir -p "$MOCKBIN" "$STUBLIB" "$SYSFS"

# The script under test, with the hard-coded library path pointed at the stub.
SCRIPT="$TMP/ifaces.sh"
sed "s|/usr/local/bin/|$STUBLIB/|g" "$BIN/trafficctl-ifaces.sh" > "$SCRIPT"

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

# The stub library stands in for trafficctl-fw.sh: sourcing the real one runs
# `nft list tables` and a ubus/jsonfilter pipeline per configured network, which
# is precisely the cost the cache exists to avoid.
write_fwlib() {   # write_fwlib "<lan devices, newline separated>"
    cat > "$STUBLIB/trafficctl-fw.sh" <<STUB
#!/bin/sh
echo "fwlib" >> "$FORKLOG"
tctl_get_lan_devices() { printf '%s\n' "$1"; }
STUB
}

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

# A cut-down `ubus call network.interface dump`. The shape matters more than the
# content: the outer '"interface": [' line carries no string value and must not
# seed a name, while the inner '"interface": "wan"' must.
write_ubus() {   # write_ubus "<iface>=<l3dev>" ...
    {
        printf '#!/bin/sh\n'
        printf 'echo "ubus $*" >> "%s"\n' "$FORKLOG"
        printf "cat <<'JSON'\n"
        printf '{\n\t"interface": [\n'
        local first=1 pair name dev
        for pair in "$@"; do
            name="${pair%%=*}"; dev="${pair#*=}"
            [ "$first" = 1 ] || printf '\t\t},\n'
            first=0
            printf '\t\t{\n\t\t\t"interface": "%s",\n\t\t\t"up": true,\n\t\t\t"l3_device": "%s",\n' "$name" "$dev"
        done
        printf '\t\t}\n\t]\n}\nJSON\n'
    } > "$MOCKBIN/ubus"
    chmod +x "$MOCKBIN/ubus"
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

run_ifaces() {
    PATH="${AWK_SHIM:+$AWK_SHIM:}$MOCKBIN:$PATH" \
    TCTL_IFROLE_CACHE="$CACHE" \
    TCTL_PROC_NET_DEV="$PROC" \
    TCTL_SYSFS_NET="$SYSFS" \
    TCTL_IFROLE_TTL="${TTL_OVERRIDE:-60}" \
        sh "$SCRIPT" 2>/dev/null
}

reset_state() {
    rm -f "$CACHE" "$FORKLOG"
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

write_fwlib "br-lan"
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

write_fwlib "br-lan"
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
write_fwlib ""
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
write_fwlib "br-lan"
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
write_fwlib "br-lan"
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
write_fwlib "br-lan"
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
assert_eq "…and forks neither ip nor ubus" "0" "$(wc -l < "$FORKLOG" | tr -d ' ')"

# Same cache, now older than the TTL.
{
    printf '# %s\n' "$(( $(date +%s) - 3600 ))"
    printf 'eth1 other 0 0 0 0 bogus-label\n'
    printf 'br-lan other 0 0 0 0 bogus-lan\n'
} > "$CACHE"
: > "$FORKLOG"

OUT=$(run_ifaces)
assert_contains "an expired cache is rebuilt" '"label":"wan","role":"wan"' "$OUT"
assert_contains "…which is what forks ubus" "ubus call network.interface dump" "$(cat "$FORKLOG")"

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
assert_contains "…by exactly one rebuild" "ubus call network.interface dump" "$(cat "$FORKLOG")"
assert_eq "…not a rebuild loop" "1" \
    "$(grep -c 'ubus call network.interface dump' "$FORKLOG" | tr -d ' ')"

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
# 8. The 2 GiB ceiling (#56), in THIS code path specifically.
#
#    /proc/net/dev is the worst case in the whole tree: the counters are 64-bit
#    and an interface on a router that has been up for a few days is past 2 GiB
#    by definition, so a %d here would be wrong almost immediately rather than
#    in some corner case.
#
#    Two layers, for the same reason test_byte_overflow.sh has two:
#      * behavioural — run the script with every awk on the box, including a
#        32-bit one if present. This is real coverage on a router and on any
#        box with busybox, and it is the layer that would catch a %d.
#      * static — pin the printf site literally. Interpreter-independent, so it
#        is what actually fails on a GitHub runner, where awk is gawk and %d is
#        64-bit clean (i.e. the behavioural layer passes even WITH the bug).
# ════════════════════════════════════════════════════════════════════════════

{
    netdev_header
    netdev_row eth1 "$BIG" "$HUGE"
} > "$PROC"
write_fwlib ""
write_ip "" ""
write_ubus

AWKS=""
for cand in gawk mawk awk; do
    command -v "$cand" >/dev/null 2>&1 && AWKS="$AWKS $cand"
done
if command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{}' 2>/dev/null; then
    AWKS="$AWKS busybox-awk"
fi

NARROW=""
for a in $AWKS; do
    shim="$TMP/shim-$a"
    mkdir -p "$shim"
    case "$a" in
        busybox-awk) printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$shim/awk" ;;
        *) printf '#!/bin/sh\nexec %s "$@"\n' "$(command -v "$a")" > "$shim/awk" ;;
    esac
    chmod +x "$shim/awk"

    # Is this one of the awks that mangles %d? Recorded so the closing note can
    # say whether the behavioural layer was real coverage or vacuous.
    got=$("$shim/awk" -v v="$BIG" 'BEGIN{ printf "%d", v }' 2>/dev/null)
    [ "$got" = "$BIG" ] || NARROW="$NARROW $a"

    reset_state
    OUT=$(AWK_SHIM="$shim" run_ifaces)
    assert_contains "$a: rx_bytes past 2 GiB survives the whole script" \
        "\"rx_bytes\":$BIG" "$OUT"
    assert_contains "$a: tx_bytes at 2^53-1 survives the whole script" \
        "\"tx_bytes\":$HUGE" "$OUT"
    assert_not_contains "$a: no clamped value in the output" '2147483647' "$OUT"
    assert_not_contains "$a: no wrapped value in the output" '-2147483648' "$OUT"
    # A byte count with a decimal point would break the consumers that re-parse
    # this with an integer regex just as badly as a truncated one.
    assert_not_contains "$a: byte fields carry no decimal point" '.0,' "$OUT"
done

# The static half. Pinned to the literal printf so a future edit cannot quietly
# swap the conversion back; the repo-wide scan in test_byte_overflow.sh covers
# the same site from the other direction, and both are cheap.
assert_contains "ifaces.sh: the counter printf uses %.0f, never %d" \
    '\"rx_bytes\":%.0f,\"tx_bytes\":%.0f' \
    "$(cat "$BIN/trafficctl-ifaces.sh")"
assert_eq "ifaces.sh: no %d anywhere near a byte field" "" \
    "$(grep -nE '"[a-z_]*bytes[a-z_]*\\?":%d' "$BIN/trafficctl-ifaces.sh")"

# ════════════════════════════════════════════════════════════════════════════

if [ -z "$NARROW" ]; then
    echo
    echo "NOTE: no 32-bit awk is installed here, so the behavioural half of"
    echo "section 8 passed vacuously — it cannot fail without one. Install"
    echo "busybox to exercise it. The static assertions are what guard this"
    echo "in CI."
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
