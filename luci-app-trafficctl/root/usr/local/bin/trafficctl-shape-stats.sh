#!/bin/sh
# shellcheck shell=dash
# Show traffic shaping statistics for all shaped devices.
# Output: JSON array with extended stats per IP.
# Fields: ip, rate_kbit, bytes, packets, backlog, drops, overlimits,
#         requeues, lended, borrowed, ecn_mark, new_flows, old_flows,
#         target_us, memory_used

. /usr/local/bin/trafficctl-fw.sh

LAN_DEV=$(tctl_get_lan_device)

if ! command -v tc >/dev/null 2>&1; then
    echo '[]'; exit 0
fi

if ! tc qdisc show dev "$LAN_DEV" 2>/dev/null | grep -q "htb 1:"; then
    echo '[]'; exit 0
fi

# Get LAN subnet prefix (first 2 octets)
SUBNET=$(ip -4 addr show dev "$LAN_DEV" 2>/dev/null | grep -oE 'inet [0-9.]+' | head -1 | awk '{print $2}')
if [ -n "$SUBNET" ]; then
    PREFIX=$(echo "$SUBNET" | cut -d. -f1-2)
else
    PREFIX="192.168"
fi

# Collect class stats into a temp file so we can merge with qdisc stats
CLASS_DATA=$(tc -s class show dev "$LAN_DEV" 2>/dev/null)
QDISC_DATA=$(tc -s qdisc show dev "$LAN_DEV" 2>/dev/null)

# Parse class stats: emit lines "classid ip rate bytes pkts backlog drops overlimits requeues lended borrowed"
CLASS_PARSED=$(echo "$CLASS_DATA" | awk -v prefix="$PREFIX" '
function hex2dec(hex,    i, c, dec, len) {
    dec = 0
    len = length(hex)
    for (i = 1; i <= len; i++) {
        c = substr(hex, i, 1)
        if (c ~ /[0-9]/) dec = dec * 16 + (c + 0)
        else if (c == "a" || c == "A") dec = dec * 16 + 10
        else if (c == "b" || c == "B") dec = dec * 16 + 11
        else if (c == "c" || c == "C") dec = dec * 16 + 12
        else if (c == "d" || c == "D") dec = dec * 16 + 13
        else if (c == "e" || c == "E") dec = dec * 16 + 14
        else if (c == "f" || c == "F") dec = dec * 16 + 15
    }
    return dec
}

/class fq_codel/ { skip = 1; next }
/^class htb 1:/ {
    # emit previous record if valid
    if (have_record && current_rate > 0 && current_rate < 1000000) {
        printf "%s %s.%d.%d %d %d %d %d %d %d %d %d %d\n", \
            classid, prefix, current_o3, current_o4, current_rate, \
            bytes, pkts, backlog, drops, overlimits, requeues, lended, borrowed
    }
    minor = $3
    sub(/^1:/, "", minor)
    if (minor == "1" || minor == "fffe") { skip = 1; next }
    skip = 0
    classid = "1:" minor
    dec_val = hex2dec(minor)
    current_o3 = int(dec_val / 256)
    current_o4 = dec_val % 256
    current_rate = 0
    for (i = 1; i <= NF; i++) {
        if ($i == "rate") {
            v = $(i+1)
            if (v ~ /Gbit/) { sub(/Gbit/, "", v); current_rate = (v+0) * 1000000 }
            else if (v ~ /Mbit/) { sub(/Mbit/, "", v); current_rate = (v+0) * 1000 }
            else if (v ~ /[Kk]bit/) { sub(/[Kk]bit/, "", v); current_rate = v+0 }
            break
        }
    }
    bytes = 0; pkts = 0; backlog = 0; drops = 0; overlimits = 0; requeues = 0
    lended = 0; borrowed = 0
    have_record = 1
}
/Sent [0-9]+ bytes/ && !skip {
    for (i = 1; i <= NF; i++) {
        if ($i == "Sent") bytes = $(i+1)
        if ($i ~ /^[0-9]+$/ && $(i+1) == "pkt") pkts = $i
    }
    # parse "(dropped N, overlimits N requeues N)" from same line
    for (i = 1; i <= NF; i++) {
        if ($i == "(dropped") { v = $(i+1); sub(/,/, "", v); drops = v + 0 }
        if ($i == "overlimits") { v = $(i+1); sub(/[^0-9]/, "", v); overlimits = v + 0 }
    }
    # requeues at end of Sent line
    for (i = 1; i <= NF; i++) {
        if ($i == "requeues") {
            v = $(i+1); sub(/[^0-9]/, "", v)
            if (v != "") requeues = v + 0
        }
    }
}
/backlog/ && !skip {
    for (i = 1; i <= NF; i++) {
        if ($i == "backlog") {
            v = $(i+1); sub(/b$/, "", v)
            backlog = v + 0
        }
    }
}
/lended:/ && !skip {
    for (i = 1; i <= NF; i++) {
        if ($i == "lended:") lended = $(i+1) + 0
        if ($i == "borrowed:") borrowed = $(i+1) + 0
    }
}
END {
    if (have_record && current_rate > 0 && current_rate < 1000000) {
        printf "%s %s.%d.%d %d %d %d %d %d %d %d %d %d\n", \
            classid, prefix, current_o3, current_o4, current_rate, \
            bytes, pkts, backlog, drops, overlimits, requeues, lended, borrowed
    }
}
')

# Parse fq_codel qdisc stats: emit lines "parent_classid ecn_mark new_flows old_flows target_us memory_used"
QDISC_PARSED=$(echo "$QDISC_DATA" | awk '
/^qdisc fq_codel/ {
    # emit previous fq_codel record if any
    if (have_qdisc && parent_id != "") {
        printf "%s %d %d %d %d %d\n", parent_id, ecn_mark, new_flows, old_flows, target_us, memory_used
    }
    # extract parent classid
    parent_id = ""
    target_us = 0
    for (i = 1; i <= NF; i++) {
        if ($i == "parent") parent_id = $(i+1)
        if ($i == "target") {
            v = $(i+1)
            if (v ~ /ms$/) { sub(/ms$/, "", v); target_us = (v + 0) * 1000 }
            else if (v ~ /us$/) { sub(/us$/, "", v); target_us = v + 0 }
        }
    }
    ecn_mark = 0; new_flows = 0; old_flows = 0; memory_used = 0
    have_qdisc = 1
    next
}
/^qdisc/ && !/fq_codel/ {
    # different qdisc type, emit previous if valid
    if (have_qdisc && parent_id != "") {
        printf "%s %d %d %d %d %d\n", parent_id, ecn_mark, new_flows, old_flows, target_us, memory_used
    }
    have_qdisc = 0
    parent_id = ""
    next
}
have_qdisc && /ecn_mark/ {
    for (i = 1; i <= NF; i++) {
        if ($i == "ecn_mark") ecn_mark = $(i+1) + 0
    }
}
have_qdisc && /new_flows/ && !/new_flow_count/ {
    for (i = 1; i <= NF; i++) {
        if ($i == "new_flows") new_flows = $(i+1) + 0
        if ($i == "old_flows") old_flows = $(i+1) + 0
    }
}
have_qdisc && /memory_used/ {
    for (i = 1; i <= NF; i++) {
        if ($i == "memory_used") memory_used = $(i+1) + 0
    }
}
END {
    if (have_qdisc && parent_id != "") {
        printf "%s %d %d %d %d %d\n", parent_id, ecn_mark, new_flows, old_flows, target_us, memory_used
    }
}
')

# If no classes found, output empty array
if [ -z "$CLASS_PARSED" ]; then
    echo '[]'
    exit 0
fi

# Write qdisc data to temp file for awk to read
QDISC_TMP=$(mktemp /tmp/tctl_qdisc.XXXXXX)
echo "$QDISC_PARSED" > "$QDISC_TMP"

# Merge class and qdisc data, output JSON
# First file (QDISC_TMP) is loaded into arrays, second input (stdin) is class data
echo "$CLASS_PARSED" | awk '
NR == FNR {
    # Reading qdisc temp file
    if (NF >= 6) {
        qd_ecn[$1] = $2 + 0
        qd_new[$1] = $3 + 0
        qd_old[$1] = $4 + 0
        qd_target[$1] = $5 + 0
        qd_mem[$1] = $6 + 0
    }
    next
}
{
    classid = $1
    ip = $2
    rate = $3 + 0
    bytes = $4 + 0
    pkts = $5 + 0
    backlog = $6 + 0
    drops = $7 + 0
    overlimits = $8 + 0
    requeues = $9 + 0
    lended = $10 + 0
    borrowed = $11 + 0

    ecn = 0; nf = 0; of = 0; tgt = 0; mem = 0
    if (classid in qd_ecn) ecn = qd_ecn[classid]
    if (classid in qd_new) nf = qd_new[classid]
    if (classid in qd_old) of = qd_old[classid]
    if (classid in qd_target) tgt = qd_target[classid]
    if (classid in qd_mem) mem = qd_mem[classid]

    if (first) printf ","
    printf "{\"ip\":\"%s\",\"rate_kbit\":%d,\"bytes\":%d,\"packets\":%d,\"backlog\":%d,\"drops\":%d,\"overlimits\":%d,\"requeues\":%d,\"lended\":%d,\"borrowed\":%d,\"ecn_mark\":%d,\"new_flows\":%d,\"old_flows\":%d,\"target_us\":%d,\"memory_used\":%d}", \
        ip, rate, bytes, pkts, backlog, drops, overlimits, requeues, lended, borrowed, ecn, nf, of, tgt, mem
    first = 1
}
BEGIN { printf "[" }
END { printf "]\n" }
' "$QDISC_TMP" -

rm -f "$QDISC_TMP"
