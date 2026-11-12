#!/bin/bash
# Tests for trafficctl-block.sh / trafficctl-unblock.sh — previously had NO
# test coverage at all. Fakes nft/ip/conntrack/uci on PATH and runs the real
# scripts (test_direction.sh's pattern): source-line redirected via sed, then
# assert on the nft/conntrack calls the fakes recorded and the JSON emitted.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

BLOCK_SH="$TMPDIR/block.sh"
UNBLOCK_SH="$TMPDIR/unblock.sh"
sed "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" "$BIN/trafficctl-block.sh" > "$BLOCK_SH"
sed "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" "$BIN/trafficctl-unblock.sh" > "$UNBLOCK_SH"

NFT_LOG="$TMPDIR/nft.log"
CONNTRACK_LOG="$TMPDIR/conntrack.log"
BLOCKED_STATE="$TMPDIR/blocked_ips.txt"
: > "$BLOCKED_STATE"

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    -4\ addr\ show*) echo "inet 192.168.1.254/24" ;;
    *) exit 1 ;;
esac
MOCK
cat > "$MOCKBIN/conntrack" <<MOCK
#!/bin/sh
echo "\$*" >> "$CONNTRACK_LOG"
exit 0
MOCK
# nft mock: an insert with saddr X adds X to the state file; a delete removes
# only the handle whose comment carries the exact target IP; list dumps only
# addresses in the state file, each with its own distinguishable comment/handle.
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
echo "\$*" >> "$NFT_LOG"
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    insert\ rule*)
        ip=\$(printf '%s' "\$*" | sed -n 's/.*saddr \([0-9.]*\).*/\1/p')
        echo "\$ip" >> "$BLOCKED_STATE"
        ;;
    -a\ list\ chain\ inet\ fw4\ forward)
        n=0
        while read -r ip; do
            [ -z "\$ip" ] && continue
            n=\$((n + 1))
            slug=\$(printf '%s' "\$ip" | tr '.' '_')
            printf '\tip saddr %s counter packets 1 bytes 1 drop comment "tctl_block_%s" # handle %d\n' "\$ip" "\$slug" "\$n"
        done < "$BLOCKED_STATE"
        ;;
    list\ chain\ inet\ fw4\ forward)
        while read -r ip; do
            [ -z "\$ip" ] && continue
            slug=\$(printf '%s' "\$ip" | tr '.' '_')
            printf 'ip saddr %s counter packets 1 bytes 1 drop comment "tctl_block_%s"\n' "\$ip" "\$slug"
        done < "$BLOCKED_STATE"
        ;;
    delete\ rule*)
        h=\$(printf '%s' "\$*" | awk '{print \$NF}')
        n=0
        : > "$TMPDIR/blocked_ips.new"
        while read -r ip; do
            [ -z "\$ip" ] && continue
            n=\$((n + 1))
            if [ "\$n" != "\$h" ]; then echo "\$ip" >> "$TMPDIR/blocked_ips.new"; fi
        done < "$BLOCKED_STATE"
        mv "$TMPDIR/blocked_ips.new" "$BLOCKED_STATE"
        ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN"/*

run_block() { : > "$NFT_LOG"; PATH="$MOCKBIN:$PATH" sh "$BLOCK_SH" "$@" 2>&1; }
run_unblock() { : > "$NFT_LOG"; PATH="$MOCKBIN:$PATH" sh "$UNBLOCK_SH" "$@" 2>&1; }

# ── usage / validation ──────────────────────────────────────────────────────

OUT=$(run_block)
assert_contains "block: missing ip rejected" '"ok":false' "$OUT"

OUT=$(run_block 'bad;ip')
assert_contains "block: invalid ip rejected" '"ok":false' "$OUT"
assert_contains "block: invalid ip rejected — no nft calls made" "" "$(cat "$NFT_LOG")"

OUT=$(run_block 192.168.1.254)
assert_contains "block: cannot block the router's own LAN address" "cannot block the router itself" "$OUT"

# ── block adds a drop rule and flushes conntrack ────────────────────────────

: > "$BLOCKED_STATE"
OUT=$(run_block 192.168.1.50)
assert_contains "block: reports ok" '"ok":true' "$OUT"
NFT=$(cat "$NFT_LOG")
assert_contains "block: inserts a drop rule for the target saddr" "saddr 192.168.1.50" "$NFT"
assert_contains "block: rule carries the address-derived comment" "tctl_block_192_168_1_50" "$NFT"
CT=$(cat "$CONNTRACK_LOG")
assert_contains "block: flushes conntrack entries as source" "-D -s 192.168.1.50" "$CT"
assert_contains "block: flushes conntrack entries as destination" "-D -d 192.168.1.50" "$CT"

# ── blocking an already-blocked address is idempotent (reports ok, no dup) ──

OUT=$(run_block 192.168.1.50)
assert_contains "block: already-blocked address reports ok without erroring" \
    '"ok":true' "$OUT"
assert_contains "block: already-blocked message says so" "already blocked" "$OUT"

# ── self-block (TCTL_SRC == target) gets a distinct message ────────────────

: > "$BLOCKED_STATE"
OUT=$(PATH="$MOCKBIN:$PATH" TCTL_SRC=192.168.1.77 sh "$BLOCK_SH" 192.168.1.77 2>&1)
assert_contains "block: self-block preserves LuCI access message" "LuCI access preserved" "$OUT"

# ── unblock removes only the target's rule ──────────────────────────────────

: > "$BLOCKED_STATE"
printf '192.168.1.10\n192.168.1.1\n' > "$BLOCKED_STATE"
OUT=$(run_unblock 192.168.1.1)
assert_contains "unblock: reports ok" '"ok":true' "$OUT"
REMAINING=$(cat "$BLOCKED_STATE")
assert_contains "unblock: leaves 192.168.1.10 blocked" "192.168.1.10" "$REMAINING"
EXACT_MATCH=$(awk '$0 == "192.168.1.1"' "$BLOCKED_STATE")
assert_eq "unblock: 192.168.1.1 no longer present as its own exact entry" "" "$EXACT_MATCH"

OUT=$(run_unblock 'bad;ip')
assert_contains "unblock: invalid ip rejected" '"ok":false' "$OUT"


# ── fw4-reload restore hook ────────────────────────────────────────────────
# Blocks live in inet fw4 forward, so a firewall reload drops them while
# rules.json and the UI still say blocked. The include script must put only
# the block records back, leave already-present rules alone, and do nothing
# when persist_rules is off.

RESTORE_SRC="$BIN/trafficctl-fw-restore.sh"
assert_eq "the restore hook ships in the package tree" "1" \
    "$([ -x "$RESTORE_SRC" ] && echo 1 || echo 0)"
assert_contains "the restore hook sources the firewall helpers" \
    ". /usr/libexec/trafficctl/trafficctl-fw.sh" "$(cat "$RESTORE_SRC")"
assert_contains "the restore hook is gated on persist_rules" \
    "tctl_persist_enabled" "$(cat "$RESTORE_SRC")"
assert_contains "the restore hook uses tctl_block_add, not the block script" \
    "tctl_block_add" "$(cat "$RESTORE_SRC")"
assert_not_contains "the restore hook does not invoke trafficctl-block.sh" \
    "/usr/libexec/trafficctl/trafficctl-block.sh" "$(cat "$RESTORE_SRC")"
assert_not_contains "the restore hook does not replay rate limits" \
    "tctl_ratelimit_add" "$(cat "$RESTORE_SRC")"
assert_not_contains "the restore hook does not replay port-forward pauses" \
    "trafficctl-portfw.sh" "$(cat "$RESTORE_SRC")"

RULES="$TMPDIR/rules.json"
FW="$TMPDIR/trafficctl-fw.sh"
RESTORE="$TMPDIR/trafficctl-fw-restore.sh"
sed -e "s|TCTL_RULES_FILE=\"/etc/trafficctl/rules.json\"|TCTL_RULES_FILE=\"$RULES\"|" \
    "$BIN/trafficctl-fw.sh" > "$FW"
sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FW|" \
    "$RESTORE_SRC" > "$RESTORE"
chmod +x "$RESTORE"

# jsonfilter: emit the ip of every type=block record, one per line.
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
file=""; expr=""
while [ $# -gt 0 ]; do
    case "$1" in
        -i) file="$2"; shift 2 ;;
        -e) expr="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
[ "$expr" = '@[@.type="block"].ip' ] || exit 0
[ -f "$file" ] || exit 1
# The production file is a single-line array of objects; split on "},{"
# the same way a JSON-aware reader would isolate records.
tr '}' '\n' < "$file" | while read -r rec; do
    case "$rec" in
        *'"type":"block"'*)
            printf '%s\n' "$rec" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p'
            ;;
    esac
done
MOCK
chmod +x "$MOCKBIN/jsonfilter"

printf '%s' > "$TMPDIR/persist" '1'
cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
case "\$*" in
    *trafficctl.main.persist_rules*) cat "$TMPDIR/persist" ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/uci"

LOGGER_LOG="$TMPDIR/logger.log"
: > "$LOGGER_LOG"
cat > "$MOCKBIN/logger" <<MOCK
#!/bin/sh
echo "\$*" >> "$LOGGER_LOG"
MOCK
chmod +x "$MOCKBIN/logger"

# A mixed file: two blocks, one rate limit, one garbage address, one pfw pause.
# Only the two valid blocks must be restored.
printf '%s\n' '[{"type":"block","ip":"192.0.2.10","param":"lab"},{"type":"ratelimit","ip":"192.0.2.20","param":"1000"},{"type":"block","ip":"not-an-ip","param":"x"},{"type":"block","ip":"192.0.2.11","param":"lab"},{"type":"pfw_pause","ip":"wan/tcp/192.0.2.30/80","param":"1"}]' > "$RULES"

: > "$NFT_LOG"
: > "$BLOCKED_STATE"
: > "$LOGGER_LOG"
out=$(PATH="$MOCKBIN:$PATH" sh "$RESTORE" 2>&1)
assert_eq "restore: writes nothing to stdout" "" "$out"
assert_contains "restore: inserts the first block" "saddr 192.0.2.10" "$(cat "$NFT_LOG")"
assert_contains "restore: inserts the second block" "saddr 192.0.2.11" "$(cat "$NFT_LOG")"
assert_not_contains "restore: does not insert the rate-limited address" "192.0.2.20" "$(cat "$NFT_LOG")"
assert_not_contains "restore: does not insert an invalid address" "not-an-ip" "$(cat "$NFT_LOG")"
assert_not_contains "restore: does not insert a port-forward target" "192.0.2.30" "$(cat "$NFT_LOG")"
assert_eq "restore: both valid blocks are now in the nft state" "2" \
    "$(wc -l < "$BLOCKED_STATE" | tr -d ' ')"

# Idempotent: a second run must not insert again.
: > "$NFT_LOG"
PATH="$MOCKBIN:$PATH" sh "$RESTORE" >/dev/null 2>&1
assert_not_contains "restore: a second run does not insert an already-blocked address" \
    "insert rule" "$(cat "$NFT_LOG")"
assert_eq "restore: still exactly two blocked addresses after a second run" "2" \
    "$(wc -l < "$BLOCKED_STATE" | tr -d ' ')"

# persist_rules off: touch nothing.
printf '%s' > "$TMPDIR/persist" '0'
: > "$NFT_LOG"
: > "$BLOCKED_STATE"
PATH="$MOCKBIN:$PATH" sh "$RESTORE" >/dev/null 2>&1
assert_not_contains "restore: persist_rules=0 inserts no rules" "insert rule" "$(cat "$NFT_LOG")"

# Missing or empty rules file: also a no-op, even with persist on.
printf '%s' > "$TMPDIR/persist" '1'
rm -f "$RULES"
: > "$NFT_LOG"
PATH="$MOCKBIN:$PATH" sh "$RESTORE" >/dev/null 2>&1
assert_not_contains "restore: a missing rules.json inserts no rules" "insert rule" "$(cat "$NFT_LOG")"
: > "$RULES"
PATH="$MOCKBIN:$PATH" sh "$RESTORE" >/dev/null 2>&1
assert_not_contains "restore: an empty rules.json inserts no rules" "insert rule" "$(cat "$NFT_LOG")"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
