#!/bin/bash
# Tests for the REAL trafficctl-bytes-nft.sh nft byte counter.
#
# A fake `nft` on PATH runs the real script end to end, the same pattern as
# test_direction.sh. The fake serves listings captured from OpenWrt rootfs
# containers, so the parser is pinned to what nft actually prints, not to what
# we think it prints. tests/fixtures/nft-set/<nft version>/ came from
# ghcr.io/openwrt/rootfs x86-64-v22.03.7 (nft 1.0.2) and x86-64-v25.12.4
# (nft 1.1.6), run with --cap-add NET_ADMIN on kernel 6.12: the real script
# built the table, a temporary output chain with the same two rules counted
# pings to four addresses on lo, the chain was deleted, and then
#   bytes_*.txt       nft list set inet trafficctl_mon bytes_*
#   bytes_*.json      nft -j list set inet trafficctl_mon bytes_*
#   table-terse.txt   nft -t list table inet trafficctl_mon
#   expected.json     the script's own output at that moment

PASS=0
FAIL=0

HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../trafficctl/files/usr/libexec/trafficctl"
FIX="$HERE/fixtures/nft-set"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

# One device object per line, sorted: awk's `for (k in a)` order is not
# defined, and differs between busybox, mawk and gawk.
norm() { sed 's/^\[//; s/\]$//; s/},{/}\n{/g' | sort; }

# Point the script's absolute paths at the repository and the scratch dir.
SCRIPT="$TMPDIR/bytes-nft.sh"
FALLBACK_MARK="$TMPDIR/fallback_called"
cat > "$TMPDIR/bytes.sh" <<MOCK
#!/bin/sh
touch "$FALLBACK_MARK"
echo '[]'
MOCK
chmod +x "$TMPDIR/bytes.sh"
sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" \
    -e "s|/usr/libexec/trafficctl/trafficctl-bytes.sh|$TMPDIR/bytes.sh|" \
    "$BIN/trafficctl-bytes-nft.sh" > "$SCRIPT"

# The fake nft. State lives in files so a test can arrange any table:
#   table.txt    what `nft -t list table` prints; absent = no table
#   built.txt    what the table looks like after a successful `nft -f -`
#   build_fails  present = `nft -f -` is refused, as the 1.30 map always was
#   nojson       present = nftables-nojson: `nft -j` fails
#   bytes_in.{txt,json}, bytes_out.{txt,json}   set listings
#   nft.log      every call; nft-f.in the last batch fed to `nft -f -`
ST="$TMPDIR/state"
mkdir -p "$ST"
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
echo "\$*" >> "$ST/nft.log"
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    "-t list table inet trafficctl_mon")
        [ -f "$ST/table.txt" ] || exit 1
        cat "$ST/table.txt" ;;
    "-f -")
        cat > "$ST/nft-f.in"
        [ -f "$ST/build_fails" ] && { echo "Error: Could not process rule: Not supported" >&2; exit 1; }
        cp "$ST/built.txt" "$ST/table.txt" ;;
    "-j list set inet trafficctl_mon "*)
        [ -f "$ST/nojson" ] && { echo "Error: JSON support not compiled-in" >&2; exit 1; }
        cat "$ST/\${6}.json" 2>/dev/null || exit 1 ;;
    "list set inet trafficctl_mon "*)
        cat "$ST/\${5}.txt" 2>/dev/null || exit 1 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/nft"

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci"

reset_state() {   # reset_state <fixture version>
    rm -f "$ST"/*
    cp "$FIX/$1/table-terse.txt" "$ST/built.txt"
    cp "$FIX/$1/table-terse.txt" "$ST/table.txt"
    cp "$FIX/$1"/bytes_*.txt "$FIX/$1"/bytes_*.json "$ST/"
    rm -f "$FALLBACK_MARK"
}

run_bytes_nft() {
    PATH="$MOCKBIN:$PATH" sh "$SCRIPT" 2>/dev/null
}

builds() { grep -c '^-f -$' "$ST/nft.log" 2>/dev/null; }

# ── real listings, both nft versions, JSON and text ─────────────────────────
#
# 1.0.2 is OpenWrt 22.03, 1.1.6 is 25.12. The text form has several elements
# per line, and 1.1.6 wraps them across lines; the 1.30.x parser read one
# element per line and needed the map's " : counter", so it returned [] here.
for v in 1.0.2 1.1.6; do
    for mode in json text; do
        reset_state "$v"
        [ "$mode" = text ] && touch "$ST/nojson"
        OUT=$(run_bytes_nft)
        assert_eq "nft $v ($mode): every device and counter matches" \
            "$(norm < "$FIX/$v/expected.json")" "$(echo "$OUT" | norm)"
        assert_eq "nft $v ($mode): a current table is left alone" "0" "$(builds)"
        assert_eq "nft $v ($mode): no conntrack fallback" "no" \
            "$([ -f "$FALLBACK_MARK" ] && echo yes || echo no)"
    done
    # The fixtures must exercise what they claim to, or the loop above proves
    # nothing about multi-element and wrapped lines.
    assert_eq "fixture $v: text holds several elements on one line" "yes" \
        "$(grep -qE 'counter packets [0-9]+ bytes [0-9]+, [0-9.]+ counter' "$FIX/$v/bytes_in.txt" && echo yes || echo no)"
done
assert_eq "fixture 1.1.6: text wraps elements across lines" "yes" \
    "$(grep -qE '^[[:space:]]+[0-9.]+ counter packets' "$FIX/1.1.6/bytes_in.txt" && echo yes || echo no)"

# ── text corner cases ───────────────────────────────────────────────────────

reset_state 1.1.6
touch "$ST/nojson"
printf 'table inet trafficctl_mon {\n\tset bytes_in {\n\t\ttype ipv4_addr\n\t\tsize 65535\n\t\tflags dynamic\n\t}\n}\n' > "$ST/bytes_in.txt"
echo 'elements = { 192.168.0.50 counter packets 10 bytes 9999 }' > "$ST/bytes_out.txt"
OUT=$(run_bytes_nft)
assert_eq "out-only host: bytes_in is 0, bytes_out kept" \
    '[{"ip":"192.168.0.50","bytes_in":0,"bytes_out":9999,"bytes_tcp":-1,"bytes_udp":-1,"src":"nft","degraded":false}]' "$OUT"

echo 'elements = { 192.168.0.7 counter packets 1 bytes 100, }' > "$ST/bytes_in.txt"
echo 'elements = { 192.168.0.7 counter packets 1 bytes 50, }' > "$ST/bytes_out.txt"
OUT=$(run_bytes_nft)
assert_eq "trailing comma" \
    '[{"ip":"192.168.0.7","bytes_in":100,"bytes_out":50,"bytes_tcp":-1,"bytes_udp":-1,"src":"nft","degraded":false}]' "$OUT"

: > "$ST/bytes_in.txt"
: > "$ST/bytes_out.txt"
assert_eq "both sets empty → []" "[]" "$(run_bytes_nft)"

# ── JSON corner cases ───────────────────────────────────────────────────────

reset_state 1.1.6
# An element with no counter (the set is shared with a rule that does not
# count) must be skipped, not credited with the next element's bytes.
echo '{"nftables": [{"metainfo": {"version": "1.1.6"}}, {"set": {"family": "inet", "name": "bytes_in", "table": "trafficctl_mon", "type": "ipv4_addr", "elem": [{"elem": {"val": "192.168.0.1"}}, {"elem": {"val": "192.168.0.2", "counter": {"packets": 1, "bytes": 77}}}]}}]}' > "$ST/bytes_in.json"
echo '{"nftables": [{"metainfo": {"version": "1.1.6"}}, {"set": {"family": "inet", "name": "bytes_out", "table": "trafficctl_mon", "type": "ipv4_addr", "size": 65535}}]}' > "$ST/bytes_out.json"
OUT=$(run_bytes_nft)
assert_eq "json: element without a counter borrows nothing" \
    '[{"ip":"192.168.0.2","bytes_in":77,"bytes_out":0,"bytes_tcp":-1,"bytes_udp":-1,"src":"nft","degraded":false}]' "$OUT"

# ── what gets built ─────────────────────────────────────────────────────────
#
# Fresh install: no table yet. The batch must declare plain dynamic sets and
# put the counter in the rule. A `: counter` map is what the kernel refuses
# (5.10, 5.15, 6.6 and 6.12 alike).
reset_state 1.1.6
rm -f "$ST/table.txt"
run_bytes_nft >/dev/null
B="$ST/nft-f.in"
assert_eq "fresh: exactly one build" "1" "$(builds)"
assert_eq "fresh: bytes_in is a set" "1" "$(grep -c 'set bytes_in {' "$B")"
assert_eq "fresh: bytes_out is a set" "1" "$(grep -c 'set bytes_out {' "$B")"
assert_eq "fresh: no counter map" "0" "$(grep -cE 'map |: counter' "$B")"
assert_eq "fresh: bytes_in is keyed by daddr (download)" "1" \
    "$(grep -c 'update @bytes_in { ip daddr counter }' "$B")"
assert_eq "fresh: bytes_out is keyed by saddr (upload)" "1" \
    "$(grep -c 'update @bytes_out { ip saddr counter }' "$B")"
assert_eq "fresh: no inverted rule" "0" "$(grep -cE '@bytes_in \{ ip saddr|@bytes_out \{ ip daddr' "$B")"
assert_eq "fresh: hook ahead of the flowtable" "1" \
    "$(grep -c 'type filter hook forward priority -200; policy accept;' "$B")"
# One transaction that replaces the table, so a rebuild can never stack a
# second copy of the rules on top of the first.
assert_eq "fresh: batch replaces the table atomically" \
    "add table inet trafficctl_mon|delete table inet trafficctl_mon|table inet trafficctl_mon {" \
    "$(head -3 "$B" | paste -sd '|' -)"

# ── upgrades: anything but the current layout is rebuilt ────────────────────

upgrade_case() {   # upgrade_case <desc>  (table.txt already arranged)
    : > "$ST/nft.log"
    run_bytes_nft >/dev/null
    assert_eq "upgrade from $1: rebuilt once" "1" "$(builds)"
}

# 1.14 .. 1.30.x meant to build counter maps. No kernel accepted them, but
# should one have, their rules list exactly like the set rules: a gate on the
# rule text alone would keep the map, and the set listing would then fail on
# every poll.
reset_state 1.1.6
cat > "$ST/table.txt" <<'EOF'
table inet trafficctl_mon {
	map bytes_in {
		type ipv4_addr : counter
		size 65535
		flags dynamic
	}

	map bytes_out {
		type ipv4_addr : counter
		size 65535
		flags dynamic
	}

	chain mon_forward {
		type filter hook forward priority -200; policy accept;
		update @bytes_in { ip daddr counter }
		update @bytes_out { ip saddr counter }
	}
}
EOF
upgrade_case "1.30.x counter maps"

# What 1.30.x really left behind: the map add failed, the chain was still
# created, and both rules were refused, leaving an empty chain.
reset_state 1.1.6
printf 'table inet trafficctl_mon {\n\tchain mon_forward {\n\t\ttype filter hook forward priority -200; policy accept;\n\t}\n}\n' > "$ST/table.txt"
upgrade_case "the 1.30.x half-built table"

# Up to 1.13.x: rules keyed the other way round.
reset_state 1.1.6
sed -e 's/@bytes_in { ip daddr/@bytes_in { ip saddr/' \
    -e 's/@bytes_out { ip saddr/@bytes_out { ip daddr/' \
    "$FIX/1.1.6/table-terse.txt" > "$ST/table.txt"
upgrade_case "1.13.x inverted rules"

# A doubled rule double-counts every packet.
reset_state 1.1.6
awk '{ print } /update @bytes_in/ { print }' "$FIX/1.1.6/table-terse.txt" > "$ST/table.txt"
assert_eq "duplicate fixture really holds two bytes_in rules" "2" \
    "$(grep -c 'update @bytes_in' "$ST/table.txt")"
upgrade_case "a duplicated rule"

# ── kernel refuses the table: falls back to conntrack ───────────────────────

reset_state 1.1.6
rm -f "$ST/table.txt"
touch "$ST/build_fails"
run_bytes_nft >/dev/null
assert_eq "unsupported: falls back to the conntrack script" "yes" \
    "$([ -f "$FALLBACK_MARK" ] && echo yes || echo no)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
