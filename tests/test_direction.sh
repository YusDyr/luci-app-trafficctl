#!/bin/bash
# Regression tests: rate limiting and shaping must apply to BOTH directions.
#
# The original implementations only ever touched download (nft matched
# "ip daddr" at WAN ingress; tc built an HTB tree on the LAN device only), so a
# limited device still uploaded at full line rate. These assert the upload half
# exists and is removed again.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"
NFT_LOG="$TMPDIR/nft.log"
TC_LOG="$TMPDIR/tc.log"

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

# ── mocks ────────────────────────────────────────────────────────────────────
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    network.wan.device) echo "eth1" ;;
    network.lan.device) echo "br-lan" ;;
    # Patterns quoted: [0] is a glob character class otherwise, so these
    # would never match the literal uci key.
    "firewall.@zone[0].name") echo "lan" ;;
    "firewall.@zone[0].network") echo "lan" ;;
    *) exit 1 ;;
esac
MOCK

cat > "$MOCKBIN/ubus" <<'MOCK'
#!/bin/sh
case "$2" in
    network.interface.wan) echo '{"l3_device":"eth1"}' ;;
    *) echo '{"l3_device":"br-lan","ipv4-address":[{"address":"192.168.1.1","mask":24}]}' ;;
esac
MOCK

# Parses its stdin rather than hardcoding, so the wan/lan distinction survives.
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
input=$(cat)
case "$2" in
    '@.l3_device') echo "$input" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].address') echo "$input" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].mask') echo "$input" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p' ;;
esac
MOCK

IP_LOG="$TMPDIR/ip.log"
cat > "$MOCKBIN/ip" <<MOCK
#!/bin/sh
echo "\$*" >> "$IP_LOG"
case "\$*" in
    "link show tctl-ifb0") exit 1 ;;   # not created yet
esac
exit 0
MOCK

cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
echo "\$*" >> "$NFT_LOG"
case "\$*" in
    "list tables") echo "table inet fw4" ;;
esac
exit 0
MOCK

cat > "$MOCKBIN/tc" <<MOCK
#!/bin/sh
echo "\$*" >> "$TC_LOG"
case "\$*" in
    "class show dev tctl-ifb0") echo "class htb 1:1 root rate 1000Mbit" ;;
    "filter show dev tctl-ifb0 parent 1:")
        echo "filter parent 1: protocol ip pref 10 u32 chain 0 fh 800::800 order 2048 key ht 800 bkt 0 *flowid 1:2 not_in_hw"
        echo "  match c0a80132/ffffffff at 12" ;;
    *"class show"*) exit 0 ;;
esac
exit 0
MOCK

chmod +x "$MOCKBIN"/*

# tc needs the WAN device to look present
mkdir -p "$TMPDIR/sys/class/net/eth1"

# br-lan is a bridge with two physical ports. Ingress hooks must land on the
# PORTS: a netdev ingress hook bound to the bridge itself never sees bridged
# traffic, which is how upload limiting silently did nothing.
mkdir -p "$TMPDIR/sys/class/net/br-lan/brif/lan1" \
         "$TMPDIR/sys/class/net/br-lan/brif/lan2"
export TCTL_SYSFS_NET="$TMPDIR/sys/class/net"

# ── WAN device resolution ────────────────────────────────────────────────────
# The old code fell back to the literal string "wan", which is an interface
# name rather than a device: nft rejected the chain and download limiting
# silently did nothing.
WANDEV=$(PATH="$MOCKBIN:$PATH" sh -c ". $BIN/trafficctl-fw.sh; tctl_get_wan_device")
assert_contains "wan: resolves to a real device" "eth1" "$WANDEV"

# With no resolvable candidate, it must fail rather than emit a bogus name.
cat > "$MOCKBIN/ubus" <<'MOCK'
#!/bin/sh
echo '{}'
MOCK
cat > "$MOCKBIN/uci_nowan" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/ubus" "$MOCKBIN/uci_nowan"
OUT=$(PATH="$MOCKBIN:$PATH" sh -c "cp $MOCKBIN/uci_nowan $MOCKBIN/uci; . $BIN/trafficctl-fw.sh; tctl_get_wan_device || echo NO_WAN" 2>/dev/null)
assert_contains "wan: reports failure instead of the literal 'wan'" "NO_WAN" "$OUT"

# restore working mocks
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    network.wan.device) echo "eth1" ;;
    network.lan.device) echo "br-lan" ;;
    "firewall.@zone[0].name") echo "lan" ;;
    "firewall.@zone[0].network") echo "lan" ;;
    *) exit 1 ;;
esac
MOCK
cat > "$MOCKBIN/ubus" <<'MOCK'
#!/bin/sh
case "$2" in
    network.interface.wan) echo '{"l3_device":"eth1"}' ;;
    *) echo '{"l3_device":"br-lan","ipv4-address":[{"address":"192.168.1.1","mask":24}]}' ;;
esac
MOCK
chmod +x "$MOCKBIN/uci" "$MOCKBIN/ubus"

# ── limiter: both directions ─────────────────────────────────────────────────
: > "$NFT_LOG"
PATH="$MOCKBIN:$PATH" sh -c ". $BIN/trafficctl-fw.sh; tctl_ratelimit_add 192.168.1.50 5000 rl_test" >/dev/null 2>&1
NFT=$(cat "$NFT_LOG")

# Download is policed at LAN EGRESS on the BRIDGE. At WAN ingress the packet
# is still addressed to the router's masqueraded WAN address — conntrack only
# restores the client address in prerouting, after the netdev ingress hook — so
# a daddr match there never fires for a NATed client. The bridge (not its
# ports) is the right device: the IP stack transmits to br-lan, and the
# port-level egress hook does not fire for routed traffic.
assert_contains "limiter: download chain hooked on LAN egress" \
    "add chain netdev tm_ratelimit dl_br_lan { type filter hook egress device br-lan priority 0" "$NFT"
assert_contains "limiter: download rule matches daddr" \
    "add rule netdev tm_ratelimit dl_br_lan ip daddr 192.168.1.50 limit rate over 625000 bytes/second" "$NFT"

if printf '%s' "$NFT" | grep -q "hook egress device lan1"; then
    FAIL=$((FAIL + 1))
    printf "FAIL: limiter: egress hook bound to a bridge port, where it never fires\n"
else
    PASS=$((PASS + 1))
fi

assert_contains "limiter: upload chain on first bridge port" \
    "add chain netdev tm_ratelimit ul_lan1 { type filter hook ingress device lan1 priority -200" "$NFT"
assert_contains "limiter: upload chain on second bridge port" \
    "add chain netdev tm_ratelimit ul_lan2 { type filter hook ingress device lan2 priority -200" "$NFT"
assert_contains "limiter: upload rule matches saddr on port chain" \
    "add rule netdev tm_ratelimit ul_lan1 ip saddr 192.168.1.50 limit rate over 625000 bytes/second" "$NFT"

# The regression itself: hooking the bridge matches nothing.
if printf '%s' "$NFT" | grep -q "hook ingress device br-lan"; then
    FAIL=$((FAIL + 1))
    printf "FAIL: limiter: ingress hook bound to the bridge instead of its ports\n"
else
    PASS=$((PASS + 1))
fi

# ── limiter: removal clears both ─────────────────────────────────────────────
: > "$NFT_LOG"
PATH="$MOCKBIN:$PATH" sh -c ". $BIN/trafficctl-fw.sh; tctl_ratelimit_remove 192.168.1.50 rl_test" >/dev/null 2>&1
NFT=$(cat "$NFT_LOG")
assert_contains "limiter: removal scans the whole table" "list table netdev tm_ratelimit" "$NFT"

# ── shaper: both directions ──────────────────────────────────────────────────
: > "$TC_LOG"
SHAPE="$TMPDIR/shape.sh"
sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" \
    -e "s|SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|SHAPES_FILE=\"$TMPDIR/shapes.json\"|" \
    -e "s|/sys/class/net/|$TMPDIR/sys/class/net/|g" \
    "$BIN/trafficctl-shape.sh" > "$SHAPE"
OUT=$(PATH="$MOCKBIN:$PATH" sh "$SHAPE" add 192.168.1.50 5000 2>&1)
TC=$(cat "$TC_LOG")

assert_contains "shaper: add reports success" '"ok":true' "$OUT"
assert_contains "shaper: says both directions" 'both directions' "$OUT"

# Minors are allocated, not derived from the address: deriving them put
# 192.168.0.1 on the reserved root class 1:1 and collided across subnets.
# The first shape on an empty router therefore gets the lowest free minor, 1:2.
CID=$(sed -n 's/.*"ip":"192.168.1.50","rate_kbit":5000,"classid":"\(1:[0-9a-f]*\)".*/\1/p' "$TMPDIR/shapes.json")
assert_eq "shaper: allocates the lowest free minor" "1:2" "$CID"
assert_contains "shaper: download class on LAN device" \
    "class add dev br-lan parent 1:1 classid $CID htb rate 5000kbit" "$TC"
assert_contains "shaper: download filter matches dst" \
    "filter add dev br-lan parent 1:0 prio 10 protocol ip u32 match ip dst 192.168.1.50/32" "$TC"

# Upload must be shaped PRE-NAT on an IFB fed from LAN ingress. At WAN egress
# the source is already masqueraded to the router's WAN address, so a per-client
# src filter there would match nothing.
assert_contains "shaper: upload class on the IFB device" \
    "class add dev tctl-ifb0 parent 1:1 classid $CID htb rate 5000kbit" "$TC"
assert_contains "shaper: upload filter matches src on IFB" \
    "filter add dev tctl-ifb0 parent 1:0 prio 10 protocol ip u32 match ip src 192.168.1.50/32" "$TC"

IPL=$(cat "$IP_LOG")
assert_contains "shaper: IFB device created" "link add name tctl-ifb0 type ifb" "$IPL"
assert_contains "shaper: IFB device brought up" "link set tctl-ifb0 up" "$IPL"

assert_contains "shaper: ingress qdisc on first bridge port" \
    "qdisc add dev lan1 handle ffff: ingress" "$TC"
assert_contains "shaper: ingress mirrored into the IFB" \
    "action mirred egress redirect dev tctl-ifb0" "$TC"

if printf '%s' "$TC" | grep -q "filter add dev eth1 .*match ip src"; then
    FAIL=$((FAIL + 1))
    printf "FAIL: shaper: upload filtered on WAN egress, where NAT has already rewritten the source\n"
else
    PASS=$((PASS + 1))
fi

# ── shaper: removal clears both ──────────────────────────────────────────────
: > "$TC_LOG"
PATH="$MOCKBIN:$PATH" sh "$SHAPE" remove 192.168.1.50 >/dev/null 2>&1
TC=$(cat "$TC_LOG")
assert_contains "shaper: removes LAN class" "class del dev br-lan classid $CID" "$TC"
assert_contains "shaper: removes IFB class" "class del dev tctl-ifb0 classid $CID" "$TC"
# By handle: without one, u32 deletes every prio-10 filter on the device.
assert_contains "shaper: removes upload filter by its handle" \
    "filter del dev tctl-ifb0 parent 1:0 prio 10 handle 800::800 protocol ip u32" "$TC"

# ── subnet / whole-network targets ───────────────────────────────────────────

RL="$TMPDIR/ratelimit.sh"
sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" \
    "$BIN/trafficctl-ratelimit.sh" > "$RL"

: > "$NFT_LOG"
OUT=$(PATH="$MOCKBIN:$PATH" sh "$RL" 10.0.20.0/24 5000 2>&1)
NFT=$(cat "$NFT_LOG")
assert_contains "subnet: accepted" '"ok":true' "$OUT"
assert_contains "subnet: defaults to per-device buckets" 'each' "$OUT"
# A meter keyed by address gives each host its own bucket; a bare limit would
# make one device able to starve the rest of the subnet.
assert_contains "subnet: download meter keyed by daddr" \
    "ip daddr 10.0.20.0/24 meter tctl_m_10_0_20_0_24_dl_br_lan { ip daddr limit rate over 625000 bytes/second }" "$NFT"
assert_contains "subnet: upload meter keyed by saddr" \
    "ip saddr 10.0.20.0/24 meter tctl_m_10_0_20_0_24_ul_lan1 { ip saddr limit rate over 625000 bytes/second }" "$NFT"

: > "$NFT_LOG"
OUT=$(PATH="$MOCKBIN:$PATH" sh "$RL" 10.0.20.0/24 5000 "" shared 2>&1)
NFT=$(cat "$NFT_LOG")
assert_contains "subnet: shared mode is an aggregate bucket" \
    "ip daddr 10.0.20.0/24 limit rate over 625000 bytes/second" "$NFT"

: > "$NFT_LOG"
OUT=$(PATH="$MOCKBIN:$PATH" sh "$RL" all 2000 2>&1)
NFT=$(cat "$NFT_LOG")
assert_contains "all: whole network accepted" '"ok":true' "$OUT"
assert_contains "all: expands to 0.0.0.0/0 with per-device buckets" \
    "ip saddr 0.0.0.0/0 meter tctl_m_0_0_0_0_0_ul_lan2" "$NFT"

# A single host stays a plain per-host bucket.
: > "$NFT_LOG"
PATH="$MOCKBIN:$PATH" sh "$RL" 10.0.20.122 1000 >/dev/null 2>&1
NFT=$(cat "$NFT_LOG")
assert_contains "host: no meter for a single address" \
    "ip saddr 10.0.20.122 limit rate over 125000 bytes/second" "$NFT"

OUT=$(PATH="$MOCKBIN:$PATH" sh "$RL" '10.0.20.0/99' 1000 2>&1)
assert_contains "invalid prefix rejected" '"ok":false' "$OUT"
OUT=$(PATH="$MOCKBIN:$PATH" sh "$RL" 'bad;target' 1000 2>&1)
assert_contains "invalid target rejected" '"ok":false' "$OUT"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
