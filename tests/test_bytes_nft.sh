#!/bin/bash
# Tests for `trafficctl bytes-nft`: per-device byte counters from the nft
# counter maps, the sampler's source under flow offload without counter sync.
#
# The real CLI runs against a fake `nft` (tests/lib/bytes_env.sh) that replays
# a listing per command line, in both forms nftables prints: `nft -j` (read
# first) and the text listing (an nftables built without JSON). The shapes
# here are the ones nftables 1.0.2 (OpenWrt 22.03) and 1.1.6 (25.12) print.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/bytes_env.sh
. "$(dirname "$0")/lib/bytes_env.sh"

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

IN_TXT="$BE_NFT/list map inet trafficctl_mon bytes_in"
OUT_TXT="$BE_NFT/list map inet trafficctl_mon bytes_out"
IN_JSON="$BE_NFT/-j list map inet trafficctl_mon bytes_in"
OUT_JSON="$BE_NFT/-j list map inet trafficctl_mon bytes_out"
CHAIN="$BE_NFT/list chain inet trafficctl_mon mon_forward"

# The rules as they are now, so the gate leaves the table alone.
good_chain() {
    printf 'table inet trafficctl_mon {\n\tchain mon_forward {\n\t\ttype filter hook forward priority -200; policy accept;\n\t\tupdate @bytes_in { ip daddr counter }\n\t\tupdate @bytes_out { ip saddr counter }\n\t}\n}\n' > "$CHAIN"
}
good_chain

run_nft() { be_run bytes-nft; }
# One device's field: dev <json> <ip> <field>
dev() { printf '%s' "$1" | jq -r --arg ip "$2" --arg f "$3" '.[] | select(.ip == $ip) | .[$f]'; }
maps() { rm -f "$IN_TXT" "$OUT_TXT" "$IN_JSON" "$OUT_JSON"; }

# ── single host ──────────────────────────────────────────────────────────────

cat > "$IN_TXT" <<'EOF'
table inet trafficctl_mon {
    map bytes_in {
        type ipv4_addr : counter
        flags dynamic
        elements = { 192.168.0.100 : counter packets 584 bytes 892341 }
    }
}
EOF
cat > "$OUT_TXT" <<'EOF'
table inet trafficctl_mon {
    map bytes_out {
        type ipv4_addr : counter
        flags dynamic
        elements = { 192.168.0.100 : counter packets 312 bytes 45678 }
    }
}
EOF

OUT=$(run_nft)
assert_eq "single host: the exact output" \
    '[{"ip":"192.168.0.100","bytes_in":892341,"bytes_out":45678,"bytes_tcp":-1,"bytes_udp":-1,"src":"nft","degraded":false}]' "$OUT"

# ── multiple hosts, one a line (1.1.6 text) ──────────────────────────────────

maps
cat > "$IN_TXT" <<'EOF'
elements = { 192.168.0.10 : counter packets 100 bytes 10000,
             192.168.0.20 : counter packets 200 bytes 20000 }
EOF
cat > "$OUT_TXT" <<'EOF'
elements = { 192.168.0.10 : counter packets 50 bytes 5000,
              192.168.0.20 : counter packets 80 bytes 8000 }
EOF

OUT=$(run_nft)
assert_eq "multi host: both present, in address order" "192.168.0.10 192.168.0.20" \
    "$(printf '%s' "$OUT" | jq -r 'map(.ip) | join(" ")')"
assert_eq "multi host: .10 bytes_in"  "10000" "$(dev "$OUT" 192.168.0.10 bytes_in)"
assert_eq "multi host: .20 bytes_out" "8000"  "$(dev "$OUT" 192.168.0.20 bytes_out)"

# ── several elements on ONE line (1.0.2 text) ────────────────────────────────
# nftables 1.0.2 does not wrap the element list. Read a line at a time, as the
# shell did, only the last element of the line survived.
maps
echo "elements = { 192.168.0.10 : counter packets 1 bytes 111, 192.168.0.20 : counter packets 2 bytes 222, 192.168.0.30 : counter packets 3 bytes 333 }" > "$IN_TXT"
echo "elements = { 192.168.0.30 : counter packets 3 bytes 3 }" > "$OUT_TXT"
OUT=$(run_nft)
assert_eq "one-line list: every element is read" "111 222 333" \
    "$(printf '%s' "$OUT" | jq -r 'map(.bytes_in) | join(" ")')"

# ── host only in bytes_out (destination-only traffic) ───────────────────────

maps
cat > "$IN_TXT" <<'EOF'
table inet trafficctl_mon { map bytes_in { type ipv4_addr : counter; flags dynamic } }
EOF
cat > "$OUT_TXT" <<'EOF'
elements = { 192.168.0.50 : counter packets 10 bytes 9999 }
EOF

OUT=$(run_nft)
assert_eq "out-only host: present in output" "192.168.0.50" "$(printf '%s' "$OUT" | jq -r '.[].ip')"
assert_eq "out-only host: bytes_in is 0"     "0"    "$(dev "$OUT" 192.168.0.50 bytes_in)"
assert_eq "out-only host: bytes_out"         "9999" "$(dev "$OUT" 192.168.0.50 bytes_out)"

# ── both maps empty → empty JSON array ───────────────────────────────────────

maps
printf 'table inet trafficctl_mon {\n\tmap bytes_in {\n\t\ttype ipv4_addr : counter\n\t\tflags dynamic\n\t}\n}\n' > "$IN_TXT"
printf 'table inet trafficctl_mon {\n\tmap bytes_out {\n\t\ttype ipv4_addr : counter\n\t\tflags dynamic\n\t}\n}\n' > "$OUT_TXT"
OUT=$(run_nft)
assert_eq "both maps empty → []" "[]" "$OUT"
printf '%s\n' '{"nftables": [{"metainfo": {"version": "1.1.6", "json_schema_version": 1}}, {"map": {"family": "inet", "name": "bytes_in", "table": "trafficctl_mon", "type": "ipv4_addr", "handle": 2, "map": "counter", "flags": ["dynamic"]}}]}' > "$IN_JSON"
OUT=$(run_nft)
assert_eq "both maps empty, -j (no elem key at all) → []" "[]" "$OUT"

# ── trailing comma variant (nft sometimes emits it) ─────────────────────────

maps
echo "elements = { 192.168.0.7 : counter packets 1 bytes 100, }" > "$IN_TXT"
echo "elements = { 192.168.0.7 : counter packets 1 bytes 50, }" > "$OUT_TXT"
OUT=$(run_nft)
assert_eq "trailing comma: bytes_in"  "100" "$(dev "$OUT" 192.168.0.7 bytes_in)"
assert_eq "trailing comma: bytes_out"  "50" "$(dev "$OUT" 192.168.0.7 bytes_out)"

# ── nft -j ───────────────────────────────────────────────────────────────────
# Read before the text listing. A counter map lists [ key, { counter } ]
# pairs; a set with a counter per element lists { elem: { val, counter } }.
# The text listing is wrong on purpose, to show it is not the one read.
maps
echo "elements = { 192.168.0.9 : counter packets 1 bytes 1 }" > "$IN_TXT"
echo "elements = { 192.168.0.9 : counter packets 1 bytes 1 }" > "$OUT_TXT"
printf '%s\n' '{"nftables": [{"metainfo": {"version": "1.0.2", "release_name": "Lester Gooch", "json_schema_version": 1}}, {"map": {"family": "inet", "name": "bytes_in", "table": "trafficctl_mon", "type": "ipv4_addr", "handle": 2, "map": "counter", "flags": ["dynamic"], "elem": [["192.168.0.100", {"counter": {"packets": 5, "bytes": 5368709120}}], ["192.168.0.101", {"counter": {"packets": 1, "bytes": 64}}]]}}]}' > "$IN_JSON"
printf '%s\n' '{"nftables": [{"metainfo": {"version": "1.1.6", "release_name": "Commodore Bullmoose #7", "json_schema_version": 1}}, {"set": {"family": "inet", "name": "bytes_out", "table": "trafficctl_mon", "type": "ipv4_addr", "handle": 3, "flags": ["dynamic"], "elem": [{"elem": {"val": "192.168.0.100", "counter": {"packets": 2, "bytes": 9007199254740993}}}]}}]}' > "$OUT_JSON"
OUT=$(run_nft)
assert_eq "-j map pairs: 5 GiB download" "5368709120" "$(dev "$OUT" 192.168.0.100 bytes_in)"
assert_eq "-j map pairs: second element" "64" "$(dev "$OUT" 192.168.0.101 bytes_in)"
# Past 2^53 a double cannot hold it; jq would round it, so it is grepped.
assert_eq "-j set elements: 2^53+1 upload, exact" "1" \
    "$(printf '%s' "$OUT" | grep -c '"bytes_out":9007199254740993,')"
assert_eq "-j: the text listing is not used" "" "$(dev "$OUT" 192.168.0.9 bytes_in)"

# Not JSON at all (an nft that ignores -j): the text listing is read instead.
echo "table inet trafficctl_mon {" > "$IN_JSON"
OUT=$(run_nft)
assert_eq "-j unparsable: the text listing is read" "1" "$(dev "$OUT" 192.168.0.9 bytes_in)"

# Elements in a shape none of the readers knows (a later nftables, say): the
# map is not empty, so the text listing is read rather than an empty map.
printf '%s\n' '{"nftables": [{"map": {"name": "bytes_in", "elem": [{"key": "192.168.0.9", "data": {"bytes": 5}}]}}]}' > "$IN_JSON"
OUT=$(run_nft)
assert_eq "-j elements not understood: the text listing is read" "1" "$(dev "$OUT" 192.168.0.9 bytes_in)"
maps

# ── rule orientation: which map each direction is keyed by ──────────────────
#
# The maps used to be keyed the wrong way round: bytes_in by `ip saddr`, which
# is traffic the device SENT, i.e. its upload, while the conntrack sampler,
# docs/API.md and the DL/UL columns in status.js all define bytes_in as
# download. The same RPC call returned DL and UL swapped depending on the
# router's offload mode.
#
# These tests pin the orientation at the point where the rules are created,
# not where the output is parsed, so a future swap in the parser cannot make
# them pass while the counters are wrong.

echo "elements = { 192.168.0.100 : counter packets 584 bytes 892341 }" > "$IN_TXT"
echo "elements = { 192.168.0.100 : counter packets 312 bytes 45678 }" > "$OUT_TXT"

# fresh install: no chain yet
rm -f "$CHAIN"
: > "$BE_NFTLOG"
run_nft >/dev/null

assert_eq "fresh: bytes_in is keyed by daddr (download)" "1" \
    "$(grep -c '^add rule inet trafficctl_mon mon_forward update @bytes_in { ip daddr counter }$' "$BE_NFTLOG")"
assert_eq "fresh: bytes_out is keyed by saddr (upload)" "1" \
    "$(grep -c '^add rule inet trafficctl_mon mon_forward update @bytes_out { ip saddr counter }$' "$BE_NFTLOG")"
assert_eq "fresh: no inverted bytes_in rule" "0" \
    "$(grep -c '@bytes_in { ip saddr counter }' "$BE_NFTLOG")"
assert_eq "fresh: the maps are dynamic counter maps" "2" \
    "$(grep -c '^add map inet trafficctl_mon bytes_\(in\|out\) { type ipv4_addr : counter; flags dynamic; }$' "$BE_NFTLOG")"
assert_eq "fresh: the chain runs ahead of the flowtable" "1" \
    "$(grep -c '^add chain inet trafficctl_mon mon_forward { type filter hook forward priority -200; policy accept; }$' "$BE_NFTLOG")"

# upgrade from a router that already carries the old, inverted rules.
# The creation gate must NOT accept them: a looser check ("does any rule
# mention saddr?") matches the broken chain too, so the corrected rules would
# only ever reach fresh installs.
cat > "$CHAIN" <<'EOF'
table inet trafficctl_mon {
	chain mon_forward {
		type filter hook forward priority -200; policy accept;
		update @bytes_in { ip saddr counter }
		update @bytes_out { ip daddr counter }
	}
}
EOF
: > "$BE_NFTLOG"
run_nft >/dev/null

assert_eq "upgrade: stale table is dropped" "1" \
    "$(grep -c '^delete table inet trafficctl_mon$' "$BE_NFTLOG")"
assert_eq "upgrade: the table goes before the rules come" "delete add" \
    "$(awk '/^delete table/ { printf "delete" } /^add rule/ && !r { printf " add"; r = 1 }' "$BE_NFTLOG")"
assert_eq "upgrade: corrected bytes_in rule is installed" "1" \
    "$(grep -c 'update @bytes_in { ip daddr counter }' "$BE_NFTLOG")"

# already correct: must be a no-op, or every poll would delete and rebuild
# the table and the counters would never accumulate.
good_chain
: > "$BE_NFTLOG"
run_nft >/dev/null

assert_eq "correct chain: table is not dropped" "0" \
    "$(grep -c '^delete table' "$BE_NFTLOG")"
assert_eq "correct chain: no rules re-added" "0" \
    "$(grep -c '^add rule' "$BE_NFTLOG")"

# ── unsupported dynamic counter maps: falls back to conntrack ───────────────
# When `nft list map ... bytes_in` fails (kernel lacks dynamic counter maps:
# kernel 6.12 refuses `type ipv4_addr : counter; flags dynamic` with "Not
# supported"), the sampler must read conntrack instead of returning [] forever.
maps
cat > "$BE_CT" <<'EOF'
ipv4     2 tcp      6 431999 ESTABLISHED src=192.168.1.100 dst=142.250.185.78 sport=52134 dport=443 packets=142 bytes=15234 src=142.250.185.78 dst=192.168.1.100 sport=443 dport=52134 packets=198 bytes=245678 [ASSURED] mark=0 zone=0 use=2
EOF
be_offload software
OUT=$(run_nft)
assert_eq "unsupported counter maps: conntrack is read instead" "ct 245678" \
    "$(printf '%s' "$OUT" | jq -r '.[] | "\(.src) \(.bytes_in)"')"
assert_eq "unsupported counter maps: flagged degraded under uncountered offload" "true" \
    "$(dev "$OUT" 192.168.1.100 degraded)"
be_offload hardware-counter
OUT=$(run_nft)
assert_eq "unsupported counter maps, counter offload: not degraded" "false" \
    "$(dev "$OUT" 192.168.1.100 degraded)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
