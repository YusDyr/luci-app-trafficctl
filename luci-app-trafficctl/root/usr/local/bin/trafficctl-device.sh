#!/bin/sh
# shellcheck shell=dash
# Detailed device info with connections.
# Usage: trafficctl-device.sh <ip> [--rdns] [--proto tcp|udp|all]

. /usr/local/bin/trafficctl-fw.sh

LAN_DEV=$(tctl_get_lan_device)

# Parse arguments
IP=""
DO_RDNS=0
PROTO_FILTER="all"

while [ $# -gt 0 ]; do
    case "$1" in
        --rdns) DO_RDNS=1 ;;
        --proto) shift; PROTO_FILTER="$1" ;;
        *) [ -z "$IP" ] && IP="$1" ;;
    esac
    shift
done

if [ -z "$IP" ]; then
    echo '{"ok":false,"msg":"usage: trafficctl-device.sh <ip> [--rdns] [--proto tcp|udp|all]"}'
    exit 1
fi

if ! tctl_validate_ip "$IP"; then
    echo '{"ok":false,"msg":"invalid IP address"}'
    exit 1
fi

# Get device name from DHCP leases
NAME=""
MAC=""
if [ -f /tmp/dhcp.leases ]; then
    NAME=$(awk -v ip="$IP" '$3 == ip {print $4}' /tmp/dhcp.leases | head -1)
    MAC=$(awk -v ip="$IP" '$3 == ip {print $2}' /tmp/dhcp.leases | head -1)
fi
if [ -z "$MAC" ]; then
    MAC=$(ip neigh show "$IP" 2>/dev/null | grep -oE '[0-9a-fA-F:]{17}' | head -1)
fi
MAC=$(echo "$MAC" | tr 'A-F' 'a-f')
[ -z "$NAME" ] && NAME="*"

# Detect connection type — specific interface or band
CONN_TYPE=""
CONN_LAST=""
CONN_CACHE="/tmp/trafficctl_conn_cache"
[ -f "$CONN_CACHE" ] || : > "$CONN_CACHE"

if [ -n "$MAC" ]; then
    _wifi_stations=$(
        for _wi in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
            _ch=$(iw dev "$_wi" info 2>/dev/null | awk '/channel/{print $2}')
            _band=""
            if [ -n "$_ch" ]; then
                if [ "$_ch" -le 14 ] 2>/dev/null; then _band="2.4G"
                elif [ "$_ch" -le 177 ] 2>/dev/null; then _band="5G"
                else _band="6G"; fi
            fi
            iw dev "$_wi" station dump 2>/dev/null | awk -v iface="$_wi" -v band="$_band" \
                '/Station/{print tolower($2), iface, band}'
        done
    )
    WIFI_LINE=$(echo "$_wifi_stations" | grep -i "$MAC")
    if [ -n "$WIFI_LINE" ]; then
        CONN_TYPE=$(echo "$WIFI_LINE" | awk '{print $3}')
        [ -z "$CONN_TYPE" ] && CONN_TYPE="wifi"
    else
        BR_PORT=$(brctl showmacs "$LAN_DEV" 2>/dev/null | awk -v mac="$MAC" '
            NR>1 && $3=="no" && tolower($2)==mac {print $1; exit}')
        if [ -n "$BR_PORT" ]; then
            PORT_IFACE=""
            for pdir in /sys/class/net/"$LAN_DEV"/brif/*/; do
                [ -d "$pdir" ] || continue
                pno=$(cat "${pdir}port_no" 2>/dev/null)
                [ -z "$pno" ] && continue
                if [ $(( pno )) -eq "$BR_PORT" ] 2>/dev/null; then
                    PORT_IFACE=$(basename "$pdir")
                    break
                fi
            done
            case "$PORT_IFACE" in
                phy*|wlan*) CONN_TYPE="wifi" ;;
                "") ;;
                *) CONN_TYPE="$PORT_IFACE" ;;
            esac
        fi
    fi
fi

if [ -n "$CONN_TYPE" ]; then
    sed -i "/^$IP /d" "$CONN_CACHE" 2>/dev/null
    echo "$IP $CONN_TYPE $(date +%s)" >> "$CONN_CACHE"
else
    _arp_state=$(ip neigh show "$IP" 2>/dev/null | awk '{print $NF}')
    case "$_arp_state" in
        REACHABLE|STALE|DELAY|PROBE) CONN_TYPE="ethernet" ;;
        *)
            CONN_TYPE="?"
            _cached=$(grep "^$IP " "$CONN_CACHE" 2>/dev/null | tail -1)
            if [ -n "$_cached" ]; then
                CONN_LAST=$(echo "$_cached" | awk '{print $2 "@" $3}')
            fi
            ;;
    esac
fi

# Check blocked status
BLOCKED=false
BLOCK_PACKETS=0
BLOCK_BYTES=0
if tctl_is_blocked "$IP"; then
    BLOCKED=true
    if [ "$TCTL_FW" = "nft" ]; then
        block_line=$(nft list chain inet fw4 forward 2>/dev/null | grep "ip saddr $IP.*drop")
        BLOCK_PACKETS=$(echo "$block_line" | grep -oE 'packets [0-9]+' | awk '{print $2}')
        BLOCK_BYTES=$(echo "$block_line" | grep -oE 'bytes [0-9]+' | awk '{print $2}')
    else
        block_line=$(iptables -L FORWARD -nvx 2>/dev/null | grep "DROP" | grep "$IP")
        BLOCK_PACKETS=$(echo "$block_line" | awk '{print $1}')
        BLOCK_BYTES=$(echo "$block_line" | awk '{print $2}')
    fi
fi
[ -z "$BLOCK_PACKETS" ] && BLOCK_PACKETS=0
[ -z "$BLOCK_BYTES" ] && BLOCK_BYTES=0

# Check wifi blocked
WIFI_BLOCKED=false
if [ -n "$MAC" ]; then
    IFACES=$(tctl_get_wifi_interfaces)
    for iface in $IFACES; do
        maclist=$(uci -q get "wireless.${iface}.maclist")
        if echo "$maclist" | grep -qi "$MAC"; then
            WIFI_BLOCKED=true
            break
        fi
    done
fi

# Get rate limit
RATE_LIM=0
if [ "$TCTL_FW" = "nft" ]; then
    RATE_LIM=$(nft list table netdev tm_ratelimit 2>/dev/null | grep "daddr $IP" | \
        grep -oE '[0-9]+ kbytes' | awk '{print $1 * 8}')
else
    RATE_LIM=$(iptables -t mangle -L FORWARD -nv 2>/dev/null | grep "rl_ratelimit" | grep "$IP" | \
        grep -oE '[0-9]+kbit' | head -1 | sed 's/kbit//')
fi
[ -z "$RATE_LIM" ] && RATE_LIM=0

# Get shape rate
SHAPE_KBIT=0
o3=$(echo "$IP" | cut -d. -f3)
o4=$(echo "$IP" | cut -d. -f4)
dec=$((o3 * 256 + o4))
hex=$(printf "%x" "$dec")
classid="1:$hex"
# Skip reserved HTB classes (root 1:1 and default 1:fffe)
shape_info=""
case "$hex" in 1|fffe) ;; *) shape_info=$(tc class show dev "$LAN_DEV" classid "$classid" 2>/dev/null) ;; esac
if [ -n "$shape_info" ]; then
    SHAPE_KBIT=$(echo "$shape_info" | grep -oE 'rate [0-9]+[A-Za-z]+' | head -1 | awk '{
        rate=$2; num=rate+0
        if (rate ~ /Gbit/) print num*1000000
        else if (rate ~ /Mbit/) print num*1000
        else if (rate ~ /[Kk]bit/) print num
        else print num
    }')
fi
[ -z "$SHAPE_KBIT" ] && SHAPE_KBIT=0

# Parse conntrack for connections and totals
TIMESTAMP=$(date +%s)
CONNTRACK_DATA=$(cat /proc/net/nf_conntrack 2>/dev/null | grep "src=$IP ")

# Compute metadata (totals + states)
META_LINE=$(echo "$CONNTRACK_DATA" | awk -v ip="$IP" -v pf="$PROTO_FILTER" '
BEGIN { total=0; n_tcp=0; n_udp=0; n_other=0; est=0; tw=0; ss=0; cw=0 }
{
    proto=""
    for (i=1; i<=NF; i++) {
        if ($i == "tcp") proto="tcp"
        else if ($i == "udp") proto="udp"
        else if ($i == "icmp") proto="icmp"
    }
    if (pf != "all" && proto != pf) next

    dst=""; bytes=0; state=""
    src_key = "src=" ip
    seen_src=0; got_dst=0
    for (i=1; i<=NF; i++) {
        if ($i == src_key && !seen_src) { seen_src=1; continue }
        if (seen_src && !got_dst && index($i, "dst=") == 1) { dst=substr($i, 5); got_dst=1 }
        if (seen_src && !got_dst) continue
        if (seen_src && index($i, "bytes=") == 1 && bytes == 0) { bytes=substr($i, 7)+0 }
        if ($i == "ESTABLISHED") state="ESTABLISHED"
        else if ($i == "TIME_WAIT") state="TIME_WAIT"
        else if ($i == "SYN_SENT") state="SYN_SENT"
        else if ($i == "CLOSE_WAIT") state="CLOSE_WAIT"
    }
    if (dst == "" || dst == ip) next
    total += bytes
    if (proto == "tcp") n_tcp++
    else if (proto == "udp") n_udp++
    else n_other++
    if (state == "ESTABLISHED") est++
    else if (state == "TIME_WAIT") tw++
    else if (state == "SYN_SENT") ss++
    else if (state == "CLOSE_WAIT") cw++
}
END { printf "%d %d %d %d %d %d %d %d", total, n_tcp, n_udp, n_other, est, tw, ss, cw }
')

TOTAL=$(echo "$META_LINE" | awk '{print $1}')
N_TCP=$(echo "$META_LINE" | awk '{print $2}')
N_UDP=$(echo "$META_LINE" | awk '{print $3}')
N_OTHER=$(echo "$META_LINE" | awk '{print $4}')
EST=$(echo "$META_LINE" | awk '{print $5}')
TW=$(echo "$META_LINE" | awk '{print $6}')
SS=$(echo "$META_LINE" | awk '{print $7}')
CW=$(echo "$META_LINE" | awk '{print $8}')

[ -z "$TOTAL" ] && TOTAL=0
[ -z "$N_TCP" ] && N_TCP=0
[ -z "$N_UDP" ] && N_UDP=0
[ -z "$N_OTHER" ] && N_OTHER=0
[ -z "$EST" ] && EST=0
[ -z "$TW" ] && TW=0
[ -z "$SS" ] && SS=0
[ -z "$CW" ] && CW=0

# Build connections JSON array
CONNS_OUT=$(echo "$CONNTRACK_DATA" | awk -v ip="$IP" -v pf="$PROTO_FILTER" '
BEGIN { n=0 }
{
    proto=""
    for (i=1; i<=NF; i++) {
        if ($i == "tcp") proto="tcp"
        else if ($i == "udp") proto="udp"
        else if ($i == "icmp") proto="icmp"
    }
    if (pf != "all" && proto != pf) next

    dst=""; dport=""; bytes=0; state=""
    src_key = "src=" ip
    seen_src=0; got_dst=0
    for (i=1; i<=NF; i++) {
        if ($i == src_key && !seen_src) { seen_src=1; continue }
        if (seen_src && !got_dst && index($i, "dst=") == 1) { dst=substr($i, 5); got_dst=1 }
        if (seen_src && !got_dst) continue
        if (seen_src && index($i, "dport=") == 1 && dport == "") dport=substr($i, 7)
        if (seen_src && index($i, "bytes=") == 1 && bytes == 0) bytes=substr($i, 7)+0
        if ($i == "ESTABLISHED") state="ESTABLISHED"
        else if ($i == "TIME_WAIT") state="TIME_WAIT"
        else if ($i == "SYN_SENT") state="SYN_SENT"
        else if ($i == "CLOSE_WAIT") state="CLOSE_WAIT"
        else if ($i == "FIN_WAIT") state="FIN_WAIT"
    }
    if (dst == "" || dst == ip) next
    if (dport == "") dport = "0"

    # Service name lookup
    svc=""
    if (dport == "80") svc="http"
    else if (dport == "443") svc="https"
    else if (dport == "53") svc="dns"
    else if (dport == "22") svc="ssh"
    else if (dport == "123") svc="ntp"
    else if (dport == "5353") svc="mdns"
    else if (dport == "21") svc="ftp"
    else if (dport == "25") svc="smtp"
    else if (dport == "993") svc="imaps"
    else if (dport == "8080") svc="http-alt"

    if (n > 0) printf ","
    printf "{\"proto\":\"%s\",\"dst\":\"%s\",\"host\":\"\",\"port\":%s,\"service\":\"%s\",\"bytes\":%d,\"state\":\"%s\"}", proto, dst, dport, svc, bytes, state
    n++
}
')

# Optionally resolve DNS for connection destinations
if [ "$DO_RDNS" = "1" ] && command -v dig >/dev/null 2>&1; then
    DST_IPS=$(echo "$CONNTRACK_DATA" | grep -oE 'dst=[0-9.]+' | sed 's/dst=//' | sort -u | grep -v "^$IP$")
    RDNS_MAP="/tmp/trafficctl_rdns_$$"
    : > "$RDNS_MAP"
    for dip in $DST_IPS; do
        host=$(dig +short +time=1 +tries=1 -x "$dip" 2>/dev/null | grep -v '^;;' | head -1 | sed 's/\.$//')
        case "$host" in
            *[!a-zA-Z0-9._-]*|"") continue ;;
        esac
        echo "$dip $host" >> "$RDNS_MAP"
    done
    if [ -s "$RDNS_MAP" ]; then
        # Build sed expression from map
        SED_EXPR=$(awk '{printf "s|\"dst\":\"%s\",\"host\":\"\"|\"dst\":\"%s\",\"host\":\"%s\"|g\n", $1, $1, $2}' "$RDNS_MAP")
        CONNS_OUT=$(printf "%s" "$CONNS_OUT" | sed "$SED_EXPR")
    fi
    rm -f "$RDNS_MAP"
fi

# Output final JSON
printf '{"ip":"%s","name":"%s","mac":"%s","conn_type":"%s","conn_last":"%s","timestamp":%d,"blocked":%s,"block_packets":%d,"block_bytes":%d,"wifi_blocked":%s,"total":%d,"protocols":{"tcp":%d,"udp":%d,"other":%d},"tcp_states":{"established":%d,"time_wait":%d,"syn_sent":%d,"close_wait":%d},"connections":[%s],"rate_limit_kbit":%d,"shape_kbit":%d}\n' \
    "$IP" "$NAME" "$MAC" "$CONN_TYPE" "$CONN_LAST" "$TIMESTAMP" "$BLOCKED" "$BLOCK_PACKETS" "$BLOCK_BYTES" \
    "$WIFI_BLOCKED" "$TOTAL" "$N_TCP" "$N_UDP" "$N_OTHER" \
    "$EST" "$TW" "$SS" "$CW" "$CONNS_OUT" "$RATE_LIM" "$SHAPE_KBIT"
