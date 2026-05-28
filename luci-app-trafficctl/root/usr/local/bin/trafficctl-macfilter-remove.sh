#!/bin/sh
# shellcheck shell=dash
# Remove device WiFi MAC filter (unblock from wifi deny list).
# Uses hostapd beacon update — no wifi reload, other clients stay connected.
# Usage: trafficctl-macfilter-remove.sh <ip>

. /usr/local/bin/trafficctl-fw.sh

IP="$1"

if [ -z "$IP" ]; then
    echo '{"ok":false,"msg":"usage: trafficctl-macfilter-remove.sh <ip>"}'
    exit 1
fi

if ! tctl_validate_ip "$IP"; then
    echo '{"ok":false,"msg":"invalid IP address"}'
    exit 1
fi

# Look up MAC from DHCP leases
MAC=""
if [ -f /tmp/dhcp.leases ]; then
    MAC=$(awk -v ip="$IP" '$3 == ip {print toupper($2)}' /tmp/dhcp.leases | head -1)
fi

if [ -z "$MAC" ]; then
    MAC=$(ip neigh show "$IP" 2>/dev/null | grep -oE '[0-9a-fA-F:]{17}' | head -1 | tr 'a-f' 'A-F')
fi

if [ -z "$MAC" ]; then
    echo "{\"ok\":false,\"msg\":\"cannot find MAC for $IP\"}"
    exit 1
fi

# Normalize MAC to lowercase
MAC=$(echo "$MAC" | tr 'A-F' 'a-f')

# Remove MAC from maclist on all wifi interfaces
IFACES=$(tctl_get_wifi_interfaces)
if [ -z "$IFACES" ]; then
    echo '{"ok":false,"msg":"no wifi interfaces found"}'
    exit 1
fi

CHANGED=0
for iface in $IFACES; do
    existing=$(uci -q get "wireless.${iface}.maclist")
    if echo "$existing" | grep -qi "$MAC"; then
        uci del_list "wireless.${iface}.maclist=$MAC"
        CHANGED=1
    fi
done

if [ "$CHANGED" = "1" ]; then
    uci commit wireless
    # Remove from runtime deny ACL — client can reassociate immediately
    tctl_hostapd_allow_mac "$MAC"
fi

tctl_log "wifi_unblock" "$IP" "MAC=$MAC" "${TCTL_VIA:-cli}" "${TCTL_SRC:-local}"
echo "{\"ok\":true,\"msg\":\"MAC $MAC removed from wifi filter for $IP\"}"
