#!/bin/sh
# Live check of the read-only nft/tc readers, run INSIDE an OpenWrt rootfs
# container with NET_ADMIN (see .github/workflows/compat.yml, job
# live-readers). The current shell writers build real kernel state (blocks,
# rate limits, shapes) on a bridge with two dummy ports, then the v1.30.0
# shell readers and the ucode CLI report it, each into its own file:
#
#   /out/legacy/<command>.json   v1.30.0 trafficctl-<command>.sh
#   /out/new/<command>.json      /usr/sbin/trafficctl <command>
#
# After the comparison, blocks written by v1.30.0 and by the ucode CLI meet on
# one chain (each removes the other's, restore brings back a v1.30.0 block from
# its rules.json record) and the DHCP hook applies its default limit:
# /out/new/interop.txt.
#
# tools/ci/live-compare.sh compares them on the host. With capture, it also
# writes what the kernel listed as replay fixtures for tests/equiv.sh and the
# unit tests:
#
#   /out/fixture/cmd/<command line>        nft/tc output of the writers' state
#   /out/fixture/root/etc/trafficctl/      rules.json, shapes.json
#   /out/nft/<name>.<table>.{nft,json}     each tests/fixtures/nft-src/<name>.nft
#                                          loaded with nft -f and listed back
#                                          (table: tm_ratelimit, fw4)
#
# The container shares the CI host's kernel, which has the netdev egress hook
# (5.16+), so the limiter's download rules always go to dl_<bridge> at LAN
# egress: the WAN-ingress "dl" fallback 22.03's own kernel (5.10) takes is
# not exercised here.
#
# Mounts: /src the repository (read-only), /legacy the v1.30.0 trafficctl/files
# tree (git archive v1.30.0 trafficctl/files), /out writable.
#
# Usage: live-readers.sh [capture|bench]
#   bench  instead of comparing: LIVE_EXTRA (default 60) more limits and
#          LIVE_EXTRA/3 more shapes, then tools/bench.sh against the v1.30.0
#          scripts in /legacy

set -u
MODE="${1:-}"
OUT=/out
W=/work
mkdir -p "$W/bin" "$OUT/legacy" "$OUT/new" /var/lock /var/log /var/run /tmp/trafficctl /etc/trafficctl

say() { echo "== $*"; }
die() { echo "live-readers: $*" >&2; exit 1; }

# ── packages: the rootfs ships no tc ─────────────────────────────────────────
if ! command -v tc >/dev/null 2>&1; then
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1; opkg install tc-tiny >/dev/null 2>&1
    else
        apk update >/dev/null 2>&1; apk add tc-tiny >/dev/null 2>&1
    fi
fi
command -v tc >/dev/null 2>&1 || die "no tc in the image"
say "nft $(nft --version)"
say "tc $(tc -V 2>&1)"

# ── the backend as installed: current files, v1.30.0 readers beside them ────
cp -R /src/trafficctl/files/. /
mkdir -p "$W/legacy"
cp -R /legacy/usr/libexec/trafficctl "$W/legacy/"
L="$W/legacy/trafficctl"
# The legacy readers source and call each other by absolute path.
sed -i "s|/usr/libexec/trafficctl/|$L/|g" "$L"/*.sh
sed -i "s|^SCRIPTS=\"/usr/libexec/trafficctl\"|SCRIPTS=\"$L\"|" "$L"/*.sh

# ── network: br-lan with two ports, a WAN, the fw4 forward chain ─────────────
# Dummy ports: the rootfs's ip has no veth. Two of them, so the writer's
# per-port upload loop builds more than one ul_<port> chain.
ip link add br-lan type bridge
for p in lan1 lan2; do
    ip link add "$p" type dummy
    ip link set "$p" master br-lan
done
ip link add wan type dummy
for d in br-lan lan1 lan2 wan; do ip link set "$d" up; done
ip addr add 192.168.0.1/24 dev br-lan
ip addr add 203.0.113.2/24 dev wan
# kmod-ifb: the CI kernel has it, Docker Desktop's does not; without it the
# shaper reports "download only", and the readers still meet every class.
ip link add name tctl-ifb0 type ifb 2>/dev/null && ip link del tctl-ifb0
# fw4 itself needs netifd on ubus; its forward chain is all a block writes to.
nft -f - <<'NFT' || die "cannot create inet fw4"
table inet fw4 {
	chain forward {
		type filter hook forward priority filter; policy drop;
		ct state vmap { established : accept, related : accept } comment "!fw4: Handle forwarded flows"
	}
}
NFT

cat > /etc/config/network <<'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.0.1'
	option netmask '255.255.255.0'

config interface 'wan'
	option device 'wan'
	option proto 'dhcp'
EOF
uci set trafficctl.main.persist_rules=1
uci commit trafficctl

# No netifd, so no network.interface on ubus: the shell writers' ubus calls
# get its answer from a stand-in. The ucode readers ask nothing of it.
cat > "$W/bin/ubus" <<'EOF'
#!/bin/sh
case "$*" in
    "call network.interface dump")
        echo '{"interface":[{"interface":"lan","up":true,"l3_device":"br-lan","ipv4-address":[{"address":"192.168.0.1","mask":24}]},{"interface":"wan","up":true,"l3_device":"wan","ipv4-address":[{"address":"203.0.113.2","mask":24}]}]}' ;;
    "call network.interface.lan status")
        echo '{"up":true,"l3_device":"br-lan","ipv4-address":[{"address":"192.168.0.1","mask":24}]}' ;;
    "call network.interface.wan status")
        echo '{"up":true,"l3_device":"wan","ipv4-address":[{"address":"203.0.113.2","mask":24}]}' ;;
    list) ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$W/bin/ubus"
export PATH="$W/bin:$PATH"

cat > /tmp/dhcp.leases <<'EOF'
1794381090 02:00:00:00:00:50 192.168.0.50 kid-tablet *
1794381090 02:00:00:00:00:60 192.168.0.60 tv *
1794381090 02:00:00:00:00:70 192.168.0.70 * *
EOF

# ── the writers ──────────────────────────────────────────────────────────────
S=/usr/libexec/trafficctl
run() { say "$*"; "$@"; echo; }
run sh $S/trafficctl-block.sh 192.168.0.50
run sh $S/trafficctl-block.sh 192.168.0.5
run sh $S/trafficctl-ratelimit.sh 192.168.0.60 5000 "" shared 1000
run sh $S/trafficctl-ratelimit.sh 192.168.0.6 5000
run sh $S/trafficctl-ratelimit.sh 192.168.0.7 8192
# Each mode on 22.03: the writer gives a target's upload meter the same name
# in every ul_<port> chain, and nftables 1.0.2 refuses a second meter of that
# name ("Resource busy"), so ul_lan2 gets no IPv4 upload rule for these two
# targets while the writer still reports ok. That writer bug is fixed
# separately (docs/ARCHITECTURE.md, "Reading the rules back"). Both readers
# see the same partial state, so the comparison keeps these targets.
run sh $S/trafficctl-ratelimit.sh 192.168.0.70 2000 "" each
run sh $S/trafficctl-ratelimit.sh 10.0.20.0/24 2000 "" each 500
run sh $S/trafficctl-shape.sh add 192.168.0.81 3000
run sh $S/trafficctl-shape.sh add 192.168.0.80 8000 x 2000
# A saved-only block and limit: in rules.json, not in the kernel.
run sh $S/trafficctl-block.sh 192.168.0.90
run sh $S/trafficctl-unblock.sh 192.168.0.90 >/dev/null
sed -i 's/^\[/[{"type":"block","ip":"192.168.0.90","param":"block_192.168.0.90"},{"type":"ratelimit","ip":"192.168.0.66","param":"2000"},/' \
    /etc/trafficctl/rules.json
# Blocks as releases before v1.13.2 wrote them: the comment carried the
# caller's label (the Telegram bot's "tg", LuCI's default block_<ip>).
for b in "192.168.0.51 tctl_block_tg" "192.168.0.52 tctl_block_block_192.168.0.52"; do
    nft insert rule inet fw4 forward "ip saddr ${b% *} counter drop comment \"${b#* }\"" \
        || die "cannot write the legacy block ${b% *}"
done

if [ "$MODE" = bench ]; then
    n="${LIVE_EXTRA:-60}" i=0
    while [ "$i" -lt "$n" ]; do
        h=$((100 + i))
        sh $S/trafficctl-ratelimit.sh "192.168.0.$h" $((1000 + i * 100)) "" shared 500 >/dev/null
        [ $((i % 3)) = 0 ] && sh $S/trafficctl-shape.sh add "192.168.0.$h" $((2000 + i * 10)) >/dev/null
        i=$((i + 1))
    done
    say "rules: $(nft -a list table netdev tm_ratelimit | grep -c comment), classes: $(tc class show dev br-lan | grep -c htb)"
    BENCH_LEGACY=/legacy/usr/libexec/trafficctl BENCH_RUNS="${BENCH_RUNS:-5}" sh /src/tools/bench.sh 2000
    exit 0
fi

# ── both readers ─────────────────────────────────────────────────────────────
for c in ratelimit-stats shape-stats rules; do
    sh "$L/trafficctl-$c.sh" > "$OUT/legacy/$c.json" 2> "$OUT/legacy/$c.err"
    /usr/sbin/trafficctl "$c" > "$OUT/new/$c.json" 2> "$OUT/new/$c.err"
done

# ── fixtures ─────────────────────────────────────────────────────────────────
if [ "$MODE" = capture ]; then
    F="$OUT/fixture"
    mkdir -p "$F/cmd" "$F/root/etc/trafficctl"
    cp /etc/trafficctl/rules.json /etc/trafficctl/shapes.json "$F/root/etc/trafficctl/"
    for c in "nft list table netdev tm_ratelimit" "nft -j list table netdev tm_ratelimit" \
             "nft list chain inet fw4 forward" "nft -j list chain inet fw4 forward" \
             "nft -a list chain inet fw4 forward" \
             "tc qdisc show dev br-lan" "tc -j qdisc show dev br-lan" \
             "tc -s qdisc show dev br-lan" "tc -j -s qdisc show dev br-lan" \
             "tc class show dev br-lan" "tc -s class show dev br-lan" "tc -j class show dev br-lan" \
             "tc class show dev tctl-ifb0" "tc -j class show dev tctl-ifb0"; do
        $c > "$F/cmd/$c" 2>/dev/null || rm -f "$F/cmd/$c"
    done
fi

# ── unblock of the legacy blocks, as the Rules tab sends it (no label) ───────
for ip in 192.168.0.51 192.168.0.52; do
    sh $S/trafficctl-unblock.sh "$ip" "" >/dev/null
done
/usr/sbin/trafficctl rules > "$OUT/new/rules-after-unblock.json"
nft list chain inet fw4 forward > "$OUT/new/fw4-after-unblock.nft"

# ── blocks across the upgrade: v1.30.0 and the ucode writers on one chain ────
# One line per check in interop.txt, "ok <name>" or "FAIL <name>: <why>";
# tools/ci/live-compare.sh wants every name ok.
I="$OUT/new/interop.txt"
: > "$I"
check() {   # check <name> <shell test...>
    n="$1"; shift
    if eval "$*"; then echo "ok $n" >> "$I"; else echo "FAIL $n: $* (chain: $(nft list chain inet fw4 forward | grep -c comment) rules)" >> "$I"; fi
}
rules_of() { nft list chain inet fw4 forward | grep -cE "\"tctl_block_$1(_mac)?\""; }
printf '1794381090 02:00:00:00:00:53 192.168.0.53 a *\n1794381090 02:00:00:00:00:54 192.168.0.54 b *\n1794381090 02:00:00:00:00:55 192.168.0.55 c *\n' >> /tmp/dhcp.leases
# Both halves (v4 and the MAC-keyed v6) written by v1.30.0, removed by the
# ucode unblock; the other way round.
sh "$L/trafficctl-block.sh" 192.168.0.53 >/dev/null
check v130-block-both-halves '[ "$(rules_of 192_168_0_53)" = 2 ]'
/usr/sbin/trafficctl unblock 192.168.0.53 >/dev/null
check new-unblock-removes-v130-block '[ "$(rules_of 192_168_0_53)" = 0 ]'
/usr/sbin/trafficctl block 192.168.0.54 >/dev/null
check new-block-both-halves '[ "$(rules_of 192_168_0_54)" = 2 ]'
sh "$L/trafficctl-unblock.sh" 192.168.0.54 >/dev/null
check v130-unblock-removes-new-block '[ "$(rules_of 192_168_0_54)" = 0 ]'
# The same rule text from both: v1.30.0 reads a ucode block as blocked.
/usr/sbin/trafficctl block 192.168.0.54 >/dev/null
check v130-sees-new-block 'sh "$L/trafficctl-block.sh" 192.168.0.54 | grep -q "already blocked"'
/usr/sbin/trafficctl unblock 192.168.0.54 >/dev/null
# Restore after a reboot of a block v1.30.0 placed, from its rules.json
# record: the kernel lost the block, restore puts both halves back and
# doubles none already there.
sh "$L/trafficctl-block.sh" 192.168.0.55 >/dev/null 2>&1
# v1.30.0's own save fails on BusyBox awk ("bad regex '},{'", fixed in
# v1.30.x), so the record is written by the shell writer the limiter still
# uses: the same bytes v1.30.x saves.
sh -c '. /usr/libexec/trafficctl/trafficctl-fw.sh; tctl_persist_save block 192.168.0.55 block_192.168.0.55'
check shell-saved-the-block 'grep -qF "{\"type\":\"block\",\"ip\":\"192.168.0.55\",\"param\":\"block_192.168.0.55\"}" /etc/trafficctl/rules.json'
for h in $(nft -a list chain inet fw4 forward | grep -E '"tctl_block_192_168_0_55(_mac)?"' | sed 's/.*# handle //'); do
    nft delete rule inet fw4 forward handle "$h"
done
/usr/sbin/trafficctl restore > "$OUT/new/restore.json"
check restore-of-a-v130-block '[ "$(rules_of 192_168_0_55)" = 2 ]'
check restore-doubles-nothing '[ "$(rules_of 192_168_0_50)" = 2 ] && [ "$(rules_of 192_168_0_5)" = 1 ]'
# A label shared by two devices' pre-v1.13.2 blocks: unblocking one with that
# label leaves the other (the shell lifted both).
for ip in 192.168.0.56 192.168.0.57; do
    nft insert rule inet fw4 forward "ip saddr $ip counter drop comment \"tctl_block_tg\""
done
/usr/sbin/trafficctl unblock 192.168.0.56 tg >/dev/null
check legacy-label-unblock-only-its-own '! nft list chain inet fw4 forward | grep -q "ip saddr 192.168.0.56 " && nft list chain inet fw4 forward | grep -q "ip saddr 192.168.0.57 "'
/usr/sbin/trafficctl unblock 192.168.0.57 >/dev/null
check legacy-label-unblock-no-label '! nft list chain inet fw4 forward | grep -q "ip saddr 192.168.0.57 "'
# The DHCP hook's default limit, on the real limiter: a device already
# limited (192.168.0.60) is left alone, a new one gets the limit.
uci set trafficctl.newdevice.enabled=1; uci set trafficctl.newdevice.limit_kbit=3000; uci commit trafficctl
printf '02:00:00:00:00:01\n' > /etc/trafficctl/seen_macs
ACTION=add MACADDR=02:00:00:00:00:61 IPADDR=192.168.0.60 HOSTNAME=x /usr/sbin/trafficctl newdevice
ACTION=add MACADDR=02:00:00:00:00:08 IPADDR=192.168.0.8 HOSTNAME=y /usr/sbin/trafficctl newdevice
/usr/sbin/trafficctl ratelimit-stats > "$OUT/new/newdevice-stats.json"
check newdevice-leaves-a-limit "jsonfilter -i '$OUT/new/newdevice-stats.json' -e '@[@.ip=\"192.168.0.60\"].rate_kbit' | grep -qx 5000"
check newdevice-limits-a-new-device "jsonfilter -i '$OUT/new/newdevice-stats.json' -e '@[@.ip=\"192.168.0.8\"].rate_kbit' | grep -qx 3000"
check newdevice-marks-both 'grep -qx 02:00:00:00:00:61 /etc/trafficctl/seen_macs && grep -qx 02:00:00:00:00:08 /etc/trafficctl/seen_macs'

[ "$MODE" = capture ] || exit 0

# Hand-written listings (the unit tests' scenarios), as each nftables release
# lists them back. Devices they name are created as dummies.
mkdir -p "$OUT/nft"
for src in /src/tests/fixtures/nft-src/*.nft; do
    [ -f "$src" ] || continue
    n=$(basename "$src" .nft)
    for d in $(sed -n 's/.*device "\([^"]*\)".*/\1/p' "$src" | sort -u); do
        ip link show "$d" >/dev/null 2>&1 || { ip link add "$d" type dummy; ip link set "$d" up; }
    done
    nft delete table netdev tm_ratelimit 2>/dev/null
    nft flush chain inet fw4 forward
    nft -f "$src" || { echo "cannot load $src" >&2; continue; }
    if grep -q 'table netdev tm_ratelimit' "$src"; then
        nft list table netdev tm_ratelimit > "$OUT/nft/$n.tm_ratelimit.nft"
        nft -j list table netdev tm_ratelimit > "$OUT/nft/$n.tm_ratelimit.json"
    fi
    if grep -q 'table inet fw4' "$src"; then
        nft list chain inet fw4 forward > "$OUT/nft/$n.fw4.nft"
        nft -j list chain inet fw4 forward > "$OUT/nft/$n.fw4.json"
    fi
done
