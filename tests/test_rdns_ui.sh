#!/bin/bash
# Destination names in the device view behind AdGuard Home (#165).
#
# The view resolves the public destinations of a device's connections with
# network.rrdns, which replies once every query is answered or the timeout
# (5 s) has run out. AdGuard Home on :53 (dnsmasq moved to :54) allows each
# client 20 queries a second by default and drops the rest without an answer;
# the router is one client. The view sent every unresolved destination in one
# batch, and the device poll restarts every 3 s and threw away any reply that
# came back after the next poll had begun. More than 20 destinations therefore
# meant: 20 answered, the rest dropped, rrdns waits 5 s, the reply is
# discarded, the next tick sends the same batch. No name ever appeared.
#
# Reproduced on an OpenWrt 25.12.4 rootfs with adguardhome 0.107 on :53 and
# dnsmasq on :54: one rrdns batch of 21 addresses resolved 20 and took 5 s; of
# 80, 20 in 5 s. With AGH's ratelimit set to 0, or dnsmasq on :53, 80 of 80
# came back at once.
#
# The scheduling is SLICED OUT OF status.js and driven against a model of
# that resolver with a virtual clock, so it cannot drift into testing a copy.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}

if ! command -v node >/dev/null 2>&1; then
    printf "SKIP: node is not installed — the frontend slices cannot be run here.\n"
    printf "0 passed, 0 failed\n"
    exit 0
fi

slice() {
    awk -v fn="$1" '
        $0 ~ "^function " fn "\\(" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$JS"
}

{
    grep -E '^var RDNS_[A-Z_]+ = ' "$JS"
    for fn in rdnsState rdnsPick rdnsShown rdnsResolve; do slice "$fn"; done
} > "$TMP/slices.js"

for fn in rdnsState rdnsPick rdnsShown rdnsResolve; do
    assert_eq "status.js defines $fn" "1" "$(grep -c "^function $fn(" "$JS")"
done

# The rrdns callback must not be gated on the poll generation any more: that
# guard is what threw the late replies away.
assert_eq "no rDNS reply is dropped for a newer poll" "0" \
    "$(grep -c 'gen !== self._queryGen' "$JS")"

cat > "$TMP/sim.js" <<'EOF'
// Virtual clock and event queue.
var now = 0, events = [];
function at(t, fn) { events.push({ t: t, fn: fn }); events.sort(function(a, b) { return a.t - b.t; }); }
function flush() { return new Promise(function(r) { setImmediate(r); }); }
async function runUntil(end) {
    while (events.length && events[0].t <= end) {
        var e = events.shift();
        now = e.t;
        e.fn();
        await flush();
    }
    now = end;
}

// AdGuard Home in front of the router: at most RL queries from this client in
// any 1000 ms window are answered (after 10 ms); the rest get no answer at
// all. rrdns replies when every query is answered, else at its timeout with
// what it has.
var RL = 20, sent = [], dupInFlight = 0, inFlight = {}, worstWindow = 0;
function lookup(addrs) {
    return new Promise(function(resolve) {
        var answered = {}, waiting = 0, t0 = now;
        addrs.forEach(function(a) {
            if (inFlight[a]) dupInFlight++;
            inFlight[a] = true;
            var recent = sent.filter(function(t) { return t > t0 - 1000; }).length;
            sent.push(t0);
            worstWindow = Math.max(worstWindow, recent + 1);
            if (recent < RL) { answered[a] = 'host-' + a.replace(/\./g, '-') + '.example.net'; }
            else waiting++;
        });
        var finish = function() { addrs.forEach(function(a) { delete inFlight[a]; }); resolve(answered); };
        at(t0 + (waiting ? RDNS_TIMEOUT : 10), finish);
    });
}

var mode = process.argv[2];
var st = rdnsState(), painted = {};
function paint(a, h) { painted[a] = h; }
function clock() { return now; }

var dsts = [];
for (var i = 1; i <= 60; i++) dsts.push('45.33.0.' + i);

function tick() {
    rdnsResolve(st, rdnsPick(st, dsts, now), lookup, paint, clock);
}

(async function() {
    if (mode === 'ticks') {
        // The device poll: every 3 s for 30 s.
        for (var t = 0; t < 30000; t += 3000) at(t, tick);
        await runUntil(30000);
        var named = dsts.filter(function(a) { return !!painted[a]; }).length;
        console.log([named, worstWindow <= RL ? 'ok' : 'burst ' + worstWindow, dupInFlight].join(' '));
    } else if (mode === 'late') {
        // A reply that lands after the next poll has begun is still used.
        var p = rdnsResolve(st, ['45.33.0.1'], function() {
            return new Promise(function(r) { at(5000, function() { r({ '45.33.0.1': 'late.example.net' }); }); });
        }, paint, clock);
        at(3000, function() { tick(); });
        await runUntil(6000);
        await p;
        console.log([rdnsShown(st, '45.33.0.1'), painted['45.33.0.1']].join(' '));
    } else if (mode === 'pending') {
        // In flight: not picked again, and shown as still resolving.
        rdnsResolve(st, ['45.33.0.1'], function() { return new Promise(function() {}); }, paint, clock);
        console.log([rdnsPick(st, ['45.33.0.1', '45.33.0.2'], 0).join(','), String(rdnsShown(st, '45.33.0.1'))].join(' '));
    } else if (mode === 'retry') {
        // No answer, or a failed call: "—" now, asked again after RDNS_RETRY_MS.
        await rdnsResolve(st, ['45.33.0.1'], function() { return Promise.resolve({}); }, paint, clock);
        await rdnsResolve(st, ['45.33.0.2'], function() { return Promise.reject(new Error('x')); }, paint, clock);
        var shown = [String(rdnsShown(st, '45.33.0.1')), String(rdnsShown(st, '45.33.0.2'))].join(',');
        var soon = rdnsPick(st, ['45.33.0.1', '45.33.0.2'], RDNS_RETRY_MS - 1).length;
        var later = rdnsPick(st, ['45.33.0.1', '45.33.0.2'], RDNS_RETRY_MS).length;
        console.log([shown, soon, later].join(' '));
    } else if (mode === 'batch') {
        console.log(rdnsPick(st, dsts, 0).length);
    }
})();
EOF

run() { cat "$TMP/slices.js" "$TMP/sim.js" > "$TMP/all.js"; node "$TMP/all.js" "$1" 2>&1 | tail -1; }

assert_eq "60 destinations behind AGH: all named within 30 s, never over 20 q/s, nothing sent twice" \
    "60 ok 0" "$(run ticks)"
assert_eq "a reply that arrives after the next poll is kept and painted" \
    "late.example.net late.example.net" "$(run late)"
assert_eq "an address in flight is not picked again and still shows as resolving" \
    "45.33.0.2 undefined" "$(run pending)"
assert_eq "no answer and a failed call show '—', and are retried after RDNS_RETRY_MS" \
    "null,null 0 2" "$(run retry)"
assert_eq "one tick asks for at most RDNS_BATCH addresses, under AGH's 20/s" \
    "16" "$(run batch)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
