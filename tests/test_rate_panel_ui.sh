#!/bin/bash
# The Speed Limit panel when its target changes, and what its clicks do.
#
# The panel is shared between the devices and the network-wide target, and
# its rate chips were synced from a device only by that device's poll. After
# "All devices" the chip of the device just left stayed picked: the panel read
# "Every device in every device may use 10 Mbit/s of its own", which looks like
# a limit already in force, and one click on a chip there limited every device
# on the network with no question asked. Off on a shaped device then reported
# "rate limit removed", which reads as if the shape were still there. A device
# poll still in flight when the target changed put that device's chip back on
# the new panel.
#
# applyRate(), updateModeUI() and runSingle() are sliced out of status.js and
# run under node
# with the panel's state stubbed.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

if ! command -v node >/dev/null 2>&1; then
    printf "FAIL: node is not installed\n"
    exit 1
fi

# A nested function of the view, from its line to the closing brace at the
# same indent. String tests, not regexes, so it does not depend on which awk
# runs it (CI has mawk).
slice() {
    awk -v fn="$1" '
        index($0, "\t\tfunction " fn "(") == 1 { inside = 1 }
        inside { print }
        inside && $0 == "\t\t}" { exit }
    ' "$JS"
}

{
    slice applyRate
    awk 'index($0, "\t\tvar _panelFor = ") == 1' "$JS"
    slice updateModeUI
    slice runSingle
} | sed 's/^\t\t//' > "$TMP/slices.js"

cat > "$TMP/run.js" <<'NODE'
var fs = require('fs');
function _(s) { return s; }
function cls() { return { toggle: function() {}, add: function() {}, remove: function() {}, contains: function() { return true; } }; }
var log = [], confirmAnswer = true, confirmAsked = null;
var window = { confirm: function(m) { confirmAsked = m; return confirmAnswer; } };
var self = { _devRate: null };
var sel = '__all__', rate = '0';
var searchSelect = { getValue: function() { return sel; } };
var ratePick = { getValue: function() { return rate; }, setValue: function(v) { rate = v; } };
var scopeInput = { value: 'all' }, scopeExplain = { textContent: 'Every device may use 10 Mbit/s of its own.' };
var _scopeSelected = 'each', _modeSelected = 'shaper', _upPinned = false, _customPinned = false;
var customHidden = false, customRow = { classList: { add: function() { customHidden = true; }, remove: function() { customHidden = false; }, toggle: function() {}, contains: function() { return customHidden; } } };
var statusDiv = {}, status = [];
function showUpRow() {}
function getRateKbit() { return rate; }
function getRateKbitUp() { return ''; }
function rateLabel(k) { return k; }
function setStatus(d, kind, msg) { status.push(kind + ':' + msg); }
function runQuery() {}
function P(v) { return { then: function(f) { var r = f(v); return (r && r.then) ? r : P(r); }, catch: function() { return this; } }; }
var Promise = { all: function(a) { return P(a.map(function(p) { return p._v; })); } };
function callRatelimit(ip, kbit) { log.push('ratelimit ' + ip + ' ' + kbit); var p = P({ ok: true, msg: 'rate limit removed for ' + ip }); p._v = { ok: true, msg: 'rate limit removed for ' + ip }; return p; }
function callShapeRemove(ip) { log.push('shape_remove ' + ip); var p = P({ ok: true, msg: 'shape removed for ' + ip }); p._v = { ok: true, msg: 'shape removed for ' + ip }; return p; }
function callShapeAdd(ip, kbit) { log.push('shape_add ' + ip + ' ' + kbit); return P({ ok: true }); }
function isAllMode() { return sel === '__all__'; }
var actionRow = { classList: cls() }, rateLimitRow = { classList: cls() }, scopeRow = { classList: cls() };
var modeToggle = { classList: cls() }, rdnsCheck = { classList: cls() }, extStatsCheck = { classList: cls() };
var overviewCheck = { classList: cls() }, overviewDiv = { classList: cls() }, extStatsDiv = { classList: cls() };
function renderSubnetLimits() {}
function loadOpts() { return {}; }
eval(fs.readFileSync(process.argv[2], 'utf8'));

var out = [];
function step(name, fn) { log = []; status = []; confirmAsked = null; fn(); out.push(name + ': ' + log.join(', ') + (confirmAsked ? ' [asked]' : '') + ' | ' + status.join(' ')); }

// A device with a 10 Mbit/s shape, then "All devices".
sel = '192.168.1.50'; updateModeUI(); rate = '10000';
sel = '__all__'; updateModeUI();
out.push('after All devices the chip is ' + rate);

step('declined', function() { rate = '10000'; customHidden = false; _customPinned = true; confirmAnswer = false; applyRate(); });
out.push('declined leaves the chip at ' + rate + ', custom ' + (customHidden ? 'closed' : 'open') + (_customPinned ? ' pinned' : ''));
step('confirmed', function() { rate = '10000'; confirmAnswer = true; applyRate(); });
step('network off', function() { rate = '0'; applyRate(); });

sel = '192.168.1.50'; updateModeUI();
self._devRate = { ip: '192.168.1.50', shape: 10000, limit: 0 };
step('off shaped', function() { rate = '0'; applyRate(); });
self._devRate = { ip: '192.168.1.50', shape: 0, limit: 5000 };
step('off limited', function() { rate = '0'; applyRate(); });
step('device limit', function() { _modeSelected = 'limiter'; rate = '5000'; applyRate(); });

// A device poll answered after the panel went to "All devices": nothing of
// it may reach the panel.
var pending = null, readPast = false, pollsEnded = 0;
Promise.all = function() { return { then: function(f) { pending = f; return { catch: function() {} }; } }; };
var opts = { get showStats() { readPast = true; return false; } };
function pollStart() {}
function pollEnd() { pollsEnded++; }
function callDevice() {}
self._localNames = { get: function() {} };
sel = '192.168.1.50'; rate = '0'; runSingle('192.168.1.50');
sel = '__all__';
try { pending([{ shape_kbit: 10000, protocols: {} }, {}]); } catch (e) {}
out.push('late poll: ' + (readPast ? 'used' : 'dropped') + ', poll ended ' + pollsEnded + ', chip ' + rate);
console.log(out.join('\n'));
NODE

got=$(node "$TMP/run.js" "$TMP/slices.js" 2>&1)
# Every scenario prints a line; without them node failed, and its error says why.
if ! printf '%s\n' "$got" | grep -q '^late poll:'; then
    printf "node output:\n%s\n" "$got"
fi
line() { printf '%s\n' "$got" | grep -F "$1:" | head -1; }

assert_eq "harness: the three functions were sliced" "3" "$(grep -cE '^function (applyRate|updateModeUI|runSingle)\(' "$TMP/slices.js")"
assert_eq "a device's rate is not carried onto the network-wide panel" \
    "after All devices the chip is 0" "$(printf '%s\n' "$got" | grep -F 'after All devices')"
assert_eq "a network-wide limit is asked first; no means nothing is sent" \
    "declined:  [asked] | " "$(line declined)"
assert_eq "declining puts the chip back to Off and closes the custom field" \
    "declined leaves the chip at 0, custom closed" "$(printf '%s\n' "$got" | grep -F 'declined leaves')"
assert_eq "a network-wide limit goes out after a yes" \
    "confirmed: ratelimit all 10000 [asked] | loading:Limiting all → 10000 (each)… action:rate limit removed for all" "$(line confirmed)"
assert_eq "lifting the network-wide limit is not asked" \
    "network off: ratelimit all 0 | loading:Removing throttle… ok:rate limit removed for all" "$(line 'network off')"
assert_eq "Off on a shaped device names the shape" \
    "off shaped: ratelimit 192.168.1.50 0, shape_remove 192.168.1.50 | loading:Removing throttle… ok:shape removed for 192.168.1.50" "$(line 'off shaped')"
assert_eq "Off on a limited device names the limit" \
    "off limited: ratelimit 192.168.1.50 0, shape_remove 192.168.1.50 | loading:Removing throttle… ok:rate limit removed for 192.168.1.50" "$(line 'off limited')"
assert_eq "a device limit is not asked" \
    "device limit: shape_remove 192.168.1.50, ratelimit 192.168.1.50 5000" "$(line 'device limit' | sed 's/ |.*//')"
assert_eq "a device poll answered after the target changed is dropped" \
    "late poll: dropped, poll ended 1, chip 0" "$(line 'late poll')"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
