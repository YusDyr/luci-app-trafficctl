#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=dash
# Rate-limit bandwidth in both directions (policer).
#
# Usage: trafficctl-ratelimit.sh <target> <rate_kbit> [label] [mode] [rate_up]
#   target   a host (10.0.20.122), a CIDR (10.0.20.0/24), or "all"
#   mode     each   — every address in the target gets its own bucket (default
#                     for CIDR/all, so "5 Mbit each" means per device)
#            shared — the whole target shares one bucket (aggregate cap)
#   rate_up  upload ceiling in kbit/s; omitted means the same as rate_kbit,
#            which is what this did before the directions could differ
# rate_kbit=0 removes the limit.

. /usr/libexec/trafficctl/trafficctl-fw.sh

IP="$1"
RATE="$2"
MODE="$4"
# Fifth positional so every existing caller keeps working unchanged. Empty is
# "same as download", never zero — a zero ceiling policed every packet, which
# is a total block dressed up as a limit.
RATE_UP="$5"
[ -z "$RATE_UP" ] && RATE_UP="$RATE"

if [ -z "$IP" ] || [ -z "$RATE" ]; then
    echo '{"ok":false,"msg":"usage: trafficctl-ratelimit.sh <target> <rate_kbit> [label] [each|shared]"}'
    exit 1
fi

# Validated here and not at the callers: rpcd, the bot and the CLI all land here.
if [ "$RATE" != "0" ] && ! tctl_validate_rate "$RATE"; then
    echo "{\"ok\":false,\"msg\":\"invalid rate: expected whole kbit/s, 1 to $TCTL_RATE_MAX_KBIT\"}"
    exit 1
fi
if [ "$RATE" != "0" ] && ! tctl_validate_rate "$RATE_UP"; then
    echo "{\"ok\":false,\"msg\":\"invalid upload rate: expected whole kbit/s, 1 to $TCTL_RATE_MAX_KBIT\"}"
    exit 1
fi

TARGET=$(tctl_validate_target "$IP") || {
    echo '{"ok":false,"msg":"invalid target — expected an IP, a CIDR, or \"all\""}'
    exit 1
}
IP="$TARGET"

if [ -z "$MODE" ]; then
    MODE=$(tctl_ratelimit_default_mode "$IP")
fi
case "$MODE" in
    each|shared) ;;
    *) echo '{"ok":false,"msg":"mode must be each or shared"}'; exit 1 ;;
esac

LABEL="${3:-rl_$(tctl_target_slug "$IP")}"
COMMENT=$(tctl_ratelimit_comment "$IP")

if [ "$RATE" = "0" ]; then
    # Limits written before comments were derived from the target carry the
    # caller's label, so one set from LuCI could not be removed from Telegram.
    tctl_ratelimit_remove "$IP" "rl_ratelimit_${LABEL}" 2>/dev/null
    if tctl_ratelimit_remove "$IP" "$COMMENT"; then
        tctl_persist_enabled && tctl_persist_remove "ratelimit" "$IP"
        tctl_log "ratelimit_remove" "$IP" "" "${TCTL_VIA:-cli}" "${TCTL_SRC:-local}"
        echo "{\"ok\":true,\"msg\":\"rate limit removed for $IP\"}"
    else
        echo "{\"ok\":false,\"msg\":\"failed to remove rate limit for $IP\"}"
        exit 1
    fi
else
    # How the applied ceiling is spelled out. Naming one number when the
    # operator gave two would hide exactly the thing they asked for.
    rate_text() {
        if [ "$RATE_UP" != "$RATE" ]; then
            echo "${RATE} kbit/s down, ${RATE_UP} kbit/s up"
        else
            echo "${RATE} kbit/s"
        fi
    }
    tctl_ratelimit_remove "$IP" "$COMMENT" 2>/dev/null
    TCTL_RL_DOWNLOAD_FAILED=0
    TCTL_RL_UPLOAD_FAILED=0
    TCTL_RL_UPLOAD6_OK=0
    TCTL_RL_DOWNLOAD6_OK=0
    TCTL_RL_NETDEV_FAILED=0
    TCTL_RL_DOWNLOAD_ERR=""
    TCTL_RL_UPLOAD_ERR=""
    tctl_ratelimit_add "$IP" "$RATE" "$COMMENT" "$MODE" "$RATE_UP"
    if [ "$TCTL_RL_NETDEV_FAILED" = "1" ]; then
        echo "{\"ok\":false,\"msg\":\"failed to set rate limit for $IP: cannot create the nftables netdev table (is kmod-nft-netdev installed?)\"}"
        exit 1
    fi

    # IPv6 coverage depends on whether the target has a MAC to key on, and
    # each half can fail to load on its own. The operator has to know which
    # part is live: claiming "both directions" without this note is how issue
    # #67 stayed invisible.
    if [ "$TCTL_RL_UPLOAD6_OK" = "1" ] && [ "$TCTL_RL_DOWNLOAD6_OK" = "1" ]; then
        V6NOTE=" [IPv6: both directions]"
    elif [ "$TCTL_RL_UPLOAD6_OK" = "1" ]; then
        V6NOTE=" [IPv6: upload only]"
    elif [ "$TCTL_RL_DOWNLOAD6_OK" = "1" ]; then
        V6NOTE=" [IPv6: download only]"
    else
        V6NOTE=" [IPv4 only]"
    fi
    V6UP=$([ "$TCTL_RL_UPLOAD6_OK" = "1" ] && echo true || echo false)
    V6DN=$([ "$TCTL_RL_DOWNLOAD6_OK" = "1" ] && echo true || echo false)

    # A half-applied limit is a silent trap: report exactly which direction
    # is live rather than claiming success for both.
    if [ "$TCTL_RL_DOWNLOAD_FAILED" = "1" ] && [ "$TCTL_RL_UPLOAD_FAILED" = "1" ]; then
        why="no usable WAN or LAN ingress device"
        if [ -n "$TCTL_RL_DOWNLOAD_ERR$TCTL_RL_UPLOAD_ERR" ]; then
            why="${TCTL_RL_DOWNLOAD_ERR:-no usable WAN device}; ${TCTL_RL_UPLOAD_ERR:-no LAN ingress device}"
        fi
        echo "{\"ok\":false,\"msg\":\"failed to set rate limit for $IP ($why)\"}"
        exit 1
    fi
    # The mode is persisted with the rate. Without it the restore hook fell back
    # to tctl_ratelimit_add's own default ("shared"), so a subnet limited
    # "5 Mbit each" came back after a reboot as 5 Mbit for the entire subnet.
    # The upload rate is persisted alongside, and only when it differs — a
    # symmetric limit keeps producing exactly the record it always did.
    tctl_persist_enabled && tctl_persist_save "ratelimit" "$IP" "$RATE" "$MODE" \
        "$([ "$RATE_UP" != "$RATE" ] && echo "$RATE_UP")"
    tctl_log "ratelimit_set" "$IP" "$(rate_text)" "${TCTL_VIA:-cli}" "${TCTL_SRC:-local}"
    # An already-accelerated flow is not re-evaluated against a rule that
    # appeared afterwards, exactly as with flow offload — so the NSS flow
    # table gets the same treatment the conntrack table does.
    tctl_nss_defunct
    # On a Qualcomm NSS router the rules above are installed and inert: the
    # packets never reach the Linux stack. Reporting an unqualified success
    # there is the defect in #81, so every message below carries the verdict
    # and the result carries the status as a field.
    NSSNOTE="$(tctl_nss_note)$(tctl_persist_note)"
    NSS="$(tctl_nss_status)"
    PERSIST=$(tctl_persist_enabled && echo true || echo false)
    # A direction can also be live on some devices and not on others (a port
    # that refused the rule). Those rules stay in, so the limit is ok, but
    # the devices it misses and nft's reason are part of the message, and
    # "partial" says so for a caller that reads fields rather than text.
    PARTIAL=false
    PNOTE=""
    if [ -n "$TCTL_RL_DOWNLOAD_ERR$TCTL_RL_UPLOAD_ERR" ]; then
        PARTIAL=true
        PNOTE=" — PARTIAL: ${TCTL_RL_DOWNLOAD_ERR}${TCTL_RL_DOWNLOAD_ERR:+${TCTL_RL_UPLOAD_ERR:+; }}${TCTL_RL_UPLOAD_ERR}"
    fi
    # The IPv6 flags and note are what tctl_ratelimit_add found loaded, in
    # every branch: a v6 rule that is in the kernel is reported as live.
    FIELDS="\"ok\":true,\"partial\":$PARTIAL,\"ipv6_upload\":$V6UP,\"ipv6_download\":$V6DN,\"nss\":\"$NSS\",\"persist\":$PERSIST"
    if [ "$TCTL_RL_DOWNLOAD_FAILED" = "1" ]; then
        echo "{$FIELDS,\"msg\":\"rate limit ${RATE_UP} kbit/s applied to $IP UPLOAD ONLY — ${TCTL_RL_DOWNLOAD_ERR:-WAN device not resolvable}${TCTL_RL_UPLOAD_ERR:+; $TCTL_RL_UPLOAD_ERR}$V6NOTE$NSSNOTE\"}"
    elif [ "$TCTL_RL_UPLOAD_FAILED" = "1" ]; then
        echo "{$FIELDS,\"msg\":\"rate limit ${RATE} kbit/s applied to $IP DOWNLOAD ONLY — ${TCTL_RL_UPLOAD_ERR:-no LAN ingress device}${TCTL_RL_DOWNLOAD_ERR:+; $TCTL_RL_DOWNLOAD_ERR}$V6NOTE$NSSNOTE\"}"
    else
        echo "{$FIELDS,\"msg\":\"rate limit $(rate_text) for $IP (both directions, $MODE)$PNOTE$V6NOTE$NSSNOTE\"}"
    fi
fi
