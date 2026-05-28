#!/bin/sh
# shellcheck shell=dash
# Block internet access for a device.
# Usage: trafficctl-block.sh <ip> [label]

. /usr/local/bin/trafficctl-fw.sh

IP="$1"
LABEL="${2:-block_$IP}"

if [ -z "$IP" ]; then
    echo '{"ok":false,"msg":"usage: trafficctl-block.sh <ip> [label]"}'
    exit 1
fi

if ! tctl_validate_ip "$IP"; then
    echo '{"ok":false,"msg":"invalid IP address"}'
    exit 1
fi

ROUTER_IP=$(ip -4 addr show dev "$(tctl_get_lan_device)" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)
if [ "$IP" = "$ROUTER_IP" ]; then
    echo '{"ok":false,"msg":"cannot block the router itself"}'
    exit 1
fi

COMMENT="tctl_block_${LABEL}"
SELF_BLOCK=false
if [ -n "$TCTL_SRC" ] && [ "$TCTL_SRC" = "$IP" ]; then
    SELF_BLOCK=true
fi

if tctl_is_blocked "$IP"; then
    echo "{\"ok\":true,\"msg\":\"$IP is already blocked\"}"
    exit 0
fi

if tctl_block_add "$IP" "$COMMENT"; then
    conntrack -D -s "$IP" >/dev/null 2>&1
    conntrack -D -d "$IP" >/dev/null 2>&1
    tctl_persist_enabled && tctl_persist_save "block" "$IP" "$LABEL"
    tctl_log "block" "$IP" "$LABEL" "${TCTL_VIA:-cli}" "${TCTL_SRC:-local}"
    if [ "$SELF_BLOCK" = "true" ]; then
        echo "{\"ok\":true,\"msg\":\"internet blocked for $IP (your device — LuCI access preserved)\"}"
    else
        echo "{\"ok\":true,\"msg\":\"internet blocked for $IP\"}"
    fi
else
    echo "{\"ok\":false,\"msg\":\"failed to block $IP\"}"
    exit 1
fi
