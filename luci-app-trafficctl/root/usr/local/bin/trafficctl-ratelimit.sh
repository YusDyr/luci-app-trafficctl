#!/bin/sh
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

. /usr/local/bin/trafficctl-fw.sh

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
    tctl_ratelimit_add "$IP" "$RATE" "$COMMENT" "$MODE" "$RATE_UP"

    # IPv6 coverage is partial by construction and the operator has to know
    # which part: upload is policed on the MAC, download is not policed at all
    # over v6 (see tctl_ratelimit_add). Claiming "both directions" without
    # this note is how issue #67 stayed invisible.
    if [ "$TCTL_RL_UPLOAD6_OK" = "1" ]; then
        V6NOTE=" [IPv6: upload only]"
    else
        V6NOTE=" [IPv4 only]"
    fi

    # A half-applied limit is a silent trap: report exactly which direction
    # is live rather than claiming success for both.
    if [ "$TCTL_RL_DOWNLOAD_FAILED" = "1" ] && [ "$TCTL_RL_UPLOAD_FAILED" = "1" ]; then
        echo "{\"ok\":false,\"msg\":\"failed to set rate limit for $IP (no usable WAN or LAN ingress device)\"}"
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
    if [ "$TCTL_RL_DOWNLOAD_FAILED" = "1" ]; then
        echo "{\"ok\":true,\"ipv6_upload\":$([ "$TCTL_RL_UPLOAD6_OK" = "1" ] && echo true || echo false),\"msg\":\"rate limit ${RATE_UP} kbit/s applied to $IP UPLOAD ONLY — WAN device not resolvable$V6NOTE\"}"
    elif [ "$TCTL_RL_UPLOAD_FAILED" = "1" ]; then
        echo "{\"ok\":true,\"ipv6_upload\":false,\"msg\":\"rate limit ${RATE} kbit/s applied to $IP DOWNLOAD ONLY — no LAN ingress device [IPv4 only]\"}"
    else
        echo "{\"ok\":true,\"ipv6_upload\":$([ "$TCTL_RL_UPLOAD6_OK" = "1" ] && echo true || echo false),\"msg\":\"rate limit $(rate_text) for $IP (both directions, $MODE)$V6NOTE\"}"
    fi
fi
