#!/bin/sh
# shellcheck shell=dash
# Per-device byte counters from conntrack (for speed calculation).
# Output: JSON array [{"ip":"...","bytes_in":N,"bytes_out":N}]

. /usr/local/bin/trafficctl-fw.sh

# Any offload mode (software, hardware, hardware-counter) bypasses conntrack counters
# for fast-path packets. Use nftables counters at forward priority -200 (before the
# flowtable at -150) which capture every packet regardless of offload state.
# Only pure "none" mode has accurate conntrack counters.
# Modes whose counters ARE synced back to conntrack ("*-counter") keep the
# conntrack path accurate; only the uncountered ones need the nft fallback.
# TCTL_FORCE_CONNTRACK is set by that fallback when the kernel lacks dynamic
# counter maps, so we don't bounce between the two.
_offload=$(tctl_get_offload_mode)
case "$_offload" in
    none|*-counter) ;;
    *)
        [ "$TCTL_FW" = "nft" ] && [ -z "$TCTL_FORCE_CONNTRACK" ] && \
            exec /usr/local/bin/trafficctl-bytes-nft.sh
        ;;
esac

# All monitored subnets (connected LANs + routed downstream subnets +
# trafficctl.main.extra_subnets), as awk membership spec.
MATCH_SPEC=$(tctl_monitored_subnets | awk '{printf "%s%s:%s:%s",(NR>1?" ":""),$2,$3,$4}')
[ -z "$MATCH_SPEC" ] && { echo '[]'; exit 0; }

# Router-owned IPv4 addresses, excluded from the NAT fallback below.
LOCAL_IPS=$(ip -4 addr show 2>/dev/null | awk '/inet /{split($2,a,"/");print a[1]}' | tr '\n' ' ')

cat /proc/net/nf_conntrack 2>/dev/null | awk -v spec="$MATCH_SPEC" -v localips="$LOCAL_IPS" '
function ip2int(ip,   a) {
    split(ip, a, ".")
    return a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4]
}
function is_lan(ip,   si, k) {
    si = ip2int(ip)
    for (k = 1; k <= ns; k++)
        if (si - (si % blk[k]) == base[k]) return 1
    return 0
}
BEGIN {
    printf "["
    ns = split(spec, parts, " ")
    for (k = 1; k <= ns; k++) {
        split(parts[k], kv, ":")
        base[k] = kv[1] + 0; blk[k] = kv[2] + 0
    }
    nl = split(localips, lp, " ")
    for (k = 1; k <= nl; k++) if (lp[k] != "") islocal[lp[k]] = 1
}
{
    src=""; osrc=""; rdst=""; nsrc=0; bytes_orig=0; bytes_reply=0; bc=0
    for (i=1; i<=NF; i++) {
        if ($i ~ /^src=/) {
            v = substr($i, 5)
            nsrc++
            if (nsrc == 1) osrc = v
            if (src == "" && is_lan(v)) src = v
        }
        if (nsrc == 2 && rdst == "" && $i ~ /^dst=/) rdst = substr($i, 5)
        if ($i ~ /^bytes=/) {
            v = substr($i, 7) + 0
            bc++
            if (bc == 1) bytes_orig = v
            else if (bc == 2) bytes_reply = v
        }
    }
    # NAT fallback: flow was SNAT/masqueraded here (reply dst != original
    # src), so the original src is a forwarded client even though it is not
    # in any monitored subnet (e.g. behind a downstream router).
    if (src == "" && osrc != "" && rdst != "" && rdst != osrc && \
        osrc ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !(osrc in islocal))
        src = osrc
    if (src != "") {
        key = src
        in_total[key] += bytes_reply
        out_total[key] += bytes_orig
    }
}
END {
    n = 0
    for (ip in in_total) {
        if (n > 0) printf ","
        printf "{\"ip\":\"%s\",\"bytes_in\":%.0f,\"bytes_out\":%.0f}", ip, in_total[ip], out_total[ip]
        n++
    }
    printf "]\n"
}
'
