#!/bin/bash
# Independent download and upload ceilings — issue #66.
#
# The enforcement was always two-sided: the limiter polices download at LAN
# egress and upload at LAN ingress as separate nftables rules on separate
# hooks, and the shaper builds separate HTB classes on separate devices. They
# were symmetric only because both halves took the same number. This feature
# threads a second number through, and almost all of its risk is in the stored
# record rather than in the enforcement.
#
# The dangerous part is shapes.json. Its records are not parsed — they are
# extracted with a single `grep -o` pattern. A record the pattern does not match
# does not get misread, it DISAPPEARS: used_minors() stops seeing its classid,
# alloc_classid hands that minor to the next device, and two devices end up
# sharing one HTB class, so removing either tears down the other. Adding a field
# to the record is therefore a change to what counts as a record at all, which
# is what the first section here is about. A round-trip test would not catch it;
# only asking whether the allocator still sees an existing minor does.
#
# Second concern: absence must keep meaning "symmetric". Every record written
# before this feature has no upload field, and so does every symmetric record
# written after it. If absence were ever read as zero, the restore hook would
# come back from a reboot policing every upload packet — a total block
# reporting itself as a successful limit.

PASS=0
FAIL=0

REPO="$(cd "$(dirname "$0")/.." && pwd)"
RPCD="$REPO/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"

# The limiter and the shaper are `trafficctl ratelimit` and `trafficctl shape`,
# their restore `trafficctl restore` (ucode, tests/lib/shape_env.sh, with a
# stateful tc). Both write the one rules.json, $RULES.
# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/shape_env.sh
. "$UC_TESTLIB/shape_env.sh"
lt_cfg 1
st_net br-lan lan1
printf '[]' > "$RULES"
TMP="$UC_TMP/asym"
mkdir -p "$TMP"

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
        printf "FAIL: %s\n  should NOT contain: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}


mkdir -p "$TMP/sys/class/net/br-lan/brif/lan1"
export TCTL_SYSFS_NET="$TMP/sys/class/net"

rl() { lt_run ratelimit "$@"; }

# The shaper's record readers, called directly (trafficctl.shape).
shp() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.shape "$@"; }
entries_n() { shp entries | grep -o '\\"ip\\"' | wc -l | tr -d ' '; }

# ════════════════════════════════════════════════════════════════════════════
# 1. The record format — an asymmetric record must still be VISIBLE
# ════════════════════════════════════════════════════════════════════════════
#
# This is the section that matters. If the reader does not recognise the new
# record, the allocator reuses its class and two devices collide.

printf '[{"ip":"192.168.1.50","rate_kbit":20000,"classid":"1:2","rate_kbit_up":2000}]' > "$SHAPES"

assert_eq "an asymmetric record is seen by entries()" "1" "$(entries_n)"
assert_eq "its classid is found" "1:2" "$(shp lookup_classid '"192.168.1.50"')"
# The collision test: minor 2 is taken, so the next allocation must not be 1:2.
assert_eq "the allocator does NOT reuse a minor held by an asymmetric record" "1:3" \
    "$(shp alloc_classid)"

# ── and an old symmetric record must keep working unchanged ─────────────────

printf '[{"ip":"10.0.0.7","rate_kbit":5000,"classid":"1:4"}]' > "$SHAPES"
assert_eq "a pre-existing symmetric record is still seen" "1" "$(entries_n)"
assert_eq "its classid is still found" "1:4" "$(shp lookup_classid '"10.0.0.7"')"
assert_eq "the allocator skips its minor too" "1:2" "$(shp alloc_classid)"

# ── a file holding both forms at once, which is what an upgrade produces ────

printf '[{"ip":"10.0.0.7","rate_kbit":5000,"classid":"1:2"},{"ip":"10.0.0.8","rate_kbit":9000,"classid":"1:3","rate_kbit_up":1000}]' > "$SHAPES"
assert_eq "both forms are seen side by side" "2" "$(entries_n)"
assert_eq "old-form classid in a mixed file" "1:2" "$(shp lookup_classid '"10.0.0.7"')"
assert_eq "new-form classid in a mixed file" "1:3" "$(shp lookup_classid '"10.0.0.8"')"
assert_eq "allocation skips both minors" "1:4" "$(shp alloc_classid)"

# ════════════════════════════════════════════════════════════════════════════
# 2. The shaper applies two different ceilings
# ════════════════════════════════════════════════════════════════════════════

: > "$SHAPES"; printf '[]' > "$SHAPES"
: > "$TC_LOG"
out=$(st_run add 192.168.1.60 20000 shape_test 2000)

assert_contains "shaper reports both ceilings when they differ" \
    "20000 kbit/s down, 2000 kbit/s up" "$out"
assert_contains "download class gets the download rate" "rate 20000kbit" "$(cat "$TC_LOG")"
assert_contains "upload class gets the upload rate" "rate 2000kbit" "$(cat "$TC_LOG")"
assert_contains "the asymmetric record is persisted" '"rate_kbit_up":2000' "$(cat "$SHAPES")"

# Burst is 10ms of the rate it belongs to; reusing the download burst for a
# much smaller upload ceiling would let the upload burst far past its cap.
assert_contains "upload burst is sized from the upload rate" "burst 2500b" "$(cat "$TC_LOG")"

# ── symmetric still writes exactly the record it always wrote ──────────────

st_reset
printf '[]' > "$SHAPES"
out=$(st_run add 192.168.1.61 5000 shape_test)
assert_eq "a symmetric shape writes the pre-feature record verbatim" \
    '[{"ip":"192.168.1.61","rate_kbit":5000,"classid":"1:2"}]' "$(cat "$SHAPES")"
assert_not_contains "no upload field appears for a symmetric shape" \
    "rate_kbit_up" "$(cat "$SHAPES")"
assert_contains "and it reports a single figure" "shape 5000 kbit/s applied" "$out"

# Explicitly equal rates are symmetric, not a special asymmetric case.
st_reset
printf '[]' > "$SHAPES"
st_run add 192.168.1.62 5000 shape_test 5000 >/dev/null
assert_not_contains "an explicitly equal upload rate still writes no field" \
    "rate_kbit_up" "$(cat "$SHAPES")"

# ════════════════════════════════════════════════════════════════════════════
# 3. The limiter polices two different rates
# ════════════════════════════════════════════════════════════════════════════

: > "$NFT_LOG"
out=$(rl 192.168.1.70 8000 rl_test each 800)

# 8000 kbit is 1000000 bytes/s (SI: kbit * 125); 800 kbit is 100000.
assert_contains "download rule takes the download rate" \
    "ip daddr 192.168.1.70 meter tctl_m_192_168_1_70_dl_" "$(cat "$NFT_LOG")"
assert_contains "download rate reaches nft as bytes" "1000000 bytes/second" "$(cat "$NFT_LOG")"
assert_contains "upload rate reaches nft as bytes" "100000 bytes/second" "$(cat "$NFT_LOG")"
assert_contains "limiter reports both figures" "8000 kbit/s down, 800 kbit/s up" "$out"

# ── absence means symmetric, and never zero ────────────────────────────────

: > "$NFT_LOG"
out=$(rl 192.168.1.71 8000 rl_test each)
assert_contains "a limit with no upload argument polices upload at the same rate" \
    "1000000 bytes/second" "$(cat "$NFT_LOG")"
# 1 byte/s is what rate 0 would floor to — the total-block signature.
assert_not_contains "an omitted upload rate is NOT read as zero" \
    "over 1 bytes/second" "$(cat "$NFT_LOG")"
assert_contains "and it reports a single figure" "8000 kbit/s for" "$out"

# ════════════════════════════════════════════════════════════════════════════
# 4. Persistence and the reboot restore
# ════════════════════════════════════════════════════════════════════════════

printf '[]' > "$RULES"
rl 192.168.1.80 8000 rl_test each 800 >/dev/null
assert_contains "an asymmetric limit persists its upload rate" '"param_up":"800"' "$(cat "$RULES")"

printf '[]' > "$RULES"
rl 192.168.1.81 8000 rl_test each >/dev/null
assert_not_contains "a symmetric limit writes no upload field" "param_up" "$(cat "$RULES")"
assert_contains "and still records mode and rate as before" '"mode":"each"' "$(cat "$RULES")"

# ── the restore must carry the upload rate back ────────────────────────────

lt_reset
printf '[{"type":"ratelimit","ip":"192.168.1.90","param":"8000","mode":"each","param_up":"800"}]' > "$RULES"
printf '[]' > "$SHAPES"
lt_run restore >/dev/null
assert_contains "restore re-applies the download rate" "1000000 bytes/second" "$(cat "$NFT_LOG")"
assert_contains "restore re-applies the upload rate" "100000 bytes/second" "$(cat "$NFT_LOG")"

# A record from before the feature must come back symmetric, not zeroed.
lt_reset
printf '[{"type":"ratelimit","ip":"192.168.1.91","param":"8000","mode":"each"}]' > "$RULES"
lt_run restore >/dev/null
assert_contains "a pre-feature record restores symmetrically" "1000000 bytes/second" "$(cat "$NFT_LOG")"
assert_not_contains "a pre-feature record does not restore as a total upload block" \
    "over 1 bytes/second" "$(cat "$NFT_LOG")"

# ── and the shaper's restore path ──────────────────────────────────────────

st_reset
printf '[]' > "$RULES"
printf '[{"ip":"192.168.1.92","rate_kbit":20000,"classid":"1:2","rate_kbit_up":2000}]' > "$SHAPES"
lt_run restore >/dev/null
assert_contains "shape restore re-applies the download ceiling" \
    "class add dev br-lan parent 1:1 classid 1:2 htb rate 20000kbit" "$(cat "$TC_LOG")"
assert_contains "shape restore re-applies the upload ceiling" \
    "class add dev tctl-ifb0 parent 1:1 classid 1:2 htb rate 2000kbit" "$(cat "$TC_LOG")"
assert_eq "and the record is written back as it was" \
    '[{"ip":"192.168.1.92","rate_kbit":20000,"classid":"1:2","rate_kbit_up":2000}]' "$(cat "$SHAPES")"

# A record with no upload field comes back symmetric, never as a zero ceiling.
st_reset
printf '[{"ip":"192.168.1.93","rate_kbit":5000,"classid":"1:4"}]' > "$SHAPES"
lt_run restore >/dev/null
assert_contains "a pre-feature shape restores its upload at the download rate" \
    "class add dev tctl-ifb0 parent 1:1 classid 1:4 htb rate 5000kbit" "$(cat "$TC_LOG")"
assert_not_contains "and gains no upload field" "rate_kbit_up" "$(cat "$SHAPES")"

# A restore puts back what was there: no "Limit applied" per device on every
# boot. The same shaper call made by hand does announce itself. The shaper is
# ucode (shape.uc): its event goes out through notify.uc.
st_reset
lt_events_on
printf '[{"ip":"192.168.1.93","rate_kbit":5000,"classid":"1:4"}]' > "$SHAPES"
printf '[{"type":"ratelimit","ip":"192.168.1.93","param":"8000","mode":"each"}]' > "$RULES"
lt_run restore >/dev/null
assert_contains "restore: the shape is put back" "class add dev br-lan parent 1:1 classid 1:4 htb rate 5000kbit" "$(cat "$TC_LOG")"
assert_eq "restore: the shape and the limit put back announce nothing" "" "$(cat "$EVENTS_LOG")"
st_run add 192.168.1.94 20000 shape_192.168.1.94 2000 >/dev/null
assert_eq "shaper: a shape added by hand announces itself, with both rates" \
    "ACTION=limit_applied IP=192.168.1.94 MODE=shaper RATE_KBIT=20000 RATE_KBIT_UP=2000 SRC=local VIA=cli" "$(cat "$EVENTS_LOG")"
: > "$EVENTS_LOG"
st_run add 192.168.1.94 abc >/dev/null
st_run remove 192.168.1.94 >/dev/null
assert_eq "shaper: a removal or a refused rate announces nothing" "" "$(cat "$EVENTS_LOG")"
TCTL_NOTIFY=0 st_run add 192.168.1.95 5000 >/dev/null
assert_eq "shaper: TCTL_NOTIFY=0 (the ifup hook) keeps it quiet" "" "$(cat "$EVENTS_LOG")"
lt_events_off
printf '[]' > "$RULES"

# The limiter is ucode (limit.uc): its event goes out through notify.uc.
lt_reset
lt_events_on
rl 192.168.1.95 8000 rl_test each 800 >/dev/null
assert_eq "limiter: a limit set by hand announces itself, with both rates" \
    "ACTION=limit_applied IP=192.168.1.95 MODE=limiter RATE_KBIT=8000 RATE_KBIT_UP=800 SRC=local VIA=cli" "$(cat "$EVENTS_LOG")"
: > "$EVENTS_LOG"
rl 192.168.1.96 8000 rl_test each >/dev/null
assert_contains "limiter: a symmetric limit gives the same rate up" "RATE_KBIT_UP=8000" "$(cat "$EVENTS_LOG")"
: > "$EVENTS_LOG"
rl 192.168.1.96 0 rl_test >/dev/null
rl 192.168.1.97 abc rl_test >/dev/null
assert_eq "limiter: a removal or a refused rate announces nothing" "" "$(cat "$EVENTS_LOG")"
TCTL_NOTIFY=0 rl 192.168.1.98 8000 rl_test each >/dev/null
assert_eq "limiter: TCTL_NOTIFY=0 (the ifup hook) keeps it quiet" "" "$(cat "$EVENTS_LOG")"
lt_reset
printf '[{"type":"ratelimit","ip":"192.168.1.99","param":"8000","mode":"each"}]' > "$RULES"
lt_run restore >/dev/null
assert_contains "limiter: the restore puts the limit back" "rl_ratelimit_192_168_1_99" "$(lt_table)"
assert_eq "limiter: ...and announces nothing, even with events wanted" "" "$(cat "$EVENTS_LOG")"
lt_events_off
lt_reset

# ════════════════════════════════════════════════════════════════════════════
# 5. The rpcd surface
# ════════════════════════════════════════════════════════════════════════════
#
# Read statically: the handlers shell out, and what matters is that a missing
# or zero field is normalised to "symmetric" before it gets there.

# tests/test_rpcd.sh checks what reaches the command; this is the source.
rpcd_src=$(cat "$RPCD")
assert_contains "ratelimit accepts an upload rate" \
    "ratelimit: { ip: 'str', rate_kbit: 'int', label: 'str', mode: 'str', rate_kbit_up: 'int' }" "$rpcd_src"
assert_contains "shape_add accepts an upload rate" \
    "shape_add: { ip: 'str', rate_kbit: 'int', label: 'str', rate_kbit_up: 'int' }" "$rpcd_src"
assert_eq "both handlers normalise a zero upload rate away" "2" \
    "$(grep -c "if (up == '0')" "$RPCD")"

# ════════════════════════════════════════════════════════════════════════════
# 6. The frontend
# ════════════════════════════════════════════════════════════════════════════
#
# getRateKbitUp is the one place in the UI that decides between "symmetric" and
# "a second ceiling", and the distinction it has to preserve is empty-vs-zero:
# an empty string means symmetric, while a 0 would reach the backend as a
# ceiling and floor to one byte/second — a total upload block. It is sliced out
# of status.js rather than restated, so this cannot drift into testing a copy.

JS="$REPO/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"

if command -v node >/dev/null 2>&1; then
    sed -n '/^\t\tfunction getRateKbitUp()/,/^\t\t}/p' "$JS"  > "$TMP/ui.js"
    sed -n '/^\t\tfunction rateLabel(/,/^\t\t}/p'      "$JS" >> "$TMP/ui.js"
    [ -s "$TMP/ui.js" ] || { echo "FAIL: could not slice the UI helpers out of status.js"; FAIL=$((FAIL + 1)); }

    cat > "$TMP/ui_run.js" <<'NODE'
function _(s) { return s; }
String.prototype.format = function () {
    var a = arguments, i = 0;
    return this.replace(/%s/g, function () { return a[i++]; });
};
// Only what the slices touch.
function fmtRate(kbit) {
    if (!kbit || kbit <= 0) return '—';
    var mbit = kbit / 1000;
    if (mbit >= 1) return (mbit % 1 === 0 ? mbit.toFixed(0) : mbit.toFixed(1)) + ' Mbit/s';
    return kbit + ' kbit/s';
}
var _hidden = true, _upUnit = 'mbit';
var upInput = { value: '' };
var upRow = { classList: { contains: function () { return _hidden; } } };
NODE
    cat "$TMP/ui.js" | sed 's/^\t\t//' >> "$TMP/ui_run.js"
    cat >> "$TMP/ui_run.js" <<'NODE'
function probe(hidden, unit, value) {
    _hidden = hidden; _upUnit = unit; upInput.value = value;
    return getRateKbitUp();
}
var out = [
    probe(true,  'mbit', '2'),      // control closed -> symmetric
    probe(false, 'mbit', ''),       // opened but empty -> symmetric
    probe(false, 'mbit', '0'),      // zero -> symmetric, never a 0 ceiling
    probe(false, 'mbit', '-5'),     // negative -> symmetric
    probe(false, 'mbit', '2'),      // 2 Mbit -> 2000 kbit
    probe(false, 'kbit', '800'),    // 800 kbit stays 800
    probe(false, 'mbit', '1.5'),    // fractional Mbit rounds
    rateLabel('8000', ''),          // symmetric label
    rateLabel('8000', '8000'),      // explicitly equal is still one figure
    rateLabel('20000', '2000')      // asymmetric label
].join('|');
console.log(out);
NODE
    got=$(node "$TMP/ui_run.js" 2>&1)
    assert_eq "the upload reader distinguishes empty from zero, and converts units" \
        "||||2000|800|1500|8 Mbit/s|8 Mbit/s|20 Mbit/s down / 2 Mbit/s up" \
        "$got"
else
    printf 'skip: no node, not exercising the frontend slices\n'
fi

# The each/shared sentence must quote the rate that will actually be applied.
# Naming only the download figure next to a split ceiling describes a different
# rule than the one being installed, in the one place the repository added full
# sentences specifically so the bucket layout could not be misread.
if command -v node >/dev/null 2>&1; then
    sed -n '/^\t\tfunction updateScopeExplain()/,/^\t\t}/p' "$JS" > "$TMP/explain.js"
    cat > "$TMP/explain_run.js" <<'NODE'
function _(s) { return s; }
String.prototype.format = function () {
    var a = arguments, i = 0;
    return this.replace(/%s/g, function () { return a[i++]; });
};
function fmtRate(kbit) {
    if (!kbit || kbit <= 0) return '—';
    var mbit = kbit / 1000;
    if (mbit >= 1) return (mbit % 1 === 0 ? mbit.toFixed(0) : mbit.toFixed(1)) + ' Mbit/s';
    return kbit + ' kbit/s';
}
var _dl = '5000', _up = '', _scopeSelected = 'each';
function getRateKbit()   { return _dl; }
function getRateKbitUp() { return _up; }
var scopeInput   = { value: '10.0.20.0/24' };
var scopeExplain = { textContent: '' };
var scopeWarn    = { textContent: '', classList: { toggle: function () {} } };
function targetIsMonitored() { return true; }
NODE
    cat "$TMP/explain.js" | sed 's/^\t\t//' >> "$TMP/explain_run.js"
    cat >> "$TMP/explain_run.js" <<'NODE'
function say(dl, up, scope) {
    _dl = dl; _up = up; _scopeSelected = scope;
    updateScopeExplain();
    return scopeExplain.textContent;
}
console.log([
    say('5000', '',     'each'),
    say('5000', '500',  'each'),
    say('5000', '',     'shared'),
    say('5000', '500',  'shared')
].join('\n'));
NODE
    explain=$(node "$TMP/explain_run.js" 2>&1)

    assert_contains "symmetric per-device sentence is unchanged" \
        "Every device in 10.0.20.0/24 may use 5 Mbit/s of its own." "$explain"
    assert_contains "a split ceiling is spelled out per device" \
        "may use 5 Mbit/s down and 500 kbit/s up of its own." "$explain"
    assert_contains "symmetric aggregate sentence is unchanged" \
        "share 5 Mbit/s between them — one bucket for the whole subnet." "$explain"
    # Two rates in shared mode means two buckets, one per direction.
    assert_contains "a split aggregate says one bucket PER DIRECTION" \
        "one bucket per direction for the whole subnet." "$explain"
    assert_not_contains "no sentence describes a split ceiling with the download figure alone" \
        "may use 5 Mbit/s of its own. Every device in 10.0.20.0/24 may use 5 Mbit/s of its own." "$explain"
fi

# Static checks on the wiring the slices cannot see.
js_src=$(cat "$JS")
assert_contains "the ratelimit rpc call carries an upload rate" \
    "params: ['ip', 'rate_kbit', 'label', 'mode', 'rate_kbit_up']" "$js_src"
assert_contains "the shape_add rpc call carries an upload rate" \
    "params: ['ip', 'rate_kbit', 'label', 'rate_kbit_up']" "$js_src"
# null rather than 0 for the symmetric case: 0 would be a ceiling.
assert_eq "every apply path sends null, not 0, when symmetric" "3" \
    "$(grep -c "kbitUp ? parseInt(kbitUp) : null" "$JS")"

# ══════════════════════════════════════════════════════════════════════════
# 7. Persisted records must not overwrite one another
# ════════════════════════════════════════════════════════════════════════════
#
# lib.persist_save replaces the record for one ip+type and keeps the rest. This
# repository has shipped the undelimited version of that comparison twice — the
# block comment that matched 192.168.1.1 inside 192.168.1.10, and the _ul rule
# comment that is a prefix of _ul6 — so the case is pinned rather than reasoned
# about, especially now that records carry an extra field.

printf '[]' > "$RULES"
rl 192.168.1.10  4000 rl_test each     >/dev/null
rl 192.168.1.100 5000 rl_test each     >/dev/null
rl 192.168.1.1   6000 rl_test each 600 >/dev/null

rules=$(cat "$RULES")
assert_eq "three adjacent addresses keep three separate records" "3" \
    "$(printf '%s' "$rules" | grep -o '"type":"ratelimit"' | wc -l | tr -d ' ')"
assert_contains "the .10 record survives saving .1" '"ip":"192.168.1.10","param":"4000"' "$rules"
assert_contains "the .100 record survives too" '"ip":"192.168.1.100","param":"5000"' "$rules"
assert_contains "and .1 is stored with its own upload rate" '"param_up":"600"' "$rules"

# Re-saving one target must replace exactly that record and leave its neighbours.
rl 192.168.1.1 7000 rl_test each >/dev/null
rules=$(cat "$RULES")
assert_eq "re-saving one target still leaves three records" "3" \
    "$(printf '%s' "$rules" | grep -o '"type":"ratelimit"' | wc -l | tr -d ' ')"
assert_contains "the rewritten record has the new rate" '"ip":"192.168.1.1","param":"7000"' "$rules"
assert_not_contains "and dropped the upload rate it no longer has" '"param_up"' "$rules"
assert_contains "the .10 neighbour is untouched" '"ip":"192.168.1.10","param":"4000"' "$rules"

# ── and the REMOVAL side of the same comparison (#79) ──────────────────────
#
# lib.persist_remove selects the record to drop with the same comparison
# persist_save uses to select the one to replace, but until now only the
# save side was pinned. The removal side is where a mis-selection is worse:
# saving the wrong record leaves a visibly wrong rate, while removing the
# wrong one silently deletes a limit that the next reboot then does not
# restore — the damage surfaces long after the cause.
#
# Rate 0 is the removal path of `trafficctl ratelimit`.
rl 192.168.1.1 0 rl_test >/dev/null
rules=$(cat "$RULES")
assert_eq "removing one target leaves its two neighbours" "2" \
    "$(printf '%s' "$rules" | grep -o '"type":"ratelimit"' | wc -l | tr -d ' ')"
assert_not_contains "the removed record is gone" '"ip":"192.168.1.1","' "$rules"
assert_contains "the .10 neighbour survived the removal" '"ip":"192.168.1.10","param":"4000"' "$rules"
assert_contains "the .100 neighbour survived too" '"ip":"192.168.1.100","param":"5000"' "$rules"

# The longest-prefix direction as well: removing .10 must not take .100.
rl 192.168.1.10 0 rl_test >/dev/null
rules=$(cat "$RULES")
assert_eq "removing the shorter of two prefixed addresses leaves the longer" "1" \
    "$(printf '%s' "$rules" | grep -o '"type":"ratelimit"' | wc -l | tr -d ' ')"
assert_contains "and the one left is the longer address" '"ip":"192.168.1.100","param":"5000"' "$rules"


# ════════════════════════════════════════════════════════════════════════════
# Rates are whole numbers
# ════════════════════════════════════════════════════════════════════════════
#
# Shell arithmetic reads "abc" as 0 and "010" as octal. v1.30's
# tctl_rate_bytes then clamped the 0 to 1 byte/s, so a typo became a persisted
# near-total block reported as {"ok":true}. limit.valid_rate keeps the cases
# main's tctl_validate_rate refused.

for r in 1 5000 100000000; do
    assert_eq "valid_rate accepts $r" "$r" "$(tcall trafficctl.limit valid_rate "\"$r\"")"
done
for r in '' 0 abc 1.5 010 -5 1e3 ' 5' 100000001 999999999999999999999; do
    assert_eq "valid_rate refuses '$r'" "" "$(tcall trafficctl.limit valid_rate "\"$r\"")"
done

printf '[]' > "$RULES"
for r in abc 1.5 010 -5 100000001; do
    : > "$NFT_LOG"
    out=$(rl 192.168.1.90 "$r")
    assert_contains "ratelimit: rate '$r' is refused" '"ok":false' "$out"
    assert_not_contains "ratelimit: rate '$r' writes no rule" 'limit rate over' "$(cat "$NFT_LOG")"
done
out=$(rl 192.168.1.90 5000 rl_test each abc)
assert_contains "ratelimit: an invalid upload rate is refused" '"ok":false' "$out"
assert_not_contains "ratelimit: nothing invalid was persisted" '192.168.1.90' "$(cat "$RULES")"
out=$(rl 192.168.1.90 0)
assert_contains "ratelimit: 0 still removes" '"ok":true' "$out"

: > "$SHAPES"
for r in abc 1.5 010 0; do
    : > "$TC_LOG"
    out=$(st_run add 192.168.1.91 "$r")
    assert_contains "shape: rate '$r' is refused" '"ok":false' "$out"
    assert_not_contains "shape: rate '$r' builds no class" '192.168.1.91' "$(cat "$TC_LOG")"
done
out=$(st_run add 192.168.1.91 5000 shape_test abc)
assert_contains "shape: an invalid upload rate is refused" '"ok":false' "$out"
assert_not_contains "shape: nothing invalid was persisted" '192.168.1.91' "$(cat "$SHAPES")"

# ════════════════════════════════════════════════════════════════════════════
# The limiter's netdev table
# ════════════════════════════════════════════════════════════════════════════
#
# Without kmod-nft-netdev the kernel has no netdev family. The table creation
# failed into /dev/null and the result still read as applied.

: > "$LOGGER_LOG"
out=$(NFT_FAIL_TABLE=1 rl 192.168.1.92 5000)
assert_contains "no netdev family: the limit is refused" '"ok":false' "$out"
assert_contains "no netdev family: the reply names kmod-nft-netdev" 'kmod-nft-netdev' "$out"
assert_contains "no netdev family: the failure is logged with nft's error" \
    'Operation not supported' "$(cat "$LOGGER_LOG")"

# ════════════════════════════════════════════════════════════════════════════
# The restore logs real failures only
# ════════════════════════════════════════════════════════════════════════════
#
# `a && b && c || logger` logged "Failed to restore" for every record with no
# rate, where nothing was attempted, and never for a real failure: the nft
# path of tctl_ratelimit_add returns 0 whatever happened.

hook() {
    lt_reset
    printf '%s' "$1" > "$RULES"
    lt_run restore >/dev/null
}

hook '[{"type":"ratelimit","ip":"192.168.1.93","param":"0"},{"type":"ratelimit","ip":"192.168.1.95","param":""},{"type":"pfw_limit","ip":"forward/tcp/192.168.1.94/8080","param":"0"}]'
assert_not_contains "restore: records with no rate log no failure" 'Failed to restore' "$(cat "$LOGGER_LOG")"

hook '[{"type":"ratelimit","ip":"192.168.1.96","param":"abc"}]'
assert_contains "restore: an invalid persisted rate is skipped and logged" \
    'Not restoring ratelimit for 192.168.1.96' "$(cat "$LOGGER_LOG")"
assert_not_contains "restore: and no rule is written for it" '192.168.1.96' "$(cat "$NFT_LOG")"

NFT_FAIL_TABLE=1 hook '[{"type":"ratelimit","ip":"192.168.1.97","param":"5000"}]'
assert_contains "restore: a limit that failed to load is logged" \
    'Failed to restore ratelimit for 192.168.1.97' "$(cat "$LOGGER_LOG")"

hook '[{"type":"ratelimit","ip":"192.168.1.98","param":"5000"}]'
assert_not_contains "restore: a limit that loaded logs nothing" 'Failed to restore' "$(cat "$LOGGER_LOG")"
assert_contains "restore: and its rule is there" 'ip daddr 192.168.1.98' "$(cat "$NFT_LOG")"

# ── rules.json is JSON-edited ─────────────────────────────────────────────
# v1.30's shell writers split the file with awk, and BusyBox awk wiped it
# (main's fix: the /\},\{/ split and the empty-output guard). lib.persist_save
# parses the file instead; a zero-length file and the last record removed are
# pinned in tests/test_persistence.sh.

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
