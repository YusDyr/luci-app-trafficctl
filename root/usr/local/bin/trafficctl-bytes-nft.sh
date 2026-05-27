#!/bin/sh
# shellcheck shell=dash
# Per-device byte counters using nftables maps.
# Works with software flow offload (hook priority -200, before flowtable at -150).
# Output: JSON array [{"ip":"...","bytes_in":N,"bytes_out":N}]

. /usr/local/bin/trafficctl-fw.sh

command -v nft >/dev/null 2>&1 || { echo '[]'; exit 0; }

# Create table/maps/chain/rules if not already present (idempotent)
if ! nft list chain inet trafficctl_mon mon_forward 2>/dev/null | grep -q "saddr"; then
    nft add table inet trafficctl_mon 2>/dev/null
    nft add map inet trafficctl_mon bytes_in \
        '{ type ipv4_addr : counter; flags dynamic; }' 2>/dev/null
    nft add map inet trafficctl_mon bytes_out \
        '{ type ipv4_addr : counter; flags dynamic; }' 2>/dev/null
    nft add chain inet trafficctl_mon mon_forward \
        '{ type filter hook forward priority -200; policy accept; }' 2>/dev/null
    nft add rule inet trafficctl_mon mon_forward \
        'update @bytes_in { ip saddr counter }' 2>/dev/null
    nft add rule inet trafficctl_mon mon_forward \
        'update @bytes_out { ip daddr counter }' 2>/dev/null
fi

IN=$(nft list map inet trafficctl_mon bytes_in 2>/dev/null)
OUT=$(nft list map inet trafficctl_mon bytes_out 2>/dev/null)

# Parse: lines look like "192.168.0.100 : counter packets 584 bytes 892341[,]"
printf '%s\n__SEP__\n%s\n' "$IN" "$OUT" | awk '
/^__SEP__$/ { phase = 1; next }
/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ : counter/ {
    ip = ""; val = 0
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip = $i
        if ($i == "bytes") val = $(i+1) + 0
    }
    if (ip != "") {
        if (phase == 0) in_b[ip]  += val
        else            out_b[ip] += val
    }
}
END {
    printf "["
    n = 0
    for (ip in in_b) {
        if (n > 0) printf ","
        printf "{\"ip\":\"%s\",\"bytes_in\":%d,\"bytes_out\":%d}", ip, in_b[ip], out_b[ip]+0
        n++
    }
    for (ip in out_b) {
        if (!(ip in in_b)) {
            if (n > 0) printf ","
            printf "{\"ip\":\"%s\",\"bytes_in\":0,\"bytes_out\":%d}", ip, out_b[ip]
            n++
        }
    }
    printf "]\n"
}
'
