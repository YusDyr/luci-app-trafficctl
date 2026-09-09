#!/bin/bash
# Tests for the REAL trafficctl-bytes-nft.sh nft-map byte counter.
#
# The old version of this file pasted the awk program into the test body and
# ran it directly against synthetic input — so a change to the actual script
# (trafficctl-bytes-nft.sh) was invisible to the suite. This version puts a
# fake `nft` on PATH and runs the real script end to end, the same pattern as
# test_direction.sh.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/local/bin"

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

# Point the script's `. /usr/local/bin/trafficctl-fw.sh` at the real fw lib.
SCRIPT="$TMPDIR/bytes-nft.sh"
sed "s|/usr/local/bin/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" \
    "$BIN/trafficctl-bytes-nft.sh" > "$SCRIPT"

BYTES_IN_FILE="$TMPDIR/bytes_in.txt"
BYTES_OUT_FILE="$TMPDIR/bytes_out.txt"

cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    "list chain inet trafficctl_mon mon_forward") exit 0 ;;
    "list map inet trafficctl_mon bytes_in") cat "$BYTES_IN_FILE" 2>/dev/null ;;
    "list map inet trafficctl_mon bytes_out") cat "$BYTES_OUT_FILE" 2>/dev/null ;;
    add\ *) exit 0 ;;
    *) exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/nft"

# `command` and `uci` are stubbed generically; the fw lib only needs uci to
# fail quietly so it doesn't matter it's not present as a real device.
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci"

run_bytes_nft() {
    PATH="$MOCKBIN:$PATH" sh "$SCRIPT" 2>&1
}

# ── single host ──────────────────────────────────────────────────────────────

cat > "$BYTES_IN_FILE" <<'EOF'
table inet trafficctl_mon {
    map bytes_in {
        type ipv4_addr : counter
        flags dynamic
        elements = { 192.168.0.100 : counter packets 584 bytes 892341 }
    }
}
EOF
cat > "$BYTES_OUT_FILE" <<'EOF'
table inet trafficctl_mon {
    map bytes_out {
        type ipv4_addr : counter
        flags dynamic
        elements = { 192.168.0.100 : counter packets 312 bytes 45678 }
    }
}
EOF

OUT=$(run_bytes_nft)
assert_eq "single host: bytes_in" \
    "892341" "$(echo "$OUT" | grep -o '"bytes_in":[0-9]*' | cut -d: -f2)"
assert_eq "single host: bytes_out" \
    "45678" "$(echo "$OUT" | grep -o '"bytes_out":[0-9]*' | cut -d: -f2)"
assert_eq "single host: ip field" \
    "192.168.0.100" "$(echo "$OUT" | grep -o '"ip":"[^"]*"' | cut -d'"' -f4)"

# ── multiple hosts ───────────────────────────────────────────────────────────

cat > "$BYTES_IN_FILE" <<'EOF'
elements = { 192.168.0.10 : counter packets 100 bytes 10000,
             192.168.0.20 : counter packets 200 bytes 20000 }
EOF
cat > "$BYTES_OUT_FILE" <<'EOF'
elements = { 192.168.0.10 : counter packets 50 bytes 5000,
              192.168.0.20 : counter packets 80 bytes 8000 }
EOF

OUT=$(run_bytes_nft)
assert_eq "multi host: .10 present" "1" "$(echo "$OUT" | grep -c '192\.168\.0\.10')"
assert_eq "multi host: .20 present" "1" "$(echo "$OUT" | grep -c '192\.168\.0\.20')"
assert_eq "multi host: .10 bytes_in"  "10000" "$(echo "$OUT" | grep -o '"ip":"192\.168\.0\.10","bytes_in":[0-9]*' | grep -o '[0-9]*$')"
assert_eq "multi host: .20 bytes_out" "8000"  "$(echo "$OUT" | grep -o '"ip":"192\.168\.0\.20","bytes_in":[0-9]*,"bytes_out":[0-9]*' | grep -o '[0-9]*$')"

# ── host only in bytes_out (destination-only traffic) ───────────────────────

cat > "$BYTES_IN_FILE" <<'EOF'
table inet trafficctl_mon { map bytes_in { type ipv4_addr : counter; flags dynamic } }
EOF
cat > "$BYTES_OUT_FILE" <<'EOF'
elements = { 192.168.0.50 : counter packets 10 bytes 9999 }
EOF

OUT=$(run_bytes_nft)
assert_eq "out-only host: present in output" "1" "$(echo "$OUT" | grep -c '192\.168\.0\.50')"
assert_eq "out-only host: bytes_in is 0"     "0" "$(echo "$OUT" | grep -o '"bytes_in":[0-9]*' | cut -d: -f2)"
assert_eq "out-only host: bytes_out"      "9999" "$(echo "$OUT" | grep -o '"bytes_out":[0-9]*' | cut -d: -f2)"

# ── both maps empty → empty JSON array ───────────────────────────────────────

: > "$BYTES_IN_FILE"
: > "$BYTES_OUT_FILE"
OUT=$(run_bytes_nft)
assert_eq "both maps empty → []" "[]" "$OUT"

# ── trailing comma variant (nft sometimes emits it) ─────────────────────────

cat > "$BYTES_IN_FILE" <<'EOF'
elements = { 192.168.0.7 : counter packets 1 bytes 100, }
EOF
cat > "$BYTES_OUT_FILE" <<'EOF'
elements = { 192.168.0.7 : counter packets 1 bytes 50, }
EOF
OUT=$(run_bytes_nft)
assert_eq "trailing comma: bytes_in"  "100" "$(echo "$OUT" | grep -o '"bytes_in":[0-9]*' | cut -d: -f2)"
assert_eq "trailing comma: bytes_out"  "50" "$(echo "$OUT" | grep -o '"bytes_out":[0-9]*' | cut -d: -f2)"

# ── output shape ─────────────────────────────────────────────────────────────

cat > "$BYTES_IN_FILE" <<'EOF'
elements = { 192.168.0.100 : counter packets 584 bytes 892341 }
EOF
cat > "$BYTES_OUT_FILE" <<'EOF'
elements = { 192.168.0.100 : counter packets 312 bytes 45678 }
EOF
OUT=$(run_bytes_nft)
assert_eq "output starts with ["  "[" "$(echo "$OUT" | cut -c1)"
assert_eq "output ends with ]"    "]" "$(echo "$OUT" | rev | cut -c1)"

# ── rule orientation: which map each direction is keyed by ──────────────────
#
# The maps used to be keyed the wrong way round: bytes_in by `ip saddr`, which
# is traffic the device SENT, i.e. its upload — while trafficctl-bytes.sh (the
# conntrack backend this script substitutes for), docs/API.md and the DL/UL
# columns in status.js all define bytes_in as download. The same RPC call
# returned DL and UL swapped depending on the router's offload mode.
#
# These tests pin the orientation at the point where the rules are created,
# not where the output is parsed, so a future swap in the awk cannot make them
# pass while the counters are wrong.

NFT_LOG="$TMPDIR/nft.log"
CHAIN_FILE="$TMPDIR/chain.txt"

cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
echo "\$*" >> "$NFT_LOG"
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    "list chain inet trafficctl_mon mon_forward") cat "$CHAIN_FILE" 2>/dev/null ;;
    "list map inet trafficctl_mon bytes_in") cat "$BYTES_IN_FILE" 2>/dev/null ;;
    "list map inet trafficctl_mon bytes_out") cat "$BYTES_OUT_FILE" 2>/dev/null ;;
    *) exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/nft"

cat > "$BYTES_IN_FILE" <<'EOF'
elements = { 192.168.0.100 : counter packets 584 bytes 892341 }
EOF
cat > "$BYTES_OUT_FILE" <<'EOF'
elements = { 192.168.0.100 : counter packets 312 bytes 45678 }
EOF

# fresh install — no chain yet
: > "$CHAIN_FILE"
: > "$NFT_LOG"
run_bytes_nft >/dev/null

assert_eq "fresh: bytes_in is keyed by daddr (download)" "1" \
    "$(grep -c 'add rule inet trafficctl_mon mon_forward update @bytes_in { ip daddr counter }' "$NFT_LOG")"
assert_eq "fresh: bytes_out is keyed by saddr (upload)" "1" \
    "$(grep -c 'add rule inet trafficctl_mon mon_forward update @bytes_out { ip saddr counter }' "$NFT_LOG")"
assert_eq "fresh: no inverted bytes_in rule" "0" \
    "$(grep -c '@bytes_in { ip saddr counter }' "$NFT_LOG")"

# upgrade from a router that already carries the old, inverted rules.
# The creation gate must NOT accept them: a looser check ("does any rule
# mention saddr?") matches the broken chain too, so the corrected rules would
# only ever reach fresh installs.
cat > "$CHAIN_FILE" <<'EOF'
table inet trafficctl_mon {
	chain mon_forward {
		type filter hook forward priority -200; policy accept;
		update @bytes_in { ip saddr counter }
		update @bytes_out { ip daddr counter }
	}
}
EOF
: > "$NFT_LOG"
run_bytes_nft >/dev/null

assert_eq "upgrade: stale table is dropped" "1" \
    "$(grep -c '^delete table inet trafficctl_mon$' "$NFT_LOG")"
assert_eq "upgrade: corrected bytes_in rule is installed" "1" \
    "$(grep -c 'update @bytes_in { ip daddr counter }' "$NFT_LOG")"

# already correct — must be a no-op, or every poll would delete and rebuild
# the table and the counters would never accumulate.
cat > "$CHAIN_FILE" <<'EOF'
table inet trafficctl_mon {
	chain mon_forward {
		type filter hook forward priority -200; policy accept;
		update @bytes_in { ip daddr counter }
		update @bytes_out { ip saddr counter }
	}
}
EOF
: > "$NFT_LOG"
run_bytes_nft >/dev/null

assert_eq "correct chain: table is not dropped" "0" \
    "$(grep -c '^delete table' "$NFT_LOG")"
assert_eq "correct chain: no rules re-added" "0" \
    "$(grep -c '^add rule' "$NFT_LOG")"

# ── unsupported dynamic counter maps: falls back to conntrack script ────────
# When `nft list map ... bytes_in` fails (kernel lacks dynamic counter maps),
# the script must re-exec trafficctl-bytes.sh instead of returning [] forever.

cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    "list chain inet trafficctl_mon mon_forward") exit 0 ;;
    "list map inet trafficctl_mon bytes_in") exit 1 ;;
    add\ *) exit 0 ;;
    *) exit 0 ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/nft"

FALLBACK_MARK="$TMPDIR/fallback_called"
mkdir -p "$TMPDIR/usr/local/bin"
cat > "$MOCKBIN/../usr/local/bin/trafficctl-bytes.sh" <<MOCK
#!/bin/sh
touch "$FALLBACK_MARK"
echo '[]'
MOCK
# The real script execs the literal absolute path, so redirect it too.
sed -i.bak "s|/usr/local/bin/trafficctl-bytes.sh|$TMPDIR/usr/local/bin/trafficctl-bytes.sh|" "$SCRIPT"
chmod +x "$TMPDIR/usr/local/bin/trafficctl-bytes.sh"

run_bytes_nft >/dev/null
assert_eq "unsupported counter maps: falls back to conntrack script" \
    "yes" "$([ -f "$FALLBACK_MARK" ] && echo yes || echo no)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
