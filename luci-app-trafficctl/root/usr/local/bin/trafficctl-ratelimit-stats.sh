#!/bin/sh
# shellcheck shell=dash
# Show active rate-limit statistics.
# Output: JSON array [{"ip":"...","rate_kbit":N,"packets":N,"bytes":N,"pass_packets":0,"pass_bytes":0}]

. /usr/local/bin/trafficctl-fw.sh

if [ "$TCTL_FW" = "nft" ]; then
    nft list table netdev tm_ratelimit 2>/dev/null | awk '
    /ip daddr/ && /limit rate/ && /counter/ {
        ip = ""
        rate = 0
        packets = 0
        bytes = 0
        for (i = 1; i <= NF; i++) {
            if ($i == "daddr" && i < NF) ip = $(i+1)
            if ($i == "rate" && $(i+1) == "over") {
                val = $(i+2)
                gsub(/[^0-9]/, "", val)
                # stored as kbytes/second, convert back to kbit
                rate = val * 8
            }
            if ($i == "counter") {
                # format: counter packets N bytes N
                if ($(i+1) == "packets") packets = $(i+2)
                if ($(i+3) == "bytes") bytes = $(i+4)
            }
        }
        if (ip != "") {
            if (first) printf ","
            printf "{\"ip\":\"%s\",\"rate_kbit\":%d,\"packets\":%d,\"bytes\":%d,\"pass_packets\":0,\"pass_bytes\":0}", ip, rate, packets, bytes
            first = 1
        }
    }
    BEGIN { printf "["; first = 0 }
    END { printf "]\n" }
    '
else
    iptables -t mangle -L FORWARD -nvx 2>/dev/null | grep "rl_ratelimit" | awk '
    {
        packets = $1
        bytes = $2
        ip = ""
        rate = 0
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip == "") {
                # skip source 0.0.0.0/0, take destination
            }
            if (i == 9) ip = $i
        }
        # extract rate from hashlimit-above
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+kbit/) {
                gsub(/kbit.*/, "", $i)
                rate = $i
                break
            }
        }
        if (ip != "" && ip != "0.0.0.0/0") {
            if (first) printf ","
            printf "{\"ip\":\"%s\",\"rate_kbit\":%d,\"packets\":%d,\"bytes\":%d,\"pass_packets\":0,\"pass_bytes\":0}", ip, rate, packets, bytes
            first = 1
        }
    }
    BEGIN { printf "["; first = 0 }
    END { printf "]\n" }
    '
fi
