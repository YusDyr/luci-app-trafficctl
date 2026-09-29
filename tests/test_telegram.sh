#!/bin/bash
# Unit tests for Telegram bot integration — exercises the REAL functions in
# trafficctl-telegram.sh and trafficctl-telegram-test.sh, not local
# redefinitions.
#
# The previous version of this file defined its own validate_token,
# validate_chat_id, parse_verb/parse_ip/parse_param, sanitize_mac/name and
# json_escape and asserted against those copies. None of those names exist in
# the production scripts (token/chat_id format checks are inline grep -qE in
# trafficctl-telegram-test.sh; callback parsing/validation is inline in
# handle_callback() in trafficctl-telegram.sh), so a reviewer could delete the
# real validation entirely and this suite stayed green. This version invokes
# the daemon script directly, either as a real invalidated-and-neutered
# subprocess (bot loop suppressed) so individual functions can be called, or
# runs the real telegram-test.sh binary for the token/chat_id checks.

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

# ── mocks shared by all sections below ──────────────────────────────────────

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
# Minimal jsonfilter: given "-e '@.field'" (or "@.nested.field"), extract the
# last path segment's value from stdin JSON. Good enough for the flat
# {"ok":true,...}/{"description":"..."} shapes used by the API responses here.
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
expr="$2"
key=$(printf '%s' "$expr" | sed "s/.*\.//;s/\[.*//")
input=$(cat)
val=$(printf '%s' "$input" | sed -n "s/.*\"$key\":\"\([^\"]*\)\".*/\1/p")
if [ -n "$val" ]; then printf '%s' "$val"; exit 0; fi
printf '%s' "$input" | sed -n "s/.*\"$key\":\([A-Za-z0-9_.-]*\).*/\1/p"
MOCK
cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/uci" "$MOCKBIN/jsonfilter" "$MOCKBIN/ip"

# handle_callback dispatches to these by absolute-ish path ($SCRIPTS/...);
# stub them so real dispatch doesn't blow up on a missing binary — the point
# of these tests is the validation gate BEFORE dispatch, not the sub-scripts
# (which have their own real-code tests elsewhere).
for sub in trafficctl-ratelimit.sh trafficctl-block.sh trafficctl-unblock.sh \
           trafficctl-shape.sh trafficctl-macfilter-add.sh trafficctl-macfilter-remove.sh \
           trafficctl-summary.sh; do
    cat > "$MOCKBIN/$sub" <<'MOCK'
#!/bin/sh
echo '{"ok":true,"msg":"stub"}'
MOCK
    chmod +x "$MOCKBIN/$sub"
done

CURL_LOG="$TMPDIR/curl.log"
CURL_STDIN_LOG="$TMPDIR/curl_stdin.log"
cat > "$MOCKBIN/curl" <<MOCK
#!/bin/sh
echo "\$*" >> "$CURL_LOG"
cat >> "$CURL_STDIN_LOG"
echo "---" >> "$CURL_STDIN_LOG"
echo '{"ok":true,"result":{"message_id":1}}'
MOCK
chmod +x "$MOCKBIN/curl"

# Stub for the `. /lib/functions.sh` source line inside trafficctl-telegram.sh
mkdir -p "$TMPDIR/lib"
cat > "$TMPDIR/lib/functions.sh" <<'MOCK'
network_get_ipaddr() { eval "$1='1.2.3.4'"; }
config_load() { :; }
config_get() { eval "$2=\"\${4:-}\""; }
MOCK

# A copy of the daemon with:
#   - the trailing `main` call neutered (so sourcing/running it doesn't enter
#     the poll loop or call validate_config, which would exit the process)
#   - `. /lib/functions.sh` redirected to the stub above
# All function bodies are untouched — this is real production code.
NEUTERED="$TMPDIR/telegram_neutered.sh"
sed -e "s|\. /lib/functions.sh|. $TMPDIR/lib/functions.sh|" \
    -e '$s|^main$|:|' \
    "$BIN/trafficctl-telegram.sh" > "$NEUTERED"

tail -1 "$NEUTERED" | grep -q '^main$' && {
    echo "FAIL: harness bug — could not neuter the main() call, refusing to run (would loop forever)"
    exit 1
}

# ── Token / chat_id format validation (real trafficctl-telegram-test.sh) ───
# These are the actual regex checks the production binary runs before ever
# touching the network — invoked as a real subprocess, not a copy-pasted
# regex.

run_tg_test() {
    PATH="$MOCKBIN:$PATH" sh "$BIN/trafficctl-telegram-test.sh" "$1" "$2" 2>/dev/null
}

OUT=$(run_tg_test '123456:ABC!@#' '999')
assert_contains "invalid token special chars rejected" "invalid token format" "$OUT"

OUT=$(run_tg_test ':ABCdef' '999')
assert_contains "invalid token no bot id rejected" "invalid token format" "$OUT"

OUT=$(run_tg_test '123456ABCdef' '999')
assert_contains "invalid token no colon rejected" "invalid token format" "$OUT"

OUT=$(run_tg_test '123; rm -rf /' '999')
assert_contains "injection token rejected" "invalid token format" "$OUT"

OUT=$(run_tg_test '123456:ABCdef' 'abc123')
assert_contains "invalid chat_id letters rejected" "chat_id must be numeric" "$OUT"

OUT=$(run_tg_test '123456:ABCdef' '123;whoami')
assert_contains "injection chat_id rejected" "chat_id must be numeric" "$OUT"

OUT=$(run_tg_test '' '999')
assert_contains "empty token rejected before network call" "required" "$OUT"

# A syntactically valid token/chat_id must pass validation and reach curl
# (mocked, so no real network call happens).
: > "$CURL_LOG"
OUT=$(run_tg_test '7104583920:AAF_x9k-Lm2NpQ3rS5tU7vW' '-100123456789')
assert_contains "valid token/chat_id reaches the API call" '"ok":true' "$OUT"
assert_eq "valid token/chat_id: curl was actually invoked" "yes" "$([ -s "$CURL_LOG" ] && echo yes || echo no)"

# ── tg_json_escape (real function) ──────────────────────────────────────────

ESCAPED=$(PATH="$MOCKBIN:$PATH" sh -c ". '$NEUTERED'; tg_json_escape 'he said \"hi\" and a \\\\ backslash'")
assert_not_contains "json escape: no raw double-quoted hi" "\"hi\"" "$ESCAPED"
assert_contains "json escape: quote escaped" '\"hi\"' "$ESCAPED"
assert_contains "json escape: backslash doubled" '\\\\' "$ESCAPED"

ESCAPED_NEWLINE=$(PATH="$MOCKBIN:$PATH" sh -c ". '$NEUTERED'; tg_json_escape \"line1
line2\"")
assert_contains "json escape: real newline becomes \\n" 'line1\nline2' "$ESCAPED_NEWLINE"

# ── tg_answer_cb length cap ────────────────────────────────────
# The Bot API caps a callback toast at 200 characters and REJECTS the call when
# it is longer, so an over-long message does not arrive truncated -- it does not
# arrive at all. Backend results that carry remediation advice (the WiFi
# enforcement ones run to ~170 characters) sit close enough to that limit that a
# silently missing toast is a live risk, and "the operator is told nothing" is
# the exact failure this plugin is being fixed for.

LONG_TOAST=$(printf 'x%.0s' $(seq 1 300))
: > "$CURL_LOG"
PATH="$MOCKBIN:$PATH" sh -c ". '$NEUTERED'; tg_answer_cb 'cb123' '$LONG_TOAST'" >/dev/null 2>&1
TOAST_BODY=$(cat "$CURL_LOG")
assert_contains "answer_cb: over-long toast is trimmed with an ellipsis" \
    "..." "$TOAST_BODY"
assert_not_contains "answer_cb: nothing at or over the 200-char API limit is sent" \
    "$(printf 'x%.0s' $(seq 1 200))" "$TOAST_BODY"

# A message that already fits must go through untouched -- the cap must not
# start mangling the ordinary case.
SHORT_TOAST="MAC aa:bb:cc:dd:ee:ff blocked on wifi for 192.168.1.50"
: > "$CURL_LOG"
PATH="$MOCKBIN:$PATH" sh -c ". '$NEUTERED'; tg_answer_cb 'cb123' '$SHORT_TOAST'" >/dev/null 2>&1
TOAST_BODY=$(cat "$CURL_LOG")
assert_contains "answer_cb: a toast within the limit is sent whole" "$SHORT_TOAST" "$TOAST_BODY"
assert_not_contains "answer_cb: a toast within the limit gains no ellipsis" "..." "$TOAST_BODY"

# ── Known devices JSON manipulation (real add_known_mac / is_known_mac) ────

KNOWN_TEST="$TMPDIR/known.json"
FLOW="
KNOWN_FILE='$KNOWN_TEST'
is_known_mac 'aa:bb:cc:dd:ee:ff' && echo FOUND || echo NOTFOUND
"
echo '[]' > "$KNOWN_TEST"
OUT=$(PATH="$MOCKBIN:$PATH" sh -c ". '$NEUTERED'; $FLOW")
assert_eq "empty known: not found" "NOTFOUND" "$OUT"

OUT=$(PATH="$MOCKBIN:$PATH" sh -c "
. '$NEUTERED'
KNOWN_FILE='$KNOWN_TEST'
add_known_mac 'aa:bb:cc:dd:ee:ff' 'test1' '192.168.0.1'
is_known_mac 'aa:bb:cc:dd:ee:ff' && echo FOUND || echo NOTFOUND
")
assert_eq "known: found after real add_known_mac" "FOUND" "$OUT"

OUT=$(PATH="$MOCKBIN:$PATH" sh -c "
. '$NEUTERED'
KNOWN_FILE='$KNOWN_TEST'
add_known_mac 'aa:bb:cc:dd:ee:ff' 'test1' '192.168.0.1'
add_known_mac '11:22:33:44:55:66' 'test2' '192.168.0.2'
is_known_mac '11:22:33:44:55:66' && echo FOUND2
is_known_mac 'aa:bb:cc:dd:ee:ff' && echo FOUND1
")
assert_contains "known: second device found after real add" "FOUND2" "$OUT"
assert_contains "known: first device still found" "FOUND1" "$OUT"

# add_known_mac must sanitize inputs — this is the same function that used to
# be faked as a standalone "sanitize_mac"/"sanitize_name" in this file.
: > "$KNOWN_TEST"; echo '[]' > "$KNOWN_TEST"
OUT=$(PATH="$MOCKBIN:$PATH" sh -c "
. '$NEUTERED'
KNOWN_FILE='$KNOWN_TEST'
add_known_mac 'aa:bb:cc:dd:ee:ff\"; rm -rf /' 'evil\"};\$(rm -rf /);{\"' '192.168.0.1'
cat '$KNOWN_TEST'
")
assert_not_contains "add_known_mac: no semicolon survives into the store" ";" "$OUT"
assert_not_contains "add_known_mac: no raw double-quote survives" '";' "$OUT"
assert_not_contains "add_known_mac: no dollar-paren survives" '$(' "$OUT"

# ── Callback validation (real handle_callback, verb "noop" so nothing fires) ─
# handle_callback validates ip/param before dispatching on verb, so an unknown
# verb lets us probe validation without touching block/unblock/etc.

cb_test() {
    PATH="$MOCKBIN:$PATH" sh -c "
    . '$NEUTERED'
    SCRIPTS='$MOCKBIN'
    handle_callback 'cbid1' '$1' 'msg1'
    "
}

: > "$CURL_LOG"
cb_test 'act:noop:192.168.0.1'
assert_not_contains "cb ip: valid address is not rejected" "invalid IP" "$(cat "$CURL_LOG")"

: > "$CURL_LOG"
cb_test 'act:noop:192.168.0.1;whoami'
assert_contains "cb ip: injection semicolon rejected" "invalid IP" "$(cat "$CURL_LOG")"

: > "$CURL_LOG"
cb_test 'act:noop:1.1.1.1|cat'
assert_contains "cb ip: injection pipe rejected" "invalid IP" "$(cat "$CURL_LOG")"

: > "$CURL_LOG"
cb_test 'act:noop:abc.def.ghi.jkl'
assert_contains "cb ip: letters rejected" "invalid IP" "$(cat "$CURL_LOG")"

: > "$CURL_LOG"
cb_test 'act:limit:192.168.0.1:10000'
assert_not_contains "cb param: valid rate accepted" "invalid param" "$(cat "$CURL_LOG")"

: > "$CURL_LOG"
cb_test 'act:limit:192.168.0.1:10000;rm'
assert_contains "cb param: injection rejected" "invalid param" "$(cat "$CURL_LOG")"

: > "$CURL_LOG"
cb_test 'act:limit:192.168.0.1:abc'
assert_contains "cb param: letters rejected" "invalid param" "$(cat "$CURL_LOG")"

: > "$CURL_LOG"
cb_test 'act:back'
assert_not_contains "cb ip: back verb skips ip check even with empty ip" "invalid IP" "$(cat "$CURL_LOG")"

# ── Callback data length (Telegram limit: 64 bytes) tied to real generator ──
# Rather than hand-building a callback_data string and checking its length
# (which says nothing about the generator), build the longest strings the
# real build_action_keyboard() actually emits and check those.

DEVICES_JSON='[{"ip":"192.168.255.255","name":"x","blocked":false,"wifi_blocked":false,"rate_limit_kbit":0,"shape_kbit":0,"conn_type":"ethernet"}]'
KB=$(PATH="$MOCKBIN:$PATH" sh -c "
. '$NEUTERED'
build_action_keyboard '192.168.255.255' '$DEVICES_JSON'
")
LONGEST_CB=$(printf '%s' "$KB" | grep -o '"callback_data":"[^"]*"' | sed 's/.*:"//;s/"$//' | awk '{ if (length($0) > m) { m = length($0); s = $0 } } END { print s }')
assert_eq "longest real callback_data stays within Telegram's 64-byte limit" \
    "yes" "$([ "${#LONGEST_CB}" -le 64 ] && echo yes || echo no)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
