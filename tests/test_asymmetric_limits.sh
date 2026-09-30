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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/luci-app-trafficctl/root/usr/local/bin"
HOTPLUG="$ROOT/luci-app-trafficctl/root/etc/hotplug.d/iface/99-trafficctl-shapes"
RPCD="$ROOT/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MOCKBIN="$TMP/bin"
mkdir -p "$MOCKBIN"
SHAPES="$TMP/shapes.json"
RULES="$TMP/rules.json"
NFT_LOG="$TMP/nft.log"
TC_LOG="$TMP/tc.log"

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

# ── mocks ───────────────────────────────────────────────────────────────────

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    network.lan.device) echo "br-lan" ;;
    network.wan.device) echo "eth1" ;;
    "firewall.@zone[0].name")    echo "lan" ;;
    "firewall.@zone[0].network") echo "lan" ;;
    "firewall.@zone[1].name")    echo "wan" ;;
    "firewall.@zone[1].network") echo "wan" ;;
    trafficctl.main.persist_rules) [ -f "$TCTL_TEST_PERSIST" ] && echo "1" || exit 1 ;;
    *) exit 1 ;;
esac
MOCK

cat > "$MOCKBIN/ubus" <<'MOCK'
#!/bin/sh
case "$2" in
    network.interface.wan) echo '{"l3_device":"eth1"}' ;;
    *) echo '{"l3_device":"br-lan","ipv4-address":[{"address":"192.168.1.1","mask":24}]}' ;;
esac
MOCK

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
if [ -n "$file" ]; then
    [ -f "$file" ] || exit 1
    input=$(cat "$file")
else
    input=$(cat)
fi
case "$expr" in
    '@.l3_device') echo "$input" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].address') echo "$input" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].mask') echo "$input" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p' ;;
    '@.'*)
        key=${expr#@.}
        printf '%s' "$input" | sed -n "s/.*\"$key\":\([0-9][0-9]*\).*/\1/p" | head -1
        ;;
    '@[*].ip')
        printf '%s' "$input" | tr ',' '\n' | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p'
        ;;
    "@[@.ip='"*"']."*)
        want=$(echo "$expr" | sed -n "s/^@\[@\.ip='\([^']*\)'\]\..*/\1/p")
        key=$(echo "$expr" | sed -n "s/^@\[@\.ip='[^']*'\]\.\(.*\)$/\1/p")
        printf '%s' "$input" | awk -v w="$want" -v k="$key" '
        {
            gsub(/^\[/, ""); gsub(/\]$/, "")
            n = split($0, a, "},{")
            for (i = 1; i <= n; i++) {
                s = a[i]
                if (s !~ "\"ip\":\"" w "\",") continue
                if (match(s, "\"" k "\":[0-9]+")) {
                    t = substr(s, RSTART, RLENGTH)
                    sub("\"" k "\":", "", t)
                    print t
                }
                exit
            }
        }'
        ;;
    '@[*]') printf '%s' "$input" | awk '{ n = split($0, a, "},{"); for (i = 1; i <= n; i++) print i }' ;;
    '@['*'].'*)
        idx=$(echo "$expr" | sed -n 's/^@\[\([0-9]*\)\]\..*/\1/p')
        key=$(echo "$expr" | sed -n 's/^@\[[0-9]*\]\.\(.*\)$/\1/p')
        printf '%s' "$input" | awk -v n="$idx" -v k="$key" '
        {
            gsub(/^\[/, ""); gsub(/\]$/, "")
            m = split($0, a, "},{")
            if (n + 1 > m) exit
            s = a[n + 1]
            if (match(s, "\"" k "\":\"[^\"]*\"")) {
                t = substr(s, RSTART, RLENGTH)
                sub("\"" k "\":\"", "", t)
                sub("\"$", "", t)
                print t
            }
        }'
        ;;
esac
MOCK

cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
printf '%s\n' "\$*" >> "$NFT_LOG"
case "\$*" in
    # fw.sh selects the nft backend only if this lists something.
    "list tables") echo "table inet fw4" ;;
esac
exit 0
MOCK

cat > "$MOCKBIN/tc" <<MOCK
#!/bin/sh
printf '%s\n' "\$*" >> "$TC_LOG"
case "\$*" in
    # ensure_ifb's last act is to confirm the IFB root class exists, and it
    # returns failure if it does not — without this the upload half is skipped
    # and the test would be measuring a missing kmod-ifb rather than the rates.
    # Only the root class is reported: minor 1 is below CLASSID_MIN, so this
    # does not feed the allocator and the record format stays the only thing
    # deciding which minors are taken.
    "class show dev "*) echo "class htb 1:1 root rate 1000Mbit ceil 1000Mbit burst 125000b cburst 125000b" ;;
esac
exit 0
MOCK

for m in logger conntrack ip; do
    printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/$m"
done

chmod +x "$MOCKBIN"/*

export TCTL_TEST_PERSIST="$TMP/persist_on"
mkdir -p "$TMP/sys/class/net/br-lan/brif/lan1"
export TCTL_SYSFS_NET="$TMP/sys/class/net"

# The shipped scripts name their state files by absolute path, as they must on
# a router; rewrite those into the scratch directory rather than adding
# test-only seams to production code.
FW="$TMP/trafficctl-fw.sh"
sed -e "s|TCTL_RULES_FILE=\"/etc/trafficctl/rules.json\"|TCTL_RULES_FILE=\"$RULES\"|" \
    "$BIN/trafficctl-fw.sh" > "$FW"

patch_script() {
    sed -e "s|/usr/local/bin/trafficctl-fw.sh|$FW|" \
        -e "s|SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|SHAPES_FILE=\"$SHAPES\"|" \
        -e "s|SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|SHAPES_FILE=\"$SHAPES\"|" \
        -e "s|RULES_FILE=\"/etc/trafficctl/rules.json\"|RULES_FILE=\"$RULES\"|" \
        -e "s|/usr/local/bin/trafficctl-shape.sh|$TMP/shape.sh|" \
        "$1" > "$2"
    chmod +x "$2"
}
patch_script "$BIN/trafficctl-shape.sh"     "$TMP/shape.sh"
patch_script "$BIN/trafficctl-ratelimit.sh" "$TMP/ratelimit.sh"
patch_script "$HOTPLUG"                     "$TMP/hotplug"

assert_not_contains "harness: no production shapes path survived the rewrite" \
    "/etc/trafficctl/shapes.json" "$(cat "$TMP/shape.sh")"

run() { PATH="$MOCKBIN:$PATH" sh "$@" 2>/dev/null; }

# Source only the record helpers out of the patched shaper, so they can be
# called directly without going through its action dispatch.
slice_helpers() {
    awk '/^SHAPES_FILE=/ { print }
         /^re_quote\(\)/, /^}/ { print }
         /^shapes_entries\(\)/, /^}/ { print }
         /^lookup_classid\(\)/, /^}/ { print }
         /^lookup_rate_up\(\)/, /^}/ { print }
         /^used_minors\(\)/, /^}/ { print }
         /^alloc_classid\(\)/, /^}/ { print }
         /^CLASSID_MIN=/ { print }
         /^CLASSID_MAX=/ { print }' "$TMP/shape.sh" > "$TMP/helpers.sh"
    printf 'LAN_DEV=br-lan\nIFB_DEV=tctl-ifb0\n' >> "$TMP/helpers.sh"
}
slice_helpers

helper() {
    PATH="$MOCKBIN:$PATH" sh -c ". '$TMP/helpers.sh'; $1" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════════════
# 1. The record format — an asymmetric record must still be VISIBLE
# ════════════════════════════════════════════════════════════════════════════
#
# This is the section that matters. If the reader does not recognise the new
# record, the allocator reuses its class and two devices collide.

printf '[{"ip":"192.168.1.50","rate_kbit":20000,"classid":"1:2","rate_kbit_up":2000}]' > "$SHAPES"

assert_eq "an asymmetric record is seen by shapes_entries" "1" \
    "$(helper 'shapes_entries | wc -l' | tr -d ' ')"
assert_eq "its classid is found" "1:2" "$(helper 'lookup_classid 192.168.1.50')"
assert_eq "its upload ceiling is read back" "2000" "$(helper 'lookup_rate_up 192.168.1.50')"
# The collision test: minor 2 is taken, so the next allocation must not be 1:2.
assert_eq "the allocator does NOT reuse a minor held by an asymmetric record" "1:3" \
    "$(helper 'alloc_classid')"

# ── and an old symmetric record must keep working unchanged ─────────────────

printf '[{"ip":"10.0.0.7","rate_kbit":5000,"classid":"1:4"}]' > "$SHAPES"
assert_eq "a pre-existing symmetric record is still seen" "1" \
    "$(helper 'shapes_entries | wc -l' | tr -d ' ')"
assert_eq "its classid is still found" "1:4" "$(helper 'lookup_classid 10.0.0.7')"
assert_eq "it reports no upload ceiling, meaning symmetric" "" \
    "$(helper 'lookup_rate_up 10.0.0.7')"
assert_eq "the allocator skips its minor too" "1:2" "$(helper 'alloc_classid')"

# ── a file holding both forms at once, which is what an upgrade produces ────

printf '[{"ip":"10.0.0.7","rate_kbit":5000,"classid":"1:2"},{"ip":"10.0.0.8","rate_kbit":9000,"classid":"1:3","rate_kbit_up":1000}]' > "$SHAPES"
assert_eq "both forms are seen side by side" "2" \
    "$(helper 'shapes_entries | wc -l' | tr -d ' ')"
assert_eq "old-form classid in a mixed file" "1:2" "$(helper 'lookup_classid 10.0.0.7')"
assert_eq "new-form classid in a mixed file" "1:3" "$(helper 'lookup_classid 10.0.0.8')"
assert_eq "allocation skips both minors" "1:4" "$(helper 'alloc_classid')"

# ════════════════════════════════════════════════════════════════════════════
# 2. The shaper applies two different ceilings
# ════════════════════════════════════════════════════════════════════════════

: > "$SHAPES"; printf '[]' > "$SHAPES"
: > "$TC_LOG"
out=$(run "$TMP/shape.sh" add 192.168.1.60 20000 shape_test 2000)

assert_contains "shaper reports both ceilings when they differ" \
    "20000 kbit/s down, 2000 kbit/s up" "$out"
assert_contains "download class gets the download rate" "rate 20000kbit" "$(cat "$TC_LOG")"
assert_contains "upload class gets the upload rate" "rate 2000kbit" "$(cat "$TC_LOG")"
assert_contains "the asymmetric record is persisted" '"rate_kbit_up":2000' "$(cat "$SHAPES")"

# Burst is 10ms of the rate it belongs to; reusing the download burst for a
# much smaller upload ceiling would let the upload burst far past its cap.
assert_contains "upload burst is sized from the upload rate" "burst 2500b" "$(cat "$TC_LOG")"

# ── symmetric still writes exactly the record it always wrote ──────────────

printf '[]' > "$SHAPES"
: > "$TC_LOG"
out=$(run "$TMP/shape.sh" add 192.168.1.61 5000 shape_test)
assert_eq "a symmetric shape writes the pre-feature record verbatim" \
    '[{"ip":"192.168.1.61","rate_kbit":5000,"classid":"1:2"}]' "$(cat "$SHAPES")"
assert_not_contains "no upload field appears for a symmetric shape" \
    "rate_kbit_up" "$(cat "$SHAPES")"
assert_contains "and it reports a single figure" "shape 5000 kbit/s applied" "$out"

# Explicitly equal rates are symmetric, not a special asymmetric case.
printf '[]' > "$SHAPES"
run "$TMP/shape.sh" add 192.168.1.62 5000 shape_test 5000 >/dev/null
assert_not_contains "an explicitly equal upload rate still writes no field" \
    "rate_kbit_up" "$(cat "$SHAPES")"

# ════════════════════════════════════════════════════════════════════════════
# 3. The limiter polices two different rates
# ════════════════════════════════════════════════════════════════════════════

: > "$NFT_LOG"
out=$(run "$TMP/ratelimit.sh" 192.168.1.70 8000 rl_test each 800)

# 8000 kbit is 1000 kbytes/s; 800 kbit is 100.
assert_contains "download rule takes the download rate" \
    "ip daddr 192.168.1.70 meter tctl_d_" "$(cat "$NFT_LOG")"
assert_contains "download rate reaches nft as kbytes" "1000 kbytes/second" "$(cat "$NFT_LOG")"
assert_contains "upload rate reaches nft as kbytes" "100 kbytes/second" "$(cat "$NFT_LOG")"
assert_contains "limiter reports both figures" "8000 kbit/s down, 800 kbit/s up" "$out"

# ── absence means symmetric, and never zero ────────────────────────────────

: > "$NFT_LOG"
out=$(run "$TMP/ratelimit.sh" 192.168.1.71 8000 rl_test each)
assert_contains "a limit with no upload argument polices upload at the same rate" \
    "1000 kbytes/second" "$(cat "$NFT_LOG")"
# 1 kbyte/s is what rate 0 would floor to — the total-block signature.
assert_not_contains "an omitted upload rate is NOT read as zero" \
    "over 1 kbytes/second" "$(cat "$NFT_LOG")"
assert_contains "and it reports a single figure" "8000 kbit/s for" "$out"

# ════════════════════════════════════════════════════════════════════════════
# 4. Persistence and the reboot restore
# ════════════════════════════════════════════════════════════════════════════

: > "$TCTL_TEST_PERSIST"
printf '[]' > "$RULES"
run "$TMP/ratelimit.sh" 192.168.1.80 8000 rl_test each 800 >/dev/null
assert_contains "an asymmetric limit persists its upload rate" '"param_up":"800"' "$(cat "$RULES")"

printf '[]' > "$RULES"
run "$TMP/ratelimit.sh" 192.168.1.81 8000 rl_test each >/dev/null
assert_not_contains "a symmetric limit writes no upload field" "param_up" "$(cat "$RULES")"
assert_contains "and still records mode and rate as before" '"mode":"each"' "$(cat "$RULES")"

# ── the restore hook must carry the upload rate back ───────────────────────

: > "$NFT_LOG"
printf '[{"type":"ratelimit","ip":"192.168.1.90","param":"8000","mode":"each","param_up":"800"}]' > "$RULES"
printf '[]' > "$SHAPES"
INTERFACE=lan ACTION=ifup run "$TMP/hotplug" >/dev/null 2>&1
assert_contains "restore re-applies the download rate" "1000 kbytes/second" "$(cat "$NFT_LOG")"
assert_contains "restore re-applies the upload rate" "100 kbytes/second" "$(cat "$NFT_LOG")"

# A record from before the feature must come back symmetric, not zeroed.
: > "$NFT_LOG"
printf '[{"type":"ratelimit","ip":"192.168.1.91","param":"8000","mode":"each"}]' > "$RULES"
INTERFACE=lan ACTION=ifup run "$TMP/hotplug" >/dev/null 2>&1
assert_contains "a pre-feature record restores symmetrically" "1000 kbytes/second" "$(cat "$NFT_LOG")"
assert_not_contains "a pre-feature record does not restore as a total upload block" \
    "over 1 kbytes/second" "$(cat "$NFT_LOG")"

# ── and the shaper's restore path ──────────────────────────────────────────

: > "$TC_LOG"
printf '[]' > "$RULES"
printf '[{"ip":"192.168.1.92","rate_kbit":20000,"classid":"1:2","rate_kbit_up":2000}]' > "$SHAPES"
INTERFACE=lan ACTION=ifup run "$TMP/hotplug" >/dev/null 2>&1
assert_contains "shape restore re-applies the download ceiling" "rate 20000kbit" "$(cat "$TC_LOG")"
assert_contains "shape restore re-applies the upload ceiling" "rate 2000kbit" "$(cat "$TC_LOG")"

# ════════════════════════════════════════════════════════════════════════════
# 5. The rpcd surface
# ════════════════════════════════════════════════════════════════════════════
#
# Read statically: the handlers shell out, and what matters is that a missing
# or zero field is normalised to "symmetric" before it gets there.

rpcd_src=$(cat "$RPCD")
assert_contains "ratelimit accepts an upload rate" '"rate_kbit_up":"int"' "$rpcd_src"
assert_contains "ratelimit passes it to the script" \
    '"$ip" "${rate:-0}" "$label" "$mode" "$rate_up"' "$rpcd_src"
assert_contains "shape_add passes it to the script" \
    'add "$ip" "$rate" "$label" "$rate_up"' "$rpcd_src"
assert_eq "both handlers normalise a zero upload rate away" "2" \
    "$(grep -c '\[ "\$rate_up" = "0" \] && rate_up=""' "$RPCD")"

# ════════════════════════════════════════════════════════════════════════════
# 6. The frontend
# ════════════════════════════════════════════════════════════════════════════
#
# getRateKbitUp is the one place in the UI that decides between "symmetric" and
# "a second ceiling", and the distinction it has to preserve is empty-vs-zero:
# an empty string means symmetric, while a 0 would reach the backend as a
# ceiling and floor to one kbyte/second — a total upload block. It is sliced out
# of status.js rather than restated, so this cannot drift into testing a copy.

JS="$ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"

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
# tctl_persist_save replaces the record for one ip+type and keeps the rest. This
# repository has shipped the undelimited version of that comparison twice — the
# block comment that matched 192.168.1.1 inside 192.168.1.10, and the _ul rule
# comment that is a prefix of _ul6 — so the case is pinned rather than reasoned
# about, especially now that records carry an extra field.

: > "$TCTL_TEST_PERSIST"
printf '[]' > "$RULES"
run "$TMP/ratelimit.sh" 192.168.1.10  4000 rl_test each     >/dev/null
run "$TMP/ratelimit.sh" 192.168.1.100 5000 rl_test each     >/dev/null
run "$TMP/ratelimit.sh" 192.168.1.1   6000 rl_test each 600 >/dev/null

rules=$(cat "$RULES")
assert_eq "three adjacent addresses keep three separate records" "3" \
    "$(printf '%s' "$rules" | grep -o '"type":"ratelimit"' | wc -l | tr -d ' ')"
assert_contains "the .10 record survives saving .1" '"ip":"192.168.1.10","param":"4000"' "$rules"
assert_contains "the .100 record survives too" '"ip":"192.168.1.100","param":"5000"' "$rules"
assert_contains "and .1 is stored with its own upload rate" '"param_up":"600"' "$rules"

# Re-saving one target must replace exactly that record and leave its neighbours.
run "$TMP/ratelimit.sh" 192.168.1.1 7000 rl_test each >/dev/null
rules=$(cat "$RULES")
assert_eq "re-saving one target still leaves three records" "3" \
    "$(printf '%s' "$rules" | grep -o '"type":"ratelimit"' | wc -l | tr -d ' ')"
assert_contains "the rewritten record has the new rate" '"ip":"192.168.1.1","param":"7000"' "$rules"
assert_not_contains "and dropped the upload rate it no longer has" '"param_up"' "$rules"
assert_contains "the .10 neighbour is untouched" '"ip":"192.168.1.10","param":"4000"' "$rules"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
