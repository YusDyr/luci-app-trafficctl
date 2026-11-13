#!/bin/sh
# Live check of the limiter on a bridge with two ports, run INSIDE an OpenWrt
# rootfs container with NET_ADMIN (.github/workflows/compat.yml, job
# live-ratelimit). Real nft against the real kernel: an each-mode limit must
# put its upload rule on BOTH ports and its download rule on the bridge, with
# a meter per chain, and removing it must leave no rule and no meter set.
#
# On nftables 1.0 (22.03) one meter name in every chain failed on the second
# port with "Resource busy"; on 1.1 (23.05+) the meter is a named set that the
# old code left behind with each address's bucket at the old rate.
#
# The container shares the host's kernel, which has the netdev egress hook
# (5.16+), so download goes to dl_br_lan at LAN egress; the WAN-ingress
# fallback that 22.03's own kernel (5.10) takes is covered by the unit tests.
#
# The limiter is the ucode CLI (`trafficctl ratelimit`, behind the
# trafficctl-ratelimit.sh wrapper); it reads the interfaces from ubus, so a
# private ubusd carries a recorded network.interface (tests/lib/ubus-mock.uc).
#
# Usage: live-ratelimit.sh [repository root, default /src]

set -u
SRC="${1:-/src}"
FAILS=0
say() { echo "== $*"; }
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
die() { echo "live-ratelimit: $*" >&2; exit 2; }

W=/work
mkdir -p "$W/ubus" /var/lock /var/run/ubus /tmp/trafficctl /etc/trafficctl
cp -R "$SRC/trafficctl/files/." / || die "cannot install the backend"

# The ubus stand-in needs uloop in ucode.
add() {
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1; opkg install "$@" >/dev/null 2>&1
    else
        apk update >/dev/null 2>&1; apk add "$@" >/dev/null 2>&1
    fi
}
[ -e /usr/lib/ucode/uloop.so ] || add ucode-mod-uloop
[ -e /usr/lib/ucode/uloop.so ] || die "no ucode-mod-uloop in the image"
say "$(nft --version)"

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
# No netifd in the container: a private ubusd on the default socket answers
# for network.interface.
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
uci -q get firewall.@zone[0].name | grep -qx lan || die "the image's firewall config has no lan zone first"

# trafficctl-fw.sh picks nftables when any table exists; fw4 itself needs
# netifd, and its forward chain is not what this checks.
nft add table inet fw4 || die "cannot create inet fw4"

S=/usr/libexec/trafficctl
table() { nft -a list table netdev tm_ratelimit 2>/dev/null; }
# Chains holding a rule whose comment is exactly $1, one per line.
chains_of() {
    table | awk -v c="\"$1\"" '
        /^[ \t]*chain / { chain = $2; next }
        { for (i = 1; i < NF; i++) if ($i == "comment" && $(i+1) == c) print chain }' | sort | tr '\n' ' '
}

check_target() {  # <target> <comment> <expected upload rate in bytes/s>
    t="$1" cmt="$2"
    [ "$(chains_of "${cmt}_ul")" = "ul_lan1 ul_lan2 " ] \
        && ok "$t: upload rule on both ports" \
        || bad "$t: upload rule on: '$(chains_of "${cmt}_ul")', want ul_lan1 and ul_lan2"
    [ "$(chains_of "$cmt")" = "dl_br_lan " ] \
        && ok "$t: download rule on the bridge" \
        || bad "$t: download rule on: '$(chains_of "$cmt")', want dl_br_lan"
    n=$(table | grep "\"${cmt}_ul\"" | grep -c "limit rate over $3 bytes/second\|limit rate over $(( $3 / 1024 )) kbytes/second")
    [ "$n" = 2 ] && ok "$t: both upload rules at the current rate" || bad "$t: $n upload rules at $3 bytes/s"
}

# ── each mode, a subnet and a host ───────────────────────────────────────────
for spec in "10.0.20.0/24 2000 500" "192.168.0.70 2000 2000"; do
    set -- $spec
    say "ratelimit $1 $2 each up $3"
    out=$(sh $S/trafficctl-ratelimit.sh "$1" "$2" "" each "$3")
    echo "$out"
    case "$out" in
        *'both directions, each'*) ok "$1: reported in both directions" ;;
        *) bad "$1: not reported in both directions" ;;
    esac
    case "$out" in
        *'"ok":true,"partial":false'*) ok "$1: reported complete" ;;
        *) bad "$1: not reported as ok and complete" ;;
    esac
    check_target "$1" "rl_ratelimit_$(echo "$1" | tr './' '__')" $(( $3 * 125 ))
done
say "nft list table netdev tm_ratelimit"
table

stats=$(sh $S/trafficctl-ratelimit-stats.sh)
echo "$stats"
case "$stats" in
    *'"ip":"10.0.20.0/24","mode":"each"'*) ok "stats: the subnet limit reads as each" ;;
    *) bad "stats: the subnet limit does not read as each" ;;
esac

# A new rate replaces the limit; the meters of the first one are gone.
say "ratelimit 10.0.20.0/24 4000 each up 1000"
out=$(sh $S/trafficctl-ratelimit.sh 10.0.20.0/24 4000 "" each 1000)
echo "$out"
check_target 10.0.20.0/24 rl_ratelimit_10_0_20_0_24 125000

# ── removal ──────────────────────────────────────────────────────────────────
for t in 10.0.20.0/24 192.168.0.70; do
    sh $S/trafficctl-ratelimit.sh "$t" 0 >/dev/null
done
left=$(table | grep -c 'comment "rl_ratelimit_')
[ "$left" = 0 ] && ok "removed: no rule left" || bad "removed: $left rules left"
if table | grep -q 'set tctl_'; then
    bad "removed: meter sets left behind"; table
else
    ok "removed: no meter set left"
fi

# ── a limit written by 1.30.4 and earlier: one meter name on every port ─────
say "legacy limit (tctl_u_<slug> on every port)"
nft add table netdev tm_ratelimit
for p in lan1 lan2; do
    nft add chain netdev tm_ratelimit "ul_$p" "{ type filter hook ingress device $p priority -200; policy accept; }"
done
nft add rule netdev tm_ratelimit ul_lan1 'ip saddr 10.0.40.0/24 meter tctl_u_10_0_40_0_24 { ip saddr limit rate over 62500 bytes/second } counter drop comment "rl_ratelimit_10_0_40_0_24_ul"' \
    || die "cannot write the legacy rule"
# On nftables 1.0 this is the "Resource busy" of the bug.
nft add rule netdev tm_ratelimit ul_lan2 'ip saddr 10.0.40.0/24 meter tctl_u_10_0_40_0_24 { ip saddr limit rate over 62500 bytes/second } counter drop comment "rl_ratelimit_10_0_40_0_24_ul"' \
    && say "second port took the shared meter name" \
    || say "second port refused the shared meter name (expected on nftables 1.0)"
sh $S/trafficctl-ratelimit.sh 10.0.40.0/24 0 >/dev/null
if table | grep -q 'rl_ratelimit_10_0_40_0_24\|set tctl_u_10_0_40_0_24'; then
    bad "legacy limit: not fully removed"; table
else
    ok "legacy limit: rules and meter removed"
fi

# ── limits from before v1.13.2: one label comment on several targets ─────────
# The bot's limits all read "rl_ratelimit_tg". Removing one target's goes by
# the rules that name it; v1.30.5 and earlier lifted every target's.
say "legacy label limits (rl_ratelimit_tg on two hosts)"
nft add chain netdev tm_ratelimit dl_br_lan '{ type filter hook egress device br-lan priority 0; policy accept; }' \
    || die "cannot create dl_br_lan"
for h in 192.168.0.80 192.168.0.81; do
    nft add rule netdev tm_ratelimit dl_br_lan "ip daddr $h limit rate over 62500 bytes/second counter drop comment \"rl_ratelimit_tg\"" \
        || die "cannot write the legacy download rule"
    nft add rule netdev tm_ratelimit ul_lan1 "ip saddr $h limit rate over 62500 bytes/second counter drop comment \"rl_ratelimit_tg_ul\"" \
        || die "cannot write the legacy upload rule"
done
out=$(sh $S/trafficctl-ratelimit.sh 192.168.0.80 0 tg)
echo "$out"
case "$out" in
    *'"ok":true'*) ok "legacy label: removal reported ok" ;;
    *) bad "legacy label: removal not reported ok" ;;
esac
if table | grep -q 'ip [sd]addr 192\.168\.0\.80 '; then
    bad "legacy label: this target's rules left"; table
else
    ok "legacy label: this target's rules removed"
fi
n=$(table | grep -c 'ip [sd]addr 192\.168\.0\.81 .*"rl_ratelimit_tg\(_ul\)\{0,1\}"')
[ "$n" = 2 ] && ok "legacy label: the other target keeps both rules" || bad "legacy label: the other target has $n of 2 rules"

echo
[ "$FAILS" = 0 ] && echo "live-ratelimit: all checks passed" || echo "live-ratelimit: $FAILS failed"
[ "$FAILS" = 0 ]
