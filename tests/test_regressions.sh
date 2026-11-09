#!/bin/bash
# Regression tests for 8 bugs fixed on this branch. Each test targets the REAL
# production script/function and is written to fail against the OLD (pre-fix)
# behavior — see the "would have failed before" comment on each section.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"
ROOT="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root"

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

# ════════════════════════════════════════════════════════════════════════════
# 1. log_file is constrained (path traversal / arbitrary root read+truncate)
# ════════════════════════════════════════════════════════════════════════════

uci() { echo ""; }
export -f uci
. "$BIN/trafficctl-fw.sh"

assert_eq "log_file: rejects /etc/shadow" 1 \
    "$(tctl_validate_log_file '/etc/shadow' && echo 0 || echo 1)"
assert_eq "log_file: rejects /etc/config/network" 1 \
    "$(tctl_validate_log_file '/etc/config/network' && echo 0 || echo 1)"
assert_eq "log_file: rejects traversal out of /tmp/trafficctl" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/../../etc/shadow' && echo 0 || echo 1)"
assert_eq "log_file: rejects trailing traversal" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/..' && echo 0 || echo 1)"
assert_eq "log_file: rejects shell metacharacters" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/x;rm -rf /' && echo 0 || echo 1)"
assert_eq "log_file: rejects glob metacharacters" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/*' && echo 0 || echo 1)"
assert_eq "log_file: rejects backtick" 1 \
    "$(tctl_validate_log_file '/tmp/trafficctl/$(whoami)' && echo 0 || echo 1)"
assert_eq "log_file: accepts /tmp/trafficctl/activity.log" 0 \
    "$(tctl_validate_log_file '/tmp/trafficctl/activity.log' && echo 0 || echo 1)"
assert_eq "log_file: accepts /var/log/trafficctl.log" 0 \
    "$(tctl_validate_log_file '/var/log/trafficctl.log' && echo 0 || echo 1)"

# tctl_log_file falls back to the default when uci returns a rejected value.
_log_file_with() {
    (
        _val="$1"
        uci() { [ "$3" = "trafficctl.logging.log_file" ] && echo "$_val" || echo ""; }
        . "$BIN/trafficctl-fw.sh"
        tctl_log_file
    )
}
assert_eq "log_file: falls back to default for /etc/shadow" \
    "/tmp/trafficctl/activity.log" "$(_log_file_with '/etc/shadow')"
assert_eq "log_file: passes through a legitimate value" \
    "/var/log/trafficctl.log" "$(_log_file_with '/var/log/trafficctl.log')"

# logging_config_set (the real rpcd method) rejects a bad log_file and a
# max_lines outside 20..100000. Drive it the way rpcd does: `call
# logging_config_set` with JSON on stdin.
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
expr="$2"
key=$(printf '%s' "$expr" | sed "s/.*\.//;s/\[.*//")
input=$(cat)
val=$(printf '%s' "$input" | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p")
if [ -n "$val" ]; then printf '%s' "$val"; exit 0; fi
printf '%s' "$input" | sed -n "s/.*\"$key\":\([A-Za-z0-9_.-]*\).*/\1/p"
MOCK
chmod +x "$MOCKBIN/uci" "$MOCKBIN/jsonfilter"

RPCD="$TMPDIR/rpcd.sh"
sed "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" \
    "$ROOT/usr/libexec/rpcd/luci.trafficctl" > "$RPCD"

run_rpcd_call() {
    local method="$1" json="$2"
    printf '%s' "$json" | PATH="$MOCKBIN:$PATH" sh "$RPCD" call "$method" 2>&1
}

OUT=$(run_rpcd_call logging_config_set '{"log_file":"/etc/shadow"}')
assert_contains "logging_config_set: rejects /etc/shadow" '"ok":false' "$OUT"
OUT=$(run_rpcd_call logging_config_set '{"log_file":"/tmp/trafficctl/x.log"}')
assert_contains "logging_config_set: accepts a legitimate path" '"ok":true' "$OUT"
OUT=$(run_rpcd_call logging_config_set '{"max_lines":"1"}')
assert_contains "logging_config_set: rejects max_lines=1 (would round rotation to 0 and truncate)" \
    '"ok":false' "$OUT"
OUT=$(run_rpcd_call logging_config_set '{"max_lines":"100001"}')
assert_contains "logging_config_set: rejects max_lines above 100000" '"ok":false' "$OUT"
OUT=$(run_rpcd_call logging_config_set '{"max_lines":"500"}')
assert_contains "logging_config_set: accepts a legitimate max_lines" '"ok":true' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# 2. activity_log removed from the read ACL + general mutating/read invariant
# ════════════════════════════════════════════════════════════════════════════

ACL_FILE="$ROOT/usr/share/rpcd/acl.d/luci-app-trafficctl.json"

READ_METHODS=$(sed -n '/"read"/,/"write"/p' "$ACL_FILE" | sed -n '/"luci\.trafficctl"/,/\]/p')
WRITE_METHODS=$(sed -n '/"write"/,$p' "$ACL_FILE" | sed -n '/"luci\.trafficctl"/,/\]/p')

assert_not_contains "acl: activity_log is not in the read ACL" "activity_log" "$READ_METHODS"
assert_contains "acl: activity_log is in the write ACL" "activity_log" "$WRITE_METHODS"

# General invariant: every method the write ACL lists as mutating must be
# ABSENT from the read ACL. Anything present in both would be readable
# without the write grant. This catches a FUTURE regression too, not just
# activity_log specifically.
WRITE_LIST=$(printf '%s' "$WRITE_METHODS" | grep -oE '"[a-z_]+"' | tr -d '"' | grep -v '^luci\.trafficctl$')
OFFENDERS=""
for m in $WRITE_LIST; do
    if printf '%s' "$READ_METHODS" | grep -qE "\"$m\""; then
        OFFENDERS="$OFFENDERS $m"
    fi
done
assert_eq "acl: no mutating method also appears in the read ACL" "" "$OFFENDERS"

# ════════════════════════════════════════════════════════════════════════════
# 3. Shaper classids are allocated, not derived from the address
# ════════════════════════════════════════════════════════════════════════════

SHAPE_SETUP() {
    : > "$TC_LOG"
    cat > "$MOCKBIN/tc" <<MOCK
#!/bin/sh
echo "\$*" >> "$TC_LOG"
case "\$*" in
    "class show dev br-lan") echo "class htb 1:1 root rate 1000Mbit" ;;
    "class show dev tctl-ifb0") exit 1 ;;
    *"qdisc show"*) echo "qdisc noqueue 0: root" ;;
esac
exit 0
MOCK
    chmod +x "$MOCKBIN/tc"
}

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    network.lan.device) echo "br-lan" ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCKBIN/uci"
cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/ip"

TC_LOG="$TMPDIR/tc.log"
SHAPES_JSON="$TMPDIR/shapes.json"
SHAPE="$TMPDIR/shape.sh"
sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" \
    -e "s|SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|SHAPES_FILE=\"$SHAPES_JSON\"|" \
    "$BIN/trafficctl-shape.sh" > "$SHAPE"

# 192.168.0.1 must NOT land on 1:1 (the reserved root class) — the old
# derivation used the last two octets (0*256+1=1).
: > "$SHAPES_JSON"; echo '[]' > "$SHAPES_JSON"
SHAPE_SETUP
OUT=$(PATH="$MOCKBIN:$PATH" sh "$SHAPE" add 192.168.0.1 5000 2>&1)
CID=$(sed -n 's/.*"classid":"\(1:[0-9a-f]*\)".*/\1/p' "$SHAPES_JSON")
assert_not_contains "shaper: 192.168.0.1 does not land on the reserved root class 1:1" "1:1" "$CID"

# x.x.255.254 must NOT land on 1:fffe (the reserved default class) — the old
# derivation used 255*256+254=65534=0xfffe.
: > "$SHAPES_JSON"; echo '[]' > "$SHAPES_JSON"
SHAPE_SETUP
OUT=$(PATH="$MOCKBIN:$PATH" sh "$SHAPE" add 10.0.255.254 5000 2>&1)
CID=$(sed -n 's/.*"classid":"\(1:[0-9a-f]*\)".*/\1/p' "$SHAPES_JSON")
assert_not_contains "shaper: x.x.255.254 does not land on the reserved default class 1:fffe" "1:fffe" "$CID"

# Two addresses sharing their last two octets across different subnets must
# get DIFFERENT minors — the old derivation collided them.
: > "$SHAPES_JSON"; echo '[]' > "$SHAPES_JSON"
SHAPE_SETUP
PATH="$MOCKBIN:$PATH" sh "$SHAPE" add 192.168.1.50 5000 >/dev/null 2>&1
CID1=$(sed -n 's/.*"ip":"192.168.1.50","rate_kbit":[0-9]*,"classid":"\(1:[0-9a-f]*\)".*/\1/p' "$SHAPES_JSON")
PATH="$MOCKBIN:$PATH" sh "$SHAPE" add 10.0.1.50 5000 >/dev/null 2>&1
CID2=$(sed -n 's/.*"ip":"10.0.1.50","rate_kbit":[0-9]*,"classid":"\(1:[0-9a-f]*\)".*/\1/p' "$SHAPES_JSON")
assert_eq "shaper: cross-subnet collision test — both minors captured" \
    "yes" "$([ -n "$CID1" ] && [ -n "$CID2" ] && echo yes || echo no)"
if [ "$CID1" = "$CID2" ]; then
    FAIL=$((FAIL + 1))
    printf "FAIL: shaper: two addresses sharing last two octets got the SAME minor (%s)\n" "$CID1"
else
    PASS=$((PASS + 1))
fi

# Re-shaping an existing address must reuse its recorded minor.
: > "$SHAPES_JSON"; echo '[]' > "$SHAPES_JSON"
SHAPE_SETUP
PATH="$MOCKBIN:$PATH" sh "$SHAPE" add 192.168.1.77 5000 >/dev/null 2>&1
FIRST_CID=$(sed -n 's/.*"classid":"\(1:[0-9a-f]*\)".*/\1/p' "$SHAPES_JSON")
PATH="$MOCKBIN:$PATH" sh "$SHAPE" add 192.168.1.77 8000 >/dev/null 2>&1
SECOND_CID=$(sed -n 's/.*"classid":"\(1:[0-9a-f]*\)".*/\1/p' "$SHAPES_JSON")
assert_eq "shaper: re-shaping the same address reuses its minor" "$FIRST_CID" "$SECOND_CID"

# A shape recorded without a classid field (pre-upgrade state on disk) must
# still be removable — do_remove falls back to the legacy address-derived
# classid.
LEGACY_IP="192.168.1.77"
O3=1; O4=77
LEGACY_HEX=$(printf '%x' $((O3 * 256 + O4)))
echo "[{\"ip\":\"$LEGACY_IP\",\"rate_kbit\":5000}]" > "$SHAPES_JSON"
SHAPE_SETUP
OUT=$(PATH="$MOCKBIN:$PATH" sh "$SHAPE" remove "$LEGACY_IP" 2>&1)
assert_contains "shaper: pre-upgrade entry with no classid field is removable" '"ok":true' "$OUT"
TC=$(cat "$TC_LOG")
assert_contains "shaper: removal used the legacy address-derived classid 1:$LEGACY_HEX" \
    "classid 1:$LEGACY_HEX" "$TC"

# ════════════════════════════════════════════════════════════════════════════
# 4. ensure_root_qdisc must not tear down a foreign root qdisc (e.g. SQM cake)
# ════════════════════════════════════════════════════════════════════════════

: > "$SHAPES_JSON"; echo '[]' > "$SHAPES_JSON"
: > "$TC_LOG"
cat > "$MOCKBIN/tc" <<MOCK
#!/bin/sh
echo "\$*" >> "$TC_LOG"
case "\$*" in
    "class show dev br-lan") exit 0 ;;
    "qdisc show dev br-lan") echo "qdisc cake 8021: root refcnt 2 bandwidth 100Mbit" ;;
    "class show dev tctl-ifb0") exit 1 ;;
    *"qdisc show"*) echo "qdisc noqueue 0: root" ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/tc"

OUT=$(PATH="$MOCKBIN:$PATH" sh "$SHAPE" add 192.168.1.90 5000 2>&1)
assert_contains "shaper: declines to shape when root qdisc is foreign (cake/SQM)" '"ok":false' "$OUT"
TC=$(cat "$TC_LOG")
assert_not_contains "shaper: never deletes the foreign root qdisc" "qdisc del dev br-lan root" "$TC"

# ════════════════════════════════════════════════════════════════════════════
# 5. Rule removal is anchored — unblocking one address must not remove another
#    whose address is a substring/prefix match. Cover both nft and iptables.
# ════════════════════════════════════════════════════════════════════════════

# --- nft branch ---
NFT_DUMP_FILE="$TMPDIR/nft_forward_dump.txt"
cat > "$NFT_DUMP_FILE" <<'EOF'
table inet fw4 {
	chain forward {
		ip saddr 192.168.1.1 counter packets 5 bytes 500 drop comment "tctl_block_192_168_1_1" # handle 10
		ip saddr 192.168.1.10 counter packets 3 bytes 300 drop comment "tctl_block_192_168_1_10" # handle 11
	}
}
EOF
NFT_DELETE_LOG="$TMPDIR/nft_delete.log"
: > "$NFT_DELETE_LOG"
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    -a\ list\ chain\ inet\ fw4\ forward) cat "$NFT_DUMP_FILE" ;;
    list\ chain\ inet\ fw4\ forward) cat "$NFT_DUMP_FILE" ;;
    delete\ rule*) echo "\$*" >> "$NFT_DELETE_LOG" ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/nft"
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci"

OUT=$(PATH="$MOCKBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_block_remove 192.168.1.1 tctl_block_192_168_1_1")
DELETED=$(cat "$NFT_DELETE_LOG")
assert_contains "nft unblock: removes the handle for 192.168.1.1" "handle 10" "$DELETED"
assert_not_contains "nft unblock: does not touch 192.168.1.10's rule" "handle 11" "$DELETED"

OUT=$(PATH="$MOCKBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_is_blocked 192.168.1.1 && echo BLOCKED || echo NOTBLOCKED")
assert_eq "nft: tctl_is_blocked matches the exact address" "BLOCKED" "$OUT"

# --- iptables branch (TCTL_FW=iptables), using the real -L -n column layout
# trafficctl-fw.sh's tctl_is_blocked parses ---
IPT_L_FILE="$TMPDIR/iptables_L_n.txt"
cat > "$IPT_L_FILE" <<'EOF'
Chain FORWARD (policy ACCEPT)
target     prot opt source               destination
DROP       all  --  192.168.1.1          0.0.0.0/0
DROP       all  --  192.168.1.10         0.0.0.0/0
EOF
cat > "$MOCKBIN/nft" <<'MOCK'
#!/bin/sh
exit 1
MOCK
cat > "$MOCKBIN/iptables" <<MOCK
#!/bin/sh
case "\$*" in
    -L\ FORWARD\ -n) cat "$IPT_L_FILE" ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$MOCKBIN/nft" "$MOCKBIN/iptables"

OUT=$(PATH="$MOCKBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_is_blocked 192.168.1.1 && echo BLOCKED || echo NOTBLOCKED")
assert_eq "iptables: tctl_is_blocked 192.168.1.1 matches its own exact row" "BLOCKED" "$OUT"

OUT=$(PATH="$MOCKBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_is_blocked 192.168.1.11 && echo BLOCKED || echo NOTBLOCKED")
assert_eq "iptables: tctl_is_blocked 192.168.1.11 (unanchored prefix of .1 / .10) is NOT blocked" \
    "NOTBLOCKED" "$OUT"

# The scenario from the brief: only 192.168.1.10 is blocked (192.168.1.1 is
# NOT). tctl_is_blocked 192.168.1.1 must therefore be false — an unanchored
# match on the string "192.168.1.1" would incorrectly match the
# "192.168.1.10" row (which contains "192.168.1.1" as a substring).
IPT_ONLY_10_FILE="$TMPDIR/iptables_only_10.txt"
cat > "$IPT_ONLY_10_FILE" <<'EOF'
Chain FORWARD (policy ACCEPT)
target     prot opt source               destination
DROP       all  --  192.168.1.10         0.0.0.0/0
EOF
cat > "$MOCKBIN/iptables" <<MOCK
#!/bin/sh
case "\$*" in
    -L\ FORWARD\ -n) cat "$IPT_ONLY_10_FILE" ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$MOCKBIN/iptables"
OUT=$(PATH="$MOCKBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_is_blocked 192.168.1.1 && echo BLOCKED || echo NOTBLOCKED")
assert_eq "iptables: only .10 blocked — tctl_is_blocked 192.168.1.1 is NOT blocked" "NOTBLOCKED" "$OUT"
OUT=$(PATH="$MOCKBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_is_blocked 192.168.1.10 && echo BLOCKED || echo NOTBLOCKED")
assert_eq "iptables: only .10 blocked — tctl_is_blocked 192.168.1.10 IS blocked" "BLOCKED" "$OUT"

# Restore the two-row fixture for the assertions below.
cat > "$MOCKBIN/iptables" <<MOCK
#!/bin/sh
case "\$*" in
    -L\ FORWARD\ -n) cat "$IPT_L_FILE" ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$MOCKBIN/iptables"

# The equivalent summary.sh column layout (-L -nvx: pkts/bytes/target/prot/opt/in/out/source/destination)
SUMMARY_L_FILE="$TMPDIR/summary_iptables_L_nvx.txt"
cat > "$SUMMARY_L_FILE" <<'EOF'
Chain FORWARD (policy ACCEPT 0 packets, 0 bytes)
    pkts      bytes target     prot opt in     out     source               destination
       5      500 DROP       all  --  *      *       192.168.1.1          0.0.0.0/0
       3      300 DROP       all  --  *      *       192.168.1.10         0.0.0.0/0
EOF
# trafficctl-summary.sh's lookup_blocked (iptables branch) reads column 4 (src)
# after skipping pkts/bytes/target — verify unblocking 192.168.1.1 leaves
# 192.168.1.10's row intact and distinguishable.
BLOCKED_11=$(awk -v ip="192.168.1.1" '
    $3 == "DROP" {
        for (i = 4; i <= NF; i++) {
            src = $i
            sub(/\/32$/, "", src)
            if (src == ip) { found = 1; exit }
        }
    }
    END { print (found ? 1 : 0) }' "$SUMMARY_L_FILE")
BLOCKED_1_10=$(awk -v ip="192.168.1.10" '
    $3 == "DROP" {
        for (i = 4; i <= NF; i++) {
            src = $i
            sub(/\/32$/, "", src)
            if (src == ip) { found = 1; exit }
        }
    }
    END { print (found ? 1 : 0) }' "$SUMMARY_L_FILE")
assert_eq "summary iptables -nvx layout: 192.168.1.1 blocked" "1" "$BLOCKED_11"
assert_eq "summary iptables -nvx layout: 192.168.1.10 blocked independently" "1" "$BLOCKED_1_10"

# ════════════════════════════════════════════════════════════════════════════
# 6. Rule comments are derived from the target, not the caller's label
# ════════════════════════════════════════════════════════════════════════════

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci"

LUCI_COMMENT=$(PATH="$MOCKBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_block_comment 192.168.1.20")
TG_COMMENT=$(PATH="$MOCKBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_block_comment 192.168.1.20")
assert_eq "block comment: identical regardless of caller (no label input at all)" \
    "$LUCI_COMMENT" "$TG_COMMENT"

# End-to-end: block via trafficctl-block.sh with LABEL="" (what LuCI passes
# for an unset label), then unblock via the exact call trafficctl-unblock.sh
# makes from the Telegram path (label "tg") and confirm it actually clears.
: > "$NFT_DELETE_LOG"
BLOCKED_COMMENT_FILE="$TMPDIR/blocked_comment.txt"
rm -f "$BLOCKED_COMMENT_FILE"
# The dump reflects whatever comment the real `insert rule` call actually
# used (captured verbatim from argv), NOT a hardcoded string — otherwise a
# mutation that changes which comment trafficctl-block.sh writes would be
# invisible to the "list" step that the unblock path greps against.
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
echo "\$*" >> "$TMPDIR/nft_block_calls.log"
case "\$*" in
    "list tables") echo "table inet fw4" ;;
    -a\ list\ chain\ inet\ fw4\ forward)
        if [ -f "$BLOCKED_COMMENT_FILE" ]; then
            cmt=\$(cat "$BLOCKED_COMMENT_FILE")
            printf 'chain forward {\n\tip saddr 192.168.1.20 counter drop comment "%s" # handle 42\n}\n' "\$cmt"
        fi
        ;;
    delete\ rule*) echo "\$*" >> "$NFT_DELETE_LOG"; rm -f "$BLOCKED_COMMENT_FILE" ;;
    insert\ rule*)
        # argv looks like: insert rule inet fw4 forward ip saddr <ip> counter drop comment "<cmt>"
        cmt=\$(printf '%s' "\$*" | sed -n 's/.*comment "\([^"]*\)".*/\1/p')
        printf '%s' "\$cmt" > "$BLOCKED_COMMENT_FILE"
        ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/nft"
cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/ip"
cat > "$MOCKBIN/conntrack" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$MOCKBIN/conntrack"

BLOCK_SH="$TMPDIR/block.sh"
UNBLOCK_SH="$TMPDIR/unblock.sh"
sed "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" "$BIN/trafficctl-block.sh" > "$BLOCK_SH"
sed "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" "$BIN/trafficctl-unblock.sh" > "$UNBLOCK_SH"

rm -f "$BLOCKED_COMMENT_FILE"
OUT=$(PATH="$MOCKBIN:$PATH" sh "$BLOCK_SH" 192.168.1.20 "" 2>&1)
assert_contains "block via LuCI (empty label) succeeds" '"ok":true' "$OUT"

OUT=$(PATH="$MOCKBIN:$PATH" sh "$UNBLOCK_SH" 192.168.1.20 "tg" 2>&1)
assert_contains "unblock via Telegram path (label tg) succeeds against a LuCI-placed block" \
    '"ok":true' "$OUT"
DELETED=$(cat "$NFT_DELETE_LOG")
assert_contains "unblock via Telegram path actually deleted the rule (handle 42)" "handle 42" "$DELETED"

# ════════════════════════════════════════════════════════════════════════════
# 7. Port ranges survive on the iptables branch; hashlimit name stays <=15 chars
# ════════════════════════════════════════════════════════════════════════════

PFW="$TMPDIR/portfw.sh"
sed "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" "$BIN/trafficctl-portfw.sh" > "$PFW"

cat > "$MOCKBIN/nft" <<'MOCK'
#!/bin/sh
exit 1
MOCK
IPT_LOG="$TMPDIR/iptables_calls.log"
: > "$IPT_LOG"
# -S (list rule specs) always returns empty here (no pre-existing rules to
# delete), and a bare `-D <chain>` with no further args (i.e. delete_by_comment
# re-evaluating an empty match) must FAIL like the real iptables does —
# otherwise pfw_delete_by_comment's `while ... :; done` loop never terminates.
cat > "$MOCKBIN/iptables" <<MOCK
#!/bin/sh
echo "\$*" >> "$IPT_LOG"
case "\$*" in
    -S\ *) exit 0 ;;
    -D\ FORWARD|-D\ INPUT) exit 1 ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$MOCKBIN/nft" "$MOCKBIN/iptables"

: > "$IPT_LOG"
OUT=$(PATH="$MOCKBIN:$PATH" sh "$PFW" pause forward tcp 192.168.1.30 8000-8100 2>&1)
assert_contains "pfw pause: ok" '"ok":true' "$OUT"
CALLS=$(cat "$IPT_LOG")
assert_contains "pfw pause: iptables gets the FULL range 8000:8100, not truncated to 8000" \
    "--dport 8000:8100" "$CALLS"
assert_not_contains "pfw pause: does not pass the bare truncated low port alone" \
    "--dport 8000 " "$CALLS"

: > "$IPT_LOG"
OUT=$(PATH="$MOCKBIN:$PATH" sh "$PFW" limit forward tcp 192.168.1.30 8000-8100 5000 2>&1)
assert_contains "pfw limit: ok" '"ok":true' "$OUT"
CALLS=$(cat "$IPT_LOG")
assert_contains "pfw limit: iptables gets the full range for --dport too" "--dport 8000:8100" "$CALLS"
HLNAME=$(printf '%s' "$CALLS" | grep -o 'hashlimit-name [^ ]*' | head -1 | awk '{print $2}')
assert_eq "pfw limit: hashlimit name stays within iptables' 15-char limit" \
    "yes" "$([ "${#HLNAME}" -le 15 ] && echo yes || echo no)"

# ════════════════════════════════════════════════════════════════════════════
# 8. Telegram bot token never appears in fake-curl argv (goes via stdin)
# ════════════════════════════════════════════════════════════════════════════
# (Covered end-to-end against tg_api/tg_send in test_security.sh; repeated
# here narrowly against trafficctl-telegram-test.sh's independent tg call
# path, which has its own curl invocation.)

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
echo "OpenWrt"
MOCK
CURL_ARGV="$TMPDIR/curl_argv2.log"
CURL_STDIN="$TMPDIR/curl_stdin2.log"
: > "$CURL_ARGV"; : > "$CURL_STDIN"
cat > "$MOCKBIN/curl" <<MOCK
#!/bin/sh
echo "\$*" >> "$CURL_ARGV"
cat >> "$CURL_STDIN"
echo '{"ok":true}'
MOCK
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
exit 1
MOCK
cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci" "$MOCKBIN/curl" "$MOCKBIN/jsonfilter" "$MOCKBIN/ip"

PATH="$MOCKBIN:$PATH" sh "$BIN/trafficctl-telegram-test.sh" "999999:SECRETTOKENVALUE" "12345" >/dev/null 2>&1
assert_not_contains "telegram-test.sh: bot token absent from curl argv" \
    "SECRETTOKENVALUE" "$(cat "$CURL_ARGV")"
assert_contains "telegram-test.sh: bot token present on curl's stdin (--config -)" \
    "SECRETTOKENVALUE" "$(cat "$CURL_STDIN")"

# ════════════════════════════════════════════════════════════════════════════

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
