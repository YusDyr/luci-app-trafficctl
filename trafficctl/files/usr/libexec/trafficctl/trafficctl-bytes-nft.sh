#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=dash
# Per-device byte counters using nftables dynamic sets with per-element counters.
# Works with software flow offload (hook priority -200, before flowtable at -150).
# Output: JSON array
#   [{"ip":"…","bytes_in":N,"bytes_out":N,"bytes_tcp":-1,"bytes_udp":-1,
#     "src":"nft","degraded":false}]
#
# "degraded" is always false here, and that is the entire point of this script:
# these counters sit ahead of the flowtable, so they keep moving under offload
# where conntrack freezes. If this path is unavailable, trafficctl-bytes.sh
# reports degraded:true instead of quietly handing back frozen numbers.
#
# The counters here are cumulative since the table was created, unlike the
# conntrack sums trafficctl-bytes.sh returns, which cover live flows only.
# "src" lets trafficctl-totals.sh notice the swap and rebaseline instead of
# accumulating the whole set as a single enormous delta.
#
# The protocol split is -1, i.e. "unknown", not 0: the sets are keyed by
# address alone, so there is nothing here to split TCP from UDP with.
# Reporting 0 would render as a device that sent no TCP at all.

. /usr/libexec/trafficctl/trafficctl-fw.sh

command -v nft >/dev/null 2>&1 || { echo '[]'; exit 0; }

# Why a plain dynamic SET with the counter in the rule, and not the
# `type ipv4_addr : counter` map used up to 1.30.x: the kernel refuses that
# map with "Not supported" (seen on 5.10, 5.15, 6.6 and 6.12, under nft 1.0.2
# through 1.1.6), so the nft path never got past it and always fell back to
# conntrack, reporting degraded. `update @set { ip daddr counter }` attaches
# the counter through the dynset expression instead, and nft lists it per
# element; that is verified on all four kernels.
#
# Direction convention, matching trafficctl-bytes.sh and docs/API.md:
#   bytes_in  = traffic toward the device  (download) -> keyed by ip daddr
#   bytes_out = traffic from the device    (upload)   -> keyed by ip saddr
#
# One transaction: `add` then `delete` makes the delete safe when the table is
# absent, and the whole table is rebuilt or nothing is. A half-built table
# (sets created, rules refused) would pass for a working one, and two pollers
# racing through separate `nft add rule` calls could each append a copy of the
# rules and double-count every packet.
tctl_mon_build() {
    nft -f - 2>/dev/null <<'NFT'
add table inet trafficctl_mon
delete table inet trafficctl_mon
table inet trafficctl_mon {
	set bytes_in {
		type ipv4_addr
		flags dynamic
	}
	set bytes_out {
		type ipv4_addr
		flags dynamic
	}
	chain mon_forward {
		type filter hook forward priority -200; policy accept;
		update @bytes_in { ip daddr counter }
		update @bytes_out { ip saddr counter }
	}
}
NFT
}

# The gate accepts only the exact current layout: both names declared as sets
# and exactly one rule per direction, in the current orientation. Anything
# else is rebuilt, which covers every table an older version left behind:
#   * up to 1.13.x the rules were keyed the other way round (bytes_in by saddr);
#   * up to 1.30.x the table was meant to hold counter MAPS. The kernel
#     refused them, which left a chain without rules; and should a map ever
#     exist, its rules list exactly like the set rules, so the rule text alone
#     cannot tell the two apart;
#   * a duplicated rule, which would double-count.
# The rebuild resets the counters once, on upgrade; trafficctl-totals.sh sees
# the drop and rebaselines, so a single discarded sample is the whole cost.
# -t leaves the elements out: this runs on every poll.
tctl_mon_current() {
    nft -t list table inet trafficctl_mon 2>/dev/null | awk '
        /^[ \t]*set bytes_in \{/                      { si = 1 }
        /^[ \t]*set bytes_out \{/                     { so = 1 }
        /^[ \t]*map bytes_(in|out) /                  { bad = 1 }
        /^[ \t]*update @bytes_in \{ ip daddr counter \}/  { ri++; next }
        /^[ \t]*update @bytes_out \{ ip saddr counter \}/ { ro++; next }
        /@bytes_(in|out)/                             { bad = 1 }
        END { exit !(si && so && ri == 1 && ro == 1 && !bad) }'
}

tctl_mon_current || tctl_mon_build

# Some kernels or nft builds still cannot create the table; without this check
# every read would return [] and per-device speed would just stop working.
if ! tctl_mon_current; then
    TCTL_FORCE_CONNTRACK=1 exec /usr/libexec/trafficctl/trafficctl-bytes.sh
fi

# JSON first, text second. OpenWrt ships both nftables-json and
# nftables-nojson, and on the latter `nft -j` fails, so both forms have to
# parse. The awk below tells them apart per line.
tctl_mon_list() {
    _l=$(nft -j list set inet trafficctl_mon "$1" 2>/dev/null)
    case "$_l" in
        *'"nftables"'*) printf '%s\n' "$_l" ;;
        *) nft list set inet trafficctl_mon "$1" 2>/dev/null ;;
    esac
}

IN=$(tctl_mon_list bytes_in)
OUT=$(tctl_mon_list bytes_out)

# Text: "elements = { 192.168.0.100 counter packets 584 bytes 892341, ... }",
# several elements per line and wrapped across lines by nft 1.1.x. The old
# map form ("192.168.0.100 : counter packets ...") reads the same way.
# JSON: one line, {"elem": {"val": "192.168.0.100", "counter": {"packets":
# 584, "bytes": 892341}}} per element.
printf '%s\n__SEP__\n%s\n' "$IN" "$OUT" | awk '
function add(ip, v) {
    if (phase == 0) in_b[ip]  += v
    else            out_b[ip] += v
}
/^__SEP__$/ { phase = 1; next }
/"nftables"/ {
    n = split($0, part, /"val": */)
    for (k = 2; k <= n; k++) {
        p = part[k]
        if (!match(p, /^"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"/)) continue
        ip = substr(p, 2, RLENGTH - 2)
        # Bounded by the next element, so an element without a counter cannot
        # borrow the following one.
        e = index(p, "{\"elem\"")
        if (e > 0) p = substr(p, 1, e - 1)
        if (!match(p, /"bytes": *[0-9]+/)) continue
        v = substr(p, RSTART, RLENGTH)
        sub(/^"bytes": */, "", v)
        add(ip, v + 0)
    }
    next
}
{
    gsub(/[{},]/, " ")
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ip = $i
        else if ($i == "bytes" && ip != "") { add(ip, $(i+1) + 0); ip = "" }
    }
}
END {
    printf "["
    n = 0
    for (ip in in_b) {
        if (n > 0) printf ","
        printf "{\"ip\":\"%s\",\"bytes_in\":%.0f,\"bytes_out\":%.0f,\"bytes_tcp\":-1,\"bytes_udp\":-1,\"src\":\"nft\",\"degraded\":false}", \
            ip, in_b[ip], out_b[ip]+0
        n++
    }
    for (ip in out_b) {
        if (!(ip in in_b)) {
            if (n > 0) printf ","
            printf "{\"ip\":\"%s\",\"bytes_in\":0,\"bytes_out\":%.0f,\"bytes_tcp\":-1,\"bytes_udp\":-1,\"src\":\"nft\",\"degraded\":false}", \
                ip, out_b[ip]
            n++
        }
    }
    printf "]\n"
}
'
