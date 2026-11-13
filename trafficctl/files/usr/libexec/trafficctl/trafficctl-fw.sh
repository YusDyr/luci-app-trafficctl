#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=dash
# Firewall abstraction layer for trafficctl (fw4/nftables only).
# Source this file: . /usr/libexec/trafficctl/trafficctl-fw.sh

# Constant, not detected: a probe of "nft list tables" is empty before fw4
# loads its ruleset at boot, and must not pick another backend then.
# shellcheck disable=SC2034
TCTL_FW="nft"

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
# Only the directions where that holds are covered; see block_add (ctl.uc) and
# add (limit.uc) for which, and README/COMPATIBILITY for what is not.

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

# ── Rates ──────────────────────────────────────────────────────────────────
#
# The rate limiter is the ucode CLI's (trafficctl ratelimit, trafficctl.limit);
# these are what the port-forward limit and the shaper still use.

# A kbit/s ceiling as the bytes/second an nft "limit rate" is written in.
#
# kbit/s here is SI, 1000 bits, as everywhere else in the package: the UI,
# tc ("kbit" is 1000 bits to tc as well) and the speed graphs. nft's
# "kbytes" is 1024 bytes, so writing rate_kbit / 8 kbytes — what the
# limiter did — policed 2.4% above the ceiling it was given: 5000 kbit/s
# became 5120. Bytes are exact (kbit * 1000 / 8 = kbit * 125).
tctl_rate_bytes() {
    local b=$(( $1 * 125 ))
    [ "$b" -lt 1 ] && b=1
    echo "$b"
}

# A ceiling in kbit/s: a whole number from 1 to 100 Gbit/s. Shell arithmetic
# reads "abc" as 0 and "010" as octal, so anything else became a 1 byte/s
# limit, i.e. a block reported as success. Leading zeros are refused for that
# reason; the length check keeps the comparison inside 64 bits.
TCTL_RATE_MAX_KBIT=100000000
tctl_validate_rate() {
    case "$1" in
        ''|*[!0-9]*|0*) return 1 ;;
    esac
    [ "${#1}" -le 9 ] && [ "$1" -le "$TCTL_RATE_MAX_KBIT" ]
}

# awk function shared by every reader of an nft rate: tctl_rate_kbit(n, unit)
# turns "n <unit>/second" as nft lists it back into SI kbit/s. Prepended to
# an awk program; a rule written before rates were stored in bytes reads as
# what it actually polices (625 kbytes/second is 5120 kbit/s).
TCTL_NFT_RATE_AWK='
function tctl_rate_kbit(n, u,   b) {
    if (u ~ /^bytes/)       b = n
    else if (u ~ /^kbytes/) b = n * 1024
    else if (u ~ /^mbytes/) b = n * 1024 * 1024
    else if (u ~ /^gbytes/) b = n * 1024 * 1024 * 1024
    else return 0
    # Rounded here, so a reader printing %d agrees with one printing %.0f.
    return int(b * 8 / 1000 + 0.5)
}
'

# ── Internet Blocking ──────────────────────────────────────────────────────
#
# The block, the unblock, their restore on boot and the WiFi deny are the
# ucode CLI's (trafficctl block/unblock/macfilter-add/macfilter-remove/
# restore, trafficctl.ctl).

# ── Helpers ────────────────────────────────────────────────────────────────

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
    case "$mask" in ''|*[!0-9]*|0?*) return 1 ;; esac
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
            case "$mask" in ''|*[!0-9]*|0?*) return 1 ;; esac
            [ "$mask" -ge 0 ] && [ "$mask" -le 32 ] || return 1
            echo "$addr/$mask"
            ;;
        *)
            tctl_validate_ip "$t" || return 1
            echo "$t"
            ;;
    esac
}

# No leading zeros: $(( )) reads 010 as octal, and the ucode backend refuses it.
tctl_validate_ip() {
    echo "$1" | grep -qE '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' || return 1
    local IFS='.'
    # shellcheck disable=SC2086
    set -- $1
    [ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ] 2>/dev/null
}

# ── Persistence ───────────────────────────────────────────────────────────

TCTL_RULES_FILE="/etc/trafficctl/rules.json"
# Shared with the ucode writer (lib.persist_save): without it the two read
# the same file and the later rename drops the other's record. Same wait and
# takeover as the shapes lock in trafficctl-shape.sh.
TCTL_RULES_LOCK="/tmp/trafficctl_rules.lock.d"

tctl_rules_lock() {
    local tries=0
    while ! mkdir "$TCTL_RULES_LOCK" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 50 ]; then
            # A stale directory from a killed writer must not stop persistence.
            rmdir "$TCTL_RULES_LOCK" 2>/dev/null || true
            mkdir "$TCTL_RULES_LOCK" 2>/dev/null
            return 0
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
}

tctl_rules_unlock() {
    rmdir "$TCTL_RULES_LOCK" 2>/dev/null || true
}

tctl_persist_enabled() {
    [ "$(uci -q get trafficctl.main.persist_rules 2>/dev/null)" = "1" ]
}

tctl_persist_save() {
    local rc
    tctl_rules_lock
    tctl_persist_save_locked "$@"
    rc=$?
    tctl_rules_unlock
    return "$rc"
}

tctl_persist_save_locked() {
    local type="$1" ip="$2" param="$3" mode="$4" param_up="$5"
    [ -d "$(dirname "$TCTL_RULES_FILE")" ] || mkdir -p "$(dirname "$TCTL_RULES_FILE")"
    # [ -s ], not [ -f ]: a previous failed save can leave a zero-length file,
    # and awk on an empty file prints nothing. Seeding [] lets this call still
    # write the new record instead of refusing to replace the empty file below.
    [ -s "$TCTL_RULES_FILE" ] || echo '[]' > "$TCTL_RULES_FILE"
    local tmp="${TCTL_RULES_FILE}.tmp"
    # The mode field is written only when the caller has one, so records for
    # rule types that have no bucket layout (blocks, port forwards) keep their
    # exact previous shape. param_up follows the same rule: the caller passes it
    # only for an asymmetric limit, so a symmetric one still writes the record
    # it always wrote and an older package can still read it back.
    local extra=""
    [ -n "$mode" ] && extra=",\"mode\":\"$mode\""
    [ -n "$param_up" ] && extra="$extra,\"param_up\":\"$param_up\""
    # Remove existing entry for same ip+type, append new one.
    #
    # split()'s third argument is an ERE on BusyBox awk (and on POSIX awk).
    # The string "},{" is therefore read as "a '}' followed by an interval
    # expression", and BusyBox rejects it:
    #
    #     awk: bad regex '},{': Invalid contents of {}
    #
    # awk then prints nothing, the redirect creates an empty .tmp, and a bare
    # mv would replace rules.json with an empty file — so every block, unblock,
    # rate limit or port-forward change wiped persistence while the UI still
    # claimed the rules were saved. GNU awk and mawk often accept the same
    # string, which is why a suite running on those interpreters did not catch
    # this. The regex literal \},\{ is a pair of literal braces, and splits
    # the same records on every awk we have to care about.
    #
    # Only replace the file if awk succeeded and wrote something. [] is
    # non-empty, so removing the last record is fine; an empty .tmp is the
    # failure this is guarding against.
    if awk -v ip="$ip" -v t="$type" -v p="$param" -v x="$extra" '
    {
        gsub(/^\[/,""); gsub(/\]$/,"")
        n=split($0, items, /\},\{/)
        printf "["
        first=1
        for (i=1; i<=n; i++) {
            sub(/^\{/,"",items[i]); sub(/\}$/,"",items[i])
            # index(), not ~: these values reach awk as a REGEX otherwise, and
            # its safety then rests on an argument about which characters the
            # fields can hold. That argument happens to hold today — an address
            # or a CIDR carries only the dot, which among valid values can line
            # up with nothing but another dot — but it is not a property of the
            # code, and the next field added here would not have it. A fixed
            # string search needs no such argument.
            if (index(items[i], "\"ip\":\"" ip "\"") && index(items[i], "\"type\":\"" t "\"")) continue
            if (!first) printf ","
            printf "{%s}", items[i]
            first=0
        }
        if (!first) printf ","
        printf "{\"type\":\"%s\",\"ip\":\"%s\",\"param\":\"%s\"%s}]", t, ip, p, x
    }' "$TCTL_RULES_FILE" > "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$TCTL_RULES_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

tctl_persist_remove() {
    local rc
    tctl_rules_lock
    tctl_persist_remove_locked "$@"
    rc=$?
    tctl_rules_unlock
    return "$rc"
}

tctl_persist_remove_locked() {
    local type="$1" ip="$2"
    [ -s "$TCTL_RULES_FILE" ] || return 0
    local tmp="${TCTL_RULES_FILE}.tmp"
    # See tctl_persist_save for why the separator is a regex literal and why
    # the file is replaced only when awk writes a non-empty result.
    if awk -v ip="$ip" -v t="$type" '
    {
        gsub(/^\[/,""); gsub(/\]$/,"")
        n=split($0, items, /\},\{/)
        printf "["
        first=1
        for (i=1; i<=n; i++) {
            sub(/^\{/,"",items[i]); sub(/\}$/,"",items[i])
            # index(), not ~: these values reach awk as a REGEX otherwise, and
            # its safety then rests on an argument about which characters the
            # fields can hold. That argument happens to hold today — an address
            # or a CIDR carries only the dot, which among valid values can line
            # up with nothing but another dot — but it is not a property of the
            # code, and the next field added here would not have it. A fixed
            # string search needs no such argument.
            if (index(items[i], "\"ip\":\"" ip "\"") && index(items[i], "\"type\":\"" t "\"")) continue
            if (!first) printf ","
            printf "{%s}", items[i]
            first=0
        }
        printf "]"
    }' "$TCTL_RULES_FILE" > "$tmp" && [ -s "$tmp" ]; then
        mv "$tmp" "$TCTL_RULES_FILE"
    else
        rm -f "$tmp"
        return 1
    fi
}

# ── Shapes ────────────────────────────────────────────────────────────────

# TCTL_LEASES_FILE is set once at the top of this file (overridable for tests).
TCTL_SHAPES_FILE="/etc/trafficctl/shapes.json"

# "<ip> <classid>" for every shape in shapes.json — the only way from an
# address to its HTB class, because minors are ALLOCATED (see
# trafficctl-shape.sh), not derived from the address. Readers that derived
# them anyway showed one device's rate on another.
#
# Same record pattern as shapes_entries in trafficctl-shape.sh, optional
# rate_kbit_up included: a pattern that misses a record form makes that shape
# vanish from every reader. A record from before allocation carries no
# classid, and its class is still the one the old derivation gave it
# (legacy_classid there), so that is what it maps to.
tctl_shape_classmap() {
    grep -oE '\{"ip":"[^"]+","rate_kbit":[0-9]+(,"classid":"1:[0-9a-f]+")?(,"rate_kbit_up":[0-9]+)?\}' \
        "$TCTL_SHAPES_FILE" 2>/dev/null | awk '
    {
        if (!match($0, /"ip":"[^"]+"/)) next
        ip = substr($0, RSTART + 6, RLENGTH - 7)
        if (match($0, /"classid":"1:[0-9a-f]+"/)) {
            print ip, substr($0, RSTART + 11, RLENGTH - 12)
            next
        }
        if (split(ip, o, ".") != 4) next
        dec = o[3] * 256 + o[4]
        if (dec < 2 || dec > 65533) next
        printf "%s 1:%x\n", ip, dec
    }'
}

# The IFB device upload shaping runs on (see trafficctl-shape.sh).
tctl_shape_ifb_dev() {
    local d
    d=$(uci -q get trafficctl.main.shape_ifb 2>/dev/null)
    echo "${d:-tctl-ifb0}"
}

# "classid rate_kbit" for every per-device HTB class on a device, from one tc
# call. On the LAN device that is the download ceiling, on the IFB the upload
# one: a shape uses the same classid on both.
tctl_tc_class_rates() {
    command -v tc >/dev/null 2>&1 || return 0
    tc class show dev "$1" 2>/dev/null | awk '
    /^class htb 1:/ {
        classid=$3
        minor=classid; sub(/^1:/,"",minor)
        if (minor=="1" || minor=="fffe") next
        rate=0
        for (i=1;i<=NF;i++) {
            if ($i=="rate") {
                v=$(i+1)
                if (v ~ /Gbit/)       { sub(/Gbit/,"",v);   rate=(v+0)*1000000 }
                else if (v ~ /Mbit/)  { sub(/Mbit/,"",v);   rate=(v+0)*1000 }
                else if (v ~ /[Kk]bit/){ sub(/[Kk]bit/,"",v); rate=v+0 }
                else                  { rate=(v+0)/1000 }
                break
            }
        }
        print classid, rate
    }'
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
        # fw4 declares the flowtable with the counter flag from OpenWrt 23.05
        # on, syncing hardware byte counts back to conntrack, so monitoring
        # works; fw4 on 22.03 does not.
        if nft list flowtables 2>/dev/null | grep -q "counter"; then
            echo "hardware-counter"
        else
            echo "hardware"
        fi
    elif [ "$sw" = "1" ]; then
        # A counter-flagged flowtable syncs offloaded byte counts back to
        # conntrack, so conntrack accounting stays valid. Without the flag
        # (fw4 on 22.03) offloaded flows are not counted at all: the
        # flowtable hooks netdev ingress, ahead of every inet chain.
        if nft list flowtables 2>/dev/null | grep -q "counter"; then
            echo "software-counter"
        else
            echo "software"
        fi
    else
        echo "none"
    fi
}

# ── Qualcomm NSS / ECM Detection ───────────────────────────────────────────
#
# On Qualcomm NSS builds (ipq807x/ipq60xx with qca-nss-ecm, qca-nss-drv and
# qca-nss-clients) the Enhanced Connection Manager installs flow rules into
# the NSS firmware cores, and an accelerated flow NEVER TRAVERSES THE LINUX
# NETWORK STACK. Both of this package's enforcement paths are therefore inert
# on such a router: the nftables netdev policer never sees the packets, and
# Linux HTB/IFB never gets to queue them. Reported in issue #81, where a user
# applied WiFi client limits and nothing was limited.
#
# Nothing here attempts to fix that — an NSS backend would mean nsshtb/nsstbl
# and act_nssmirred in place of htb and ifb, which needs hardware to develop
# against. What these helpers do is let the callers STOP REPORTING SUCCESS for
# a rule that cannot be enforced, which is the part that can be made correct
# without hardware and is the actual complaint.
#
# Named by absolute path, as it must be on the router; the tests sed this line
# into their scratch directory (same approach as TCTL_LEASES_FILE above).
TCTL_ECM_DEBUGFS="/sys/kernel/debug/ecm"

# absent  — no ECM on this system; every rule this package installs applies
#           normally and nothing needs qualifying.
# stopped — ECM is present but its front end has been stopped, so flows are
#           back on the Linux path and our rules DO apply.
# active  — ECM is accelerating. Our rules are installed but not enforced for
#           any accelerated flow.
#
# The distinction between "stopped" and "active" is deliberate and is read
# from the kernel rather than inferred from the packages installed: somebody
# who has turned acceleration off to get working QoS must not be told their
# limits do not work.
tctl_nss_status() {
    [ -d "$TCTL_ECM_DEBUGFS" ] || { printf 'absent\n'; return 0; }
    local v4 v6
    v4=$(cat "$TCTL_ECM_DEBUGFS/front_end_ipv4_stop" 2>/dev/null)
    v6=$(cat "$TCTL_ECM_DEBUGFS/front_end_ipv6_stop" 2>/dev/null)
    # Both stopped is the only state in which the Linux datapath is whole. A
    # missing knob is NOT read as stopped: an ECM build whose debugfs layout we
    # do not recognise is still accelerating, and guessing "stopped" there
    # would restore exactly the false success this exists to remove.
    if [ "$v4" = "1" ] && [ "$v6" = "1" ]; then
        printf 'stopped\n'
    else
        printf 'active\n'
    fi
}

tctl_nss_active() { [ "$(tctl_nss_status)" = "active" ]; }

# The suffix every caller appends to its own message. One wording in one place,
# so the limiter, the shaper and the block path cannot drift into describing
# the same condition three different ways.
tctl_nss_note() {
    tctl_nss_active || return 0
    printf ' [NOT ENFORCED: Qualcomm NSS acceleration is active — accelerated flows bypass the Linux network stack entirely, so this rule is installed but has no effect. Stop acceleration (echo 1 > %s/front_end_ipv4_stop, same for ipv6) or set acceleration_engine in /etc/config/ecm, then re-apply]' \
        "$TCTL_ECM_DEBUGFS"
}

# Defunct the flows ECM has already accelerated.
#
# This is the NSS counterpart of the `conntrack -D` every rule change already
# does, and it is needed for the same reason: a flow that is ALREADY offloaded
# is not re-evaluated against a rule that appeared afterwards, so without this
# a new block or limit would only affect connections started later — which
# presents as "it works sometimes".
#
# Best effort by design: absent on every non-NSS router, and a write failure
# must never fail the operation the caller is performing. UNVERIFIED ON
# HARDWARE — there is no IPQ device here to test it against, so it is wired in
# as an addition to the existing flush rather than as something any result
# depends on.
tctl_nss_defunct() {
    local f="$TCTL_ECM_DEBUGFS/ecm_db/defunct_all"
    [ -w "$f" ] || return 0
    echo 1 > "$f" 2>/dev/null || true
    return 0
}
