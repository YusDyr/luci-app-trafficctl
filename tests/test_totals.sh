#!/bin/bash
# Tests for trafficctl-totals.sh — the shared monotonic byte accumulator that
# backs both the LuCI Bytes/TCP/UDP columns and trafficctl_device_bytes_total.
#
# The interesting behaviour is all in what the script REFUSES to count, and
# none of it is visible by eyeballing a single sample:
#
#   * conntrack sums fall when flows expire. Counting that as movement would
#     rewind a counter that is documented as monotonic; ignoring the drop
#     entirely (rather than resyncing) would double-count the next sample.
#   * the byte source switches at runtime — trafficctl-bytes.sh hands over to
#     the nft counter maps when flow offload stops conntrack from counting, and
#     trafficctl-bytes-nft.sh hands back when the kernel has no dynamic maps.
#     The two counters have unrelated magnitudes (live flows vs. everything
#     since the table was built), so a switch must rebaseline. Without that,
#     enabling offload adds an entire nft map to the total in one tick.
#   * the nft path cannot split TCP from UDP at all. Those totals have to read
#     "unavailable", not "zero" — issue #26 is precisely about a byte column
#     that showed a number nobody could explain.
#
# The script is run for real; only trafficctl-bytes.sh and the state/lock paths
# are substituted.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

STATE="$TMPDIR/totals.state"
SAMPLE="$TMPDIR/sample.json"
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
        printf "FAIL: %s\n  should NOT contain: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}

sed -e "s|/usr/local/bin/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" \
    -e "s|STATE=\"/tmp/trafficctl_totals.state\"|STATE=\"$STATE\"|" \
    -e "s|LOCKD=\"/tmp/trafficctl_totals.lock.d\"|LOCKD=\"$TMPDIR/lock.d\"|" \
    -e "s|/usr/local/bin/trafficctl-bytes.sh|$MOCKBIN/bytes|" \
    "$BIN/trafficctl-totals.sh" > "$TMPDIR/totals.sh"

# Every substitution above must have landed: sed exits 0 on no-match, so a
# renamed path would silently leave the script pointing at the REAL /tmp state
# file and the tests would pass while measuring the wrong thing.
for must in "$STATE" "$TMPDIR/lock.d" "$MOCKBIN/bytes"; do
    assert_contains "rewrote path into the script under test: $must" \
        "$must" "$(cat "$TMPDIR/totals.sh")"
done
assert_not_contains "no stale reference to the production state file" \
    "/tmp/trafficctl_totals.state" "$(cat "$TMPDIR/totals.sh")"

cat > "$MOCKBIN/bytes" <<MOCK
#!/bin/sh
cat "$SAMPLE"
MOCK
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN"/*

run()    { PATH="$MOCKBIN:$PATH" sh "$TMPDIR/totals.sh" 2>/dev/null; }
runall() { PATH="$MOCKBIN:$PATH" sh "$TMPDIR/totals.sh" --all 2>/dev/null; }
sample() { printf '%s\n' "$1" > "$SAMPLE"; }

IP='10.0.20.11'

# ── first sample establishes the total ──────────────────────────────────────
sample '[{"ip":"10.0.20.11","bytes_in":1000,"bytes_out":500,"bytes_tcp":1200,"bytes_udp":300,"src":"ct"}]'
OUT=$(run)
assert_contains "first sample seeds the download total"  '"bytes_in_total":1000'  "$OUT"
assert_contains "first sample seeds the upload total"    '"bytes_out_total":500'  "$OUT"
assert_contains "first sample seeds the TCP total"       '"bytes_tcp_total":1200' "$OUT"
assert_contains "first sample seeds the UDP total"       '"bytes_udp_total":300'  "$OUT"
assert_contains "raw sample is passed through for the speed graph" '"bytes_in":1000' "$OUT"
assert_contains "device in the sample is marked live"    '"live":true' "$OUT"

# ── growth adds the delta, not the raw value again ──────────────────────────
sample '[{"ip":"10.0.20.11","bytes_in":1500,"bytes_out":900,"bytes_tcp":2000,"bytes_udp":400,"src":"ct"}]'
OUT=$(run)
assert_contains "growth adds only the delta"        '"bytes_in_total":1500'  "$OUT"
assert_contains "upload tracked independently"      '"bytes_out_total":900'  "$OUT"
assert_contains "TCP total follows the same rule"   '"bytes_tcp_total":2000' "$OUT"

# ── expiry must not rewind, and must not be re-counted afterwards ───────────
# The raw sum collapses because flows aged out. Those bytes are already in the
# total, so the counter holds — and the NEXT rise must be measured from the
# collapsed value, otherwise the same traffic is counted twice.
sample '[{"ip":"10.0.20.11","bytes_in":200,"bytes_out":100,"bytes_tcp":50,"bytes_udp":20,"src":"ct"}]'
OUT=$(run)
assert_contains "expiry does not rewind the total"  '"bytes_in_total":1500' "$OUT"
assert_not_contains "collapsed raw sum never becomes the total" \
    '"bytes_in_total":200' "$OUT"

sample '[{"ip":"10.0.20.11","bytes_in":700,"bytes_out":100,"bytes_tcp":50,"bytes_udp":20,"src":"ct"}]'
OUT=$(run)
assert_contains "growth after an expiry resumes from the new baseline" \
    '"bytes_in_total":2000' "$OUT"

# ── the byte source switching must not fabricate traffic ────────────────────
# Enabling hardware flow offload moves trafficctl-bytes.sh onto the nft counter
# maps, which are cumulative since the table was created — here 900 MB of it.
# Differencing that against the conntrack baseline would add 900 MB to this
# device's lifetime total in a single tick.
sample '[{"ip":"10.0.20.11","bytes_in":900000000,"bytes_out":100,"bytes_tcp":-1,"bytes_udp":-1,"src":"nft"}]'
OUT=$(run)
assert_contains "source switch rebaselines instead of counting the whole map" \
    '"bytes_in_total":2000' "$OUT"
assert_not_contains "no 900 MB phantom delta on the switch" \
    '"bytes_in_total":900000000' "$OUT"
assert_contains "the switch is recorded in the state file" " nft " "$(cat "$STATE")"

# Traffic AFTER the switch is still counted, from the nft baseline.
sample '[{"ip":"10.0.20.11","bytes_in":900001000,"bytes_out":100,"bytes_tcp":-1,"bytes_udp":-1,"src":"nft"}]'
OUT=$(run)
assert_contains "growth on the new source accumulates normally" \
    '"bytes_in_total":3000' "$OUT"

# ── the protocol split is "unavailable", not zero, on the nft path ──────────
assert_contains "TCP total reports unavailable under offload" \
    '"bytes_tcp_total":-1' "$OUT"
assert_contains "UDP total reports unavailable under offload" \
    '"bytes_udp_total":-1' "$OUT"

# ── coming back from offload must not dump the frozen gap into the total ────
# tcp was last seen at 50 before offload hid it. Differencing the returning
# sample against that stale value would invent the entire intervening window.
sample '[{"ip":"10.0.20.11","bytes_in":900002000,"bytes_out":100,"bytes_tcp":800000,"bytes_udp":30,"src":"ct"}]'
OUT=$(run)
assert_contains "returning from offload rebaselines the whole sample" \
    '"bytes_tcp_total":2000' "$OUT"
assert_not_contains "stale pre-offload TCP baseline is not differenced" \
    '"bytes_tcp_total":801950' "$OUT"

# ── quiet devices: dropped from the default view, kept for the exporter ─────
# A device whose last flow expired is gone from conntrack entirely. The UI has
# nothing to show for it, but a Prometheus series that vanished and reappeared
# on every idle period would be unusable.
sample '[]'
OUT=$(run)
assert_not_contains "quiet device is absent from the default output" "$IP" "$OUT"
assert_eq "empty sample still yields a valid JSON array" "[]" "$OUT"

OUT=$(runall)
assert_contains "--all keeps the quiet device for the exporter" "$IP" "$OUT"
assert_contains "--all preserves its accumulated total" '"bytes_in_total":3000' "$OUT"
assert_contains "--all marks it not live" '"live":false' "$OUT"

# There is no current reading for a device that is not in the sample. Echoing
# its last one back would hand any consumer reading bytes_in a frozen number
# that looks live, with only the "live" flag to give it away.
assert_contains "--all reports no current download reading for a quiet device" \
    '"bytes_in":-1' "$OUT"
assert_contains "--all reports no current upload reading for a quiet device" \
    '"bytes_out":-1' "$OUT"
assert_not_contains "--all does not echo the last observed sample as current" \
    '"bytes_in":900002000' "$OUT"

# ── the state file must not grow without bound ──────────────────────────────
# A device that was seen once, carried nothing, and went away must be evicted;
# one that carried bytes is kept so its counter survives an idle period.
sample '[{"ip":"10.0.20.77","bytes_in":0,"bytes_out":0,"bytes_tcp":0,"bytes_udp":0,"src":"ct"}]'
run >/dev/null
assert_contains "zero-traffic device is recorded while it is live" \
    "10.0.20.77" "$(cat "$STATE")"
sample '[]'
run >/dev/null
assert_not_contains "zero-traffic device is evicted once it goes quiet" \
    "10.0.20.77" "$(cat "$STATE")"
assert_contains "device with a real total is retained while quiet" \
    "$IP" "$(cat "$STATE")"

assert_eq "state holds one line per retained device" "1" \
    "$(wc -l < "$STATE" | tr -d ' ')"

# ── no baseline means no fake movement for a brand-new device ───────────────
# A second device appearing must not disturb the first one's total.
sample '[{"ip":"10.0.20.11","bytes_in":900002000,"bytes_out":100,"bytes_tcp":800000,"bytes_udp":30,"src":"ct"},{"ip":"10.0.20.12","bytes_in":77,"bytes_out":7,"bytes_tcp":84,"bytes_udp":0,"src":"ct"}]'
OUT=$(run)
assert_contains "new device seeds its own total" '"ip":"10.0.20.12"' "$OUT"
assert_contains "new device total is its first sample" '"bytes_in_total":77' "$OUT"
assert_contains "existing device is untouched by the newcomer" \
    '"bytes_in_total":3000' "$OUT"

# ── a device first seen while offload is already on ─────────────────────────
# It has NO accumulated protocol history at all, so "unavailable" and "zero"
# are the two answers that look identical unless the sentinel is honoured. The
# device above cannot test this: it carries 2000 TCP bytes from before the
# switch, so a stale total there would never read as a zero.
rm -f "$STATE"
sample '[{"ip":"10.0.20.44","bytes_in":4096,"bytes_out":128,"bytes_tcp":-1,"bytes_udp":-1,"src":"nft"}]'
OUT=$(run)
assert_contains "offload-only device still gets a byte total" \
    '"bytes_in_total":4096' "$OUT"
assert_contains "offload-only device reports TCP as unavailable" \
    '"bytes_tcp_total":-1' "$OUT"
assert_not_contains "never claims the device sent zero TCP" \
    '"bytes_tcp_total":0' "$OUT"
assert_not_contains "never claims the device sent zero UDP" \
    '"bytes_udp_total":0' "$OUT"

# ── 64-bit safety: totals past 2 GiB must survive the state round-trip ──────
# The accumulator is the one place the 32-bit %d bug could not heal itself: the
# clamped value goes to disk and is read back clamped forever (see #56 and
# tests/test_byte_overflow.sh).
rm -f "$STATE"
sample '[{"ip":"10.0.20.90","bytes_in":5368709120,"bytes_out":9007199254740991,"bytes_tcp":5368709120,"bytes_udp":0,"src":"ct"}]'
OUT=$(run)
assert_contains "5 GiB download total survives"    '"bytes_in_total":5368709120' "$OUT"
assert_contains "2^53-1 upload total survives"     '"bytes_out_total":9007199254740991' "$OUT"
assert_not_contains "nothing pinned at 2^31-1"     "2147483647" "$OUT"
assert_not_contains "no wrapped negative total"    "-2147483648" "$OUT"
OUT=$(run)
assert_contains "and survives a re-seed from the state file" \
    '"bytes_in_total":5368709120' "$OUT"

# ── static guards ───────────────────────────────────────────────────────────
# Same rule as tests/test_byte_overflow.sh: every byte-valued field goes
# through %.0f. The persisted line is positional, so the generic scan there
# cannot see it and it is pinned here instead.
assert_contains "totals.sh: persisted accumulator uses %.0f" \
    'printf "%s %.0f %.0f %.0f %.0f %d %.0f %.0f %.0f %.0f %s %d\n", \' \
    "$(cat "$BIN/trafficctl-totals.sh")"
assert_eq "totals.sh prints no byte field with %d" "" \
    "$(grep -nE '"[a-z_]*bytes[a-z_]*\\?":%d' "$BIN/trafficctl-totals.sh")"

# The protocol split only exists on the conntrack path. If trafficctl-bytes.sh
# ever stops emitting it, or the nft path starts reporting 0 instead of -1, the
# UI silently goes back to showing an unexplainable number.
assert_contains "bytes.sh emits the protocol split" \
    '\"bytes_tcp\":%.0f,\"bytes_udp\":%.0f,\"src\":\"ct\"' \
    "$(cat "$BIN/trafficctl-bytes.sh")"
assert_contains "bytes-nft.sh reports the split as unavailable, not zero" \
    '\"bytes_tcp\":-1,\"bytes_udp\":-1,\"src\":\"nft\"' \
    "$(cat "$BIN/trafficctl-bytes-nft.sh")"

# One accumulator, one store: the exporter must consume this script rather
# than keep a private copy, or the UI column and the metric can disagree.
# Pinned to the invocation, not just a mention: the script name also appears in
# the comments there, so a looser check would keep passing after the call was
# swapped back to the raw sampler.
assert_contains "metrics.sh consumes the shared accumulator" \
    '/usr/local/bin/trafficctl-totals.sh --all 2>/dev/null \' \
    "$(cat "$BIN/trafficctl-metrics.sh")"
assert_eq "metrics.sh keeps no state file of its own" "" \
    "$(grep -n 'trafficctl_metrics.state' "$BIN/trafficctl-metrics.sh")"

# ── concurrent samplers must not corrupt the store ──────────────────────────
# A LuCI poll and a metrics scrape land together routinely. The lock serialises
# the read-modify-write, but it can be STOLEN after a timeout, so two writers
# coexisting is reachable rather than impossible — which is why each writes to
# its own scratch file. With one shared name they interleave lines into it and
# whichever rename lands last publishes garbage.
#
# This asserts the invariant, not the interleaving: a race that only sometimes
# reproduces would make this test flaky rather than useful, so the property
# checked is "the state file is always well-formed and monotonic", which holds
# no matter how the processes interleave.
rm -f "$STATE"
sample '[{"ip":"10.0.20.99","bytes_in":1000,"bytes_out":0,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct"}]'
run >/dev/null
for i in $(seq 1 12); do
    PATH="$MOCKBIN:$PATH" sh "$TMPDIR/totals.sh" >/dev/null 2>&1 &
done
wait
assert_eq "concurrent samplers leave exactly one line per device" "1" \
    "$(wc -l < "$STATE" | tr -d ' ')"
assert_eq "every state line still has all 12 fields" "" \
    "$(awk 'NF != 12 { print NR": "NF" fields" }' "$STATE")"
assert_eq "the accumulated total is not corrupted" "1000" \
    "$(awk '{print $2}' "$STATE")"
OUT=$(run)
assert_contains "the store still reads back cleanly afterwards" \
    '"bytes_in_total":1000' "$OUT"

# The lock must be released, not leaked: a directory left behind would make
# every later sampler wait out the steal timeout before it could accumulate.
assert_eq "the lock directory is released" "1" \
    "$([ -d "$TMPDIR/lock.d" ] && echo 0 || echo 1)"

# Each writer needs its OWN scratch file. A shared "$STATE.tmp" is the shape
# that breaks once the lock is stolen, and it is invisible to any test that
# does not happen to interleave, so it is pinned statically.
assert_contains "the state is staged through a per-process scratch file" \
    'TMPF="/tmp/.trafficctl_totals.write.$$"' "$(cat "$BIN/trafficctl-totals.sh")"
assert_eq "no shared scratch filename remains" "" \
    "$(grep -n 'state ".tmp"' "$BIN/trafficctl-totals.sh")"
assert_eq "no scratch file is left behind" "" \
    "$(find /tmp -maxdepth 1 -name '.trafficctl_totals.*' 2>/dev/null)"

# Sampling happens before the lock is taken, so the slow conntrack read is not
# inside the critical section. If that order is reversed, every poll queues
# behind a full conntrack parse and the steal-on-timeout path — which exists
# for a killed sampler — starts firing under ordinary load.
assert_contains "the byte source is sampled before the lock is taken" \
    "$MOCKBIN/bytes" "$(sed -n '1,/^while ! mkdir/p' "$TMPDIR/totals.sh")"

# ── the shell ↔ frontend field contract ─────────────────────────────────────
# These names cross a process boundary with nothing to typecheck them. Renaming
# a field on the shell side leaves status.js reading `undefined`, which
# fmtBytes() renders as an em dash — the column just goes blank and no test
# anywhere else notices.
STATUS_JS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"
for field in bytes_in_total bytes_out_total bytes_tcp_total bytes_udp_total total_since; do
    assert_contains "status.js reads $field" "$field" "$(cat "$STATUS_JS")"
    assert_contains "totals.sh emits $field" "\\\"$field\\\":" \
        "$(cat "$BIN/trafficctl-totals.sh")"
done

# The sentinel has to survive the trip: Number(-1) must not be flattened to 0
# by a `|| 0` on the way in, or the UI is back to printing a confident zero.
assert_contains "status.js keeps the -1 sentinel for the TCP total" \
    'var tcpT = (d.bytes_tcp_total == null) ? -1 : Number(d.bytes_tcp_total);' \
    "$(cat "$STATUS_JS")"
assert_contains "status.js renders a negative total as unmeasurable" \
    'if (total == null || total < 0) {' "$(cat "$STATUS_JS")"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
