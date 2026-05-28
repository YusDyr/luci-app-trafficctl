#!/bin/sh
# shellcheck shell=dash
# Block device WiFi access by adding its MAC to deny maclist on all interfaces.
# Uses hostapd to deauth only the target client — no wifi reload needed.
# Usage: trafficctl-macfilter-add.sh <ip>

. /usr/local/bin/trafficctl-fw.sh

IP="$1"

if [ -z "$IP" ]; then
    echo '{"ok":false,"msg":"usage: trafficctl-macfilter-add.sh <ip>"}'
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

# Normalize MAC to lowercase (OpenWrt stores lowercase)
MAC=$(echo "$MAC" | tr 'A-F' 'a-f')

# Add MAC to maclist on all wifi interfaces
IFACES=$(tctl_get_wifi_interfaces)
if [ -z "$IFACES" ]; then
    echo '{"ok":false,"msg":"no wifi interfaces found"}'
    exit 1
fi

CHANGED=0
for iface in $IFACES; do
    current_filter=$(uci -q get "wireless.${iface}.macfilter")
    if [ "$current_filter" != "deny" ]; then
        uci set "wireless.${iface}.macfilter=deny"
        CHANGED=1
    fi

    existing=$(uci -q get "wireless.${iface}.maclist")
    echo "$existing" | grep -qi "$MAC" && continue

    uci add_list "wireless.${iface}.maclist=$MAC"
    CHANGED=1
done

if [ "$CHANGED" = "1" ]; then
    uci commit wireless
    # Apply at runtime: add to deny ACL + deauth this client only
    tctl_hostapd_deny_mac "$MAC"
fi

tctl_log "wifi_block" "$IP" "MAC=$MAC" "${TCTL_VIA:-cli}" "${TCTL_SRC:-local}"
echo "{\"ok\":true,\"msg\":\"MAC $MAC blocked on wifi for $IP\"}"
