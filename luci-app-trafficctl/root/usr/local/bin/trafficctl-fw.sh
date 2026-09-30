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

# ── MAC-keyed matching (address-family independent) ────────────────────────
#
# Everything in this package is keyed on the IPv4 address a DHCP lease gives a
# device, and every enforcement rule matches "ip saddr"/"ip daddr" — so IPv6
# walks past all of it (issue #67: 9.96 Mbit/s over v4 against a 10 Mbit/s cap,
# 151 Mbit/s over v6 to the same endpoint).
#
# The fix is NOT "add ip6 saddr next to ip saddr": with SLAAC and privacy
# extensions a client holds several v6 addresses at once and rotates them on a
# timer, so a rule written against one stops matching without warning — the
# same silent bypass, reached more slowly. The MAC does not rotate, and on the
# hooks used here the client's own frame is still intact, so it is what the v6
# rules are keyed on.
#
# Only the directions where that holds are covered; see tctl_block_add and
# tctl_ratelimit_add for which, and README/COMPATIBILITY for what is not.

# Named by absolute path, as it must be on the router; the tests sed this line
# into their scratch directory rather than have the shipped script carry a
# test-only override (same approach as the ledger and shapes paths below).
TCTL_LEASES_FILE="/tmp/dhcp.leases"

# The MAC behind an IPv4 address: DHCP lease first, neighbour table second.
# Fails (non-zero, no output) when neither knows it — a routed/downstream
# client has no lease and no neighbour entry here, and there is nothing to key
# a rule on. Callers must report that rather than assume coverage.
#
# The result is validated strictly, not merely trimmed: it is interpolated
# into an nft rule string, so anything but six hex pairs is refused.
tctl_lookup_mac() {
    local addr="$1" mac
    tctl_validate_ip "$addr" || return 1
    mac=$(awk -v ip="$addr" '$3 == ip { print $2; exit }' "$TCTL_LEASES_FILE" 2>/dev/null)
    [ -z "$mac" ] && mac=$(ip neigh show 2>/dev/null | awk -v ip="$addr" '
        $1 == ip { for (i = 1; i < NF; i++) if ($i == "lladdr") { print $(i+1); exit } }')
    mac=$(printf '%s' "$mac" | tr 'A-F' 'a-f')
    case "$mac" in
        [0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]) ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$mac"
}

# True when this address is the next hop of a route, i.e. a router rather than
# an end device. Its MAC is the source of every packet it FORWARDS, so a
# MAC-keyed rule aimed at it would also hit every client behind it — blocking
# one device would black-hole a whole subnet. Those addresses are excluded and
# the caller says so out loud.
tctl_ip_is_nexthop() {
    local addr="$1"
    [ -n "$addr" ] || return 1
    ip route show 2>/dev/null | awk -v n="$addr" '
        { for (i = 1; i < NF; i++) if ($i == "via" && $(i+1) == n) { hit = 1; exit } }
        END { exit hit ? 0 : 1 }'
}

# The MAC to key a target's IPv6 rules on, or failure. A CIDR target has no
# single MAC; a next hop's MAC is not its own traffic.
tctl_target_mac() {
    local t="$1"
    case "$t" in
        */32) t=${t%/32} ;;
        */*)  return 1 ;;
    esac
    tctl_ip_is_nexthop "$t" && return 1
    tctl_lookup_mac "$t"
}

# Flush a device's live IPv6 flows.
#
# "conntrack -D -s <v4addr>" only touches the IPv4 table, so without this an
# established v6 flow survives a block that was just installed — and with flow
# offload it is never re-evaluated by the forward chain again, so it survives
# indefinitely. That is the same "a block that does not block" failure in a new
# place, on the offload-enabled hardware most likely to hit it.
#
# Addresses come from a one-shot neighbour snapshot. Reading them is sound even
# though a RULE written against them would not be: the snapshot cannot go stale
# between here and the next statement, whereas a rule has to stay correct for
# as long as the block lasts.
tctl_conntrack_flush_v6() {
    local mac="$1" addr
    [ -n "$mac" ] || return 0
    command -v conntrack >/dev/null 2>&1 || return 0
    ip -6 neigh show 2>/dev/null | awk -v m="$mac" '
        { for (i = 1; i < NF; i++) if ($i == "lladdr" && tolower($(i+1)) == m) { print $1; break } }
    ' | while read -r addr; do
        case "$addr" in
            ''|*[!0-9a-fA-F:]*) continue ;;
        esac
        conntrack -D -f ipv6 -s "$addr" >/dev/null 2>&1
        conntrack -D -f ipv6 -d "$addr" >/dev/null 2>&1
    done
    return 0
}

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
    local ip="$1" rate_kbit="$2" comment="$3" mode="${4:-shared}" rate_kbit_up="$5"
    # Empty means "same as download" — the only meaning this had before the two
    # directions could differ. Not zero: a zero ceiling policed every packet and
    # would be a silent total block reported as a successful limit.
    [ -z "$rate_kbit_up" ] && rate_kbit_up="$rate_kbit"
    local rate_kbyte=$((rate_kbit / 8))
    [ "$rate_kbyte" -lt 1 ] && rate_kbyte=1
    local rate_kbyte_up=$((rate_kbit_up / 8))
    [ "$rate_kbyte_up" -lt 1 ] && rate_kbyte_up=1

    local slug dl_expr ul_expr ul6_expr mac
    slug=$(tctl_target_slug "$ip")
    # The two directions were already separate rules on separate hooks — they
    # were symmetric only because both took the same number.
    if [ "$mode" = "each" ]; then
        dl_expr="ip daddr $ip meter tctl_d_$slug { ip daddr limit rate over ${rate_kbyte} kbytes/second }"
        ul_expr="ip saddr $ip meter tctl_u_$slug { ip saddr limit rate over ${rate_kbyte_up} kbytes/second }"
    else
        dl_expr="ip daddr $ip limit rate over ${rate_kbyte} kbytes/second"
        ul_expr="ip saddr $ip limit rate over ${rate_kbyte_up} kbytes/second"
    fi

    # Upload over IPv6, keyed on the MAC. This direction and only this one:
    # at LAN ingress the frame is still the client's own, so "ether saddr"
    # identifies it whatever address family it is using. Download over IPv6 is
    # policed at LAN egress, where the destination MAC is the next hop's — it
    # needs the device's current v6 address set and is deliberately not
    # attempted here.
    #
    # Scoped to IPv6 on purpose: IPv4 keeps being policed by exactly the rule it
    # always was, so nothing about existing behaviour depends on whether this
    # lookup succeeds — and an unscoped ether rule would police a dual-stack
    # client's v4 traffic TWICE, halving the ceiling it was given. Its own
    # bucket, too: sharing one would make the v4 and v6 halves cannibalise each
    # other's allowance, which is not what "10 Mbit/s" has ever meant here.
    #
    # The scope is "meta protocol ip6", NOT "meta nfproto ipv6" — these chains
    # are in the NETDEV family, where nft rejects nfproto outright ("meta
    # nfproto is only useful in the inet family", verified with nft --check
    # against nftables 1.1.1 / kernel 6.6). nfproto is what tctl_block_add uses,
    # because that rule lives in inet fw4. Same intent, different family, and
    # the wrong one does not silently under-match — it fails to load.
    ul6_expr=""
    if mac=$(tctl_target_mac "$ip"); then
        ul6_expr="meta protocol ip6 ether saddr $mac limit rate over ${rate_kbyte_up} kbytes/second"
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
        local ul_ok=0 ul6_ok=0
        for dev in $(tctl_ingress_devices); do
            chain=$(tctl_ingress_chain "$dev")
            nft add chain netdev tm_ratelimit "$chain" \
                "{ type filter hook ingress device $dev priority -200; policy accept; }" 2>/dev/null
            nft add rule netdev tm_ratelimit "$chain" \
                "$ul_expr counter drop comment \"${comment}_ul\"" 2>/dev/null \
                && ul_ok=1
            [ -n "$ul6_expr" ] || continue
            nft add rule netdev tm_ratelimit "$chain" \
                "$ul6_expr counter drop comment \"${comment}_ul6\"" 2>/dev/null \
                && ul6_ok=1
        done
        # shellcheck disable=SC2034
        [ "$ul_ok" = "1" ] || TCTL_RL_UPLOAD_FAILED=1
        # Set for the caller to report: "limited" means v4 only unless this is 1.
        # shellcheck disable=SC2034
        TCTL_RL_UPLOAD6_OK="$ul6_ok"
    else
        # fw3/iptables stays IPv4-only. A half-built ip6tables path would be
        # worse than a stated gap; see docs/COMPATIBILITY.md.
        # shellcheck disable=SC2034
        TCTL_RL_UPLOAD6_OK=0
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
        # Scan the whole table once: rules for this IP live in dl (daddr), in
        # one ul_<dev> chain per ingress device (saddr), and — for a host with
        # a known MAC — a second, IPv6-scoped rule in each of those (_ul6).
        #
        # Each comment is matched in FULL, closing quote included. The suffixes
        # are prefixes of one another ("_ul" of "_ul6"), and every comment ends
        # in an address slug, so a substring match would have a limit on
        # 192.168.1.1 delete 192.168.1.10's rules as well.
        nft -a list table netdev tm_ratelimit 2>/dev/null | awk -v cmt="$comment" '
            /^[ \t]*chain [a-zA-Z0-9_]+ \{/ { chain = $2; next }
            index($0, "\"" cmt "\"") || index($0, "\"" cmt "_ul\"") ||
            index($0, "\"" cmt "_ul6\"") {
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

# Which bucket layout a target gets when the caller names no mode.
#
# A block limited "shared" would let one device starve the rest, so per-device
# is the sane default whenever the target covers more than one address. Lives
# here rather than in trafficctl-ratelimit.sh because the reboot-restore hook
# has to reach the same answer for a record written before modes were stored —
# two copies of this rule would mean a limit that changes meaning on reboot.
tctl_ratelimit_default_mode() {
    case "$1" in
        */32) echo "shared" ;;   # a /32 is one host; both modes are identical
        */*)  echo "each" ;;     # any wider block: per-device buckets
        *)    echo "shared" ;;   # bare host address
    esac
}

# ── Internet Blocking ──────────────────────────────────────────────────────

# A block is two rules: the address-keyed one for IPv4, and a MAC-keyed one
# scoped to IPv6.
#
# This is the row of issue #67 that matters most. A rate limit that under-
# delivers shows up in a speed test; a block that reports success while the
# device keeps full, unmetered IPv6 access is invisible until it matters — and
# "block internet" is what people reach for as a parental control.
#
# The MAC is resolved HERE rather than in trafficctl-block.sh because three
# callers reach this function: the block script, the Telegram bot, and the
# ifup-lan restore hook. Resolving it in the script would bring every persisted
# block back IPv4-only after each reboot.
#
# "meta nfproto ipv6" keeps the two rules disjoint: IPv4 is still dropped by
# precisely the rule it always was, so a failed MAC lookup costs the v6 half
# and nothing else. (nfproto is correct HERE, in the inet family; the limiter's
# netdev chains need "meta protocol ip6" instead — see tctl_ratelimit_add.)
# `insert`, not `add`, for the same reason the v4 rule uses it — fw4's forward
# chain accepts established/offloaded flows near the top, and a rule appended
# below that is dead.
tctl_block_add() {
    local ip="$1" comment="$2" mac rc

    if [ "$TCTL_FW" = "nft" ]; then
        nft insert rule inet fw4 forward "ip saddr $ip counter drop comment \"$comment\""
        rc=$?
        # Whether the v6 half is live. Read by callers; see trafficctl-block.sh.
        # shellcheck disable=SC2034
        TCTL_BLOCK_IPV6=0
        if mac=$(tctl_target_mac "$ip"); then
            nft insert rule inet fw4 forward \
                "meta nfproto ipv6 ether saddr $mac counter drop comment \"${comment}_mac\"" \
                2>/dev/null && TCTL_BLOCK_IPV6=1
        fi
        return "$rc"
    else
        # fw3/iptables stays IPv4-only; see docs/COMPATIBILITY.md.
        # shellcheck disable=SC2034
        TCTL_BLOCK_IPV6=0
        iptables -I FORWARD -s "$ip" -j DROP -m comment --comment "$comment"
    fi
}

tctl_block_remove() {
    local ip="$1" comment="$2"

    if [ "$TCTL_FW" = "nft" ]; then
        # Match the quoted comment in full: comments end in the address, so a
        # substring match on 192.168.1.1 also deletes the rule for 192.168.1.10.
        # The IPv6 half carries no address to match on at all, only its own
        # "_mac" comment — which is why it is listed explicitly here rather
        # than being caught by a looser pattern.
        for h in $(nft -a list chain inet fw4 forward 2>/dev/null \
                   | awk -v cmt="$comment" 'index($0, "\"" cmt "\"") ||
                                            index($0, "\"" cmt "_mac\"") {
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
    local ip="$1" dump comment
    if [ "$TCTL_FW" = "nft" ]; then
        dump=$(nft list chain inet fw4 forward 2>/dev/null)
        # The v4 rule is still found by address, so blocks written by versions
        # that derived the comment from the caller's label keep reading as
        # blocked.
        echo "$dump" | grep -q "ip saddr $ip .*drop" && return 0
        # The v6 rule names a MAC, not an address — its comment is the only
        # handle on it, and it is matched in full for the reason above.
        comment=$(tctl_block_comment "$ip")
        echo "$dump" | grep -qF "comment \"${comment}_mac\""
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

# Running AP interface names, one per line (e.g. phy0-ap0), taken from the
# hostapd ubus objects.
#
# Returns non-zero when ubus itself could not be consulted. That is NOT the
# same as "no AP is running", and callers must not read an empty list as
# "nothing to enforce" unless the query actually succeeded — doing so would
# turn a broken router into a silent "blocked".
tctl_get_hostapd_ifaces() {
    local out
    command -v ubus >/dev/null 2>&1 || return 1
    out=$(ubus list 2>/dev/null) || return 1
    # An empty result is a valid answer -- "no AP is running" -- so the grep
    # matching nothing must not be reported as a failed query. Only ubus itself
    # failing, above, is that.
    printf '%s\n' "$out" | grep '^hostapd\.' | cut -d. -f2-
    return 0
}

# Which ACL policy a wifi-iface uses: "allow" (whitelist — only listed MACs may
# associate) or "deny" (blacklist — listed MACs are rejected). Anything else,
# including unset, means no filtering is configured yet, reported as "deny"
# because that is the mode we create on demand.
tctl_get_wifi_filter_mode() {
    local iface="$1" mode
    mode=$(uci -q get "wireless.${iface}.macfilter" 2>/dev/null)
    [ "$mode" = "allow" ] && echo "allow" || echo "deny"
}

# ── Runtime WiFi enforcement ──────────────────────────────────────────────
#
# The uci maclist is the durable half of a WiFi block; hostapd's running ACL is
# the half that decides whether the device is on the air *now*. The two drift
# apart whenever the runtime call cannot be made, and for a long time that
# drift was invisible: the calls below were fire-and-forget, their exit status
# discarded, so a router without hostapd-utils reported every block as done
# while the device kept browsing.
#
# So every entry point here reports how far enforcement actually got, as one
# of these words, and proves it by reading the state back rather than trusting
# a return code:
#
#   acl      - the running ACL was changed and the change was read back
#   ban      - no usable hostapd_cli; hostapd's ubus deauthed and banned the
#              client, which expires on its own (see TCTL_WIFI_BAN_MS)
#   none     - nothing could be applied or verified on the running radio
#   no-radio - ubus answered and no AP is running, so there is nothing to
#              enforce; the uci maclist applies when wifi next starts
#
# Only "acl" and "no-radio" mean the operator's intent is in force, and the
# functions return 0 for exactly those two.

# How long a ubus ban lasts, in milliseconds. Used only where hostapd_cli is
# unavailable: hostapd's ubus object has no ACL method (del_client, list_bans,
# get_clients, reload), so a timed ban is the strongest immediate measure it
# can offer. One hour is long enough to be worth doing and short enough that
# callers must keep calling it temporary rather than done.
TCTL_WIFI_BAN_MS=3600000

# hostapd_cli exists AND this AP's control socket answers. Both halves matter:
# the package can be absent (the router this bug was found on), or present
# while hostapd is not listening, and only a PONG shows the ACL commands will
# reach anything.
tctl_hostapd_cli_alive() {
    command -v hostapd_cli >/dev/null 2>&1 || return 1
    hostapd_cli -i "$1" ping 2>/dev/null | grep -q PONG
}

# Does the running ACL currently keep this MAC off the air? Read back from
# hostapd instead of inferred from our own call: hostapd_cli exits 0 for
# "command delivered", and an ACL that stays empty afterwards is exactly the
# failure being guarded against. hostapd also reloads its maclist file at times
# of its own choosing, so the entry present may not be the one we added — which
# is fine, and another reason to ask rather than assume.
tctl_hostapd_acl_blocks() {
    local iface="$1" mac="$2" mode="$3" acl
    if [ "$mode" = "allow" ]; then
        acl=$(hostapd_cli -i "$iface" accept_acl SHOW 2>/dev/null)
        ! printf '%s\n' "$acl" | grep -qi "$mac"
    else
        acl=$(hostapd_cli -i "$iface" deny_acl SHOW 2>/dev/null)
        printf '%s\n' "$acl" | grep -qi "$mac"
    fi
}

tctl_hostapd_ubus_banned() {
    local iface="$1" mac="$2"
    command -v ubus >/dev/null 2>&1 || return 1
    ubus call "hostapd.$iface" list_bans 2>/dev/null | grep -qi "$mac"
}

# Fallback when hostapd_cli is unusable. del_client deauthenticates and refuses
# the client for ban_time, which is not an ACL entry — the durable half stays
# the uci maclist. The call's own exit status is deliberately ignored: it can
# fail for a client that is not currently associated while the ban still lands,
# and list_bans is the only answer worth having.
tctl_hostapd_ubus_ban() {
    local iface="$1" mac="$2"
    command -v ubus >/dev/null 2>&1 || return 1
    ubus call "hostapd.$iface" del_client \
        "{\"addr\":\"$mac\",\"reason\":1,\"deauth\":true,\"ban_time\":$TCTL_WIFI_BAN_MS}" \
        >/dev/null 2>&1
    tctl_hostapd_ubus_banned "$iface" "$mac"
}

# acl > ban > none, so a loop over several APs can keep the worst result.
tctl_enforce_rank() {
    case "$1" in
        acl) echo 3 ;;
        ban) echo 2 ;;
        *)   echo 1 ;;
    esac
}

tctl_hostapd_block_iface() {
    local iface="$1" mac="$2" mode="$3"
    if tctl_hostapd_cli_alive "$iface"; then
        if [ "$mode" = "allow" ]; then
            hostapd_cli -i "$iface" accept_acl DEL_MAC "$mac" >/dev/null 2>&1
        else
            hostapd_cli -i "$iface" deny_acl ADD_MAC "$mac" >/dev/null 2>&1
        fi
        hostapd_cli -i "$iface" deauthenticate "$mac" >/dev/null 2>&1
        if tctl_hostapd_acl_blocks "$iface" "$mac" "$mode"; then
            echo acl
            return
        fi
    fi
    if tctl_hostapd_ubus_ban "$iface" "$mac"; then
        echo ban
        return
    fi
    echo none
}

tctl_hostapd_unblock_iface() {
    local iface="$1" mac="$2" mode="$3"
    if tctl_hostapd_cli_alive "$iface"; then
        if [ "$mode" = "allow" ]; then
            hostapd_cli -i "$iface" accept_acl ADD_MAC "$mac" >/dev/null 2>&1
        else
            hostapd_cli -i "$iface" deny_acl DEL_MAC "$mac" >/dev/null 2>&1
        fi
        if ! tctl_hostapd_acl_blocks "$iface" "$mac" "$mode"; then
            # The ACL permits the MAC again, but a ban left over from an
            # earlier hostapd_cli-less block would still keep it off the air,
            # and there is no ubus method to lift one.
            if tctl_hostapd_ubus_banned "$iface" "$mac"; then
                echo ban
            else
                echo acl
            fi
            return
        fi
    fi
    if tctl_hostapd_ubus_banned "$iface" "$mac"; then
        echo ban
        return
    fi
    echo none
}

# Applies $2 ("allow"/"deny" ACL policy) to every running AP and echoes the
# worst per-AP outcome. Always safe to re-run: it enforces from the runtime
# state, so calling it on a MAC that uci already lists is how a block that was
# only ever written to config gets applied for real.
tctl_hostapd_apply_mac() {
    local op="$1" mac="$2" mode="$3"
    local ifaces iface state rank worst=3
    ifaces=$(tctl_get_hostapd_ifaces) || { echo none; return 1; }
    if [ -z "$ifaces" ]; then
        echo no-radio
        return 0
    fi
    for iface in $ifaces; do
        case "$op" in
            block) state=$(tctl_hostapd_block_iface "$iface" "$mac" "$mode") ;;
            *)     state=$(tctl_hostapd_unblock_iface "$iface" "$mac" "$mode") ;;
        esac
        rank=$(tctl_enforce_rank "$state")
        [ "$rank" -lt "$worst" ] && worst="$rank"
    done
    case "$worst" in
        3) echo acl; return 0 ;;
        2) echo ban ;;
        *) echo none ;;
    esac
    return 1
}

tctl_hostapd_block_mac() {
    tctl_hostapd_apply_mac block "$1" "$2"
}

tctl_hostapd_unblock_mac() {
    tctl_hostapd_apply_mac unblock "$1" "$2"
}

# A device listed as WiFi-blocked while it is associated on a radio right now
# is proof the running ACL does not carry the block — the state a silent
# enforcement failure leaves a router in. Keyed off conn_type rather than the
# station dump so it still holds where iw is missing and the connection type
# came from the bridge port instead.
tctl_wifi_block_pending() {
    local blocked="$1" conn_type="$2"
    [ "$blocked" = "1" ] || return 1
    case "$conn_type" in
        wifi|2.4G|5G|6G) return 0 ;;
    esac
    return 1
}

# ── Persistence ───────────────────────────────────────────────────────────

TCTL_RULES_FILE="/etc/trafficctl/rules.json"

tctl_persist_enabled() {
    [ "$(uci -q get trafficctl.main.persist_rules 2>/dev/null)" = "1" ]
}

tctl_persist_save() {
    local type="$1" ip="$2" param="$3" mode="$4" param_up="$5"
    [ -d "$(dirname "$TCTL_RULES_FILE")" ] || mkdir -p "$(dirname "$TCTL_RULES_FILE")"
    [ -f "$TCTL_RULES_FILE" ] || echo '[]' > "$TCTL_RULES_FILE"
    local tmp="${TCTL_RULES_FILE}.tmp"
    # The mode field is written only when the caller has one, so records for
    # rule types that have no bucket layout (blocks, port forwards) keep their
    # exact previous shape. param_up follows the same rule: the caller passes it
    # only for an asymmetric limit, so a symmetric one still writes the record
    # it always wrote and an older package can still read it back.
    local extra=""
    [ -n "$mode" ] && extra=",\"mode\":\"$mode\""
    [ -n "$param_up" ] && extra="$extra,\"param_up\":\"$param_up\""
    # Remove existing entry for same ip+type, append new one
    awk -v ip="$ip" -v t="$type" -v p="$param" -v x="$extra" '
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
        printf "{\"type\":\"%s\",\"ip\":\"%s\",\"param\":\"%s\"%s}]", t, ip, p, x
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
# TCTL_LEASES_FILE is set once at the top of this file (overridable for tests).
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
        # The global cut is a block, just a wider one — it belongs in the same
        # category so switching "Blocks" off does not leave it unlogged.
        block|unblock|cut|uncut) category="blocks" ;;
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
