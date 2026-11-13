#!/bin/bash
# shellcheck shell=bash
# A scratch router for the tests of the ucode writers (block, unblock, the
# WiFi deny, newdevice, restore). Source it after tests/lib/ucode.sh:
#
#   ROOT              TCTL_ROOT: etc/config, etc/trafficctl, tmp
#   MOCKBIN           first on PATH for every tctl call (fw_run)
#   STATE             the fakes' state and logs:
#     nft.json        inet fw4 forward, owned by tests/lib/nft-fw4.uc
#     nft.log uci.log conntrack.log hostapd.log logger.log ubus.log
#     ip4_<dev>       `ip -4 addr show dev <dev>`
#     neigh neigh6 route  `ip neigh show`, `ip -6 neigh show`, `ip route show`
#     deny_acl accept_acl cli_mode  hostapd_cli's running ACLs and failure mode
#
#   fw_run <cmd> [args]   tctl with the fakes, TCTL_ROOT and the ubus mock
#   fw_cfg [persist]      trafficctl and network configs (persist_rules 0/1)
#   fw_rules              the chain's rule texts, one per line, insertion order
#   fw_handles            "<handle> <text>" per rule
#   fw_put <text>         a rule placed in the chain directly (as v1.30 would)
#   fw_wifi <mode> [maclist...]   one wifi-iface 'wifi0' (mode deny/allow/"")
#   fw_hostapd <cli> <ubus> [mac...]  runtime: cli ok|silent|dead|hang|missing;
#                         ubus ok|ban_nonzero|noban|noradio|broken;
#                         the MACs already in the running deny ACL. The APs
#                         are $FW_RADIOS (default wifi0); cli_mode.<ap> in
#                         STATE sets one AP's cli mode apart
#   fw_clear              empty the logs (not the state)
#
# uci is the real CLI (UCODE_PREFIX) behind a logging wrapper, so a test reads
# both the call and the file it changed. The hostapd_cli fake is stateful:
# ADD_MAC/DEL_MAC change the ACL that SHOW prints, so "did the entry land" is
# asked, not assumed (see tests/test_macfilter.sh).

FW_T="$UC_TMP/fw"
ROOT="$FW_T/root"
MOCKBIN="$FW_T/bin"
STATE="$FW_T/state"
mkdir -p "$ROOT/etc/config" "$ROOT/etc/trafficctl" "$ROOT/tmp/.uci" "$MOCKBIN" "$STATE" "$FW_T/ubus"
LEASES="$ROOT/tmp/dhcp.leases"
RULES="$ROOT/etc/trafficctl/rules.json"
: > "$LEASES"

export NFT_STATE="$STATE/nft.json" NFT_LOG="$STATE/nft.log"
UCI_LOG="$STATE/uci.log"
CONNTRACK_LOG="$STATE/conntrack.log"
HOSTAPD_LOG="$STATE/hostapd.log"
LOGGER_LOG="$STATE/logger.log"
UBUS_LOG="$STATE/ubus.log"

printf '#!/bin/sh\nexec "%s" -S "%s/nft-fw4.uc" -- "$@"\n' "$UCODE" "$UC_TESTLIB" > "$MOCKBIN/nft"
printf '#!/bin/sh\necho "$*" >> "%s"\nexec "%s/bin/uci" "$@"\n' "$UCI_LOG" "$UCODE_PREFIX" > "$MOCKBIN/uci"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$CONNTRACK_LOG" > "$MOCKBIN/conntrack"
printf '#!/bin/sh\necho "$*" >> "%s"\nexit 0\n' "$LOGGER_LOG" > "$MOCKBIN/logger"

cat > "$MOCKBIN/ip" <<MOCK
#!/bin/sh
S="$STATE"
MOCK
cat >> "$MOCKBIN/ip" <<'MOCK'
case "$*" in
    "-4 addr show dev "*) cat "$S/ip4_$5" 2>/dev/null ;;
    "neigh show") cat "$S/neigh" 2>/dev/null ;;
    "neigh show "*) grep "^$3 " "$S/neigh" 2>/dev/null ;;
    "-6 neigh show") cat "$S/neigh6" 2>/dev/null ;;
    "route show") cat "$S/route" 2>/dev/null ;;
    *) exit 1 ;;
esac
exit 0
MOCK

cat > "$MOCKBIN/hostapd_cli" <<MOCK
#!/bin/sh
echo "\$*" >> "$HOSTAPD_LOG"
STATE="$STATE"
MOCK
cat >> "$MOCKBIN/hostapd_cli" <<'MOCK'
# argv: -i <iface> <cmd> [sub] [mac]. Per AP: cli_mode.<iface> overrides
# cli_mode, and an AP other than wifi0 keeps its ACLs in <acl>.<iface>.
iface="$2"
mode=$(cat "$STATE/cli_mode.$iface" 2>/dev/null || cat "$STATE/cli_mode" 2>/dev/null)
shift 2
cmd="$1"; sub="$2"; mac="$3"
case "$cmd" in
    ping)
        [ "$mode" = "dead" ] && exit 1
        [ "$mode" = "hang" ] && sleep 30
        echo "PONG"
        ;;
    deny_acl|accept_acl)
        f="$STATE/$cmd"
        [ "$iface" = "wifi0" ] || f="$f.$iface"
        [ -f "$f" ] || : > "$f"
        case "$sub" in
            SHOW) cat "$f" ;;
            ADD_MAC) [ "$mode" = "silent" ] || grep -qixF "$mac" "$f" || echo "$mac" >> "$f" ;;
            DEL_MAC)
                if [ "$mode" != "silent" ]; then
                    grep -vixF "$mac" "$f" > "$f.new"
                    mv "$f.new" "$f"
                fi
                ;;
        esac
        ;;
esac
exit 0
MOCK
cp "$MOCKBIN/hostapd_cli" "$FW_T/hostapd_cli"
chmod +x "$MOCKBIN"/* "$FW_T/hostapd_cli"
printf 'inet 192.168.1.254/24 brd 192.168.1.255 scope global br-lan\n' > "$STATE/ip4_br-lan"

fw_run() {
    PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tctl "$@" 2>&1
}

fw_cfg() {
    {
        printf "config trafficctl 'main'\n\toption persist_rules '%s'\n" "${1:-0}"
        printf "\nconfig logging 'logging'\n\toption enabled '0'\n"
    } > "$ROOT/etc/config/trafficctl"
    printf "config interface 'lan'\n\toption device 'br-lan'\n\nconfig interface 'wan'\n\toption device 'eth1'\n" \
        > "$ROOT/etc/config/network"
    [ -f "$ROOT/etc/config/wireless" ] || : > "$ROOT/etc/config/wireless"
}

fw_rules() {
    [ -s "$NFT_STATE" ] || return 0
    python3 -c 'import json,sys; [print(r["text"]) for r in json.load(open(sys.argv[1]))["rules"]]' "$NFT_STATE"
}
fw_handles() {
    [ -s "$NFT_STATE" ] || return 0
    python3 -c 'import json,sys; [print(r["handle"], r["text"]) for r in json.load(open(sys.argv[1]))["rules"]]' "$NFT_STATE"
}
fw_put() {
    PATH="$MOCKBIN:$PATH" nft add rule inet fw4 forward "$1"
}
fw_flush() {
    rm -f "$NFT_STATE"
}
fw_clear() {
    : > "$NFT_LOG"; : > "$UCI_LOG"; : > "$CONNTRACK_LOG"; : > "$HOSTAPD_LOG"; : > "$LOGGER_LOG"; : > "$UBUS_LOG"
}

fw_wifi() {
    local mode="$1" m
    shift
    {
        printf "config wifi-iface 'wifi0'\n\toption device 'radio0'\n\toption mode 'ap'\n"
        [ -n "$mode" ] && printf "\toption macfilter '%s'\n" "$mode"
        for m in "$@"; do printf "\tlist maclist '%s'\n" "$m"; done
    } > "$ROOT/etc/config/wireless"
}

# The ubus side through the real ubus client library: a private ubusd and
# tests/lib/ubus-mock.uc, one hostapd object (wifi0) unless noradio. broken
# points the code at a socket nobody listens on.
fw_hostapd() {
    local cli="$1" ub="$2" m
    shift 2
    rm -f "$STATE"/deny_acl* "$STATE"/accept_acl* "$STATE"/cli_mode.*
    : > "$STATE/deny_acl"
    : > "$STATE/accept_acl"
    for m in "$@"; do echo "$m" >> "$STATE/deny_acl"; done
    if [ "$cli" = "missing" ]; then
        rm -f "$MOCKBIN/hostapd_cli"
    else
        cp "$FW_T/hostapd_cli" "$MOCKBIN/hostapd_cli"
        echo "$cli" > "$STATE/cli_mode"
    fi
    ubus_stop
    rm -f "$FW_T/ubus"/*.json
    echo '{}' > "$FW_T/ubus/network.interface@dump.json"
    for r in ${FW_RADIOS:-wifi0}; do
        case "$ub" in
            ok)          echo '{}' > "$FW_T/ubus/hostapd.$r@del_client.json" ;;
            ban_nonzero) echo '{"_rc":4}' > "$FW_T/ubus/hostapd.$r@del_client.json" ;;
            noban)       echo '{"_rc":4,"_ban":false}' > "$FW_T/ubus/hostapd.$r@del_client.json" ;;
        esac
        case "$ub" in
            ok|ban_nonzero|noban) echo '{"clients":[]}' > "$FW_T/ubus/hostapd.$r@list_bans.json" ;;
        esac
    done
    ubus_start "$FW_T/ubus" "$UBUS_LOG"
    [ "$ub" = "broken" ] && export TCTL_UBUS_SOCKET="$FW_T/no-such.sock"
    return 0
}
