#!/bin/bash
# `trafficctl block` / `trafficctl unblock` (trafficctl-block.sh and
# -unblock.sh are wrappers since the ucode port). Runs the CLI against the
# stateful inet fw4 fake (tests/lib/nft-fw4.uc) with fake ip/conntrack on
# PATH, and asserts on the rules the chain ends up holding, the calls made and
# the JSON replied.

PASS=0
FAIL=0

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/fw4_env.sh
. "$UC_TESTLIB/fw4_env.sh"

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}
assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$1" "$2" "$3"
    fi
}
assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$1" "$2"
    else
        PASS=$((PASS + 1))
    fi
}

fw_cfg 0
echo "1787600000 aa:bb:cc:dd:ee:50 192.168.1.50 phone *" > "$LEASES"
run_block() { fw_clear; fw_run block "$@"; }
run_unblock() { fw_clear; fw_run unblock "$@"; }
handles_deleted() {
    grep -o 'delete rule .* handle [0-9]*' "$NFT_LOG" | awk '{print $NF}' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

# ── usage / validation ──────────────────────────────────────────────────────

OUT=$(run_block)
assert_contains "block: missing ip rejected" '"ok":false' "$OUT"
assert_eq "block: usage exits 1" "1" "$(fw_run block >/dev/null; echo $?)"

OUT=$(run_block 'bad;ip')
assert_contains "block: invalid ip rejected" '"ok":false' "$OUT"
assert_eq "block: invalid ip rejected — no nft calls made" "" "$(cat "$NFT_LOG")"

OUT=$(run_block 192.168.1.254)
assert_contains "block: cannot block the router's own LAN address" "cannot block the router itself" "$OUT"
assert_eq "block: nothing inserted for the router" "" "$(fw_rules)"

# ── block adds a drop rule and flushes conntrack ────────────────────────────

OUT=$(run_block 192.168.1.50)
assert_contains "block: reports ok" '"ok":true' "$OUT"
# The text v1.30 wrote, byte for byte: the readers, the Rules tab and older
# releases' unblock all find a block by it.
assert_eq "block: the v4 and the v6 rule, as v1.30 wrote them" \
    'meta nfproto ipv6 ether saddr aa:bb:cc:dd:ee:50 counter drop comment "tctl_block_192_168_1_50_mac"
ip saddr 192.168.1.50 counter drop comment "tctl_block_192_168_1_50"' "$(fw_rules)"
assert_contains "block: inserted at the top of the chain, ahead of fw4's accepts" \
    "insert rule inet fw4 forward ip saddr 192.168.1.50" "$(cat "$NFT_LOG")"
assert_contains "block: reports IPv6 covered" '"ipv6":true' "$OUT"
CT=$(cat "$CONNTRACK_LOG")
assert_contains "block: flushes conntrack entries as source" "-D -s 192.168.1.50" "$CT"
assert_contains "block: flushes conntrack entries as destination" "-D -d 192.168.1.50" "$CT"

# ── blocking an already-blocked address is idempotent (reports ok, no dup) ──

OUT=$(run_block 192.168.1.50)
assert_contains "block: already-blocked address reports ok without erroring" '"ok":true' "$OUT"
assert_contains "block: already-blocked message says so" "already blocked" "$OUT"
assert_eq "block: no duplicate rule" "2" "$(fw_rules | wc -l | tr -d ' ')"

# A block with a pre-v1.13.2 label is found the same way.
fw_flush
fw_put 'ip saddr 192.168.1.50 counter drop comment "tctl_block_tg"'
assert_contains "block: a legacy-label block counts as blocked" "already blocked" "$(run_block 192.168.1.50)"

# ── self-block (TCTL_SRC == target) gets a distinct message ────────────────

fw_flush
OUT=$(TCTL_SRC=192.168.1.77 fw_run block 192.168.1.77)
assert_contains "block: self-block preserves LuCI access message" "LuCI access preserved" "$OUT"

# ── a failed insert is a failure ────────────────────────────────────────────

fw_flush
OUT=$(NFT_FAIL='^insert rule inet fw4 forward ip saddr' fw_run block 192.168.1.50)
assert_contains "block: nft refusing the rule is ok:false" '"ok":false' "$OUT"
assert_contains "block: and says so" "failed to block 192.168.1.50" "$OUT"

# ── unblock removes only the target's rule ──────────────────────────────────

fw_flush
fw_run block 192.168.1.10 >/dev/null
fw_run block 192.168.1.1 >/dev/null
OUT=$(run_unblock 192.168.1.1)
assert_contains "unblock: reports ok" '"ok":true' "$OUT"
assert_contains "unblock: leaves 192.168.1.10 blocked" "ip saddr 192.168.1.10 " "$(fw_rules)"
assert_not_contains "unblock: 192.168.1.1's rule is gone" "ip saddr 192.168.1.1 " "$(fw_rules)"

OUT=$(run_unblock 'bad;ip')
assert_contains "unblock: invalid ip rejected" '"ok":false' "$OUT"

# Both halves of a block go: the v6 rule carries no address, only its comment.
fw_flush
fw_run block 192.168.1.50 >/dev/null
run_unblock 192.168.1.50 >/dev/null
assert_eq "unblock: the v4 and the v6 rule both removed" "" "$(fw_rules)"

# A rule nft refuses to delete is not reported as removed.
fw_run block 192.168.1.50 >/dev/null
OUT=$(NFT_FAIL='^delete rule' fw_run unblock 192.168.1.50)
assert_contains "unblock: a failed delete is ok:false" '"ok":false' "$OUT"
fw_flush

# ── unblock removes a block written before v1.13.2 ──────────────────────────
# Its comment carries the caller's label, not the address. The Rules tab lists
# it (ctl.live_blocks) and unblocks with an empty label, so the label-derived
# guess (tctl_block_block_<ip>) misses a block placed from Telegram
# (tctl_block_tg) or with a label typed in the UI. v1.30.0 reported success
# and left the rule in place.
fw_put 'ip saddr 192.168.1.40 counter packets 1 bytes 1 drop comment "tctl_block_tg"'
fw_put 'ip saddr 192.168.1.41 counter packets 1 bytes 1 drop comment "tctl_block_kids_tablet"'
fw_put 'ip saddr 192.168.1.4 counter packets 1 bytes 1 drop comment "tctl_block_tg"'
fw_put 'ip saddr 192.168.1.40 counter packets 1 bytes 1 drop comment "someone_else"'
fw_put 'ip saddr 192.168.1.40 counter packets 1 bytes 1 accept comment "tctl_block_note"'
OUT=$(run_unblock 192.168.1.40 "")
assert_contains "unblock, legacy label: reports ok" '"ok":true' "$OUT"
assert_eq "unblock, legacy label: deletes the Telegram-placed rule, nothing else" "1" "$(handles_deleted)"
run_unblock 192.168.1.41 "" >/dev/null
assert_eq "unblock, legacy label: a label typed in the UI" "2" "$(handles_deleted)"
# The bot passes its label. The shell deleted every rule commented
# tctl_block_tg, so unblocking one device lifted 192.168.1.4's block too.
run_unblock 192.168.1.40 tg >/dev/null
assert_eq "unblock with the label tg: another device's tg block stays" "" "$(handles_deleted)"
assert_contains "unblock with the label tg: 192.168.1.4 still blocked" 'ip saddr 192.168.1.4 ' "$(fw_rules)"
# The label-named rule from before v1.13.2, removed through the label.
fw_flush
fw_put 'ip saddr 192.168.1.42 counter drop comment "tctl_block_block_192.168.1.42"'
run_unblock 192.168.1.42 >/dev/null
assert_eq "unblock: the label-derived comment of v1.13.1 and older" "" "$(fw_rules)"

# ── regressions ─────────────────────────────────────────────────────────────
# Rule matching is anchored: with only 192.168.1.10 blocked, an unanchored
# match on "192.168.1.1" read that rule as .1's.
ctl() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.ctl "$@" 2>&1; }
fw_flush
fw_put 'ip saddr 192.168.1.10 counter packets 3 bytes 300 drop comment "tctl_block_192_168_1_10"'
assert_eq "is_blocked: only .10 blocked, 192.168.1.1 is NOT blocked" "false" "$(ctl is_blocked '"192.168.1.1"')"
assert_eq "is_blocked: only .10 blocked, 192.168.1.10 IS blocked" "true" "$(ctl is_blocked '"192.168.1.10"')"

# The comment comes from the target, never from the caller's label: LuCI
# (empty label, i.e. block_<ip>) and the bot (label tg) used to write
# different comments, and neither could remove the other's block while both
# reported success.
assert_eq "block comment: from the address alone" "tctl_block_192_168_1_20" "$(ctl block_comment '"192.168.1.20"')"
fw_flush
OUT=$(fw_run block 192.168.1.20 "")
assert_contains "block via LuCI (empty label) succeeds" '"ok":true' "$OUT"
OUT=$(fw_run unblock 192.168.1.20 tg)
assert_contains "unblock via the Telegram path (label tg) succeeds against a LuCI-placed block" '"ok":true' "$OUT"
assert_eq "unblock via the Telegram path actually removed the rule" "" "$(fw_rules)"
fw_run block 192.168.1.20 tg >/dev/null
assert_contains "block via the bot writes the same comment" '"tctl_block_192_168_1_20"' "$(fw_rules)"
fw_flush

# ── Qualcomm NSS (issue #81) ────────────────────────────────────────────────
# An accelerated flow never meets the Linux stack: the block is installed and
# does nothing for it, so the reply says so, and the flows ECM holds are
# defuncted so they come back through the rule. A router with acceleration
# stopped is not told its block is broken.
ECM="$ROOT/sys/kernel/debug/ecm"
mkdir -p "$ECM/ecm_db"
: > "$ECM/ecm_db/defunct_all"
fw_flush
OUT=$(fw_run block 192.168.1.50)
assert_contains "nss active: reported" '"nss":"active"' "$OUT"
assert_contains "nss active: the message says the block is not enforced" "NOT ENFORCED" "$OUT"
assert_eq "nss active: accelerated flows are defuncted" "1" "$(cat "$ECM/ecm_db/defunct_all")"
echo 1 > "$ECM/front_end_ipv4_stop"
echo 1 > "$ECM/front_end_ipv6_stop"
fw_flush
OUT=$(fw_run block 192.168.1.50)
assert_contains "nss stopped: reported" '"nss":"stopped"' "$OUT"
assert_not_contains "nss stopped: no warning" "NOT ENFORCED" "$OUT"
rm -r "$ROOT/sys"
fw_flush

# ── unblock with a shared legacy label lifts only that device's block ───────
# Every device blocked from Telegram before v1.13.2 got the comment
# tctl_block_tg, and a delete by comment alone matches them all. v1.30.5 also
# removed tctl_block_<label>, so unblocking 192.168.1.40 from Telegram (label
# tg) lifted 192.168.1.4's block too. The other device's IPv6 half carries its
# own comment and stays as well.
fw_flush
fw_put 'ip saddr 192.168.1.40 counter packets 1 bytes 1 drop comment "tctl_block_tg"'
fw_put 'ip saddr 192.168.1.4 counter packets 1 bytes 1 drop comment "tctl_block_tg"'
fw_put 'meta nfproto ipv6 ether saddr aa:bb:cc:dd:ee:04 counter packets 1 bytes 1 drop comment "tctl_block_192_168_1_4_mac"'
fw_put 'ip saddr 192.168.1.41 counter packets 1 bytes 1 drop comment "tctl_block_kids"'
fw_put 'ip saddr 192.168.1.42 counter packets 1 bytes 1 drop comment "tctl_block_kids"'
OUT=$(run_unblock 192.168.1.40 tg)
assert_contains "unblock, shared legacy label: reports ok" '"ok":true' "$OUT"
assert_eq "unblock, shared legacy label: the other tg device stays blocked" "1" "$(handles_deleted)"
assert_contains "unblock, shared legacy label: 192.168.1.4's IPv6 half stays" \
    '"tctl_block_192_168_1_4_mac"' "$(fw_rules)"
run_unblock 192.168.1.41 kids >/dev/null
assert_eq "unblock, shared legacy label: a label typed in the UI" "4" "$(handles_deleted)"
assert_contains "unblock, shared legacy label: 192.168.1.42 still blocked" 'ip saddr 192.168.1.42 ' "$(fw_rules)"
fw_flush

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
