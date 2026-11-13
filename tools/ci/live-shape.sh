#!/bin/sh
# Live check of the shaper on a bridge with two ports, run INSIDE an OpenWrt
# rootfs container with NET_ADMIN (.github/workflows/compat.yml, job
# live-shape). Real tc, HTB, u32, mirred and IFB against the runner's kernel:
# two shapes must both stay in force (a class on the bridge and on the IFB,
# a filter for each on both), removing one must leave the other, and the
# restore on ifup lan (`trafficctl restore`) must bring them back after a
# reboot and replace them, not stack copies, when they are still there.
#
# Up to v1.30.x a shape's filters were deleted by prio with no handle, which
# removes every u32 filter of that prio on the device: each shape added or
# removed took the filters of all the others with it, and only the last one
# applied was in force. The shaper is the ucode CLI (`trafficctl shape`,
# behind the trafficctl-shape.sh wrapper); it reads the LAN device from ubus,
# so a private ubusd carries a recorded network.interface
# (tests/lib/ubus-mock.uc).
#
# Usage: live-shape.sh [repository root, default /src]

set -u
SRC="${1:-/src}"
FAILS=0
say() { echo "== $*"; }
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
die() { echo "live-shape: $*" >&2; exit 2; }

W=/work
mkdir -p "$W/ubus" /var/lock /var/run/ubus /tmp/trafficctl /etc/trafficctl
cp -R "$SRC/trafficctl/files/." / || die "cannot install the backend"

add() {
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1; opkg install "$@" >/dev/null 2>&1
    else
        apk update >/dev/null 2>&1; apk add "$@" >/dev/null 2>&1
    fi
}
# The ubus stand-in needs uloop in ucode; the rootfs has no tc (tc-tiny has
# HTB, u32 and mirred, as on a router with kmod-sched).
[ -e /usr/lib/ucode/uloop.so ] || add ucode-mod-uloop
[ -e /usr/lib/ucode/uloop.so ] || die "no ucode-mod-uloop in the image"
command -v tc >/dev/null 2>&1 || add tc-tiny
command -v tc >/dev/null 2>&1 || die "no tc in the image"
say "$(tc -V 2>&1 | head -n 1)"

# ── br-lan with two ports, a WAN ─────────────────────────────────────────────
ip link add br-lan type bridge || die "no bridge support"
for p in lan1 lan2; do
    ip link add "$p" type dummy
    ip link set "$p" master br-lan
done
ip link add wan type dummy
for d in br-lan lan1 lan2 wan; do ip link set "$d" up; done
ip addr add 192.168.0.1/24 dev br-lan
ip addr add 203.0.113.2/24 dev wan

cat > /etc/config/network <<'EOF'
config interface 'lan'
	option device 'br-lan'
	option proto 'static'
	option ipaddr '192.168.0.1'
	option netmask '255.255.255.0'

config interface 'wan'
	option device 'wan'
	option proto 'dhcp'
EOF
cat > "$W/ubus/network.interface@dump.json" <<'EOF'
{"interface":[{"interface":"lan","up":true,"device":"br-lan","l3_device":"br-lan","ipv4-address":[{"address":"192.168.0.1","mask":24}]},{"interface":"wan","up":true,"device":"wan","l3_device":"wan","ipv4-address":[{"address":"203.0.113.2","mask":24}]}]}
EOF
echo '{"up":true,"l3_device":"br-lan","ipv4-address":[{"address":"192.168.0.1","mask":24}]}' > "$W/ubus/network.interface.lan@status.json"
echo '{"up":true,"l3_device":"wan","ipv4-address":[{"address":"203.0.113.2","mask":24}]}' > "$W/ubus/network.interface.wan@status.json"
SOCK=/var/run/ubus/ubus.sock
ubusd -s "$SOCK" &
i=0
until [ -S "$SOCK" ]; do i=$((i + 1)); [ "$i" -gt 10 ] && die "ubusd did not start"; sleep 1; done
ucode -S "$SRC/tests/lib/ubus-mock.uc" "$SOCK" "$W/ubus" > "$W/mock.out" 2>&1 &
i=0
until grep -q '^ready$' "$W/mock.out"; do i=$((i + 1)); [ "$i" -gt 10 ] && die "ubus-mock did not start: $(cat "$W/mock.out")"; sleep 1; done

# Whether this kernel has IFB decides what a shape can do upstream.
if ip link add tctl-probe type ifb 2>/dev/null; then
    ip link del tctl-probe
    IFB=1
    say "kmod-ifb present: both directions"
else
    IFB=0
    say "no IFB in this kernel: download only"
fi
IFBDEV=tctl-ifb0
S=/usr/libexec/trafficctl
shape() { /usr/sbin/trafficctl shape "$@"; }

# The u32 filters of prio 10 that send an address to its class: <dev> <ip>
# <dst|src>, one flowid per line. A filter is two lines, the header with the
# flowid and its match (dst at offset 16, src at 12).
flows() {
    key=$(echo "$2" | awk -F. -v at="$([ "$3" = dst ] && echo 16 || echo 12)" \
        '{ printf "match %02x%02x%02x%02x/ffffffff at %d", $1, $2, $3, $4, at }')
    tc filter show dev "$1" parent 1: 2>/dev/null | awk -v key="$key" '
        /^filter / { fl = ""; if ($0 ~ / pref 10 /) for (i = 1; i < NF; i++) if ($i == "flowid" || $i == "*flowid") fl = $(i+1); next }
        fl != "" { l = $0; sub(/^[ \t]+/, "", l); if (l == key) print fl }'
}
class_rate() {  # <dev> <classid>: the class's rate as tc prints it
    tc class show dev "$1" classid "$2" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "rate") print $(i+1) }'
}

# Each <ip> <classid> <download rate> <upload rate as tc prints it>: one
# class at that rate on each device, and exactly one filter to it.
check_shape() {
    ip=$1 cid=$2
    r=$(class_rate br-lan "$cid")
    [ "$r" = "$3" ] && ok "$ip: download class $cid at $r" || bad "$ip: download class $cid at '$r', want $3"
    f=$(flows br-lan "$ip" dst | tr '\n' ' ')
    [ "$f" = "$cid " ] && ok "$ip: one download filter to $cid" || bad "$ip: download filters to '$f', want $cid"
    [ "$IFB" = 1 ] || return 0
    r=$(class_rate "$IFBDEV" "$cid")
    [ "$r" = "$4" ] && ok "$ip: upload class $cid at $r" || bad "$ip: upload class $cid at '$r', want $4"
    f=$(flows "$IFBDEV" "$ip" src | tr '\n' ' ')
    [ "$f" = "$cid " ] && ok "$ip: one upload filter to $cid" || bad "$ip: upload filters to '$f', want $cid"
}
check_gone() {  # <ip> <classid>
    [ -z "$(flows br-lan "$1" dst)" ] && ok "$1: no download filter left" || bad "$1: download filter left"
    [ -z "$(class_rate br-lan "$2")" ] && ok "$1: download class $2 gone" || bad "$1: download class $2 left"
    [ "$IFB" = 1 ] || return 0
    [ -z "$(flows "$IFBDEV" "$1" src)" ] && ok "$1: no upload filter left" || bad "$1: upload filter left"
    [ -z "$(class_rate "$IFBDEV" "$2")" ] && ok "$1: upload class $2 gone" || bad "$1: upload class $2 left"
}
check_mirred() {
    for p in lan1 lan2; do
        if tc filter show dev "$p" parent ffff: 2>/dev/null | grep -q "mirred.*$IFBDEV"; then
            ok "$p: ingress mirred to $IFBDEV"
        else
            bad "$p: no ingress mirred to $IFBDEV"
        fi
    done
}
dump() {
    for d in br-lan "$IFBDEV"; do
        echo "-- $d"; tc qdisc show dev "$d" 2>/dev/null; tc class show dev "$d" 2>/dev/null
        tc filter show dev "$d" parent 1: 2>/dev/null
    done
}

# ── two shapes ───────────────────────────────────────────────────────────────
say "shape add 192.168.0.70 5000 up 1000"
out=$(shape add 192.168.0.70 5000 "" 1000)
echo "$out"
if [ "$IFB" = 1 ]; then
    case "$out" in *'"ok":true'*'both directions (class 1:2)'*) ok "first: applied both directions on 1:2" ;; *) bad "first: $out" ;; esac
else
    case "$out" in *'"ok":true'*'download only'*) ok "first: applied, download only" ;; *) bad "first: $out" ;; esac
fi
say "shape add 192.168.0.71 3000"
out=$(shape add 192.168.0.71 3000)
echo "$out"
case "$out" in *'"ok":true'*'(class 1:3)'*|*'"ok":true'*'download only'*) ok "second: applied" ;; *) bad "second: $out" ;; esac
dump
check_shape 192.168.0.70 1:2 5Mbit 1Mbit
check_shape 192.168.0.71 1:3 3Mbit 3Mbit
[ "$IFB" = 1 ] && check_mirred

out=$(sh $S/trafficctl-shape.sh status 192.168.0.70)
echo "$out"
case "$out" in *'"classid":"1:2"'*'"info":"5Mbit"'*) ok "status through the wrapper: 1:2 at 5Mbit" ;; *) bad "status: $out" ;; esac

# A new rate for the first replaces its classes and filters, and the second
# keeps its own.
say "shape add 192.168.0.70 8000 up 2000 (again)"
shape add 192.168.0.70 8000 "" 2000
echo
check_shape 192.168.0.70 1:2 8Mbit 2Mbit
check_shape 192.168.0.71 1:3 3Mbit 3Mbit

# ── removing one ─────────────────────────────────────────────────────────────
say "shape remove 192.168.0.70"
shape remove 192.168.0.70
echo
check_gone 192.168.0.70 1:2
check_shape 192.168.0.71 1:3 3Mbit 3Mbit
grep -q '"192.168.0.70"' /etc/trafficctl/shapes.json && bad "removed: still in shapes.json" || ok "removed: gone from shapes.json"
# The freed minor is handed out again.
shape add 192.168.0.72 2000 >/dev/null
check_shape 192.168.0.72 1:2 2Mbit 2Mbit
check_shape 192.168.0.71 1:3 3Mbit 3Mbit
cat /etc/trafficctl/shapes.json; echo

# ── the restore on ifup lan (`trafficctl restore`) ───────────────────────────
# A reboot first (every qdisc gone, the IFB too), then an ifup with the shapes
# still in place. The restore is quiet: nothing in the activity log.
say "restore: after a reboot, then again over the live shapes"
rm -f /tmp/trafficctl/activity.log
uci set trafficctl.logging.enabled=1 2>/dev/null && uci commit trafficctl
for d in br-lan lan1 lan2; do
    tc qdisc del dev "$d" root 2>/dev/null
    tc qdisc del dev "$d" ingress 2>/dev/null
done
ip link del "$IFBDEV" 2>/dev/null
for pass in boot ifup; do
    out=$(/usr/sbin/trafficctl restore)
    echo "$out"
    case "$out" in
        '{"ok":true,"restored":2,"failed":0}') ok "restore ($pass): two shapes back" ;;
        *) bad "restore ($pass): $out" ;;
    esac
    check_shape 192.168.0.72 1:2 2Mbit 2Mbit
    check_shape 192.168.0.71 1:3 3Mbit 3Mbit
    [ "$IFB" = 1 ] && check_mirred
done
dump
[ -s /tmp/trafficctl/activity.log ] && bad "restore: wrote the activity log" || ok "restore: nothing in the activity log"

for t in 192.168.0.71 192.168.0.72; do shape remove "$t" >/dev/null; done
n=$(tc filter show dev br-lan parent 1: 2>/dev/null | grep -c 'pref 10 ')
[ "$n" = 0 ] && ok "all removed: no filter left on br-lan" || bad "all removed: $n filter lines left on br-lan"

echo
[ "$FAILS" = 0 ] && echo "live-shape: all checks passed" || echo "live-shape: $FAILS failed"
[ "$FAILS" = 0 ]
