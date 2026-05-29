#!/bin/sh
# shellcheck shell=dash
# Firewall abstraction layer for trafficctl.
# Detects nft vs iptables and provides unified functions.
# Source this file: . /usr/local/bin/trafficctl-fw.sh

if command -v nft >/dev/null 2>&1 && nft list tables 2>/dev/null | grep -q .; then
    TCTL_FW="nft"
else
    TCTL_FW="iptables"
fi

# ── Rate Limiting (policer) ────────────────────────────────────────────────

tctl_ratelimit_add() {
    local ip="$1" rate_kbit="$2" comment="$3"
    local rate_kbyte=$((rate_kbit / 8))
    [ "$rate_kbyte" -lt 1 ] && rate_kbyte=1

    if [ "$TCTL_FW" = "nft" ]; then
        nft add table netdev tm_ratelimit 2>/dev/null
        local wan_dev
        wan_dev=$(tctl_get_wan_device)
        nft add chain netdev tm_ratelimit dl \
            "{ type filter hook ingress device $wan_dev priority -200; policy accept; }" 2>/dev/null
        nft add rule netdev tm_ratelimit dl \
            "ip daddr $ip limit rate over ${rate_kbyte} kbytes/second counter drop comment \"$comment\""
    else
        iptables -t mangle -A FORWARD -d "$ip" -m hashlimit \
            --hashlimit-above "${rate_kbit}kbit/sec" --hashlimit-burst "${rate_kbit}kbit" \
            --hashlimit-mode dstip --hashlimit-name "rl_${comment}" \
            -j DROP -m comment --comment "$comment" 2>/dev/null
    fi
}

tctl_ratelimit_remove() {
    local ip="$1" comment="$2"

    if [ "$TCTL_FW" = "nft" ]; then
        for h in $(nft -a list chain netdev tm_ratelimit dl 2>/dev/null \
                   | grep "daddr $ip " | grep -o 'handle [0-9]*' | awk '{print $2}'); do
            nft delete rule netdev tm_ratelimit dl handle "$h"
        done
    else
        while iptables -t mangle -D FORWARD -d "$ip" -m comment --comment "$comment" 2>/dev/null; do :; done
    fi
}

tctl_ratelimit_list() {
    if [ "$TCTL_FW" = "nft" ]; then
        nft list table netdev tm_ratelimit 2>/dev/null
    else
        iptables -t mangle -L FORWARD -nv --line-numbers 2>/dev/null | grep "rl_ratelimit"
    fi
}

# ── Internet Blocking ──────────────────────────────────────────────────────

tctl_block_add() {
    local ip="$1" comment="$2"

    if [ "$TCTL_FW" = "nft" ]; then
        nft insert rule inet fw4 forward "ip saddr $ip counter drop comment \"$comment\""
    else
        iptables -I FORWARD -s "$ip" -j DROP -m comment --comment "$comment"
    fi
}

tctl_block_remove() {
    local ip="$1" comment="$2"

    if [ "$TCTL_FW" = "nft" ]; then
        for h in $(nft -a list chain inet fw4 forward 2>/dev/null \
                   | grep "$comment" | grep -o 'handle [0-9]*' | awk '{print $2}'); do
            nft delete rule inet fw4 forward handle "$h"
        done
    else
        while iptables -D FORWARD -s "$ip" -m comment --comment "$comment" -j DROP 2>/dev/null; do :; done
    fi
}

tctl_is_blocked() {
    local ip="$1"
    if [ "$TCTL_FW" = "nft" ]; then
        nft list chain inet fw4 forward 2>/dev/null | grep -q "ip saddr $ip .*drop"
    else
        iptables -L FORWARD -n 2>/dev/null | grep -q "DROP.*$ip"
    fi
}

# ── Helpers ────────────────────────────────────────────────────────────────

tctl_get_wan_device() {
    # Detect WAN interface device name
    local dev
    dev=$(uci -q get network.wan.device 2>/dev/null)
    [ -z "$dev" ] && dev=$(uci -q get network.wan.ifname 2>/dev/null)
    [ -z "$dev" ] && dev="wan"
    echo "$dev"
}

tctl_get_lan_device() {
    local dev
    dev=$(uci -q get network.lan.device 2>/dev/null)
    [ -z "$dev" ] && dev=$(uci -q get network.lan.ifname 2>/dev/null)
    [ -z "$dev" ] && dev="br-lan"
    echo "$dev"
}

tctl_validate_ip() {
    echo "$1" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || return 1
    local IFS='.'
    # shellcheck disable=SC2086
    set -- $1
    [ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ] 2>/dev/null
}

tctl_get_wifi_interfaces() {
    uci show wireless 2>/dev/null | grep '=wifi-iface' | cut -d. -f2 | cut -d= -f1
}

# Get running WiFi interface names (e.g. wlan0, wlan1)
tctl_get_hostapd_ifaces() {
    ubus list 2>/dev/null | grep '^hostapd\.' | cut -d. -f2
}

# Add MAC to hostapd deny ACL at runtime + deauth the client (no wifi reload)
tctl_hostapd_deny_mac() {
    local mac="$1"
    local iface
    for iface in $(tctl_get_hostapd_ifaces); do
        hostapd_cli -i "$iface" deny_acl ADD_MAC "$mac" 2>/dev/null
        hostapd_cli -i "$iface" deauthenticate "$mac" 2>/dev/null
    done
}

# Remove MAC from hostapd deny ACL at runtime (client can reassociate immediately)
tctl_hostapd_allow_mac() {
    local mac="$1"
    local iface
    for iface in $(tctl_get_hostapd_ifaces); do
        hostapd_cli -i "$iface" deny_acl DEL_MAC "$mac" 2>/dev/null
    done
}

# ── Persistence ───────────────────────────────────────────────────────────

TCTL_RULES_FILE="/etc/trafficctl/rules.json"

tctl_persist_enabled() {
    [ "$(uci -q get trafficctl.main.persist_rules 2>/dev/null)" = "1" ]
}

tctl_persist_save() {
    local type="$1" ip="$2" param="$3"
    [ -d "$(dirname "$TCTL_RULES_FILE")" ] || mkdir -p "$(dirname "$TCTL_RULES_FILE")"
    [ -f "$TCTL_RULES_FILE" ] || echo '[]' > "$TCTL_RULES_FILE"
    local tmp="${TCTL_RULES_FILE}.tmp"
    # Remove existing entry for same ip+type, append new one
    awk -v ip="$ip" -v t="$type" -v p="$param" '
    {
        gsub(/^\[/,""); gsub(/\]$/,"")
        n=split($0, items, "},{")
        printf "["
        first=1
        for (i=1; i<=n; i++) {
            sub(/^\{/,"",items[i]); sub(/\}$/,"",items[i])
            if (items[i] ~ "\"ip\":\"" ip "\"" && items[i] ~ "\"type\":\"" t "\"") continue
            if (!first) printf ","
            printf "{%s}", items[i]
            first=0
        }
        if (!first) printf ","
        printf "{\"type\":\"%s\",\"ip\":\"%s\",\"param\":\"%s\"}]", t, ip, p
    }' "$TCTL_RULES_FILE" > "$tmp"
    mv "$tmp" "$TCTL_RULES_FILE"
}

tctl_persist_remove() {
    local type="$1" ip="$2"
    [ -f "$TCTL_RULES_FILE" ] || return 0
    local tmp="${TCTL_RULES_FILE}.tmp"
    awk -v ip="$ip" -v t="$type" '
    {
        gsub(/^\[/,""); gsub(/\]$/,"")
        n=split($0, items, "},{")
        printf "["
        first=1
        for (i=1; i<=n; i++) {
            sub(/^\{/,"",items[i]); sub(/\}$/,"",items[i])
            if (items[i] ~ "\"ip\":\"" ip "\"" && items[i] ~ "\"type\":\"" t "\"") continue
            if (!first) printf ","
            printf "{%s}", items[i]
            first=0
        }
        printf "]"
    }' "$TCTL_RULES_FILE" > "$tmp"
    mv "$tmp" "$TCTL_RULES_FILE"
}

# ── Activity Logging ──────────────────────────────────────────────────────

TCTL_LOG_TAG="trafficctl"

tctl_log_enabled() {
    [ "$(uci -q get trafficctl.logging.enabled 2>/dev/null)" = "1" ]
}

tctl_log_category_enabled() {
    local cat="$1"
    [ "$(uci -q get "trafficctl.logging.log_${cat}" 2>/dev/null)" != "0" ]
}

tctl_log() {
    local action="$1" target="$2" detail="$3" via="${4:-cli}" src="${5:-local}"
    tctl_log_enabled || return 0

    local category
    case "$action" in
        block|unblock) category="blocks" ;;
        ratelimit*) category="ratelimits" ;;
        shape*) category="shapes" ;;
        telegram*) category="telegram" ;;
        config*) category="config" ;;
        *) category="config" ;;
    esac
    tctl_log_category_enabled "$category" || return 0

    local ts user log_file max_lines
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    user="${TCTL_USER:-$(id -un 2>/dev/null || echo unknown)}"
    log_file=$(uci -q get trafficctl.logging.log_file 2>/dev/null)
    log_file="${log_file:-/tmp/trafficctl/activity.log}"
    max_lines=$(uci -q get trafficctl.logging.max_lines 2>/dev/null)
    max_lines="${max_lines:-500}"

    local entry="[$TCTL_LOG_TAG] $ts src=$src user=$user via=$via action=$action target=$target${detail:+ detail=$detail}"

    [ -d "$(dirname "$log_file")" ] || mkdir -p "$(dirname "$log_file")"
    echo "$entry" >> "$log_file"

    # Rotate if over max_lines
    local lc
    lc=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    if [ "$lc" -gt "$max_lines" ]; then
        local keep=$(( max_lines * 3 / 5 ))
        tail -n "$keep" "$log_file" > "${log_file}.tmp"
        mv "${log_file}.tmp" "$log_file"
    fi

    # Duplicate to syslog if configured
    if [ "$(uci -q get trafficctl.logging.syslog 2>/dev/null)" = "1" ]; then
        logger -t "$TCTL_LOG_TAG" "$ts src=$src user=$user via=$via action=$action target=$target${detail:+ detail=$detail}"
    fi
}

# ── Flow Offload Detection ─────────────────────────────────────────────────

tctl_get_offload_mode() {
    local sw hw
    sw=$(uci -q get firewall.@defaults[0].flow_offloading 2>/dev/null)
    hw=$(uci -q get firewall.@defaults[0].flow_offloading_hw 2>/dev/null)
    if [ "$hw" = "1" ]; then
        # kernel 5.7+ supports counter sync on flowtables (docs.kernel.org/networking/nf_flowtable.html).
        # OpenWrt 22.03+ fw4 sets the counter flag by default, syncing hardware
        # byte counts back to conntrack — monitoring works.
        if nft list flowtables 2>/dev/null | grep -q "counter"; then
            echo "hardware-counter"
        else
            echo "hardware"
        fi
    elif [ "$sw" = "1" ]; then
        echo "software"
    else
        echo "none"
    fi
}
