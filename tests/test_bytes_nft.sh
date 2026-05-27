#!/bin/bash
# Unit tests for the nft map output parser in trafficctl-bytes-nft.sh.
# Extracts and runs the awk program directly against synthetic nft output.

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

# Run the awk block from trafficctl-bytes-nft.sh against synthetic nft map output.
# $1: bytes_in map body (nft list map ... output)
# $2: bytes_out map body
run_parser() {
    printf '%s\n__SEP__\n%s\n' "$1" "$2" | awk '
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
}

# Typical nft list map output (header lines are ignored by the awk pattern)
NFT_IN_ONE='table inet trafficctl_mon {
    map bytes_in {
        type ipv4_addr : counter
        flags dynamic
        elements = { 192.168.0.100 : counter packets 584 bytes 892341 }
    }
}'

NFT_OUT_ONE='table inet trafficctl_mon {
    map bytes_out {
        type ipv4_addr : counter
        flags dynamic
        elements = { 192.168.0.100 : counter packets 312 bytes 45678 }
    }
}'

assert_eq "single host: bytes_in" \
    "892341" "$(run_parser "$NFT_IN_ONE" "$NFT_OUT_ONE" | grep -o '"bytes_in":[0-9]*' | cut -d: -f2)"

assert_eq "single host: bytes_out" \
    "45678" "$(run_parser "$NFT_IN_ONE" "$NFT_OUT_ONE" | grep -o '"bytes_out":[0-9]*' | cut -d: -f2)"

assert_eq "single host: ip field" \
    "192.168.0.100" "$(run_parser "$NFT_IN_ONE" "$NFT_OUT_ONE" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4)"

# Multiple hosts — nft list map puts one entry per line
NFT_IN_MULTI='elements = { 192.168.0.10 : counter packets 100 bytes 10000,
             192.168.0.20 : counter packets 200 bytes 20000 }'
NFT_OUT_MULTI='elements = { 192.168.0.10 : counter packets 50 bytes 5000,
              192.168.0.20 : counter packets 80 bytes 8000 }'

_multi=$(run_parser "$NFT_IN_MULTI" "$NFT_OUT_MULTI")
assert_eq "multi host: .10 present" "1" "$(echo "$_multi" | grep -c '192\.168\.0\.10')"
assert_eq "multi host: .20 present" "1" "$(echo "$_multi" | grep -c '192\.168\.0\.20')"
assert_eq "multi host: .10 bytes_in"  "10000" "$(echo "$_multi" | grep -o '"ip":"192\.168\.0\.10","bytes_in":[0-9]*' | grep -o '[0-9]*$')"
assert_eq "multi host: .20 bytes_out" "8000"  "$(echo "$_multi" | grep -o '"ip":"192\.168\.0\.20","bytes_in":[0-9]*,"bytes_out":[0-9]*' | grep -o '[0-9]*$')"

# Host appears in out_b but not in_b (e.g. destination-only traffic)
NFT_IN_EMPTY='table inet trafficctl_mon { map bytes_in { type ipv4_addr : counter; flags dynamic } }'
NFT_OUT_ONLY='elements = { 192.168.0.50 : counter packets 10 bytes 9999 }'

_out_only=$(run_parser "$NFT_IN_EMPTY" "$NFT_OUT_ONLY")
assert_eq "out-only host: present in output" "1" "$(echo "$_out_only" | grep -c '192\.168\.0\.50')"
assert_eq "out-only host: bytes_in is 0"     "0" "$(echo "$_out_only" | grep -o '"bytes_in":[0-9]*' | cut -d: -f2)"
assert_eq "out-only host: bytes_out"      "9999" "$(echo "$_out_only" | grep -o '"bytes_out":[0-9]*' | cut -d: -f2)"

# Empty maps → empty JSON array
assert_eq "both maps empty → []" "[]" "$(run_parser "" "")"

# Trailing comma variant (nft sometimes emits it)
NFT_IN_COMMA='elements = { 192.168.0.7 : counter packets 1 bytes 100, }'
NFT_OUT_COMMA='elements = { 192.168.0.7 : counter packets 1 bytes 50, }'
assert_eq "trailing comma: bytes_in"  "100" "$(run_parser "$NFT_IN_COMMA" "$NFT_OUT_COMMA" | grep -o '"bytes_in":[0-9]*' | cut -d: -f2)"
assert_eq "trailing comma: bytes_out"  "50" "$(run_parser "$NFT_IN_COMMA" "$NFT_OUT_COMMA" | grep -o '"bytes_out":[0-9]*' | cut -d: -f2)"

# Output is valid JSON (starts with [ and ends with ])
_json=$(run_parser "$NFT_IN_ONE" "$NFT_OUT_ONE")
assert_eq "output starts with ["  "[" "$(echo "$_json" | cut -c1)"
assert_eq "output ends with ]"    "]" "$(echo "$_json" | rev | cut -c1)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
