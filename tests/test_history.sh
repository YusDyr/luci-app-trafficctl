#!/bin/bash
# Tests for trafficctl-history.sh — the durable per-period traffic store
# behind #89 (history for devices that are offline now) and #90 (where it
# lives, when it resets, how long it is kept).
#
# Everything interesting here is about NOT corrupting a number:
#
#   * a flush folds in GROWTH, so running it twice must not double-count,
#   * a reboot restarts the live accumulator below the cursor, and the flush
#     must rebaseline rather than subtract,
#   * a device missing from one sample must keep its cursor, or its whole
#     lifetime total lands as one fake delta when it comes back,
#   * a device that goes offline loses its DHCP lease, so re-reading an empty
#     name over a good one would erase the only label its history will have,
#   * "degraded" (uncountered offload) is a LOWER BOUND and has to survive
#     into the stored row, because a consumer must label it rather than add it
#     to a trustworthy sum.
#
# The script runs for real; only fw.sh, the totals sampler, uci and the tmpfs
# state paths are substituted.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

MOCKBIN="$TMPDIR/bin"
STORE="$TMPDIR/store"
CURSOR="$TMPDIR/history.cursor"
SAMPLE="$TMPDIR/sample.json"
UCIDB="$TMPDIR/uci.db"
LEASES="$TMPDIR/dhcp.leases"
mkdir -p "$MOCKBIN" "$STORE"

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

printf '%s\n' "1760000000 aa:bb:cc:dd:ee:01 192.168.0.50 laptop *" > "$LEASES"

# ── the scripts under test, with their absolute paths redirected ─────────────
# fw.sh names /tmp/dhcp.leases by absolute path on purpose (the shipped script
# carries no test-only override), so the MAC lookup this store keys on only
# works against a rewritten copy.
sed -e "s|TCTL_LEASES_FILE=\"/tmp/dhcp.leases\"|TCTL_LEASES_FILE=\"$LEASES\"|" \
    "$BIN/trafficctl-fw.sh" > "$TMPDIR/fw.sh"

sed -e "s|/usr/local/bin/trafficctl-fw.sh|$TMPDIR/fw.sh|g" \
    -e "s|/usr/local/bin/trafficctl-totals.sh|$MOCKBIN/totals|g" \
    -e "s|CURSOR=\"/tmp/trafficctl_history.cursor\"|CURSOR=\"$CURSOR\"|" \
    -e "s|ERRFILE=\"/tmp/trafficctl_history.err\"|ERRFILE=\"$TMPDIR/history.err\"|" \
    -e "s|STAMP=\"/tmp/trafficctl_history.stamp\"|STAMP=\"$TMPDIR/history.stamp\"|" \
    -e "s|LOCKD=\"/tmp/trafficctl_history.lock.d\"|LOCKD=\"$TMPDIR/history.lock.d\"|" \
    -e "s|TOTALS_STATE=\"/tmp/trafficctl_totals.state\"|TOTALS_STATE=\"$TMPDIR/totals.state\"|" \
    "$BIN/trafficctl-history.sh" > "$TMPDIR/history.sh"
chmod +x "$TMPDIR/history.sh"

# sed exits 0 when nothing matched, so a renamed variable would leave the
# script pointing at the real /tmp state — and the suite would pass while
# reading and WRITING files this test does not own.
for must in "$TMPDIR/fw.sh" "$MOCKBIN/totals" "$CURSOR" "$TMPDIR/history.err" \
            "$TMPDIR/history.stamp" "$TMPDIR/history.lock.d" "$TMPDIR/totals.state"; do
    assert_contains "redirected into the script under test: $must" \
        "$must" "$(cat "$TMPDIR/history.sh")"
done
assert_contains "the leases path was redirected in fw.sh" \
    "$LEASES" "$(cat "$TMPDIR/fw.sh")"
# Matched against the PRODUCTION names rather than a bare "/tmp": on Linux
# mktemp -d hands back /tmp/tmp.XXXX, so a correctly rewritten path lives under
# /tmp too and a "/tmp" test would fail there while passing on macOS.
assert_eq "no production path survives the rewrite" "" \
    "$(grep -nE '"/tmp/trafficctl_(history|totals)|^\. /usr/local/bin' "$TMPDIR/history.sh")"

# ── mocks ────────────────────────────────────────────────────────────────────
cat > "$MOCKBIN/totals" <<MOCK
#!/bin/sh
cat "$SAMPLE"
MOCK

# A one-line-per-key store so a test can set a value and the script reads it
# back through the same uci surface it uses in production.
cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
# usage: uci -q get <key>
while [ "\$1" = "-q" ]; do shift; done
[ "\$1" = "get" ] || exit 1
v=\$(awk -v k="\$2" -F'=' '\$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$UCIDB" 2>/dev/null)
[ -n "\$v" ] || exit 1
printf '%s\n' "\$v"
MOCK

# No nft, no routes: tctl_get_offload_mode reads uci (offload off -> "none")
# and tctl_ip_is_nexthop must find nothing, or a device would be refused a MAC.
cat > "$MOCKBIN/nft" <<'MOCK'
#!/bin/sh
exit 1
MOCK
cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
exit 0
MOCK
chmod +x "$MOCKBIN"/*

uciset() {
    grep -v "^$1=" "$UCIDB" > "$UCIDB.new" 2>/dev/null || true
    printf '%s=%s\n' "$1" "$2" >> "$UCIDB.new"
    mv "$UCIDB.new" "$UCIDB"
}
: > "$UCIDB"
uciset trafficctl.history.enabled 1
uciset trafficctl.history.dir "$STORE"
uciset trafficctl.history.period month
uciset trafficctl.history.keep 3

run() {
    PATH="$MOCKBIN:$PATH" sh "$TMPDIR/history.sh" "$@" 2>/dev/null
}

# bytes_in_total / bytes_out_total are what the flush reads; the live
# bytes_in/out are deliberately different numbers so a flush that read the
# wrong field would be caught instead of coincidentally right.
dev() {
    printf '{"ip":"%s","bytes_in":1,"bytes_out":2,"src":"ct","degraded":%s,"bytes_in_total":%s,"bytes_out_total":%s,"bytes_tcp_total":%s,"bytes_udp_total":%s,"total_since":1760000000,"live":true}' \
        "$1" "${5:-false}" "$2" "$3" "$4" "0"
}
sample() { printf '[%s]\n' "$(printf '%s' "$*")" > "$SAMPLE"; }

PERIOD=$(date +%Y-%m)
FILE="$STORE/$PERIOD.tsv"
row() { grep "^$1" "$FILE" 2>/dev/null; }
field() { row "$1" | cut -f"$2"; }

# ── disabled is a refusal, not a silent no-op ────────────────────────────────
uciset trafficctl.history.enabled 0
sample "$(dev 192.168.0.50 1000 100 0)"
assert_contains "disabled history refuses to flush and says so" \
    '"reason":"disabled"' "$(run flush)"
assert_eq "disabled history wrote no period file" "" "$(ls "$STORE")"
uciset trafficctl.history.enabled 1

# ── first flush: the whole total is the starting point ───────────────────────
sample "$(dev 192.168.0.50 1000 100 0)"
out=$(run flush)
assert_contains "first flush reports ok" '"ok":true' "$out"
assert_contains "first flush names the period" "\"period\":\"$PERIOD\"" "$out"
assert_eq "device with a lease is keyed on its MAC" \
    "mac:aa:bb:cc:dd:ee:01" "$(field mac: 1)"
assert_eq "first flush stores the full download total" "1000" "$(field mac: 5)"
assert_eq "first flush stores the full upload total" "100" "$(field mac: 6)"
assert_eq "the lease name is archived with the row" "laptop" "$(field mac: 4)"

# ── a second flush with no movement must add nothing ─────────────────────────
run flush >/dev/null
assert_eq "re-flushing an unchanged total does not double-count (download)" \
    "1000" "$(field mac: 5)"
assert_eq "re-flushing an unchanged total does not double-count (upload)" \
    "100" "$(field mac: 6)"

# ── growth is folded in as a delta, not as a new total ───────────────────────
sample "$(dev 192.168.0.50 1500 180 0)"
run flush >/dev/null
assert_eq "growth is added as a delta" "1500" "$(field mac: 5)"
assert_eq "growth is added as a delta (upload)" "180" "$(field mac: 6)"

# ── the accumulator restarting must rebaseline, never subtract ───────────────
# This is the reboot case: /tmp/trafficctl_totals.state is gone, so the live
# total comes back far below what has already been stored.
sample "$(dev 192.168.0.50 40 5 0)"
run flush >/dev/null
assert_eq "a restarted accumulator does not reduce the stored total" \
    "1500" "$(field mac: 5)"
# And the NEXT growth after the restart is measured from the restarted value,
# so the 40 bytes already seen are not counted twice.
sample "$(dev 192.168.0.50 140 25 0)"
run flush >/dev/null
assert_eq "growth after a restart is measured from the new baseline" \
    "1600" "$(field mac: 5)"
assert_eq "growth after a restart is measured from the new baseline (upload)" \
    "200" "$(field mac: 6)"

# ── a device missing from one sample keeps its cursor ────────────────────────
# Without this the device's whole lifetime total lands as one fake delta the
# moment it reappears.
sample "$(dev 10.0.20.7 500 50 0)"
run flush >/dev/null
assert_eq "an absent device's stored total is untouched" "1600" "$(field mac: 5)"
sample "$(dev 192.168.0.50 140 25 0)"
run flush >/dev/null
assert_eq "a returning device is not re-counted from zero" "1600" "$(field mac: 5)"

# ── no MAC: an ip: key, marked as such ──────────────────────────────────────
assert_eq "a device with no lease and no neighbour entry gets an ip: key" \
    "ip:10.0.20.7" "$(field ip:10.0.20.7 1)"
assert_eq "an ip-keyed row records no MAC" "-" "$(field ip:10.0.20.7 2)"
assert_contains "read reports which rows are MAC-keyed" \
    '"key_kind":"mac"' "$(run read)"
assert_contains "read reports which rows are only IP-keyed" \
    '"key_kind":"ip"' "$(run read)"

# ── an empty name must not erase an archived one ────────────────────────────
# A lease whose hostname field is "*" is the real shape of this: the MAC is
# still known, so the row keeps its identity, but there is no name to read.
# That is the case where the archived label is the only one there will be.
#
# Emptying the leases file entirely would NOT test this — it also removes the
# MAC, which moves the device to an ip: key and a different row, so the
# assertion would pass by reading a row nothing had touched. (Exercised
# deliberately further down.)
printf '%s\n' "1760000000 aa:bb:cc:dd:ee:01 192.168.0.50 * *" > "$LEASES"
sample "$(dev 192.168.0.50 240 35 0)"
run flush >/dev/null
assert_eq "a lease with no hostname does not erase the archived name" \
    "laptop" "$(field mac: 4)"
assert_eq "and the row is still the same MAC-keyed row" "1700" \
    "$(field mac: 5)"

# ── degraded is a lower bound and must reach the stored row ─────────────────
sample "$(dev 192.168.0.50 340 45 0 true)"
run flush >/dev/null
assert_eq "an uncountered-offload sample marks the row degraded" \
    "true" "$(field mac: 11)"
assert_eq "and still accounts the growth it did see" "1800" "$(field mac: 5)"
assert_contains "read surfaces degraded so a consumer can label it" \
    '"degraded":true' "$(run read)"
# Sticky: one tainted sample understates the total for the rest of its life,
# so a healthy sample afterwards must not re-present it as trustworthy.
sample "$(dev 192.168.0.50 440 55 0)"
run flush >/dev/null
assert_eq "degraded stays set once the total has been understated" \
    "true" "$(field mac: 11)"

# ── losing the MAC entirely starts a NEW row rather than adopting the old ───
# Documented choice: adoption would be a guess that the two rows are the same
# device, and the case it would break — an address reused by something else —
# silently merges unrelated traffic. The old row must keep its history intact.
before=$(field mac: 5)
: > "$LEASES"
sample "$(dev 192.168.0.50 640 75 0)"
run flush >/dev/null
assert_eq "a device that loses both lease and neighbour entry gets an ip: row" \
    "ip:192.168.0.50" "$(field 'ip:192.168.0.50' 1)"
assert_eq "the MAC-keyed row keeps every byte it had" "$before" "$(field mac: 5)"
printf '%s\n' "1760000000 aa:bb:cc:dd:ee:01 192.168.0.50 laptop *" > "$LEASES"

# ── atomic replace leaves nothing behind ────────────────────────────────────
assert_eq "no temp files are left in the store" "" \
    "$(find "$STORE" -name '.history.*' 2>/dev/null)"

# ── reading a range aggregates across period files ──────────────────────────
printf '# trafficctl-history 1\n' > "$STORE/2026-08.tsv"
printf 'mac:aa:bb:cc:dd:ee:01\taa:bb:cc:dd:ee:01\t192.168.0.50\tlaptop\t7000\t700\t0\t0\t1750000000\t1750000100\tfalse\n' \
    >> "$STORE/2026-08.tsv"
assert_contains "a single-period read sees only that period" \
    '"bytes_in":7000' "$(run read 2026-08)"
two=$(run read 2026-08 "$PERIOD")
assert_contains "a range read sums the periods" '"bytes_in":8900' "$two"
assert_contains "a range read lists the periods a device appeared in" \
    '"2026-08"' "$two"
assert_eq "a read of a period with no file is an empty array" "[]" "$(run read 1999-01)"

# ── periods ─────────────────────────────────────────────────────────────────
assert_contains "periods lists the stored months" '"period":"2026-08"' "$(run periods)"
assert_contains "periods lists the current month" "\"period\":\"$PERIOD\"" "$(run periods)"

# ── prune keeps the retention count and never the current period ────────────
for p in 2026-01 2026-02 2026-03 2026-04 2026-05; do
    printf '# trafficctl-history 1\n' > "$STORE/$p.tsv"
done
out=$(run prune)
assert_contains "prune reports what it kept" '"kept":3' "$out"
assert_eq "prune leaves exactly keep+current period files" "4" \
    "$(find "$STORE" -name '*.tsv' | wc -l | tr -d ' ')"
assert_eq "prune never deletes the period being written to" "1" \
    "$(find "$STORE" -name "$PERIOD.tsv" | wc -l | tr -d ' ')"
assert_eq "prune drops the oldest first" "0" \
    "$(find "$STORE" -name '2026-01.tsv' | wc -l | tr -d ' ')"

# ── status: the accuracy verdict a consumer has to label the view with ──────
st=$(run status)
assert_contains "status reports the store directory" "\"dir\":\"$STORE\"" "$st"
assert_contains "status reports the directory is writable" '"writable":true' "$st"
assert_contains "status reports an accuracy verdict" '"accuracy":"' "$st"
assert_contains "with no offload the verdict is sampled, not exact" \
    '"accuracy":"sampled"' "$st"
assert_contains "status reports the sampling interval separately from the flush interval" \
    '"sample_interval":' "$st"
# Uncountered offload with no nft fallback is a LOWER BOUND, and the verdict
# has to say so rather than defaulting to the optimistic case.
uciset firewall.@defaults[0].flow_offloading 1
assert_contains "uncountered software offload degrades the verdict" \
    '"accuracy":"degraded"' "$(run status)"
uciset firewall.@defaults[0].flow_offloading 0

# ── an unwritable store is an error state, not a silent loss ────────────────
uciset trafficctl.history.dir /proc/trafficctl-history-nope
out=$(run flush)
assert_contains "an unwritable store fails loudly" '"ok":false' "$out"
uciset trafficctl.history.dir "$STORE"
assert_contains "the failure is reported in status" '"error":"' "$(run status)"
# And recovers: a later successful flush must clear it, or the UI would show a
# stale failure for ever.
sample "$(dev 192.168.0.50 540 65 0)"
run flush >/dev/null
assert_contains "a successful flush clears the error" '"error":"",' "$(run status)"

# ── interval floors: this store exists to stay off the flash write path ─────
uciset trafficctl.history.interval 5
assert_contains "a too-short flush interval is floored" '"interval":300' "$(run status)"
uciset trafficctl.history.interval 7200
assert_contains "a sane flush interval is respected" '"interval":7200' "$(run status)"

# ── period kinds ───────────────────────────────────────────────────────────
uciset trafficctl.history.period day
assert_contains "day periods use a fixed-width sortable id" \
    "\"period\":\"$(date +%Y-%m-%d)\"" "$(run status)"
uciset trafficctl.history.period week
# %G, not %Y: in the days where the calendar year and the ISO week year
# disagree, %Y-%V names a week belonging to the other year and two different
# weeks collide on one id.
assert_contains "week periods use the ISO week year" \
    "\"period\":\"$(date +%G-W%V)\"" "$(run status)"
assert_not_contains "the week id is not built from the calendar year" \
    "period\":\"$(date +%Y)-W$(date +%V)\"-" "$(run status)"
uciset trafficctl.history.period month

# ── sample advances the accumulator without touching the store ─────────────
before=$(find "$STORE" -name '*.tsv' -newer "$UCIDB" 2>/dev/null | wc -l | tr -d ' ')
assert_contains "sample reports ok" '"ok":true' "$(run sample)"
assert_eq "sample writes nothing into the durable store" "$before" \
    "$(find "$STORE" -name '*.tsv' -newer "$UCIDB" 2>/dev/null | wc -l | tr -d ' ')"
uciset trafficctl.history.enabled 0
assert_contains "sample is a no-op while history is disabled" \
    '"reason":"disabled"' "$(run sample)"
uciset trafficctl.history.enabled 1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
