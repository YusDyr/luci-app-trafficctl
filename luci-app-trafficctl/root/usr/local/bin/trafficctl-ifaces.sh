#!/bin/sh
# shellcheck shell=dash
# Per-interface byte counters for the global (bmon-style) overview.
#
# Output: JSON array
#   [{"dev":"eth1","label":"wan","role":"wan","tunnel":false,"primary":true,
#     "defroute":true,"up":true,"rx_bytes":N,"tx_bytes":N}]
#
# rx/tx are the kernel's own counters, i.e. relative to the INTERFACE, not to
# the client: rx on the WAN device is download, rx on br-lan is what the LAN
# sent upstream. Rates are not computed here — the frontend diffs two samples
# exactly as it already does for trafficctl-bytes.sh, so this script stays
# stateless and one sample cheap.
#
# Memory / fork discipline (128–512 MB routers; the dashboard polls this on
# its Poll interval, as often as every 2 s):
#   * the hot path is ONE read of /proc/net/dev and ONE awk — nothing else
#   * the role map is the expensive part (tctl_lan_subnets forks ubus and
#     jsonfilter per configured network, and merely sourcing trafficctl-fw.sh
#     runs `nft list tables`), so it is computed on a cold path and memoized
#     in tmpfs with a TTL, the same idiom the rdns and netify caches use.
#     trafficctl-fw.sh is therefore sourced ONLY inside build_cache()
#   * even the cold path classifies every interface in a SINGLE awk rather
#     than forking one per device out of a `while read` loop
#   * the cache is a few dozen bytes per interface and lives in /tmp, so
#     polling never touches flash
#
# Usage: trafficctl-ifaces.sh

CACHE="${TCTL_IFROLE_CACHE:-/tmp/trafficctl_ifroles}"
PROC_NET_DEV="${TCTL_PROC_NET_DEV:-/proc/net/dev}"
SYSFS="${TCTL_SYSFS_NET:-/sys/class/net}"
# 60 s: a WAN failover or a tunnel changing role shows up within a minute,
# which is 30 polls' worth of work saved at the default 2 s interval. A device
# that is entirely NEW does not wait for the TTL — see the #MISS retry below.
TTL="${TCTL_IFROLE_TTL:-60}"

build_cache() {
    # COLD PATH ONLY. Never call this from the per-poll path.
    . /usr/local/bin/trafficctl-fw.sh

    # LAN = the L3 devices trafficctl already monitors (br-lan, br-guest,
    # eth0.20 …). Deliberately the L3 devices and not their bridge ports:
    # listing both would show the same bytes twice.
    _lan=$(tctl_get_lan_devices 2>/dev/null | tr '\n' ' ')

    # Devices carrying a default route, v4 or v6. This is NOT the same as
    # "the WAN" — see the role rules in the awk below.
    _defroute=$( { ip -4 route show default; ip -6 route show default; } 2>/dev/null \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") print $(i + 1) }' \
        | sort -u | tr '\n' ' ')

    # Friendly labels: the uci/ubus interface name for each L3 device, so the
    # overview says "wan"/"lan"/"vpn_fi" instead of "eth1"/"br-lan"/"awg0".
    # One ubus call, parsed line-wise — "interface" always precedes
    # "l3_device" inside an entry, and the outer '"interface": [' line has no
    # string value so it cannot seed a stale name.
    #
    # Flattened to ONE space-separated "dev name dev name …" list, not kept as
    # lines: a multi-line value passed through `awk -v` is rejected outright by
    # some awks ("newline in string"), so the pairs are read positionally
    # below. Neither a device name nor a uci interface name can contain a
    # space, so the pairing is unambiguous.
    _labels=$(ubus call network.interface dump 2>/dev/null | awk '
    function val(line,   seg) {
        if (!match(line, /:[ \t]*"/)) return ""
        seg = substr(line, RSTART + RLENGTH)
        if (!match(seg, /"/)) return ""
        return substr(seg, 1, RSTART - 1)
    }
    /"interface"[ \t]*:/ { name = val($0); next }
    /"l3_device"[ \t]*:/ {
        dev = val($0)
        if (dev != "" && name != "") { print dev " " name; name = "" }
    }' | tr '\n' ' ')

    # Every device present in /proc/net/dev gets a line, even the ones with no
    # recognisable role. That is what makes the #MISS retry below terminate:
    # after a rebuild, a lookup can only miss if an interface appeared in the
    # meantime.
    _tmp="$CACHE.$$"
    {
        echo "# $(date +%s)"
        awk -v defroute="$_defroute" -v lan="$_lan" -v labels="$_labels" '
# Device-name patterns for tunnels. This is a LABEL as much as a role: it tells
# the UI how to group and badge the interface. ppp*/pppoe* is deliberately
# ABSENT — pppoe-wan is the standard OpenWrt DSL uplink, not a VPN, and badging
# it as one would be wrong on every PPPoE line.
function is_tun(d) {
    return (d ~ /^(wg|awg|tun|tap|gre|sit|vti|ipsec|ip6tnl|xfrm|zt|nordlynx|tailscale|l2tp|pptp)/)
}
BEGIN {
    n = split(defroute, a, " ")
    for (i = 1; i <= n; i++) if (a[i] != "") isdef[a[i]] = 1
    n = split(lan, a, " ")
    for (i = 1; i <= n; i++) if (a[i] != "") islan[a[i]] = 1
    # "dev name dev name …" — read two at a time, see the flattening above.
    n = split(labels, a, " ")
    for (i = 1; i + 1 <= n; i += 2) {
        if (a[i] == "" || a[i + 1] == "") continue
        lbl[a[i]] = a[i + 1]
        # The uci network literally named "wan"/"wan6" is the uplink even when
        # something else currently owns the default route.
        if (a[i + 1] == "wan" || a[i + 1] == "wan6") isuciwan[a[i]] = 1
    }
}
NR > 2 {
    if (index($0, ":") == 0) next
    d = substr($0, 1, index($0, ":") - 1)
    gsub(/[ \t]/, "", d)
    if (d == "" || d == "lo") next
    devs[++nd] = d
    tun[d] = is_tun(d) ? 1 : 0

    # Role rules, in priority order. The ordering exists because a full-tunnel
    # router (WireGuard/AmneziaWG, common on these boxes) has its default route
    # via awg0 while the physical uplink still carries every byte ENCAPSULATED.
    # Classifying awg0 as the WAN would both hide the real uplink under "other"
    # and double-count the same traffic, so a tunnel stays a tunnel and the
    # uplink stays the WAN; "defroute" below records who actually holds the
    # route.
    if (islan[d])        role[d] = "lan"
    else if (tun[d])     role[d] = "vpn"
    else if (isuciwan[d] || isdef[d]) { role[d] = "wan"; nwan++ }
    else                 role[d] = "other"
}
END {
    # Fallback: a router whose ONLY default route is a tunnel and which has no
    # uci "wan" would otherwise have no WAN row at all, leaving the overview
    # headline blank. Promote the route holder in that case only.
    if (!nwan) {
        for (i = 1; i <= nd; i++) if (isdef[devs[i]]) { role[devs[i]] = "wan"; nwan++ }
    }
    # Exactly one interface is flagged primary — the headline graph shows that
    # one rather than a sum, because summing several WANs double-counts a
    # failover pair and mixes two unrelated links (see #28).
    for (i = 1; i <= nd && !prim; i++) {
        d = devs[i]
        if (role[d] == "wan" && isuciwan[d]) prim = d
    }
    for (i = 1; i <= nd && !prim; i++) {
        d = devs[i]
        if (role[d] == "wan" && isdef[d]) prim = d
    }
    for (i = 1; i <= nd && !prim; i++) {
        if (role[devs[i]] == "wan") prim = devs[i]
    }
    for (i = 1; i <= nd; i++) {
        d = devs[i]
        printf "%s %s %d %d %d %s\n", d, role[d], tun[d], (d == prim), \
            (d in isdef) ? 1 : 0, (d in lbl) ? lbl[d] : "-"
    }
}' "$PROC_NET_DEV" 2>/dev/null
    } > "$_tmp" 2>/dev/null
    # Rename into place so a concurrent poll never reads a half-written map.
    [ -s "$_tmp" ] && mv "$_tmp" "$CACHE" 2>/dev/null
    rm -f "$_tmp" 2>/dev/null
}

emit() {
    awk -v cache="$CACHE" -v sysfs="$SYSFS" '
BEGIN {
    while ((getline l < cache) > 0) {
        if (substr(l, 1, 1) == "#") continue
        if (split(l, f, " ") < 6) continue
        role[f[1]] = f[2]; tun[f[1]] = f[3] + 0; prim[f[1]] = f[4] + 0
        dfr[f[1]] = f[5] + 0; lbl[f[1]] = f[6]
    }
    close(cache)
    printf "["
}
NR > 2 {
    # Split on the COLON, not on whitespace. The kernel pads the name field to
    # a fixed width, so a long interface name or a counter wide enough to fill
    # it leaves no space before rx_bytes ("enp0s31f6:12345678") and every
    # positional field after it shifts by one.
    if (index($0, ":") == 0) next
    dev = substr($0, 1, index($0, ":") - 1)
    gsub(/[ \t]/, "", dev)
    if (dev == "" || dev == "lo") next
    rest = substr($0, index($0, ":") + 1)
    sub(/^[ \t]+/, "", rest)
    if (split(rest, c, /[ \t]+/) < 16) next

    # Written as if/else rather than a ternary on purpose: an awk line starting
    # "ident = (" trips the array-assignment bashism scanner in
    # tests/test_openwrt_compat.sh, which cannot tell shell from an embedded
    # awk program.
    r = "other"
    if (dev in role) { r = role[dev] } else { miss = 1 }

    # operstate is a sysfs read, not a fork, so it is cheap enough for the
    # poll path — and a tunnel that is down while still holding counters is
    # exactly what the overview needs to show.
    state = ""
    if ((getline state < (sysfs "/" dev "/operstate")) <= 0) state = ""
    close(sysfs "/" dev "/operstate")
    up = "false"
    if (state == "up" || state == "unknown") { up = "true" }

    name = dev; gsub(/["\\]/, "", name)
    label = name
    if ((dev in lbl) && lbl[dev] != "-") { label = lbl[dev] }
    gsub(/["\\]/, "", label)

    if (n++ > 0) printf ","
    # %.0f, never %d: these are 64-bit kernel counters and busybox awk formats
    # %d through a 32-bit int (see tests/test_byte_overflow.sh). /proc/net/dev
    # is the worst offender in the tree — an uptime of a few days puts any
    # active interface past 2 GiB.
    printf "{\"dev\":\"%s\",\"label\":\"%s\",\"role\":\"%s\",\"tunnel\":%s,\"primary\":%s,\"defroute\":%s,\"up\":%s,\"rx_bytes\":%.0f,\"tx_bytes\":%.0f}", \
        name, label, r, \
        (tun[dev] ? "true" : "false"), (prim[dev] ? "true" : "false"), \
        (dfr[dev] ? "true" : "false"), up, c[1] + 0, c[9] + 0
}
END {
    printf "]"
    if (miss) printf "#MISS"
}' "$PROC_NET_DEV" 2>/dev/null
}

# Guard before anything else. awk still runs its BEGIN block when the input
# file is missing but never reaches END, so emit() would print a bare "[" —
# invalid JSON that the frontend surfaces as a dead panel rather than an empty
# one. Nothing below is worth doing without counters anyway.
[ -r "$PROC_NET_DEV" ] || { echo '[]'; exit 0; }

NOW=$(date +%s)
TS=0
if [ -f "$CACHE" ]; then
    # Builtin read, no fork: the header line is "# <epoch>".
    read -r _hash TS < "$CACHE" 2>/dev/null
    case "$TS" in ''|*[!0-9]*) TS=0 ;; esac
fi
[ $((NOW - TS)) -ge "$TTL" ] && build_cache

OUT=$(emit)
case "$OUT" in
*'#MISS')
    # An interface the cached map has never seen showed up — a tunnel came up,
    # a USB modem was plugged in, a guest bridge was created. Rebuild once and
    # re-emit so it is classified immediately instead of sitting in "other"
    # until the TTL expires. build_cache() enumerates /proc/net/dev itself, so
    # the retry always resolves and this cannot spin.
    build_cache
    OUT=$(emit)
    ;;
esac

[ -z "$OUT" ] && OUT="[]"
printf '%s\n' "${OUT%\#MISS}"
