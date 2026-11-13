#!/bin/bash
# shellcheck shell=bash
# A scratch router for the tests of the limiter (trafficctl ratelimit, the
# limit half of trafficctl restore). Source it after tests/lib/ucode.sh:
#
#   ROOT              TCTL_ROOT: etc/config, etc/trafficctl, sys/class/net, tmp
#   MOCKBIN           first on PATH for every lt_run
#   STATE             the fakes' state and logs:
#     nft/            netdev tm_ratelimit, owned by tests/lib/nft-netdev.sh
#     nft.log logger.log conntrack.log
#     neigh neigh6 route  `ip neigh show`, `ip -6 neigh show`, `ip route show`
#   LEASES RULES      /tmp/dhcp.leases, /etc/trafficctl/rules.json under ROOT
#
#   lt_cfg [persist]          trafficctl, network and firewall configs
#   lt_net <lan> [port...]    the LAN device (a bridge when ports are given)
#                             and eth1, the WAN; the ubus network objects
#   lt_run <cmd> [args]       tctl with the fakes, TCTL_ROOT and the ubus mock
#   lt_table                  `nft -a list table netdev tm_ratelimit`
#   lt_rules_of <comment>     "<chain> <meter or ->" of each rule with exactly
#                             that comment
#   lt_reset                  empty nft state, logs and rules.json
#
# NFT_EMU (1.0, 1.1) and the NFT_FAIL_* knobs of nft-netdev.sh are read from
# the environment of each lt_run.

LT="$UC_TMP/lt"
ROOT="$LT/root"
MOCKBIN="$LT/bin"
STATE="$LT/state"
mkdir -p "$ROOT/etc/config" "$ROOT/etc/trafficctl" "$ROOT/tmp/.uci" "$MOCKBIN" "$STATE/nft" "$LT/ubus"
LEASES="$ROOT/tmp/dhcp.leases"
RULES="$ROOT/etc/trafficctl/rules.json"
: > "$LEASES"

export NFT_STATE="$STATE/nft" NFT_LOG="$STATE/nft.log"
LOGGER_LOG="$STATE/logger.log"
CONNTRACK_LOG="$STATE/conntrack.log"

cp "$UC_TESTLIB/nft-netdev.sh" "$MOCKBIN/nft"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$LOGGER_LOG" > "$MOCKBIN/logger"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$CONNTRACK_LOG" > "$MOCKBIN/conntrack"
cat > "$MOCKBIN/ip" <<MOCK
#!/bin/sh
S="$STATE"
MOCK
cat >> "$MOCKBIN/ip" <<'MOCK'
case "$*" in
    "neigh show") cat "$S/neigh" 2>/dev/null ;;
    "-6 neigh show") cat "$S/neigh6" 2>/dev/null ;;
    "route show") cat "$S/route" 2>/dev/null ;;
    "route show default") grep '^default' "$S/route" 2>/dev/null ;;
    *) exit 1 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN"/*

lt_cfg() {
    {
        printf "config trafficctl 'main'\n\toption persist_rules '%s'\n" "${1:-0}"
        printf "\nconfig logging 'logging'\n\toption enabled '0'\n"
    } > "$ROOT/etc/config/trafficctl"
    printf "config interface 'lan'\n\toption device 'br-lan'\n\nconfig interface 'wan'\n\toption device 'eth1'\n" \
        > "$ROOT/etc/config/network"
    printf "config zone\n\toption name 'lan'\n\tlist network 'lan'\n\nconfig zone\n\toption name 'wan'\n\tlist network 'wan'\n\toption masq '1'\n" \
        > "$ROOT/etc/config/firewall"
}

# lt_net <lan device> [bridge port...]: sysfs, and the interface dump the
# LAN subnets are read from (192.168.1.1/24 unless LT_LAN_IP/LT_LAN_MASK).
lt_net() {
    local lan="$1" p
    shift
    rm -rf "$ROOT/sys"
    mkdir -p "$ROOT/sys/class/net/$lan" "$ROOT/sys/class/net/eth1"
    for p in "$@"; do mkdir -p "$ROOT/sys/class/net/$lan/brif/$p" "$ROOT/sys/class/net/$p"; done
    ubus_stop
    rm -f "$LT/ubus"/*.json
    printf '{"interface":[{"interface":"lan","up":true,"l3_device":"%s","ipv4-address":[{"address":"%s","mask":%s}]},{"interface":"wan","up":true,"l3_device":"eth1","ipv4-address":[{"address":"203.0.113.2","mask":24}]}]}\n' \
        "$lan" "${LT_LAN_IP:-192.168.1.1}" "${LT_LAN_MASK:-24}" > "$LT/ubus/network.interface@dump.json"
    printf '{"up":true,"l3_device":"eth1"}\n' > "$LT/ubus/network.interface.wan@status.json"
    ubus_start "$LT/ubus"
}

lt_run() {
    PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tctl "$@" 2>&1
}

lt_table() {
    PATH="$MOCKBIN:$PATH" nft -a list table netdev tm_ratelimit 2>/dev/null
}

lt_rules_of() {
    lt_table | awk -v c="\"$1\"" '
        /^[ \t]*chain / { chain = $2; next }
        {
            for (i = 1; i < NF; i++) if ($i == "comment" && $(i+1) == c) {
                m = "-"
                for (j = 1; j < NF; j++) {
                    if ($j == "meter") m = $(j+1)
                    if ($j == "add" && substr($(j+1), 1, 1) == "@") m = substr($(j+1), 2)
                }
                print chain, m
            }
        }'
}

lt_reset() {
    rm -rf "${NFT_STATE:?}"
    mkdir -p "$NFT_STATE"
    : > "$NFT_LOG"; : > "$LOGGER_LOG"; : > "$CONNTRACK_LOG"
    printf '[]\n' > "$RULES"
}

lt_cfg
