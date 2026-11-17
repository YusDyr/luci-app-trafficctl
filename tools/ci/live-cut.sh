#!/bin/sh
# Live check of the global internet cut, run INSIDE an OpenWrt rootfs
# container with NET_ADMIN (see .github/workflows/compat.yml, job live-cut).
# The cut is the one control that can lock its operator out of the router, so
# this runs both implementations against the real kernel and reads back what
# nft actually holds:
#
#   * a cut engaged by v1.30.0's trafficctl-cut.sh is seen and released by
#     `trafficctl cut`, and the other way round, including a persisted cut
#     restored after a simulated reboot;
#   * whoever installed it, the prerouting chain's FIRST rule as the kernel
#     lists it is the router-local accept;
#   * with no LAN device to spare, both refuse and nothing is loaded.
#
# Mounts: /src the repository (read-only), /legacy the v1.30.0 trafficctl/files
# tree (git archive v1.30.0 trafficctl/files).

set -u
W=/work
mkdir -p "$W/ubus" /var/lock /var/log /var/run/ubus /tmp/trafficctl /etc/trafficctl
PASS=0
FAIL=0

say() { echo "== $*"; }
die() { echo "live-cut: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/    /'; }
check() {   # check <desc> <command...>
    _check_d="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$_check_d"; else bad "$_check_d"; fi
}
has() {   # has <desc> <needle> <haystack>
    case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "$3" ;; esac
}

# ── packages: the ubus stand-in needs uloop in ucode ─────────────────────────
add() {
    if command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1; opkg install "$@" >/dev/null 2>&1
    else
        apk update >/dev/null 2>&1; apk add "$@" >/dev/null 2>&1
    fi
}
[ -e /usr/lib/ucode/uloop.so ] || add ucode-mod-uloop
[ -e /usr/lib/ucode/uloop.so ] || die "no ucode-mod-uloop in the image"
say "release $(. /etc/openwrt_release; echo "$DISTRIB_RELEASE"), nft $(nft --version)"

# ── the backend as installed, and v1.30.0's cut beside it ────────────────────
cp -R /src/trafficctl/files/. /
mkdir -p "$W/legacy"
cp -R /legacy/usr/libexec/trafficctl "$W/legacy/"
L="$W/legacy/trafficctl"
sed -i "s|/usr/libexec/trafficctl/|$L/|g" "$L"/*.sh
LCUT="$L/trafficctl-cut.sh"
NCUT="/usr/sbin/trafficctl cut"
# No procd here: the keeper's init script only records that it was asked.
cat > /etc/init.d/trafficctl-cut <<'EOF'
#!/bin/sh
echo "$*" >> /tmp/keeper.log
EOF
chmod +x /etc/init.d/trafficctl-cut

# ── network: br-lan with a port, a WAN ───────────────────────────────────────
ip link add br-lan type bridge
ip link add lan1 type dummy
ip link set lan1 master br-lan
ip link add wan type dummy
for d in br-lan lan1 wan; do ip link set "$d" up; done
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
# fw4 needs netifd; v1.30's trafficctl-fw.sh only wants nft to list a table.
nft add table inet fw4 || die "cannot create inet fw4"
cp /etc/config/firewall "$W/firewall"
uci -q get firewall.@zone[0].name | grep -qx lan || die "the image's firewall config has no lan zone first"

# No netifd: a private ubusd on the default socket, so the ubus CLI (v1.30)
# and the ucode module (the port) both meet the same network.interface.
cat > "$W/ubus/network.interface@dump.json" <<'EOF'
{"interface":[{"interface":"lan","up":true,"device":"br-lan","l3_device":"br-lan","ipv4-address":[{"address":"192.168.0.1","mask":24}]},{"interface":"wan","up":true,"device":"wan","l3_device":"wan","ipv4-address":[{"address":"203.0.113.2","mask":24}]}]}
EOF
echo '{"up":true,"l3_device":"br-lan","ipv4-address":[{"address":"192.168.0.1","mask":24}]}' > "$W/ubus/network.interface.lan@status.json"
echo '{"up":true,"l3_device":"wan","ipv4-address":[{"address":"203.0.113.2","mask":24}]}' > "$W/ubus/network.interface.wan@status.json"
echo '{}' > "$W/ubus/service@list.json"
# libubus's default since 2021, which 22.03 has.
SOCK=/var/run/ubus/ubus.sock
ubusd -s "$SOCK" &
i=0
until [ -S "$SOCK" ]; do i=$((i + 1)); [ "$i" -gt 10 ] && die "ubusd did not start"; sleep 1; done
ucode -S /src/tests/lib/ubus-mock.uc "$SOCK" "$W/ubus" > "$W/mock.out" 2>&1 &
i=0
until grep -q '^ready$' "$W/mock.out"; do i=$((i + 1)); [ "$i" -gt 10 ] && die "ubus-mock did not start: $(cat "$W/mock.out")"; sleep 1; done
ubus call network.interface dump >/dev/null || die "ubus CLI cannot reach the stand-in"

# ── what the kernel holds ────────────────────────────────────────────────────
table() { nft list table inet tctl_cut 2>/dev/null; }
# The first rule of cut_prerouting as nft lists it back.
first_pre() { table | awk '/hook prerouting/ { on = 1; next } on && NF { print; exit }' | sed 's/^[[:space:]]*//'; }
safe_first() {   # <who>: accept-local first, whenever there is a prerouting chain
    _safe_t=$(table)
    case "$_safe_t" in
        *"hook prerouting"*)
            case "$(first_pre)" in
                "fib daddr type { local, broadcast, multicast } accept") ok "$1: the router-local accept is the prerouting chain's first rule" ;;
                *) bad "$1: the prerouting chain does not start with the router-local accept" "$_safe_t" ;;
            esac ;;
        *"hook forward"*) echo "NOTE: $1: no prerouting chain on this kernel (forward-only cut)" ;;
        *) bad "$1: no tctl_cut table" ;;
    esac
}
gone() { ! nft list table inet tctl_cut >/dev/null 2>&1 && [ ! -e /var/run/trafficctl/cut.state ] && [ ! -e /etc/trafficctl/cut.state ]; }

# ── v1.30 engages, the port reads and releases ───────────────────────────────
say "v1.30 engage, new status/release"
OUT=$(sh "$LCUT" engage 900 0 2>&1)
has "v1.30 engage: ok" '"ok":true' "$OUT"
COV=$(printf '%s' "$OUT" | sed -n 's/.*"coverage":"\([a-z]*\)".*/\1/p')
say "coverage on this kernel: $COV"
safe_first "v1.30 engage"
OUT=$($NCUT status 2>&1)
has "new status of a v1.30 cut: active" '"active":true,"rule_present":true' "$OUT"
has "new status of a v1.30 cut: same coverage" "\"coverage\":\"$COV\"" "$OUT"
OUT=$($NCUT release 2>&1)
has "new release of a v1.30 cut: ok" '"active":false,"rule_present":false' "$OUT"
check "new release of a v1.30 cut: table and state gone" gone

# ── the port engages, v1.30 reads and releases ───────────────────────────────
say "new engage, v1.30 status/release"
OUT=$($NCUT engage 900 1 2>&1)
has "new engage: ok" '"ok":true' "$OUT"
has "new engage: same coverage as v1.30" "\"coverage\":\"$COV\"" "$OUT"
safe_first "new engage"
OUT=$(sh "$LCUT" status 2>&1)
has "v1.30 status of a new cut: active and persistent" '"active":true,"rule_present":true' "$OUT"
has "v1.30 status of a new cut: persistent" '"persist":true' "$OUT"
OUT=$(sh "$LCUT" release 2>&1)
has "v1.30 release of a new cut: ok" '"active":false,"rule_present":false' "$OUT"
check "v1.30 release of a new cut: table and state gone" gone

# ── a persisted v1.30 cut across a reboot ────────────────────────────────────
say "v1.30 persisted cut, reboot, new restore"
sh "$LCUT" engage 0 1 >/dev/null 2>&1
nft delete table inet tctl_cut
rm -f /var/run/trafficctl/cut.state
OUT=$($NCUT restore 2>&1)
[ -z "$OUT" ] && ok "new restore: silent" || bad "new restore: silent" "$OUT"
safe_first "new restore of a v1.30 persisted cut"
has "new restore: active again" '"active":true,"rule_present":true' "$($NCUT status 2>&1)"
$NCUT release >/dev/null 2>&1
check "after the restore, release clears everything" gone

# ── the keeper tick re-asserts what was flushed ──────────────────────────────
say "new tick after a flush"
$NCUT engage 0 0 >/dev/null 2>&1
nft delete table inet tctl_cut
$NCUT tick >/dev/null 2>&1
safe_first "new tick after the table was flushed"
$NCUT release >/dev/null 2>&1
check "tick then release clears everything" gone

# ── no LAN device: refused by both, nothing loaded ───────────────────────────
say "no LAN device"
: > /etc/config/firewall
OUT=$($NCUT engage 900 0 2>&1)
has "new engage without a LAN: refused" '"ok":false' "$OUT"
has "new engage without a LAN: says why" "no LAN interfaces" "$OUT"
check "new engage without a LAN: nothing loaded" gone
OUT=$(sh "$LCUT" engage 900 0 2>&1)
has "v1.30 engage without a LAN: refused" '"ok":false' "$OUT"
check "v1.30 engage without a LAN: nothing loaded" gone
cp "$W/firewall" /etc/config/firewall

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
