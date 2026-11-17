#!/bin/bash
# The nft readers of trafficctl.ctl, on the `nft -j` output of OpenWrt 22.03
# (nftables 1.0.2) and 25.12 (1.1.6), captured from the listings in
# tests/fixtures/nft-src by tools/ci/live-readers.sh.
#
# The shell readers they replace matched substrings of the text listing. A
# per-address limit was "each" only if the text said " meter ", and nftables
# 1.1 lists it as "add @set { ... }", so every such limit read as shared on
# 25.12 (ratelimit-stats, rules): the "each" cases below fail on the v1.30.0
# readers. Blocks are listed as v1.30.0 listed them: a drop on an ip saddr
# whose comment starts with tctl_block_, because blocks written before
# v1.13.2 carry the caller's label after it (tctl_block_tg).

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PASS=0
FAIL=0
FIXTURES="$UC_REPO/tests/fixtures"
T="$UC_TMP/t"
mkdir -p "$T/bin" "$T/root"

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}

# nft answers from $NFT_DIR: <name>.<table>.json, as captured.
cat > "$T/bin/nft" <<'MOCK'
#!/bin/sh
case "$*" in
    "-j list chain inet fw4 forward") f="$NFT_DIR/$NFT_NAME.fw4.json" ;;
    "-j list table netdev tm_ratelimit") f="$NFT_DIR/$NFT_NAME.tm_ratelimit.json" ;;
    *) exit 1 ;;
esac
[ -f "$f" ] || { echo "Error: No such file or directory" >&2; exit 1; }
cat "$f"
MOCK
chmod +x "$T/bin/nft"
uc() { PATH="$T/bin:$PATH" TCTL_ROOT="$T/root" tcall trafficctl.ctl "$@" 2>&1; }

for v in 1.0.2 1.1.6; do
    export NFT_DIR="$FIXTURES/nft-$v"

    # ── blocks: the comment prefix on a drop, the v6 half by its comment ────
    export NFT_NAME=odd
    assert_eq "$v blocks: a drop starting tctl_block_, the v6 half by its exact comment" \
        '[{"ip":"192.168.1.7","mac":null},{"ip":"192.168.1.8","mac":null},{"ip":"192.168.1.10","mac":null},{"ip":"192.168.1.12","mac":"aa:aa:aa:aa:aa:12"}]' \
        "$(uc live_blocks | jq -c 'map({ip, mac})')"
    assert_eq "$v blocks: the rule handle comes along" "number" \
        "$(uc live_blocks | jq -r '.[0].handle | type')"
    export NFT_NAME=rules
    assert_eq "$v blocks: both halves of one block, two from before v1.13.2, not a foreign drop rule" \
        '["192.168.1.50","192.168.1.50","192.168.1.51","192.168.1.52"]' "$(uc live_blocks | jq -c 'map(.ip)')"
    assert_eq "$v blocks: a legacy comment comes along as written" '["tctl_block_tg","tctl_block_block_192.168.1.52"]' \
        "$(uc live_blocks | jq -c '[.[] | select(.ip == "192.168.1.51" or .ip == "192.168.1.52") | .comment]')"

    # ── rule records ────────────────────────────────────────────────────────
    export NFT_NAME=rl
    R=$(uc rl_rules)
    assert_eq "$v records: a per-address meter is each, in either listing form" \
        '[{"chain":"dl_br_lan","daddr":"192.168.1.8","each":true,"over":true,"rate_kbit":16384}]' \
        "$(printf '%s' "$R" | jq -c '[.[] | select(.daddr == "192.168.1.8") | {chain, daddr, each, over, rate_kbit}]')"
    assert_eq "$v records: a plain limit is not each" "false" \
        "$(printf '%s' "$R" | jq '.[] | select(.daddr == "192.168.1.5" and .chain == "dl_br_lan") | .each')"
    assert_eq "$v records: counters past 2^32" "5000000000" \
        "$(printf '%s' "$R" | jq '.[] | select(.daddr == "192.168.1.5" and .chain == "dl_br_guest") | .bytes')"
    assert_eq "$v records: the v6 feed rule has no limit" "false" \
        "$(printf '%s' "$R" | jq '.[] | select(.comment == "rl_ratelimit_192_168_1_5_v6") | .limit')"
    assert_eq "$v records: the MAC of the v6 policer" "aa:aa:aa:aa:aa:05" \
        "$(printf '%s' "$R" | jq -r '.[] | select(.comment == "rl_ratelimit_192_168_1_5_ul6") | .mac')"
    assert_eq "$v records: an ip6 set match is no address" "null" \
        "$(printf '%s' "$R" | jq '.[] | select(.comment == "rl_ratelimit_192_168_1_5_dl6") | .daddr')"
    assert_eq "$v lookup: a /32 rule is the host's" "5000" \
        "$(uc rl_rate_kbit '[{"over":true,"daddr":"192.168.1.5/32","rate_kbit":5000}]' '"192.168.1.5"')"

    # ── stats and the Rules tab agree on the mode ───────────────────────────
    export NFT_NAME=subnet
    assert_eq "$v stats: a per-device subnet limit is each" "each" \
        "$(PATH="$T/bin:$PATH" TCTL_ROOT="$T/root" tctl ratelimit-stats | jq -r '.[] | select(.ip == "192.168.20.0/24") | .mode')"

    export NFT_NAME=none
    assert_eq "$v: a missing table reads as no rules" "[]" "$(uc rl_rules | jq -c .)"
done

# nft steps its units by 1024; kbit is SI, rounded as the shell awk did.
for c in "625000 bytes 5000" "1000 kbytes 8192" "1 mbytes 8389" "512 bytes 4" "1 gbytes 8589935" "5 bits 0"; do
    set -- $c
    assert_eq "rate: $1 $2/second" "$3" "$(uc rate_kbit "$1" "\"$2\"")"
done

printf '#!/bin/sh\necho "{not json"\n' > "$T/bin/nft"
assert_eq "output that is not JSON reads as no rules" "[]" "$(uc nft_rules '["table","netdev","tm_ratelimit"]' | jq -c .)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
