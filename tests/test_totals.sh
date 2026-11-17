#!/bin/bash
# Tests for `trafficctl totals` (net.totals in net.uc): the shared monotonic
# byte accumulator that backs both the LuCI Bytes/TCP/UDP columns and
# trafficctl_device_bytes_total.
#
# The interesting behaviour is all in what it REFUSES to count, and none of it
# is visible by eyeballing a single sample:
#
#   * conntrack sums fall when flows expire. Counting that as movement would
#     rewind a counter that is documented as monotonic; ignoring the drop
#     entirely (rather than resyncing) would double-count the next sample.
#   * a source change must rebaseline. The sampler reads conntrack only, but
#     a state file written by 1.30.x can record source "nft": per-address
#     counter maps that counted since their table was built, a magnitude
#     unrelated to conntrack's live flows. Differencing across that would add
#     the whole map to the total in one tick.
#   * those nft-era lines carry no TCP/UDP split. Such totals have to read
#     "unavailable", not "zero": issue #26 is precisely about a byte column
#     that showed a number nobody could explain.
#
# The accumulator runs for real against a scratch TCTL_ROOT. Most sections
# feed it recorded samples through tests/lib/totals.uc; the end-to-end ones
# run the CLI over a conntrack file and a mocked flowtable listing
# (tests/lib/bytes_env.sh).

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/bytes_env.sh
. "$(dirname "$0")/lib/bytes_env.sh"

PASS=0
FAIL=0

STATUS_JS="$UC_REPO/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"
REPORT_UC="$UC_REPO/trafficctl/files/usr/share/ucode/trafficctl/report.uc"
NET_UC="$UC_LIB/trafficctl/net.uc"
STATE="$BE_ROOT/tmp/trafficctl_totals.state"
LOCKD="$BE_ROOT/tmp/trafficctl_totals.lock.d"
SAMPLE="$UC_TMP/sample.json"

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

# The haystack is often a whole file, and `grep -q` exits at the first match,
# so printf takes a SIGPIPE and bash prints "write error: Broken pipe". That is
# noise, not a failure, but it buries real output in the CI log.
assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" 2>/dev/null | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" 2>/dev/null | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}

run()    { be_totals "$SAMPLE"; }
runall() { be_totals "$SAMPLE" --all; }
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

# ── a total left by 1.30.x on the nft counter maps ──────────────────────────
# Under uncountered offload 1.30.x read nft counter maps, cumulative since
# their table was built (here 900 MB), with no protocol split. The line it
# leaves after a stretch on them: src nft, protocol baselines -1, and 1000
# bytes more accumulated on the maps.
awk '{ $2 = 3000; $4 = 900001000; $9 = -1; $10 = -1; $11 = "nft"; print }' "$STATE" > "$STATE.new"
mv "$STATE.new" "$STATE"
sample '[]'
OUT=$(runall)
assert_contains "an nft-sourced state line loads with its total" \
    '"bytes_in_total":3000' "$OUT"
assert_contains "an nft-sourced state line keeps its source until resampled" \
    '"src":"nft"' "$OUT"
assert_contains "its TCP total reads unavailable, not zero" \
    '"bytes_tcp_total":-1' "$OUT"
assert_contains "its UDP total reads unavailable, not zero" \
    '"bytes_udp_total":-1' "$OUT"

# The first conntrack sample after the upgrade is a source change. Its
# readings are not traffic since the nft baseline (900 MB of map against live
# flows), and its TCP figure is not traffic since the last split either, so
# the tick only rebaselines.
sample '[{"ip":"10.0.20.11","bytes_in":900002000,"bytes_out":100,"bytes_tcp":800000,"bytes_udp":30,"src":"ct"}]'
OUT=$(run)
assert_contains "the switch to conntrack adds no download" \
    '"bytes_in_total":3000' "$OUT"
assert_contains "the switch to conntrack rebaselines the protocol split" \
    '"bytes_tcp_total":2000' "$OUT"
assert_not_contains "the stale pre-nft TCP baseline is not differenced" \
    '"bytes_tcp_total":801950' "$OUT"
assert_not_contains "nor is the whole conntrack TCP reading added" \
    '"bytes_tcp_total":802000' "$OUT"
assert_eq "the state line now records conntrack" "ct" "$(awk '{ print $11 }' "$STATE")"

# And from there conntrack accumulates as usual.
sample '[{"ip":"10.0.20.11","bytes_in":900002000,"bytes_out":100,"bytes_tcp":800500,"bytes_udp":30,"src":"ct"}]'
OUT=$(run)
assert_contains "growth after the switch accumulates normally" \
    '"bytes_tcp_total":2500' "$OUT"

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

# ── a device 1.30.x only ever saw on the nft maps ───────────────────────────
# It has NO accumulated protocol history at all, so "unavailable" and "zero"
# are the two answers that look identical unless the sentinel is honoured. The
# device above cannot test this: it carries TCP bytes from before the maps, so
# a stale total there would never read as a zero.
rm -f "$STATE"
printf '10.0.20.44 4096 128 4096 128 1700000000 0 0 -1 -1 nft 1700000000 false\n' > "$STATE"
sample '[]'
OUT=$(runall)
assert_contains "nft-only device still gets a byte total" \
    '"bytes_in_total":4096' "$OUT"
assert_contains "nft-only device reports TCP as unavailable" \
    '"bytes_tcp_total":-1' "$OUT"
assert_not_contains "never claims the device sent zero TCP" \
    '"bytes_tcp_total":0' "$OUT"
assert_not_contains "never claims the device sent zero UDP" \
    '"bytes_udp_total":0' "$OUT"

# ── 64-bit safety: totals past 2 GiB and 2^53 survive the state round trip ──
# The accumulator is the one place a narrow integer could not heal itself: the
# clamped value goes to disk and is read back clamped forever (see #56 and
# tests/test_byte_overflow.sh). ucode integers are int64, so unlike the awk
# writer (doubles, exact to 2^53) the state keeps every byte up to 2^63.
rm -f "$STATE"
sample '[{"ip":"10.0.20.90","bytes_in":5368709120,"bytes_out":9007199254740991,"bytes_tcp":5368709120,"bytes_udp":9007199254740993,"src":"ct"}]'
OUT=$(run)
assert_contains "5 GiB download total survives"    '"bytes_in_total":5368709120' "$OUT"
assert_contains "2^53-1 upload total survives"     '"bytes_out_total":9007199254740991' "$OUT"
assert_contains "2^53+1 UDP total is exact"        '"bytes_udp_total":9007199254740993' "$OUT"
assert_not_contains "nothing pinned at 2^31-1"     "2147483647" "$OUT"
assert_not_contains "no wrapped negative total"    "-2147483648" "$OUT"
assert_contains "the state keeps 2^53+1 exactly" " 9007199254740993 " "$(cat "$STATE")"
OUT=$(run)
assert_contains "and survives a re-seed from the state file" \
    '"bytes_in_total":5368709120' "$OUT"
sample '[{"ip":"10.0.20.90","bytes_in":5368709120,"bytes_out":9007199254740995,"bytes_tcp":5368709120,"bytes_udp":9007199254740997,"src":"ct"}]'
OUT=$(run)
assert_contains "a 4-byte delta past 2^53 is counted, not rounded away" \
    '"bytes_udp_total":9007199254740997' "$OUT"
assert_contains "upload past 2^53 moves by its delta" \
    '"bytes_out_total":9007199254740995' "$OUT"

# One accumulator, one store: the exporter must consume the accumulator
# rather than keep a private copy, or the UI column and the metric can
# disagree. Pinned to the call, not just a mention: net.totals also appears
# in the comments there, so a looser check would keep passing after the call
# was swapped back to the raw sampler.
assert_contains "the exporter consumes the shared accumulator" \
    'source_text(src.totals ?? (() => net.totals(true)))' \
    "$(cat "$REPORT_UC")"
assert_eq "the exporter keeps no state file of its own" "" \
    "$(grep -n 'trafficctl_metrics.state' "$REPORT_UC")"

# ── end to end, against real /proc/net/nf_conntrack text ────────────────────
# Everything above feeds the accumulator hand-written JSON, which cannot catch
# a mistake in the thing that PRODUCES that JSON. So the real sampler runs
# here over real conntrack lines: a TCP flow, a UDP flow, and (the case an
# all-TCP fixture would silently miss) an ICMP flow, whose bytes belong in the
# total but in neither protocol bucket.
cat > "$BE_CT" <<'EOF'
ipv4     2 tcp      6 431999 ESTABLISHED src=192.168.1.100 dst=142.250.185.78 sport=52134 dport=443 packets=142 bytes=15234 src=142.250.185.78 dst=192.168.1.100 sport=443 dport=52134 packets=198 bytes=245678 [ASSURED] mark=0 zone=0 use=2
ipv4     2 udp      17 29 src=192.168.1.100 dst=192.168.1.1 sport=51234 dport=53 packets=1 bytes=68 src=192.168.1.1 dst=192.168.1.100 sport=53 dport=51234 packets=1 bytes=124 mark=0 zone=0 use=2
ipv4     2 icmp     1 29 src=192.168.1.101 dst=8.8.8.8 type=8 code=0 id=1234 packets=5 bytes=420 src=8.8.8.8 dst=192.168.1.101 type=0 code=0 id=1234 packets=5 bytes=420 mark=0 zone=0 use=2
ipv4     2 tcp      6 120 TIME_WAIT src=192.168.1.101 dst=93.184.216.34 sport=44556 dport=80 packets=10 bytes=1024 src=93.184.216.34 dst=192.168.1.101 sport=80 dport=44556 packets=12 bytes=8192 [ASSURED] mark=0 zone=0 use=2
EOF
be_offload none
REAL=$(be_run bytes)

# .100: TCP 15234 up / 245678 down, UDP 68 up / 124 down.
assert_contains "real conntrack: download is the reply direction" \
    '"bytes_in":245802' "$REAL"
assert_contains "real conntrack: upload is the original direction" \
    '"bytes_out":15302' "$REAL"
assert_contains "real conntrack: TCP split counts both directions" \
    '"bytes_tcp":260912' "$REAL"
assert_contains "real conntrack: UDP split counts both directions" \
    '"bytes_udp":192' "$REAL"
assert_contains "real conntrack: the source is tagged" '"src":"ct"' "$REAL"

# .101: ICMP 420/420 plus TCP 1024 up / 8192 down. The ICMP bytes must land in
# the totals and in NEITHER protocol bucket: if the split silently absorbed
# non-TCP/UDP traffic, tcp+udp would equal the total and nobody would notice.
assert_contains "real conntrack: ICMP bytes are in the device total" \
    '"bytes_in":8612' "$REAL"
assert_contains "real conntrack: ICMP is not counted as TCP" \
    '"bytes_tcp":9216' "$REAL"
assert_contains "real conntrack: a device with no UDP reports zero, not -1" \
    '"bytes_udp":0' "$REAL"
assert_eq "real conntrack: devices come out in address order" \
    "192.168.1.100 192.168.1.101" "$(printf '%s' "$REAL" | jq -r 'map(.ip) | join(" ")')"

# And the accumulator on top of that real output, through the CLI.
rm -f "$STATE"
OUT=$(be_run totals)
assert_contains "end to end: totals seed from the real sampler" \
    '"bytes_in_total":245802' "$OUT"
assert_contains "end to end: the protocol split survives the accumulator" \
    '"bytes_tcp_total":260912' "$OUT"
OUT=$(be_run totals)
assert_contains "end to end: a second identical read adds nothing" \
    '"bytes_in_total":245802' "$OUT"
OUT=$(be_run totals --all)
assert_contains "end to end: --all reaches the accumulator through the CLI" \
    '"live":true' "$OUT"

# ── frozen conntrack counters must not masquerade as a total ────────────────
# Uncountered flow offload (plain "hardware"/"software": fw4 on 22.03, whose
# flowtable has no counter, or a custom flowtable without one) keeps
# conntrack's byte counters frozen for every offloaded flow. Nothing else can
# count those packets: the flowtable hooks netdev ingress, so they never reach
# an inet forward chain at any priority.
#
# Without the flag the accumulator faithfully adds deltas from a frozen counter
# (almost nothing) and the column shows an authoritative-looking total that
# silently stops growing. That is strictly worse than what issue #26 reported:
# an implausibly small number gets noticed, a plausible one does not.
for mode in hardware software; do
    be_offload "$mode"
    : > "$BE_NFTLOG"
    OUT=$(be_run bytes)
    assert_contains "$mode offload without a flowtable counter: sample is flagged degraded" \
        '"degraded":true' "$OUT"
    # It still reports what conntrack has (a lower bound beats nothing), but
    # the flag is what stops it being presented as a total.
    assert_contains "$mode offload: the sample is still conntrack data" \
        '"src":"ct"' "$OUT"
    assert_eq "$mode offload: nft is only asked about the flowtable" "list flowtables" \
        "$(sort -u "$BE_NFTLOG" | tr '\n' ' ' | sed 's/ $//')"
done

# The modes where conntrack IS trustworthy must not be flagged, or the warning
# becomes noise everyone learns to ignore.
for mode in none hardware-counter software-counter; do
    be_offload "$mode"
    OUT=$(be_run bytes)
    assert_contains "$mode: conntrack is accurate, not flagged" \
        '"degraded":false' "$OUT"
    assert_not_contains "$mode: no spurious degraded flag" \
        '"degraded":true' "$OUT"
    assert_contains "$mode: conntrack is the source" '"src":"ct"' "$OUT"
done
be_offload none

# ── the operator is told why, once ──────────────────────────────────────────
# fw4 on 22.03 declares its flowtable without a counter, and no nft rule can
# count the offloaded packets instead, so the only fix is on the operator's
# side. The syslog says which, once per mode rather than on every poll.
HINT="$BE_ROOT/tmp/trafficctl_offload_hint"
: > "$BE_LOGGER"
be_offload none
be_run bytes >/dev/null
assert_eq "no offload: nothing is logged" "0" "$(grep -c . "$BE_LOGGER")"
be_offload software
be_run bytes >/dev/null
be_run bytes >/dev/null
assert_eq "uncountered offload: one warning over two samples" "1" "$(grep -c . "$BE_LOGGER")"
assert_contains "the warning names the mode" "flow offload (software)" "$(cat "$BE_LOGGER")"
assert_contains "the warning says to disable flow offloading" "Disable flow offloading" "$(cat "$BE_LOGGER")"
assert_contains "the warning names the release that fixes it" "OpenWrt 23.05" "$(cat "$BE_LOGGER")"
assert_contains "the warning goes out as a warning" "-p daemon.warn" "$(cat "$BE_LOGGER")"
be_offload hardware
be_run bytes >/dev/null
assert_eq "a different uncountered mode warns again" "2" "$(grep -c . "$BE_LOGGER")"
be_offload hardware-counter
be_run bytes >/dev/null
assert_eq "countered offload: no warning, and the markers are gone" "2 0" \
    "$(grep -c . "$BE_LOGGER") $(find "$BE_ROOT/tmp" -name 'trafficctl_offload_hint*' | wc -l | tr -d ' ')"
be_offload hardware
be_run bytes >/dev/null
assert_eq "uncountered again after a countered spell: warned again" "3" "$(grep -c . "$BE_LOGGER")"
# A marker that cannot be written (full tmpfs) must not turn the one warning
# into one per poll. A directory in its place fails every write the same way,
# whoever runs the test.
be_offload hardware-counter
be_run bytes >/dev/null
: > "$BE_LOGGER"
rm -f "$HINT" "$HINT".*
mkdir "$HINT" "$HINT.software"
be_offload software
be_run bytes >/dev/null
be_run bytes >/dev/null
assert_eq "an unwritable marker: nothing is logged" "0" "$(grep -c . "$BE_LOGGER")"
rmdir "$HINT" "$HINT.software"
# Samplers racing on a fresh marker (UI poll, exporter, history at once):
# the exclusive create lets exactly one of them log.
: > "$BE_LOGGER"
be_offload hardware
ubus_start "$BE_UBUS"
racers=""
for _ in 1 2 3 4 5 6; do
    TCTL_ROOT="$BE_ROOT" PATH="$BE_BIN:$PATH" tctl bytes >/dev/null 2>&1 &
    racers="$racers $!"
done
# Only the samplers: a bare wait would also wait for ubusd.
# shellcheck disable=SC2086
wait $racers
ubus_stop
assert_eq "concurrent samplers: one warning between them" "1" "$(grep -c . "$BE_LOGGER")"
be_offload none

# ── the accumulator carries the flag, and keeps carrying it ─────────────────
rm -f "$STATE"
sample '[{"ip":"10.0.20.55","bytes_in":100,"bytes_out":20,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct","degraded":true}]'
OUT=$(run)
assert_contains "the accumulator propagates the degraded flag" \
    '"degraded":true' "$OUT"
assert_contains "the flag is persisted for the next sample" \
    " true" "$(cat "$STATE")"

# Sticky. A total built from frozen counters stays understated forever, so a
# later healthy sample must not relabel that same number as trustworthy.
sample '[{"ip":"10.0.20.55","bytes_in":200,"bytes_out":40,"bytes_tcp":260,"bytes_udp":0,"src":"ct","degraded":false}]'
OUT=$(run)
assert_contains "a healthy sample does not clear a tainted total" \
    '"degraded":true' "$OUT"

# A device that was never sampled while degraded must stay clean.
rm -f "$STATE"
sample '[{"ip":"10.0.20.56","bytes_in":100,"bytes_out":20,"bytes_tcp":120,"bytes_udp":0,"src":"ct","degraded":false}]'
OUT=$(run)
assert_contains "a healthy device is not flagged" '"degraded":false' "$OUT"
assert_not_contains "no spurious taint on a healthy device" '"degraded":true' "$OUT"

# The UI must refuse the number rather than dress it up, the same discipline
# already applied to the -1 protocol sentinel.
assert_contains "status.js reads the degraded flag off the sample" \
    'degraded: (d.degraded === true)' "$(cat "$STATUS_JS")"
assert_contains "status.js refuses to render a total it knows is unreliable" \
    'if (degraded) {' "$(cat "$STATUS_JS")"

# ── a state file written by an older version still loads ────────────────────
# The first six fields match the layout the exporter used before the
# accumulator moved out of it. The failure would be silent: the protocol
# totals of every pre-existing device would come back as 0 ("sent no TCP")
# instead of -1 ("never measured").
rm -f "$STATE"
printf '192.168.1.100 5000 900 5000 900 1700000000\n' > "$STATE"
sample '[{"ip":"192.168.1.100","bytes_in":6000,"bytes_out":900,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct"}]'
OUT=$(run)
assert_contains "legacy six-field state line still seeds the byte total" \
    '"bytes_in_total":6000' "$OUT"

# Read back WITHOUT a fresh sample, which is the only path where the protocol
# baseline loaded from the file is what gets reported. With a live sample the
# incoming value overwrites it, so seeding it as 0 instead of -1 is invisible.
rm -f "$STATE"
printf '192.168.1.100 5000 900 5000 900 1700000000\n' > "$STATE"
sample '[]'
OUT=$(runall)
assert_contains "legacy state line is retained for the exporter" \
    '"bytes_in_total":5000' "$OUT"
assert_contains "legacy state line yields an unknown TCP total, not zero" \
    '"bytes_tcp_total":-1' "$OUT"
assert_not_contains "legacy state line does not claim zero TCP" \
    '"bytes_tcp_total":0' "$OUT"
assert_not_contains "legacy state line does not claim zero UDP" \
    '"bytes_udp_total":0' "$OUT"
assert_eq "the line is rewritten in the current 13-field form" "13" \
    "$(awk '{ print NF }' "$STATE")"

# Every line length an older writer produced: 5, 6, 10, 12, 13 fields.
rm -f "$STATE"
printf '%s\n' '10.0.0.5 50 5 50 5' '10.0.0.6 60 6 60 6 1700000000' \
    '10.0.0.10 100 10 100 10 1700000000 70 30 70 30' \
    '10.0.0.12 120 12 120 12 1700000000 80 40 80 40 nft 1690000000' \
    '10.0.0.13 130 13 130 13 1700000000 90 50 90 50 ct 1690000000 true' > "$STATE"
OUT=$(runall)
assert_eq "every legacy line length loads" "10.0.0.5 10.0.0.6 10.0.0.10 10.0.0.12 10.0.0.13" \
    "$(printf '%s' "$OUT" | jq -r 'map(.ip) | join(" ")')"
assert_eq "10 fields bring the protocol totals" "70 30" \
    "$(printf '%s' "$OUT" | jq -r '.[] | select(.ip == "10.0.0.10") | "\(.bytes_tcp_total) \(.bytes_udp_total)"')"
assert_eq "12 fields bring the source and the start" "nft 1690000000" \
    "$(printf '%s' "$OUT" | jq -r '.[] | select(.ip == "10.0.0.12") | "\(.src) \(.total_since)"')"
assert_eq "13 fields bring the degraded flag" "true" \
    "$(printf '%s' "$OUT" | jq -r '.[] | select(.ip == "10.0.0.13") | .degraded')"

# A truncated line is skipped rather than read as a device with junk totals.
rm -f "$STATE"
printf '192.168.1.100 5000\n' > "$STATE"
sample '[{"ip":"192.168.1.100","bytes_in":100,"bytes_out":10,"bytes_tcp":110,"bytes_udp":0,"src":"ct"}]'
OUT=$(run)
assert_contains "a truncated state line is ignored, not half-trusted" \
    '"bytes_in_total":100' "$OUT"

# ── concurrent samplers must not corrupt the store ──────────────────────────
# A LuCI poll and a metrics scrape land together routinely. The lock serialises
# the read-modify-write, but it can be STOLEN after a timeout, so two writers
# coexisting is reachable rather than impossible, which is why each stages its
# write in its own scratch file and renames it.
#
# Each racer brings a device of its own on top of a shared one, so a lost
# update is visible: a writer that read the store before another wrote it
# drops that one's device. The shared device grows with every racer, and the
# order the racers run in is arbitrary, so its total is only bounded: every
# rise counts once, a fall resyncs. Without the lock several of the 12 read
# the same store, and their devices go missing.
rm -f "$STATE"
sample '[{"ip":"10.0.20.99","bytes_in":1000,"bytes_out":0,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct"}]'
run >/dev/null
for round in 1 2 3; do
    for i in $(seq 12); do
        printf '[{"ip":"10.0.20.99","bytes_in":%d,"bytes_out":0,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct"},{"ip":"10.0.%d.%d","bytes_in":%d,"bytes_out":0,"bytes_tcp":-1,"bytes_udp":-1,"src":"ct"}]\n' \
            $((1000 + round * 12 + i)) "$((30 + round))" "$i" "$i" > "$UC_TMP/race.$i.json"
    done
    for i in $(seq 12); do
        be_totals "$UC_TMP/race.$i.json" >/dev/null 2>&1 &
    done
    wait
done
assert_eq "concurrent samplers lose no update (36 racer devices + the shared one)" "37" \
    "$(wc -l < "$STATE" | tr -d ' ')"
assert_eq "every racer's own total is there" "234" \
    "$(awk '$1 != "10.0.20.99" { s += $2 } END { print s }' "$STATE")"
assert_eq "every state line still has all 13 fields" "" \
    "$(awk 'NF != 13 { print NR": "NF" fields" }' "$STATE")"
SHARED=$(awk '$1 == "10.0.20.99" { print $2 }' "$STATE")
assert_eq "the shared total reaches the highest reading" "1" "$([ "$SHARED" -ge 1048 ] && echo 1 || echo 0)"
OUT=$(be_totals "$UC_TMP/none.json" --all)
assert_eq "the store still reads back cleanly afterwards" "37 $SHARED" \
    "$(printf '%s' "$OUT" | jq -r '"\(length) \(.[] | select(.ip == "10.0.20.99") | .bytes_in_total)"')"

# The lock must be released, not leaked: a directory left behind would make
# every later sampler wait out the steal timeout before it could accumulate.
assert_eq "the lock directory is released" "1" \
    "$([ -d "$LOCKD" ] && echo 0 || echo 1)"
assert_eq "no scratch file is left behind" "" \
    "$(find "$BE_ROOT/tmp" -maxdepth 1 -name 'trafficctl_totals.state.*' 2>/dev/null)"

# Sampling happens before the lock is taken, so the slow conntrack read is not
# inside the critical section. If that order is reversed, every poll queues
# behind a full conntrack parse and the steal-on-timeout path (which exists
# for a killed sampler) starts firing under ordinary load.
assert_eq "the byte source is sampled before the lock is taken" "sample lock" \
    "$(sed -n '/^function totals(all, sample)/,/^}/p' "$NET_UC" |
       awk '/sample = bytes\(\)/ { printf "sample " } /lib\.lock\(TOTALS_LOCK/ { printf "lock" }')"

# ── the lock is the shell's, so either writer can take it from the other ────
# During an upgrade the shell writer of 1.30.x and this one run side by side,
# and after a downgrade the shell one must be able to steal a lock this one
# left behind when it was killed. The shell's lock is an empty directory it
# removes with rmdir; a pid file inside would make that rmdir fail for good.
TCTL_ROOT="$BE_ROOT" tcall trafficctl.lib lock '"/tmp/trafficctl_totals.lock.d"' 1 3 true >/dev/null
assert_eq "a lock held by a killed sampler is an empty directory" "" \
    "$([ -d "$LOCKD" ] && ls -A "$LOCKD" || echo missing)"
assert_eq "so the shell writer can rmdir it" "0" \
    "$(rmdir "$LOCKD" 2>/dev/null; echo $?)"

# A lock the shell writer left behind (killed while holding it) is stolen once
# it is old enough, and the sample is still accumulated.
mkdir "$LOCKD"
touch -t 202001010000 "$LOCKD"
sample '[{"ip":"10.0.20.98","bytes_in":42,"bytes_out":0,"bytes_tcp":0,"bytes_udp":0,"src":"ct"}]'
OUT=$(run)
assert_contains "a stale shell lock does not stop accumulation" '"bytes_in_total":42' "$OUT"
assert_eq "the stolen lock is released afterwards" "1" \
    "$([ -d "$LOCKD" ] && echo 0 || echo 1)"

# A lock made just before the first try, and held through the whole wait, is
# taken over at its end, as the shell did after its 30 x 100 ms. A wait
# shorter than the steal age wrote without the lock and left the directory
# for the next caller (equiv.sh case totals-stale-lock, when its setup's mkdir
# landed early enough in a second).
rm -f "$STATE"
sample '[{"ip":"10.0.20.94","bytes_in":30,"bytes_out":0,"bytes_tcp":0,"bytes_udp":0,"src":"ct"}]'
OUT=$(export TCTL_TEST_FRESH_LOCK=1; be_totals "$SAMPLE")
assert_contains "a lock as young as it gets is waited out" '"bytes_in_total":30' "$OUT"
assert_eq "and taken over at the end of the wait, then released" "1" \
    "$([ -d "$LOCKD" ] && echo 0 || echo 1)"
rmdir "$LOCKD" 2>/dev/null

# A live holder is waited for (the shell waited 30 x 100 ms), then the sample
# is accumulated anyway, as the shell did, rather than dropped.
mkdir "$LOCKD"
T0=$(date +%s)
sample '[{"ip":"10.0.20.98","bytes_in":50,"bytes_out":0,"bytes_tcp":0,"bytes_udp":0,"src":"ct"}]'
OUT=$(run)
T1=$(date +%s)
assert_contains "a held lock delays the write but does not drop it" '"bytes_in_total":50' "$OUT"
assert_eq "the wait is bounded (under 6 s)" "1" "$([ $((T1 - T0)) -lt 6 ] && echo 1 || echo 0)"
rmdir "$LOCKD" 2>/dev/null

# An exception inside the locked section releases the lock. The bare lock
# carries no pid, so a leaked one is never seen as dead: every later sampler
# would wait the full 3 s for it to age into a steal.
rm -f "$STATE"
sample '[{"ip":"10.0.20.97","bytes_in":70,"bytes_out":0,"bytes_tcp":0,"bytes_udp":0,"src":"ct"}]'
run >/dev/null
BEFORE=$(cat "$STATE")
sample '[{"ip":"10.0.20.97","bytes_in":90,"bytes_out":0,"bytes_tcp":0,"bytes_udp":0,"src":"ct"}]'
OUT=$(export TCTL_TEST_FAIL=write; be_totals "$SAMPLE")
assert_eq "a failing state write is reported" "test: the state write fails" \
    "$(printf '%s' "$OUT" | jq -r '.error' | sed 's/^.*\(test: \)/\1/')"
assert_eq "an exception in the locked section releases the lock" "1" \
    "$([ -d "$LOCKD" ] && echo 0 || echo 1)"
assert_eq "and leaves the store as it was" "$BEFORE" "$(cat "$STATE")"

# A sample that fails is an empty one, as the shell's empty pipe was: --all
# still lists every stored device, so no Prometheus series vanishes for a
# scrape, and nothing is accumulated.
rm -f "$STATE"
sample '[{"ip":"10.0.20.95","bytes_in":5,"bytes_out":1,"bytes_tcp":6,"bytes_udp":0,"src":"ct"},{"ip":"10.0.20.96","bytes_in":7,"bytes_out":2,"bytes_tcp":9,"bytes_udp":0,"src":"ct"}]'
run >/dev/null
be_offload software
OUT=$(export TCTL_TEST_FAIL=sample; be_totals "$SAMPLE" --all)
be_offload none
assert_eq "totals --all lists the stored devices when bytes() fails" \
    "10.0.20.95:5:false:-1 10.0.20.96:7:false:-1" \
    "$(printf '%s' "$OUT" | jq -r 'map("\(.ip):\(.bytes_in_total):\(.live):\(.bytes_in)") | join(" ")')"
assert_eq "and the lock is released" "1" "$([ -d "$LOCKD" ] && echo 0 || echo 1)"

# ── the backend <-> frontend field contract ─────────────────────────────────
# These names cross a process boundary with nothing to typecheck them. Renaming
# a field on the backend side leaves status.js reading `undefined`, which
# fmtBytes() renders as an em dash: the column just goes blank and no test
# anywhere else notices.
sample '[{"ip":"10.0.20.11","bytes_in":1,"bytes_out":1,"bytes_tcp":1,"bytes_udp":1,"src":"ct"}]'
OUT=$(runall)
for field in bytes_in_total bytes_out_total bytes_tcp_total bytes_udp_total total_since; do
    assert_contains "status.js reads $field" "$field" "$(cat "$STATUS_JS")"
    assert_contains "totals emits $field" "\"$field\":" "$OUT"
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
