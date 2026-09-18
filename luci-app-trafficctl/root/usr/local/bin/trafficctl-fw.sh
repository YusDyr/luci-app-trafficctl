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

# Rate limits are symmetric: the same ceiling is policed in both directions.
#
# Download is caught at WAN ingress (packets arriving for the client) and
# upload at LAN ingress (packets the client sends into the router). Policing
# upload on the way IN is what makes it work for downstream/routed clients
# too — their packets still enter over a LAN device with the client's source
# address, whatever router sits behind it.
# mode: "each" gives every address inside the target its own bucket (an nft
# meter keyed by address); "shared" makes the whole target share one bucket.
# For a single host the two are identical.
tctl_ratelimit_add() {
    local ip="$1" rate_kbit="$2" comment="$3" mode="${4:-shared}"
    local rate_kbyte=$((rate_kbit / 8))
    [ "$rate_kbyte" -lt 1 ] && rate_kbyte=1

    local slug dl_expr ul_expr
    slug=$(tctl_target_slug "$ip")
    if [ "$mode" = "each" ]; then
        dl_expr="ip daddr $ip meter tctl_d_$slug { ip daddr limit rate over ${rate_kbyte} kbytes/second }"
        ul_expr="ip saddr $ip meter tctl_u_$slug { ip saddr limit rate over ${rate_kbyte} kbytes/second }"
    else
        dl_expr="ip daddr $ip limit rate over ${rate_kbyte} kbytes/second"
        ul_expr="ip saddr $ip limit rate over ${rate_kbyte} kbytes/second"
    fi

    if [ "$TCTL_FW" = "nft" ]; then
        nft add table netdev tm_ratelimit 2>/dev/null

        # Download is policed at LAN EGRESS, not WAN ingress.
        #
        # With masquerading on, a reply arriving at WAN ingress is still
        # addressed to the router's own WAN address: conntrack only restores
        # the client's address in prerouting, which runs after the netdev
        # ingress hook. So "ip daddr <client>" there matches nothing for any
        # NATed client. At LAN egress the translation has happened and the
        # destination is the real client address.
        # Note the asymmetry with the upload hooks: ingress must bind the
        # bridge PORTS (a bridge sees nothing on ingress), while egress must
        # bind the BRIDGE itself — routed traffic is transmitted to br-lan by
        # the IP stack, and the port-level egress hook never fires for it.
        # Verified on kernel 6.12: br-lan egress counted every packet, the
        # ports counted none.
        local dev chain dl_ok=0 wan_dev
        for dev in $(tctl_get_lan_devices); do
            chain=$(tctl_egress_chain "$dev")
            nft add chain netdev tm_ratelimit "$chain" \
                "{ type filter hook egress device $dev priority 0; policy accept; }" 2>/dev/null
            nft add rule netdev tm_ratelimit "$chain" \
                "$dl_expr counter drop comment \"$comment\"" 2>/dev/null \
                && dl_ok=1
        done
        # Kernels older than 5.16 have no netdev egress hook; fall back to WAN
        # ingress, which is correct as long as the client isn't masqueraded.
        if [ "$dl_ok" = "0" ] && wan_dev=$(tctl_get_wan_device); then
            nft add chain netdev tm_ratelimit dl \
                "{ type filter hook ingress device $wan_dev priority -200; policy accept; }" 2>/dev/null
            nft add rule netdev tm_ratelimit dl \
                "$dl_expr counter drop comment \"$comment\"" 2>/dev/null \
                && dl_ok=1
        fi
        # Set for the caller to inspect (see trafficctl-ratelimit.sh).
        # shellcheck disable=SC2034
        [ "$dl_ok" = "1" ] || TCTL_RL_DOWNLOAD_FAILED=1

        # One chain per ingress device: a device that refuses the hook then
        # only loses its own chain instead of taking the whole set with it.
        local dev chain
        local ul_ok=0
        for dev in $(tctl_ingress_devices); do
            chain=$(tctl_ingress_chain "$dev")
            nft add chain netdev tm_ratelimit "$chain" \
                "{ type filter hook ingress device $dev priority -200; policy accept; }" 2>/dev/null
            nft add rule netdev tm_ratelimit "$chain" \
                "$ul_expr counter drop comment \"${comment}_ul\"" 2>/dev/null \
                && ul_ok=1
        done
        # shellcheck disable=SC2034
        [ "$ul_ok" = "1" ] || TCTL_RL_UPLOAD_FAILED=1
    else
        iptables -t mangle -A FORWARD -d "$ip" -m hashlimit \
            --hashlimit-above "${rate_kbit}kbit/sec" --hashlimit-burst "${rate_kbit}kbit" \
            --hashlimit-mode dstip --hashlimit-name "rl_${comment}" \
            -j DROP -m comment --comment "$comment" 2>/dev/null
        iptables -t mangle -A FORWARD -s "$ip" -m hashlimit \
            --hashlimit-above "${rate_kbit}kbit/sec" --hashlimit-burst "${rate_kbit}kbit" \
            --hashlimit-mode srcip --hashlimit-name "rl_${comment}_ul" \
            -j DROP -m comment --comment "${comment}_ul" 2>/dev/null
    fi
}

tctl_ratelimit_remove() {
    local ip="$1" comment="$2"
    local chain h

    if [ "$TCTL_FW" = "nft" ]; then
        # Scan the whole table once: rules for this IP live in dl (daddr) and
        # in one ul_<dev> chain per ingress device (saddr).
        nft -a list table netdev tm_ratelimit 2>/dev/null | awk -v cmt="$comment" '
            /^[ \t]*chain [a-zA-Z0-9_]+ \{/ { chain = $2; next }
            index($0, "\"" cmt "\"") || index($0, "\"" cmt "_ul\"") {
                for (i = 1; i < NF; i++)
                    if ($i == "handle") { print chain, $(i+1); break }
            }' | while read -r chain h; do
            [ -n "$chain" ] && [ -n "$h" ] && nft delete rule netdev tm_ratelimit "$chain" handle "$h" 2>/dev/null
        done
    else
        while iptables -t mangle -D FORWARD -d "$ip" -m comment --comment "$comment" 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -s "$ip" -m comment --comment "${comment}_ul" 2>/dev/null; do :; done
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
        # Match the quoted comment in full: comments end in the address, so a
        # substring match on 192.168.1.1 also deletes the rule for 192.168.1.10.
        for h in $(nft -a list chain inet fw4 forward 2>/dev/null \
                   | awk -v cmt="$comment" 'index($0, "\"" cmt "\"") {
                          for (i = 1; i < NF; i++)
                              if ($i == "handle") { print $(i+1); break }
                      }'); do
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
        # The source renders as its own column, "ip" or "ip/32"; an unanchored
        # match would report 192.168.1.10's rule as belonging to 192.168.1.1.
        iptables -L FORWARD -n 2>/dev/null | awk -v ip="$ip" '
            $1 == "DROP" {
                src = $4
                sub(/\/32$/, "", src)
                if (src == ip) { found = 1; exit }
            }
            END { exit(found ? 0 : 1) }'
    fi
}

# ── Helpers ────────────────────────────────────────────────────────────────

# Resolve the WAN device to a name that actually exists as a netdev.
#
# The old fallback returned the literal string "wan", which is an interface
# NAME, not a device — nft then rejected the chain ("device wan" doesn't
# exist), the failure was swallowed, and download limiting silently did
# nothing while still reporting success. Every candidate is now verified
# against sysfs, with the default route as a last resort.
tctl_get_wan_device() {
    local sysfs="${TCTL_SYSFS_NET:-/sys/class/net}"
    local dev candidates

    candidates="$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null)
$(uci -q get network.wan.device 2>/dev/null)
$(uci -q get network.wan.ifname 2>/dev/null)
$(ip route show default 2>/dev/null | awk '/^default/{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit }}')"

    for dev in $candidates; do
        [ -n "$dev" ] || continue
        # A bridge/device name from uci can still be a config-only alias.
        [ -e "$sysfs/$dev" ] || continue
        echo "$dev"
        return 0
    done
    return 1
}

tctl_get_lan_device() {
    local dev
    dev=$(uci -q get network.lan.device 2>/dev/null)
    [ -z "$dev" ] && dev=$(uci -q get network.lan.ifname 2>/dev/null)
    [ -z "$dev" ] && dev="br-lan"
    echo "$dev"
}

# Enumerate all LAN-side IPv4 subnets, one per L3 interface.
#
# "LAN" = firewall zones that are NOT internet-facing. A zone is treated as LAN
# if it is named "lan", or if it is neither a wan zone nor masqueraded. This
# deliberately excludes VPN/tunnel zones (e.g. WireGuard/AmneziaWG awg*, which
# carry their own IPv4 and would otherwise be mistaken for LANs) because those
# are masqueraded out. Covers bridges (br-lan), bridge-VLANs and plain VLAN
# interfaces (eth0.20) uniformly via each interface's l3_device.
#
# Output: one line per subnet, "l3_device netbase_int block_size router_int"
# where membership can be tested without awk bit-ops:
#   ip in subnet  <=>  ipint - (ipint % block) == netbase
tctl_lan_subnets() {
    local i=0 zname zmasq nets net st l3 addr mask
    local o1 o2 o3 o4 ipint block netbase
    while zname=$(uci -q get "firewall.@zone[$i].name" 2>/dev/null); [ -n "$zname" ]; do
        zmasq=$(uci -q get "firewall.@zone[$i].masq" 2>/dev/null)
        nets=$(uci -q get "firewall.@zone[$i].network" 2>/dev/null)
        i=$((i + 1))
        case "$zname" in wan|wan6) continue ;; esac
        [ "$zname" != "lan" ] && [ "$zmasq" = "1" ] && continue
        for net in $nets; do
            st=$(ubus call "network.interface.$net" status 2>/dev/null)
            l3=$(echo "$st" | jsonfilter -e '@.l3_device' 2>/dev/null)
            addr=$(echo "$st" | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
            mask=$(echo "$st" | jsonfilter -e '@["ipv4-address"][0].mask' 2>/dev/null)
            [ -n "$l3" ] && [ -n "$addr" ] && [ -n "$mask" ] || continue
            [ "$mask" -ge 1 ] && [ "$mask" -le 32 ] 2>/dev/null || continue
            o1=${addr%%.*}; rest=${addr#*.}
            o2=${rest%%.*}; rest=${rest#*.}
            o3=${rest%%.*}; o4=${rest##*.}
            ipint=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
            block=$(( 1 << (32 - mask) ))
            netbase=$(( ipint - (ipint % block) ))
            echo "$l3 $netbase $block $ipint"
        done
    done
}

# Concrete devices to attach netdev ingress hooks to.
#
# A netdev ingress hook bound to a BRIDGE never sees bridged traffic: packets
# are received on the bridge's physical ports, so the hook must live there.
# Binding to br-lan silently matches nothing, which is exactly how upload
# limiting appeared to be applied while having no effect. Non-bridge L3
# devices (plain ports, VLAN interfaces) are hooked directly.
tctl_ingress_devices() {
    local sysfs="${TCTL_SYSFS_NET:-/sys/class/net}"
    local dev port
    for dev in $(tctl_get_lan_devices); do
        if [ -d "$sysfs/$dev/brif" ]; then
            for port in "$sysfs/$dev/brif/"*; do
                [ -e "$port" ] || continue
                basename "$port"
            done
        else
            echo "$dev"
        fi
    done | sort -u
}

# nft chain names for a device's hooks (chain names can't contain dots or
# dashes, which interface names routinely do).
tctl_ingress_chain() {
    printf 'ul_%s' "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"
}

tctl_egress_chain() {
    printf 'dl_%s' "$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"
}

# LAN L3 device names only (deduplicated), e.g. "br-lan br-guest eth0.20".
tctl_get_lan_devices() {
    tctl_lan_subnets | awk '{print $1}' | sort -u
}

# Convert "a.b.c.d/m" (or a bare host address) to "netbase_int block_size",
# normalized to the network base. Fails silently on malformed input.
tctl_cidr_spec() {
    local cidr="$1" addr mask rest o1 o2 o3 o4 ipint block
    addr=${cidr%%/*}
    mask=${cidr#*/}
    [ "$mask" = "$cidr" ] && mask=32
    tctl_validate_ip "$addr" || return 1
    case "$mask" in ''|*[!0-9]*) return 1 ;; esac
    [ "$mask" -ge 1 ] && [ "$mask" -le 32 ] || return 1
    o1=${addr%%.*}; rest=${addr#*.}
    o2=${rest%%.*}; rest=${rest#*.}
    o3=${rest%%.*}; o4=${rest##*.}
    ipint=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    block=$(( 1 << (32 - mask) ))
    echo "$(( ipint - (ipint % block) )) $block"
}

# Downstream subnets routed via a next-hop on a LAN interface — e.g. clients
# behind a second router on the LAN whose packets are forwarded (and NATed on
# WAN) through this router with their original source addresses. Also includes
# operator-defined extras from trafficctl.main.extra_subnets (space-separated
# CIDRs) for setups without an explicit kernel route.
# Output format matches tctl_lan_subnets; router_int is 0 because no local
# address lives inside a routed subnet (consumers use 0 to tell routed from
# directly connected).
tctl_routed_subnets() {
    local lan_devs dev cidr spec extras
    lan_devs=$(tctl_get_lan_devices)

    if [ -n "$lan_devs" ]; then
        ip route show 2>/dev/null | awk '
        $1 != "default" && / via / {
            dev = ""
            for (i = 1; i <= NF; i++) if ($i == "dev") dev = $(i+1)
            if (dev != "") print $1, dev
        }' | while read -r cidr dev; do
            echo "$lan_devs" | grep -qxF "$dev" || continue
            spec=$(tctl_cidr_spec "$cidr") || continue
            echo "$dev $spec 0"
        done
    fi

    extras=$(uci -q get trafficctl.main.extra_subnets 2>/dev/null)
    if [ -n "$extras" ]; then
        dev=$(tctl_get_lan_device)
        for cidr in $extras; do
            spec=$(tctl_cidr_spec "$cidr") || continue
            echo "$dev $spec 0"
        done
    fi
}

# Every subnet worth monitoring: directly connected LANs first, then routed
# and extra ones. Duplicate prefixes are dropped (first wins, keeping the
# connected entry with its real router address).
tctl_monitored_subnets() {
    { tctl_lan_subnets; tctl_routed_subnets; } | awk '!seen[$2":"$3]++'
}

# True (0) when the IP belongs to a directly connected LAN subnet; routed and
# extra subnets do not count. Used to tell on-link devices from downstream
# ones that only have an L3 presence here.
tctl_ip_in_lan() {
    local ip="$1" o1 o2 o3 o4 rest ipint
    tctl_validate_ip "$ip" || return 1
    o1=${ip%%.*}; rest=${ip#*.}
    o2=${rest%%.*}; rest=${rest#*.}
    o3=${rest%%.*}; o4=${rest##*.}
    ipint=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
    tctl_lan_subnets | awk -v si="$ipint" '
        si - (si % $3) == $2 { hit = 1; exit }
        END { exit hit ? 0 : 1 }'
}

# Accept a single host address or a CIDR block ("all" means every address).
# Echoes the normalized target, or fails.
tctl_validate_target() {
    local t="$1" addr mask
    case "$t" in
        all|any) echo "0.0.0.0/0"; return 0 ;;
    esac
    case "$t" in
        */*)
            addr=${t%%/*}
            mask=${t#*/}
            tctl_validate_ip "$addr" || return 1
            case "$mask" in ''|*[!0-9]*) return 1 ;; esac
            [ "$mask" -ge 0 ] && [ "$mask" -le 32 ] || return 1
            echo "$addr/$mask"
            ;;
        *)
            tctl_validate_ip "$t" || return 1
            echo "$t"
            ;;
    esac
}

# A target usable inside an nft set/meter name or a rule comment.
tctl_target_slug() {
    printf '%s' "$1" | tr './' '__'
}

# Rule comments identify the target, not the caller. They used to be built from
# a caller-supplied label, so a block placed from LuCI (label "block_<ip>") and
# the same block seen from the Telegram bot (label "tg") produced different
# comments — removal grepped for the wrong one, found nothing, and still
# reported success.
tctl_block_comment() {
    echo "tctl_block_$(tctl_target_slug "$1")"
}

tctl_ratelimit_comment() {
    echo "rl_ratelimit_$(tctl_target_slug "$1")"
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
# Which ACL policy a wifi-iface uses: "allow" (whitelist — only listed MACs may
# associate) or "deny" (blacklist — listed MACs are rejected). Anything else,
# including unset, means no filtering is configured yet, reported as "deny"
# because that is the mode we create on demand.
tctl_get_wifi_filter_mode() {
    local iface="$1" mode
    mode=$(uci -q get "wireless.${iface}.macfilter" 2>/dev/null)
    [ "$mode" = "allow" ] && echo "allow" || echo "deny"
}

# Block a MAC at runtime. In deny mode that means adding it to the deny ACL; in
# allow (whitelist) mode it means dropping it from the accept ACL. Either way
# the client is deauthenticated so the change takes effect immediately.
tctl_hostapd_block_mac() {
    local mac="$1" mode="$2"
    local iface
    for iface in $(tctl_get_hostapd_ifaces); do
        if [ "$mode" = "allow" ]; then
            hostapd_cli -i "$iface" accept_acl DEL_MAC "$mac" 2>/dev/null
        else
            hostapd_cli -i "$iface" deny_acl ADD_MAC "$mac" 2>/dev/null
        fi
        hostapd_cli -i "$iface" deauthenticate "$mac" 2>/dev/null
    done
}

# Unblock a MAC at runtime — the inverse of tctl_hostapd_block_mac.
tctl_hostapd_unblock_mac() {
    local mac="$1" mode="$2"
    local iface
    for iface in $(tctl_get_hostapd_ifaces); do
        if [ "$mode" = "allow" ]; then
            hostapd_cli -i "$iface" accept_acl ADD_MAC "$mac" 2>/dev/null
        else
            hostapd_cli -i "$iface" deny_acl DEL_MAC "$mac" 2>/dev/null
        fi
    done
}

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

# ── New-device ledger ─────────────────────────────────────────────────────
#
# Which MAC addresses this router has already seen. The default-limit feature
# keys off it, which makes the ledger safety-critical in one direction only:
# wrongly calling a device NEW applies an unasked-for limit, while wrongly
# calling it KNOWN merely does nothing. Every ambiguous case below therefore
# resolves to "known".
#
# It lives in /etc/trafficctl (kept across sysupgrade by keep.d) rather than
# in tmpfs. A ledger that reset on reboot would make every device on the LAN
# new again on the next lease renewal — the same mass-limiting accident, just
# reached more slowly. Flash cost is bounded by device count, not by DHCP
# traffic: an entry is appended only for a MAC that is not already listed.
TCTL_SEEN_FILE="/etc/trafficctl/seen_macs"
TCTL_SEEN_MAX=1000
TCTL_LEASES_FILE="/tmp/dhcp.leases"
TCTL_SHAPES_FILE="/etc/trafficctl/shapes.json"

tctl_seen_normalize() {
    printf '%s' "$1" | tr 'A-Z' 'a-z'
}

# Take the baseline from the devices already on the network, so switching the
# feature on does not declare the existing LAN to be new. Callers should do
# this at a moment when the network is up (i.e. from the rpcd setter, on an
# operator's action) rather than early in boot, when both sources are empty.
tctl_seen_seed() {
    [ -f "$TCTL_SEEN_FILE" ] && return 0
    mkdir -p "$(dirname "$TCTL_SEEN_FILE")" 2>/dev/null
    {
        awk '{ print $2 }' "$TCTL_LEASES_FILE" 2>/dev/null
        ip neigh show 2>/dev/null | awk '/lladdr/ { print $5 }'
    } | tr 'A-Z' 'a-z' \
      | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
      | sort -u > "${TCTL_SEEN_FILE}.tmp" 2>/dev/null
    mv "${TCTL_SEEN_FILE}.tmp" "$TCTL_SEEN_FILE" 2>/dev/null
}

tctl_seen_count() {
    [ -f "$TCTL_SEEN_FILE" ] || { echo 0; return 0; }
    wc -l < "$TCTL_SEEN_FILE" 2>/dev/null | tr -d ' ' || echo 0
}

# "Known" is the safe answer, so an unreadable MAC or a missing ledger says
# yes. Whether the ledger EXISTS is a separate question, asked by the caller
# through tctl_seen_ready before it acts on a negative.
tctl_seen_known() {
    local mac
    mac=$(tctl_seen_normalize "$1")
    [ -n "$mac" ] || return 0
    [ -f "$TCTL_SEEN_FILE" ] || return 0
    grep -qxF "$mac" "$TCTL_SEEN_FILE" 2>/dev/null
}

tctl_seen_ready() {
    [ -f "$TCTL_SEEN_FILE" ]
}

tctl_seen_mark() {
    local mac n keep
    mac=$(tctl_seen_normalize "$1")
    [ -n "$mac" ] || return 0
    # Not tctl_seen_known alone: it answers "known" for a missing ledger,
    # which here would mean never writing the first entry.
    if [ -f "$TCTL_SEEN_FILE" ] && tctl_seen_known "$mac"; then
        return 0
    fi
    mkdir -p "$(dirname "$TCTL_SEEN_FILE")" 2>/dev/null
    printf '%s\n' "$mac" >> "$TCTL_SEEN_FILE"

    # Trim from the head when the ledger outgrows the cap. A device dropped
    # this way can be seen as new again later; the cap sits far above any
    # plausible LAN, so that is a theoretical cost against an unbounded file.
    n=$(tctl_seen_count)
    if [ "$n" -gt "$TCTL_SEEN_MAX" ]; then
        keep=$((TCTL_SEEN_MAX * 4 / 5))
        tail -n "$keep" "$TCTL_SEEN_FILE" > "${TCTL_SEEN_FILE}.tmp" 2>/dev/null &&
            mv "${TCTL_SEEN_FILE}.tmp" "$TCTL_SEEN_FILE"
    fi
}

# Does this address already carry a limit somebody set deliberately?
#
# Live nft/tc state alone is not a sufficient answer. After a reboot the
# restore hook runs on `ifup lan` and only when persist_rules is on, so a
# device with a manual limit reads as unlimited until then — and a default
# limit applied in that window would silently overwrite the operator's
# choice. The persisted files are consulted as well.
tctl_has_limit() {
    local ip="$1"
    [ -n "$ip" ] || return 1

    /usr/local/bin/trafficctl-ratelimit-stats.sh 2>/dev/null \
        | grep -qF "\"ip\":\"$ip\"" && return 0
    /usr/local/bin/trafficctl-shape-stats.sh 2>/dev/null \
        | grep -qF "\"ip\":\"$ip\"" && return 0

    if [ -f "$TCTL_RULES_FILE" ]; then
        grep -qF "\"ip\":\"$ip\"" "$TCTL_RULES_FILE" 2>/dev/null && return 0
    fi
    if [ -f "$TCTL_SHAPES_FILE" ]; then
        grep -qF "\"ip\":\"$ip\"" "$TCTL_SHAPES_FILE" 2>/dev/null && return 0
    fi
    return 1
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

TCTL_LOG_DEFAULT="/tmp/trafficctl/activity.log"

# The log path is writable through the LuCI write ACL and is used both as an
# append target and as a tail/rewrite target, so an unconstrained value is an
# arbitrary root read and truncate. Only dedicated log locations are accepted.
tctl_validate_log_file() {
    local f="$1"
    case "$f" in
        /tmp/trafficctl/*|/var/log/*) ;;
        *) return 1 ;;
    esac
    case "$f" in
        */../*|*/..|*/) return 1 ;;
    esac
    # Path characters are restricted rather than blacklisted so no shell or glob
    # metacharacter can reach the redirect, tail or mv below.
    case "$f" in
        *[!A-Za-z0-9._/-]*) return 1 ;;
    esac
    return 0
}

tctl_log_file() {
    local f
    f=$(uci -q get trafficctl.logging.log_file 2>/dev/null)
    if [ -n "$f" ] && tctl_validate_log_file "$f"; then
        echo "$f"
    else
        echo "$TCTL_LOG_DEFAULT"
    fi
}

# Rotation keeps 3/5 of the cap, so a cap below 5 would round to zero lines and
# empty the file on the next write.
tctl_log_max_lines() {
    local n
    n=$(uci -q get trafficctl.logging.max_lines 2>/dev/null)
    case "$n" in
        ''|*[!0-9]*) echo 500; return 0 ;;
    esac
    [ "$n" -ge 20 ] 2>/dev/null || { echo 20; return 0; }
    [ "$n" -le 100000 ] 2>/dev/null || { echo 100000; return 0; }
    echo "$n"
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
    log_file=$(tctl_log_file)
    max_lines=$(tctl_log_max_lines)

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
        # A counter-flagged flowtable syncs offloaded byte counts back to
        # conntrack, so conntrack accounting stays valid — worth
        # distinguishing, because the nft-map fallback needs dynamic counter
        # maps that many kernels don't support.
        if nft list flowtables 2>/dev/null | grep -q "counter"; then
            echo "software-counter"
        else
            echo "software"
        fi
    else
        echo "none"
    fi
}
