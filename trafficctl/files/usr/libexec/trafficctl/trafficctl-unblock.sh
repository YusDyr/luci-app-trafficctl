#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=dash
# Unblock internet access for a device.
# Usage: trafficctl-unblock.sh <ip> [label]

. /usr/libexec/trafficctl/trafficctl-fw.sh

IP="$1"
LABEL="${2:-block_$IP}"

if [ -z "$IP" ]; then
    echo '{"ok":false,"msg":"usage: trafficctl-unblock.sh <ip> [label]"}'
    exit 1
fi

if ! tctl_validate_ip "$IP"; then
    echo '{"ok":false,"msg":"invalid IP address"}'
    exit 1
fi

COMMENT=$(tctl_block_comment "$IP")

# Rules written before comments were derived from the address carry the caller's
# label, so a block placed from LuCI could not be removed from Telegram. The
# Rules tab lists them and unblocks with no label at all. On nft they are found
# by address (tctl_block_remove_legacy), never by the label: tctl_block_remove
# matches on the comment alone, and tctl_block_tg was shared by every device
# blocked from Telegram, so unblocking one lifted all their blocks. iptables -D
# also matches -s, so there the label is safe and still the only way in.
if [ "$TCTL_FW" = "nft" ]; then
    tctl_block_remove_legacy "$IP" 2>/dev/null
else
    tctl_block_remove "$IP" "tctl_block_${LABEL}" 2>/dev/null
fi

if tctl_block_remove "$IP" "$COMMENT"; then
    tctl_persist_enabled && tctl_persist_remove "block" "$IP"
    tctl_log "unblock" "$IP" "$LABEL" "${TCTL_VIA:-cli}" "${TCTL_SRC:-local}"
    echo "{\"ok\":true,\"msg\":\"internet unblocked for $IP\"}"
else
    echo "{\"ok\":false,\"msg\":\"failed to unblock $IP\"}"
    exit 1
fi
