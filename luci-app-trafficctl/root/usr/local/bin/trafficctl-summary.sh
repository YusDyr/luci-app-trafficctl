#!/bin/sh
# shellcheck shell=dash
# Summary of all active LAN devices with traffic control status.
# Output: JSON array with per-device info.

. /usr/local/bin/trafficctl-fw.sh

LAN_DEV=$(tctl_get_lan_device)
LAN_SUBNET=$(ip -4 addr show dev "$LAN_DEV" 2>/dev/null | grep -oE 'inet [0-9.]+/[0-9]+' | head -1 | awk '{print $2}')
CONN_CACHE="/tmp/trafficctl_conn_cache"
[ -f "$CONN_CACHE" ] || : > "$CONN_CACHE"

# Get all active IPs from conntrack
get_active_ips() {
    cat /proc/net/nf_conntrack 2>/dev/null | \
        grep -oE 'src=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | \
        sed 's/src=//' | sort -u | \
        grep -v '^127\.' | grep -v '^255\.'
}

# Get device name from DHCP leases
get_name() {
    local ip="$1"
    if [ -f /tmp/dhcp.leases ]; then
        awk -v ip="$ip" '$3 == ip {print $4}' /tmp/dhcp.leases | head -1
    fi
}

# Get MAC from DHCP leases or ARP
get_mac() {
    local ip="$1"
    local mac=""
    if [ -f /tmp/dhcp.leases ]; then
        mac=$(awk -v ip="$ip" '$3 == ip {print $2}' /tmp/dhcp.leases | head -1)
    fi
    if [ -z "$mac" ]; then
        mac=$(ip neigh show "$ip" 2>/dev/null | grep -oE '[0-9a-fA-F:]{17}' | head -1)
    fi
    echo "$mac" | tr 'A-F' 'a-f'
}

# Get traffic totals and connection count from conntrack
get_traffic() {
    local ip="$1"
    cat /proc/net/nf_conntrack 2>/dev/null | grep "src=$ip " | awk -v ip="$ip" '
    BEGIN { total=0; tcp=0; udp=0; conns=0 }
    {
        proto=""
        for (i=1; i<=NF; i++) {
            if ($i == "tcp") proto="tcp"
            else if ($i == "udp") proto="udp"
        }
        src_key = "src=" ip
        seen_src=0; got_dst=0
        for (i=1; i<=NF; i++) {
            if ($i == src_key && !seen_src) { seen_src=1; continue }
            if (seen_src && !got_dst && index($i, "dst=") == 1) {
                dst=substr($i, 5)
                if (dst != ip) { got_dst=1; conns++ }
                else next
            }
            if (seen_src && got_dst && index($i, "bytes=") == 1) {
                b = substr($i, 7) + 0
                total += b
                if (proto == "tcp") tcp += b
                else if (proto == "udp") udp += b
                break
            }
        }
    }
    END { printf "%d %d %d %d", total, tcp, udp, conns }
    '
}

# Check if IP is blocked (firewall)
check_blocked() {
    local ip="$1"
    if tctl_is_blocked "$ip"; then
        echo "1"
    else
        echo "0"
    fi
}

# Get block bytes from nft/iptables counters
get_block_bytes() {
    local ip="$1"
    if [ "$TCTL_FW" = "nft" ]; then
        nft list chain inet fw4 forward 2>/dev/null | grep "ip saddr $ip" | grep -oE 'bytes [0-9]+' | awk '{print $2}' | head -1
    else
        iptables -L FORWARD -nvx 2>/dev/null | grep "DROP" | grep "$ip" | awk '{print $2}' | head -1
    fi
}

# Check if MAC is wifi-blocked (in deny maclist)
check_wifi_blocked() {
    local mac="$1"
    [ -z "$mac" ] && echo "0" && return
    local ifaces
    ifaces=$(tctl_get_wifi_interfaces)
    for iface in $ifaces; do
        local maclist
        maclist=$(uci -q get "wireless.${iface}.maclist")
        if echo "$maclist" | grep -qi "$mac"; then
            echo "1"
            return
        fi
    done
    echo "0"
}

# Get rate limit for IP
get_rate_limit() {
    local ip="$1"
    if [ "$TCTL_FW" = "nft" ]; then
        nft list table netdev tm_ratelimit 2>/dev/null | grep "daddr $ip" | \
            grep -oE '[0-9]+ kbytes' | awk '{print $1 * 8}'
    else
        iptables -t mangle -L FORWARD -nv 2>/dev/null | grep "rl_ratelimit" | grep "$ip" | \
            grep -oE '[0-9]+kbit' | head -1 | sed 's/kbit//'
    fi
}

# Get shape rate for IP from tc
get_shape_kbit() {
    local ip="$1"
    local o3 o4 dec hex classid
    o3=$(echo "$ip" | cut -d. -f3)
    o4=$(echo "$ip" | cut -d. -f4)
    dec=$((o3 * 256 + o4))
    hex=$(printf "%x" "$dec")
    classid="1:$hex"
    # Skip reserved HTB classes (root 1:1 and default 1:fffe)
    case "$hex" in 1|fffe) echo 0; return ;; esac
    tc class show dev "$LAN_DEV" classid "$classid" 2>/dev/null | \
        grep -oE 'rate [0-9]+[A-Za-z]+' | head -1 | awk '{
            rate=$2
            num=rate+0
            if (rate ~ /Gbit/) print num*1000000
            else if (rate ~ /Mbit/) print num*1000
            else if (rate ~ /[Kk]bit/) print num
            else print num
        }'
}

# Get WiFi station→interface mapping: "mac iface_name band"
get_wifi_stations() {
    iw dev 2>/dev/null | awk '/Interface/{print $2}' | while read -r iface; do
        local band=""
        local ch
        ch=$(iw dev "$iface" info 2>/dev/null | awk '/channel/{print $2}')
        if [ -n "$ch" ]; then
            if [ "$ch" -le 14 ] 2>/dev/null; then
                band="2.4G"
            elif [ "$ch" -le 177 ] 2>/dev/null; then
                band="5G"
            else
                band="6G"
            fi
        fi
        iw dev "$iface" station dump 2>/dev/null | awk -v iface="$iface" -v band="$band" \
            '/Station/{print tolower($2), iface, band}'
    done
}

# Get bridge MAC→port interface mapping: "mac port_iface"
get_bridge_macs() {
    local port_map_file="/tmp/.trafficctl_portmap.$$"
    for pdir in /sys/class/net/"$LAN_DEV"/brif/*/; do
        [ -d "$pdir" ] || continue
        local iface pno
        iface=$(basename "$pdir")
        pno=$(cat "${pdir}port_no" 2>/dev/null)
        [ -z "$pno" ] && continue
        printf "%d %s\n" "$(( pno ))" "$iface"
    done > "$port_map_file"
    brctl showmacs "$LAN_DEV" 2>/dev/null | awk -v pmf="$port_map_file" '
    BEGIN { while ((getline line < pmf) > 0) { split(line, p, " "); portname[p[1]] = p[2] } }
    NR > 1 && $3 == "no" {
        mac = tolower($2)
        port = $1 + 0
        if (port in portname) print mac, portname[port]
    }'
    rm -f "$port_map_file"
}

# Filter to only LAN IPs, exclude the router itself
LAN_PREFIX=$(echo "$LAN_SUBNET" | cut -d. -f1-3)
LAN_IP=$(echo "$LAN_SUBNET" | cut -d/ -f1)

ACTIVE_IPS=$(get_active_ips | grep "^${LAN_PREFIX}\." | grep -v "^${LAN_IP}$" | grep -v '\.255$')
WIFI_STATIONS=$(get_wifi_stations)
BRIDGE_MACS=$(get_bridge_macs)

printf "["
FIRST=1
for ip in $ACTIVE_IPS; do
    NAME=$(get_name "$ip")
    MAC=$(get_mac "$ip")
    TRAFFIC=$(get_traffic "$ip")
    TOTAL=$(echo "$TRAFFIC" | awk '{print $1}')
    TCP=$(echo "$TRAFFIC" | awk '{print $2}')
    UDP=$(echo "$TRAFFIC" | awk '{print $3}')
    CONNS=$(echo "$TRAFFIC" | awk '{print $4}')
    BLOCKED=$(check_blocked "$ip")
    BLOCK_BYTES=$(get_block_bytes "$ip")
    [ -z "$BLOCK_BYTES" ] && BLOCK_BYTES=0
    WIFI_BLK=$(check_wifi_blocked "$MAC")
    RATE_LIM=$(get_rate_limit "$ip")
    [ -z "$RATE_LIM" ] && RATE_LIM=0
    SHAPE=$(get_shape_kbit "$ip")
    [ -z "$SHAPE" ] && SHAPE=0
    [ -z "$NAME" ] && NAME="*"
    CONN_TYPE=""
    CONN_LAST=""
    if [ -n "$MAC" ]; then
        _wl=$(echo "$WIFI_STATIONS" | grep -i "$MAC")
        if [ -n "$_wl" ]; then
            _band=$(echo "$_wl" | awk '{print $3}')
            CONN_TYPE="${_band:-wifi}"
        else
            _bl=$(echo "$BRIDGE_MACS" | grep -i "$MAC")
            if [ -n "$_bl" ]; then
                _piface=$(echo "$_bl" | awk '{print $2}')
                case "$_piface" in
                    phy*|wlan*) CONN_TYPE="wifi" ;;
                    *) CONN_TYPE="$_piface" ;;
                esac
            fi
        fi
    fi
    if [ -n "$CONN_TYPE" ]; then
        sed -i "/^$ip /d" "$CONN_CACHE" 2>/dev/null
        echo "$ip $CONN_TYPE $(date +%s)" >> "$CONN_CACHE"
    else
        _arp_state=$(ip neigh show "$ip" 2>/dev/null | awk '{print $NF}')
        case "$_arp_state" in
            REACHABLE|STALE|DELAY|PROBE) CONN_TYPE="ethernet" ;;
            *)
                CONN_TYPE="?"
                _cached=$(grep "^$ip " "$CONN_CACHE" 2>/dev/null | tail -1)
                if [ -n "$_cached" ]; then
                    CONN_LAST=$(echo "$_cached" | awk '{print $2 "@" $3}')
                fi
                ;;
        esac
    fi

    if [ "$FIRST" = "1" ]; then
        FIRST=0
    else
        printf ","
    fi
    printf '{"ip":"%s","name":"%s","mac":"%s","conn_type":"%s","conn_last":"%s","conns":%d,"total":%d,"tcp":%d,"udp":%d,"blocked":%s,"block_bytes":%d,"wifi_blocked":%s,"rate_limit_kbit":%d,"shape_kbit":%d}' \
        "$ip" "$NAME" "$MAC" "$CONN_TYPE" "$CONN_LAST" "$CONNS" "$TOTAL" "$TCP" "$UDP" \
        "$([ "$BLOCKED" = "1" ] && echo true || echo false)" \
        "$BLOCK_BYTES" \
        "$([ "$WIFI_BLK" = "1" ] && echo true || echo false)" \
        "$RATE_LIM" "$SHAPE"
done
printf "]\n"
