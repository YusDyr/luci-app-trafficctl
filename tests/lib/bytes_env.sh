#!/bin/bash
# shellcheck shell=bash
# A scratch router for the byte samplers (`trafficctl bytes`, `bytes-nft`,
# `totals`). Source it after tests/lib/ucode.sh, then:
#   BE_ROOT                 the TCTL_ROOT: etc/config/firewall, proc/net/nf_conntrack
#   BE_CT                   that conntrack file
#   BE_NFT                  directory of nft replies: a file named after the
#                           arguments ("list map inet trafficctl_mon bytes_in")
#                           is printed; none = exit 1, the way nft fails on a
#                           missing map. add/delete always succeed.
#   BE_NFTLOG               every nft call, one line each
#   be_offload <mode>       none, software, hardware, software-counter,
#                           hardware-counter: uci defaults plus the flowtable
#   be_run <cmd> [args]     the CLI with the root, the mocks and the ubus dump
#   be_totals <sample> [--all]
#                           net.totals over a sample file (tests/lib/totals.uc)
#
# The LAN is 192.168.1.0/24 on br-lan; the router itself is 192.168.1.1.

BE_ROOT="$UC_TMP/root"
BE_CT="$BE_ROOT/proc/net/nf_conntrack"
BE_NFT="$UC_TMP/nft"
BE_NFTLOG="$UC_TMP/nft.log"
BE_BIN="$UC_TMP/bin"
BE_UBUS="$UC_TMP/ubus"
mkdir -p "$BE_ROOT/etc/config" "$BE_ROOT/tmp/.uci" "$BE_ROOT/proc/net" \
    "$BE_NFT" "$BE_BIN" "$BE_UBUS"
: > "$BE_CT"
: > "$BE_NFTLOG"

printf '{"interface":[{"interface":"lan","up":true,"l3_device":"br-lan","ipv4-address":[{"address":"192.168.1.1","mask":24}]},{"interface":"wan","up":true,"l3_device":"wan","ipv4-address":[{"address":"203.0.113.2","mask":24}]}]}\n' \
    > "$BE_UBUS/network.interface@dump.json"

cat > "$BE_BIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    "-4 addr show")
        echo "    inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan"
        echo "    inet 203.0.113.2/24 brd 203.0.113.255 scope global wan" ;;
esac
exit 0
MOCK
cat > "$BE_BIN/nft" <<MOCK
#!/bin/sh
echo "\$*" >> "$BE_NFTLOG"
case "\$1" in add|delete) exit 0 ;; esac
f="$BE_NFT/\$*"
[ -f "\$f" ] || exit 1
cat "\$f"
MOCK
chmod +x "$BE_BIN/ip" "$BE_BIN/nft"

be_offload() {   # be_offload <mode>
    local sw=0 hw=0
    case "$1" in
        software*) sw=1 ;;
        hardware*) sw=1; hw=1 ;;
    esac
    cat > "$BE_ROOT/etc/config/firewall" <<EOF
config defaults
	option flow_offloading '$sw'
	option flow_offloading_hw '$hw'

config zone
	option name 'lan'
	list network 'lan'

config zone
	option name 'wan'
	option masq '1'
	list network 'wan'
EOF
    case "$1" in
        *-counter) printf 'table inet fw4 {\n\tflowtable ft {\n\t\thook ingress priority filter\n\t\tdevices = { lan1, wan }\n\t\tcounter\n\t}\n}\n' ;;
        none) : ;;
        *) printf 'table inet fw4 {\n\tflowtable ft {\n\t\thook ingress priority filter\n\t\tdevices = { lan1, wan }\n\t}\n}\n' ;;
    esac > "$BE_NFT/list flowtables"
}
be_offload none

be_run() {
    ubus_start "$BE_UBUS"
    TCTL_ROOT="$BE_ROOT" PATH="$BE_BIN:$PATH" tctl "$@" 2>/dev/null
    ubus_stop
}

be_totals() {   # be_totals <sample file> [--all]
    TCTL_ROOT="$BE_ROOT" PATH="$BE_BIN:$PATH" \
        "$UCODE" -S -L "$UC_LIB" -- "$UC_TESTLIB/totals.uc" "$@" 2>/dev/null
}
