#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=dash
# Show active rate-limit statistics.
# Output: JSON array
#   [{"ip":"...","mode":"each|shared","rate_kbit":N,"packets":N,"bytes":N,
#     "pass_packets":0,"pass_bytes":0}]
#
# One entry per target, counters summed across chains: the download rule is
# installed on every LAN device's egress chain, so a router with three bridges
# holds three copies of the same limit. Only the chain on the device the target
# actually lives behind ever matches, but which copy that is cannot be known
# here — taking any single one at random reported zero drops for most targets.

. /usr/libexec/trafficctl/trafficctl-fw.sh

nft list table netdev tm_ratelimit 2>/dev/null | awk "$TCTL_NFT_RATE_AWK"'
/ip daddr/ && /limit rate/ && /counter/ {
    ip = ""
    rate = 0
    packets = 0
    bytes = 0
    for (i = 1; i <= NF; i++) {
        # FIRST daddr only. In "each" mode the rule reads
        #   ip daddr <target> meter m { ip daddr limit rate over ... }
        # and the meter key is a bare "ip daddr" with no operand, so
        # overwriting on every match reported the target as "limit" —
        # every per-device subnet limit was invisible to this output, to
        # the dashboard, and to tctl_has_limit.
        if (ip == "" && $i == "daddr" && i < NF && $(i+1) ~ /^[0-9]/) ip = $(i+1)
        if ($i == "rate" && $(i+1) == "over") {
            val = $(i+2)
            gsub(/[^0-9]/, "", val)
            # nft lists the largest whole unit, stepping by 1024
            # (see tctl_rl_rate_kbit); back to SI kbit/s.
            rate = tctl_rate_kbit(val, $(i+3))
        }
        if ($i == "counter") {
            # format: counter packets N bytes N
            if ($(i+1) == "packets") packets = $(i+2)
            if ($(i+3) == "bytes") bytes = $(i+4)
        }
    }
    if (ip != "") {
        if (!(ip in seen)) { seen[ip] = 1; order[++n] = ip }
        # A meter keyed on the address is what makes the bucket per-device.
        mode[ip] = (index($0, " meter ") > 0) ? "each" : "shared"
        rate_of[ip] = rate
        pkts[ip] += packets
        byts[ip] += bytes
    }
}
END {
    printf "["
    for (i = 1; i <= n; i++) {
        ip = order[i]
        if (i > 1) printf ","
        printf "{\"ip\":\"%s\",\"mode\":\"%s\",\"rate_kbit\":%d,\"packets\":%.0f,\"bytes\":%.0f,\"pass_packets\":0,\"pass_bytes\":0}", \
            ip, mode[ip], rate_of[ip], pkts[ip], byts[ip]
    }
    printf "]\n"
}
'
