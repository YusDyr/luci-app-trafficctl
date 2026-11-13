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

# logging_config_set, the rpcd method, refuses a bad log_file and a max_lines
# outside 20..100000 before it writes anything: tests/test_rpcd.sh, which runs
# the ucode plugin.

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

# No direct uci grant: no view reads or writes uci (everything goes through
# luci.trafficctl, which masks the bot token, the ntfy token and the webhook
# auth as ***). A read grant on trafficctl handed those secrets to any
# read-only user in clear text, one on wireless the WiFi keys; a write grant
# set options past the plugin's validation (log_file, max_lines).
assert_eq "acl: no uci access at all, read or write" "" \
    "$(jq -r '.[] | [.read.uci, .write.uci] | map(select(. != null)) | .[]' "$ACL_FILE")"
VIEWS="$(dirname "$ROOT")/htdocs/luci-static/resources/view/trafficctl"
assert_eq "acl: the views are where this looks" yes "$([ -f "$VIEWS/status.js" ] && echo yes)"
assert_eq "acl: and no view needs it (no uci module, no form.Map)" "" \
    "$(grep -lE "'require uci'|form\.Map|uci\.(load|get|set|sections)" "$VIEWS"/*.js 2>/dev/null)"

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

# 5. Rule removal is anchored, and 6. rule comments are derived from the
# target, not the caller's label: `trafficctl block`/`unblock` since the ucode
# port, tests/test_block.sh ("regressions").

# ════════════════════════════════════════════════════════════════════════════
# 7. telegram-test keeps the bot token out of curl's argv: tests/test_notify.sh
#    (the command is `trafficctl telegram-test` now).
# ════════════════════════════════════════════════════════════════════════════

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
