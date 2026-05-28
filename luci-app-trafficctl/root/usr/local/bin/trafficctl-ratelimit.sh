#!/bin/sh
# shellcheck shell=dash
# Rate-limit a device's download bandwidth (policer).
# Usage: trafficctl-ratelimit.sh <ip> <rate_kbit> [label]
# rate_kbit=0 removes the limit.

. /usr/local/bin/trafficctl-fw.sh

IP="$1"
RATE="$2"
LABEL="${3:-rl_$IP}"

if [ -z "$IP" ] || [ -z "$RATE" ]; then
    echo '{"ok":false,"msg":"usage: trafficctl-ratelimit.sh <ip> <rate_kbit> [label]"}'
    exit 1
fi

if ! tctl_validate_ip "$IP"; then
    echo '{"ok":false,"msg":"invalid IP address"}'
    exit 1
fi

COMMENT="rl_ratelimit_${LABEL}"

if [ "$RATE" = "0" ]; then
    if tctl_ratelimit_remove "$IP" "$COMMENT"; then
        tctl_persist_enabled && tctl_persist_remove "ratelimit" "$IP"
        tctl_log "ratelimit_remove" "$IP" "" "${TCTL_VIA:-cli}" "${TCTL_SRC:-local}"
        echo "{\"ok\":true,\"msg\":\"rate limit removed for $IP\"}"
    else
        echo "{\"ok\":false,\"msg\":\"failed to remove rate limit for $IP\"}"
        exit 1
    fi
else
    tctl_ratelimit_remove "$IP" "$COMMENT" 2>/dev/null
    if tctl_ratelimit_add "$IP" "$RATE" "$COMMENT"; then
        tctl_persist_enabled && tctl_persist_save "ratelimit" "$IP" "$RATE"
        tctl_log "ratelimit_set" "$IP" "${RATE}kbit" "${TCTL_VIA:-cli}" "${TCTL_SRC:-local}"
        echo "{\"ok\":true,\"msg\":\"rate limit set to ${RATE} kbit/s for $IP\"}"
    else
        echo "{\"ok\":false,\"msg\":\"failed to set rate limit for $IP\"}"
        exit 1
    fi
fi
