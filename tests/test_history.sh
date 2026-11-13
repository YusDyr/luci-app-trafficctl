#!/bin/bash
# Tests for `trafficctl history` (history.uc): the durable per-period traffic
# store behind #89 (history for devices that are offline now) and #90 (where
# it lives, when it resets, how long it is kept).
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
#     to a trustworthy sum,
#   * a period id is a file name: an ISO week computed wrong around New Year
#     splits one week into two files, or merges two weeks into one.
#
# The module runs for real against a scratch TCTL_ROOT with the real uci.
# Most sections feed it recorded samples through tests/lib/history.uc (the
# flush runs in process there); the guard and keeper sections run the CLI,
# whose flush is a child process under a timeout.
#
# The same behaviour against the v1.30.0 shell script, file by file and in
# both directions (each reads the other's store), is tests/equiv.sh.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/bytes_env.sh
. "$(dirname "$0")/lib/bytes_env.sh"

PASS=0
FAIL=0

UC="$UC_LIB/trafficctl/history.uc"
ROOT="$BE_ROOT"
STORE="$ROOT/tmp/store"
CURSOR="$ROOT/tmp/trafficctl_history.cursor"
IFCURSOR="$ROOT/tmp/trafficctl_history.ifcursor"
ERRFILE="$ROOT/tmp/trafficctl_history.err"
LEASES="$ROOT/tmp/dhcp.leases"
SAMPLE="$UC_TMP/sample.json"
IFSAMPLE="$UC_TMP/ifsample.json"
mkdir -p "$STORE" "$ROOT/etc/trafficctl" "$ROOT/usr/sbin"
: > "$IFSAMPLE"

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

uciset() {
    "$UCODE_PREFIX/bin/uci" -c "$ROOT/etc/config" set "$1=$2"
    "$UCODE_PREFIX/bin/uci" -c "$ROOT/etc/config" commit "${1%%.*}"
}
touch "$ROOT/etc/config/trafficctl"
uciset trafficctl.history history
uciset trafficctl.history.enabled 1
uciset trafficctl.history.dir /tmp/store
uciset trafficctl.history.period month
uciset trafficctl.history.keep 3

run() {
    TCTL_ROOT="$ROOT" PATH="$BE_BIN:$PATH" \
        "$UCODE" -S -L "$UC_LIB" -L "$UC_TESTLIB" -- "$UC_TESTLIB/history.uc" "$SAMPLE" "$IFSAMPLE" "$@" 2>/dev/null
}
# The CLI itself, as procd and rpcd run it.
cli() { TCTL_ROOT="$ROOT" PATH="$BE_BIN:$PATH" tctl history "$@" 2>/dev/null; }

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
assert_contains "and so does the guarded flush the CLI runs" \
    '"reason":"disabled"' "$(cli flush)"
assert_eq "disabled history wrote no period file" "" "$(ls "$STORE")"
uciset trafficctl.history.enabled 1

# ── first flush: the whole total is the starting point ───────────────────────
sample "$(dev 192.168.0.50 1000 100 0)"
out=$(run flush)
assert_contains "first flush reports ok" '"ok":true' "$out"
assert_contains "first flush names the period" "\"period\":\"$PERIOD\"" "$out"
assert_contains "first flush counts the rows it wrote" '"devices":1,' "$out"
assert_eq "the file starts with the format header" "# trafficctl-history 1" "$(head -1 "$FILE")"
assert_eq "device with a lease is keyed on its MAC" \
    "mac:aa:bb:cc:dd:ee:01" "$(field mac: 1)"
assert_eq "first flush stores the full download total" "1000" "$(field mac: 5)"
assert_eq "first flush stores the full upload total" "100" "$(field mac: 6)"
assert_eq "the lease name is archived with the row" "laptop" "$(field mac: 4)"
assert_eq "a row has the eleven fields of format 1" "11" "$(row mac: | awk -F'\t' '{ print NF }')"

# ── a second flush with no movement must add nothing ─────────────────────────
run flush >/dev/null
assert_eq "re-flushing an unchanged total does not double-count (download)" \
    "1000" "$(field mac: 5)"
assert_eq "re-flushing an unchanged total does not double-count (upload)" \
    "100" "$(field mac: 6)"
# Only movement is activity: an idle device keeps its last_seen.
sed -i "s/^\(mac:aa:bb:cc:dd:ee:01\t\([^\t]*\t\)\{8\}\)[0-9]*/\11000000000/" "$FILE"
run flush >/dev/null
assert_eq "an idle device keeps its last_seen" "1000000000" "$(field mac: 10)"

# ── growth is folded in as a delta, not as a new total ───────────────────────
sample "$(dev 192.168.0.50 1500 180 0)"
run flush >/dev/null
assert_eq "growth is added as a delta" "1500" "$(field mac: 5)"
assert_eq "growth is added as a delta (upload)" "180" "$(field mac: 6)"
moved=no
[ "$(field mac: 10)" -gt 1000000000 ] && moved=yes
assert_eq "growth moves last_seen" "yes" "$moved"

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
assert_contains "and its cursor is kept" "mac:aa:bb:cc:dd:ee:01	140	25" "$(cat "$CURSOR")"
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
# Emptying the leases file entirely would NOT test this: it also removes the
# MAC, which moves the device to an ip: key and a different row.
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
# Sticky: one tainted sample understates the total for the rest of its life.
sample "$(dev 192.168.0.50 440 55 0)"
run flush >/dev/null
assert_eq "degraded stays set once the total has been understated" \
    "true" "$(field mac: 11)"

# ── losing the MAC entirely starts a NEW row rather than adopting the old ───
before=$(field mac: 5)
: > "$LEASES"
sample "$(dev 192.168.0.50 640 75 0)"
run flush >/dev/null
assert_eq "a device that loses both lease and neighbour entry gets an ip: row" \
    "ip:192.168.0.50" "$(field 'ip:192.168.0.50' 1)"
assert_eq "the MAC-keyed row keeps every byte it had" "$before" "$(field mac: 5)"
printf '%s\n' "1760000000 aa:bb:cc:dd:ee:01 192.168.0.50 laptop *" > "$LEASES"

# ── names: alias > lease > reverse DNS ──────────────────────────────────────
# The reverse-DNS cache is "IP HOST TIMESTAMP", space-separated. The shell
# read it as tab-separated and so never found a name there; a routed device's
# PTR record is its only name source.
printf '10.0.20.8 printer.lan 1794229581\n10.0.20.9 - 1794229581\n' > "$ROOT/tmp/trafficctl_rdns_cache"
printf '192.168.0.50 Kitchen  "laptop"\n' > "$ROOT/etc/trafficctl/names"
sample "$(dev 192.168.0.50 640 75 0),$(dev 10.0.20.8 1 1 0),$(dev 10.0.20.9 1 1 0)"
run flush >/dev/null
assert_eq "a manual alias wins over the lease, its spaces collapsed" 'Kitchen "laptop"' "$(field mac: 4)"
assert_eq "a routed device is named from the reverse-DNS cache" "printer.lan" "$(field ip:10.0.20.8 4)"
assert_eq "a negative reverse-DNS answer is no name" "-" "$(field ip:10.0.20.9 4)"
assert_contains "a quote in a name is escaped in the JSON" '"name":"Kitchen \"laptop\""' "$(run read)"
run read | jq -e . >/dev/null 2>&1
assert_eq "read prints valid JSON whatever the names hold" "0" "$?"
rm -f "$ROOT/etc/trafficctl/names" "$ROOT/tmp/trafficctl_rdns_cache"

# ── a next hop is never keyed on its MAC ────────────────────────────────────
# Its MAC is the source of every packet it forwards: keying on it would merge
# a whole subnet into one row.
cat > "$BE_BIN/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    "route show") echo "10.9.0.0/16 via 192.168.0.60 dev br-lan" ;;
    "neigh show") echo "192.168.0.60 dev br-lan lladdr AA:BB:CC:DD:EE:60 REACHABLE"
                  echo "192.168.0.61 dev br-lan FAILED"
                  echo "192.168.0.61 dev br-lan lladdr aa:bb:cc:dd:ee:61 STALE" ;;
esac
exit 0
MOCK
sample "$(dev 192.168.0.60 1 1 0),$(dev 192.168.0.61 1 1 0)"
run flush >/dev/null
assert_eq "a route's next hop gets an ip: key" "ip:192.168.0.60" "$(field ip:192.168.0.60 1)"
assert_eq "a device known only to the neighbour table is keyed on that MAC, lowercased" \
    "mac:aa:bb:cc:dd:ee:61" "$(field mac:aa:bb:cc:dd:ee:61 1)"
printf '#!/bin/sh\nexit 0\n' > "$BE_BIN/ip"

# ── a sampler that printed nothing fails the flush and touches nothing ──────
before=$(md5sum < "$FILE")
: > "$SAMPLE"
assert_eq "no sample is a failed flush" '{"ok":false,"reason":"no sample"}' "$(run flush)"
assert_eq "that leaves the period file as it was" "$before" "$(md5sum < "$FILE")"
assert_contains "and puts history in the error state" '"error":"totals produced nothing"' "$(run status)"
sample "$(dev 192.168.0.50 640 75 0)"
run flush >/dev/null

# ── atomic replace leaves nothing behind ────────────────────────────────────
assert_eq "no temp files are left in the store" "" \
    "$(find "$STORE" -name '*.tmp.*' 2>/dev/null)"

# ── reading a range aggregates across period files ──────────────────────────
printf '# trafficctl-history 1\n' > "$STORE/2026-08.tsv"
printf 'mac:aa:bb:cc:dd:ee:01\taa:bb:cc:dd:ee:01\t192.168.0.50\tlaptop\t7000\t700\t0\t0\t1750000000\t1750000100\tfalse\n' \
    >> "$STORE/2026-08.tsv"
assert_contains "a single-period read sees only that period" \
    '"bytes_in":7000' "$(run read 2026-08)"
two=$(run read 2026-08 "$PERIOD")
assert_contains "a range read sums the periods" "\"bytes_in\":$((7000 + $(field mac:aa:bb:cc:dd:ee:01 5)))," "$two"
assert_contains "a range read lists the periods a device appeared in" \
    '"2026-08"' "$two"
assert_contains "and takes the earliest first_seen" '"first_seen":1750000000' "$two"
assert_eq "a read of a period with no file is an empty array" "[]" "$(run read 1999-01)"
# A 10-field row from before the degraded column reads as not degraded.
printf '# trafficctl-history 1\nip:10.1.1.1\t-\t10.1.1.1\t-\t9007199254740993\t1\t0\t0\t1\t2\n' > "$STORE/2026-07.tsv"
assert_contains "a total past 2^53 stays exact" '"bytes_in":9007199254740993' "$(run read 2026-07)"
assert_contains "a row without the degraded column is not degraded" '"degraded":false' "$(run read 2026-07)"

# ── periods ─────────────────────────────────────────────────────────────────
assert_contains "periods lists the stored months" '"period":"2026-08"' "$(run periods)"
assert_contains "periods lists the current month" "\"period\":\"$PERIOD\"" "$(run periods)"
printf '# trafficctl-history 1\n' > "$STORE/2026-06.tsv"
# The shell printed "0\n0" for a header-only file (grep -c prints 0 AND
# fails, so its "|| echo 0" ran too): invalid JSON for the whole list.
assert_contains "a period with no rows counts zero devices" \
    '{"period":"2026-06","devices":0,"bytes":0}' "$(run periods)"
run periods | jq -e . >/dev/null 2>&1
assert_eq "periods is valid JSON with an empty period in it" "0" "$?"
rm -f "$STORE/2026-06.tsv" "$STORE/2026-07.tsv"

# ── prune keeps the retention count and never the current period ────────────
for p in 2026-01 2026-02 2026-03 2026-04 2026-05; do
    printf '# trafficctl-history 1\n' > "$STORE/$p.tsv"
done
mkdir -p "$STORE/old"
printf '# trafficctl-history 1\n' > "$STORE/old/2020-01.tsv"
out=$(run prune)
assert_contains "prune reports what it kept" '"kept":3' "$out"
assert_contains "prune reports what it dropped" '"dropped":3' "$out"
assert_eq "prune leaves exactly keep+current period files" "4" \
    "$(find "$STORE" -maxdepth 1 -name '*.tsv' | wc -l | tr -d ' ')"
assert_eq "prune never deletes the period being written to" "1" \
    "$(find "$STORE" -name "$PERIOD.tsv" | wc -l | tr -d ' ')"
assert_eq "prune drops the oldest first" "0" \
    "$(find "$STORE" -name '2026-01.tsv' | wc -l | tr -d ' ')"
# The shell's find recursed, so a subdirectory's files counted as periods and
# were deleted from the store root by name (where they did not exist).
assert_eq "prune leaves a subdirectory alone" "1" \
    "$(find "$STORE/old" -name '2020-01.tsv' | wc -l | tr -d ' ')"
rm -rf "$STORE/old"

# ── status: the accuracy verdict a consumer has to label the view with ──────
st=$(run status)
assert_contains "status reports the store directory" '"dir":"/tmp/store"' "$st"
assert_contains "status reports the directory is writable" '"writable":true' "$st"
assert_contains "with no offload the verdict is sampled, not exact" \
    '"accuracy":"sampled"' "$st"
assert_contains "status reports the sampling interval separately from the flush interval" \
    '"sample_interval":60' "$st"
assert_contains "status reports the last flush" '"last_flush":1' "$st"
# Uncountered offload is a LOWER BOUND, and the verdict has to say so rather
# than defaulting to the optimistic case.
be_offload software
assert_contains "uncountered software offload degrades the verdict" \
    '"accuracy":"degraded"' "$(run status)"
be_offload software-counter
assert_contains "a counter-flagged flowtable keeps it sampled" \
    '"accuracy":"sampled"' "$(run status)"
be_offload none

# ── the store directory is constrained, because prune deletes inside it ─────
# Unconstrained, the write ACL would get arbitrary directory creation plus the
# removal of any .tsv on the filesystem. A rejected value must fall back to
# the default rather than being honoured.
uciset trafficctl.history.dir /root/somewhere
assert_contains "a path outside the allowed roots falls back to the default" \
    '"dir":"/etc/trafficctl/history"' "$(run status)"
uciset trafficctl.history.dir "/mnt/../etc/trafficctl/history"
assert_contains "a traversal is refused" \
    '"dir":"/etc/trafficctl/history"' "$(run status)"
uciset trafficctl.history.dir "/mnt"
assert_contains "a bare mount root is refused, or prune would delete all of it" \
    '"dir":"/etc/trafficctl/history"' "$(run status)"
for d in /mnt/. /mnt/./ /mnt/./. /mnt// /mnt/// /mnt//./ /etc/trafficctl/. /etc/trafficctl/ '/mnt/a;b' 'relative/x'; do
    uciset trafficctl.history.dir "$d"
    assert_contains "$d is refused: it names a bare root, or is not a plain path" \
        '"dir":"/etc/trafficctl/history"' "$(run status)"
done
# Folded, these name a directory below the root, which v1.30.0 accepted too.
for d in /mnt/./x /mnt//x /mnt/x/. /tmp/x/./y; do
    uciset trafficctl.history.dir "$d"
    assert_contains "$d is accepted: it names a directory below the root" \
        "\"dir\":\"$d\"" "$(run status)"
done
uciset trafficctl.history.dir "/mnt/.nas/x..y"
assert_contains "a dot inside a name is still a name" \
    '"dir":"/mnt/.nas/x..y"' "$(run status)"
uciset trafficctl.history.dir "/mnt/nas/tctl/"
assert_contains "a real mount point is allowed, one trailing slash dropped" \
    '"dir":"/mnt/nas/tctl"' "$(run status)"
for d in /mnt/usb /etc/trafficctl/h /media/x /srv/x /tmp/x; do
    cli validate-dir "$d"
    assert_eq "validate-dir accepts $d" "0" "$?"
done
for d in /mnt /mnt/ /etc /mnt/../etc '/tmp/a b;c' ''; do
    cli validate-dir "$d"
    assert_eq "validate-dir refuses '$d'" "1" "$?"
done
assert_eq "validate-dir prints nothing" "" "$(cli validate-dir /mnt/usb)"
uciset trafficctl.history.dir /tmp/store

# ── an unwritable store is an error state, not a silent loss ────────────────
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$ROOT/tmp/ro"
    chmod 500 "$ROOT/tmp/ro"
    uciset trafficctl.history.dir /tmp/ro/sub
    out=$(run flush)
    assert_contains "an unwritable store fails loudly" '"reason":"mkdir failed"' "$out"
    chmod 700 "$ROOT/tmp/ro"
    uciset trafficctl.history.dir /tmp/store
    assert_contains "the failure is reported in status" '"error":"cannot create /tmp/ro/sub"' "$(run status)"
    assert_eq "with the time it happened" "1" "$(run status | jq '.error_at > 1700000000 | if . then 1 else 0 end')"
    # And recovers: a later successful flush must clear it, or the UI would
    # show a stale failure for ever.
    sample "$(dev 192.168.0.50 540 65 0)"
    run flush >/dev/null
    assert_contains "a successful flush clears the error" '"error":"",' "$(run status)"
else
    echo "(root: the unwritable-store section is skipped, root writes anywhere)"
fi
printf '1794000000\tcannot write "/mnt/x"\\\n' > "$ERRFILE"
assert_contains "an error message loses its quotes and backslashes in status" \
    '"error":"cannot write /mnt/x","error_at":1794000000' "$(run status)"
rm -f "$ERRFILE"

# ── interval floors: this store exists to stay off the flash write path ─────
uciset trafficctl.history.interval 5
assert_contains "a too-short flush interval is floored" '"interval":300' "$(run status)"
uciset trafficctl.history.interval 7200
assert_contains "a sane flush interval is respected" '"interval":7200' "$(run status)"
uciset trafficctl.history.interval 99999999999999999999999
assert_contains "an interval past int64 is not a negative number" '"interval":' "$(run status)"
assert_not_contains "an interval past int64 is not a negative number" '"interval":-' "$(run status)"
uciset trafficctl.history.interval 3600
uciset trafficctl.history.sample_interval 1
assert_contains "the sampling interval is floored at 10 s" '"sample_interval":10' "$(run status)"
uciset trafficctl.history.sample_interval 9999
assert_contains "and capped at an hour" '"sample_interval":3600' "$(run status)"
uciset trafficctl.history.sample_interval 60
uciset trafficctl.history.keep 0
assert_contains "keep is at least one period" '"keep":1' "$(run status)"
uciset trafficctl.history.keep 12x
assert_contains "a keep that is not a number is the default" '"keep":12' "$(run status)"
uciset trafficctl.history.keep 3

# ── period kinds ───────────────────────────────────────────────────────────
uciset trafficctl.history.period day
assert_contains "day periods use a fixed-width sortable id" \
    "\"period\":\"$(date +%Y-%m-%d)\"" "$(run status)"
uciset trafficctl.history.period week
assert_contains "week periods use the ISO week year" \
    "\"period\":\"$(date +%G-W%V)\"" "$(run status)"
uciset trafficctl.history.period month

# The ISO week is computed by hand (there is no strftime): checked against
# date(1)'s %G-W%V for every 3rd day over 41 years (every weekday and both
# year lengths at every New Year) and around the 2026/2027 boundary hour by
# hour, in UTC and in zones both sides of it with DST. A wrong week id is a
# wrong FILE name: one week split in two, or two weeks merged.
uciset trafficctl.history.period week
cat > "$UC_TMP/weeks.uc" <<'EOF'
import * as h from 'trafficctl.history';
for (let t = +ARGV[0]; t <= +ARGV[1]; t += +ARGV[2])
	print(t, ' ', h.period_id(t), '\n');
EOF
weeks() {   # weeks <TZ> <from> <to> <step>
    TZ="$1" TCTL_ROOT="$ROOT" "$UCODE" -S -L "$UC_LIB" "$UC_TMP/weeks.uc" "$2" "$3" "$4" > "$UC_TMP/w.new"
    awk '{ print "@" $1 }' "$UC_TMP/w.new" | TZ="$1" date -f - +%G-W%V |
        paste -d ' ' <(awk '{ print $1 }' "$UC_TMP/w.new") - > "$UC_TMP/w.date"
    diff "$UC_TMP/w.date" "$UC_TMP/w.new" | head -5
}
for z in UTC 'NZST-12NZDT,M9.5.0,M4.1.0/3' '<-04>4<-03>,M9.1.6/24,M4.1.6/24'; do
    assert_eq "ISO weeks 2000-2040 equal date +%G-W%V ($z)" "" "$(weeks "$z" 946684800 2240611200 259200)"
    assert_eq "ISO weeks 2026-12-27..2027-01-05 hourly equal date +%G-W%V ($z)" "" \
        "$(weeks "$z" 1798329600 1799107200 3600)"
done
pid() { TZ="$1" TCTL_ROOT="$ROOT" tcall trafficctl.history period_id "$2"; }
assert_eq "2026-12-28 is in week 53 of 2026" "2026-W53" "$(pid UTC 1798416000)"
assert_eq "2027-01-03 is still 2026-W53" "2026-W53" "$(pid UTC 1799020799)"
assert_eq "2027-01-04 starts 2027-W01" "2027-W01" "$(pid UTC 1799020800)"
assert_eq "the local date decides: 2027-01-03 23:00 UTC is Monday in Auckland" "2027-W01" \
    "$(pid 'NZST-12NZDT,M9.5.0,M4.1.0/3' 1799017200)"
uciset trafficctl.history.period day
assert_eq "a day id rolls over at local midnight across a DST change at midnight" \
    "2026-09-05 2026-09-06" \
    "$(pid '<-04>4<-03>,M9.1.6/24,M4.1.6/24' 1788667199) $(pid '<-04>4<-03>,M9.1.6/24,M4.1.6/24' 1788667200)"
uciset trafficctl.history.period month
assert_eq "a month id is the local month" "2027-01" "$(pid 'NZST-12NZDT,M9.5.0,M4.1.0/3' 1798725600)"

# ── sample advances the accumulator without touching the store ─────────────
before=$(cat "$STORE"/*.tsv | md5sum)
assert_contains "sample reports ok" '"ok":true' "$(run sample)"
assert_eq "sample writes nothing into the durable store" "$before" "$(cat "$STORE"/*.tsv | md5sum)"
uciset trafficctl.history.enabled 0
assert_contains "sample is a no-op while history is disabled" \
    '"reason":"disabled"' "$(run sample)"
uciset trafficctl.history.enabled 1

# ── the lock ───────────────────────────────────────────────────────────────
# A live flush's lock is never stolen; one left by a flush the guard killed
# (it has no handler to remove it) is, once it is older than the guard.
mkdir "$ROOT/tmp/trafficctl_history.lock.d"
t0=$(date +%s)
assert_contains "a flush waits for a lock held by a live flush, then gives up" \
    '"reason":"locked"' "$(run flush)"
assert_eq "it waits about five seconds, as the shell did" "1" "$(( $(date +%s) - t0 >= 4 ))"
touch -d @1700000000 "$ROOT/tmp/trafficctl_history.lock.d"
assert_contains "a lock older than the guard is taken over" '"ok":true' "$(run flush)"
assert_eq "and released afterwards" "0" "$(test -e "$ROOT/tmp/trafficctl_history.lock.d" && echo 1 || echo 0)"

# ── the NFS stall guard ────────────────────────────────────────────────────
# `flush` runs `trafficctl history flush-now` as a child, under timeout(1)
# where the system has it and under system()'s own kill in any case, because
# a write that blocks on a dead mount cannot be timed out from inside.
real_cli() {
    printf '#!/bin/sh\nPOSIXLY_CORRECT=1 exec "%s" -S -L "%s" "%s" "$@"\n' "$UCODE" "$UC_LIB" \
        "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" > "$ROOT/usr/sbin/trafficctl"
    chmod +x "$ROOT/usr/sbin/trafficctl"
}
printf '#!/bin/sh\necho "$*" >> "%s/child.log"\nexec /bin/sleep 300\n' "$UC_TMP" > "$ROOT/usr/sbin/trafficctl"
chmod +x "$ROOT/usr/sbin/trafficctl"
# timeout 15 becomes timeout 1, so the case takes a second.
REAL_TIMEOUT=$(command -v timeout)
printf '#!/bin/sh\nshift\nexec "%s" 1 "$@"\n' "$REAL_TIMEOUT" > "$BE_BIN/timeout"
chmod +x "$BE_BIN/timeout"
t0=$(date +%s)
out=$(cli flush)
assert_eq "a flush that hangs is reported, not waited for" '{"ok":false,"reason":"timed out"}' "$out"
assert_eq "within the timeout" "1" "$(( $(date +%s) - t0 <= 5 ))"
assert_eq "the child was the store writer" "history flush-now" "$(cat "$UC_TMP/child.log")"
assert_contains "and the error state says why" '"error":"flush did not finish within 15 s"' "$(run status)"
rm -f "$BE_BIN/timeout"
# Without timeout(1) (22.03's BusyBox has none) system() still kills the
# child, at 20 s.
printf '#!/bin/sh\nexec /bin/sleep 300\n' > "$ROOT/usr/sbin/trafficctl"
t0=$(date +%s)
out=$(TCTL_ROOT="$ROOT" PATH="$BE_BIN" "$UCODE" -S -L "$UC_LIB" -- "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" history flush 2>/dev/null)
el=$(( $(date +%s) - t0 ))
assert_eq "without timeout(1) the flush is still bounded" '{"ok":false,"reason":"timed out"}' "$out"
assert_eq "by system()'s own kill (took ${el} s)" "1" "$(( el >= 19 && el <= 25 ))"
# The child's own reply and exit status are passed on as they are.
printf '#!/bin/sh\necho %s\nexit 1\n' "'{\"ok\":false,\"reason\":\"write failed\",\"file\":\"/x\"}'" > "$ROOT/usr/sbin/trafficctl"
out=$(cli flush); rc=$?
assert_eq "the child's reply is the flush's reply" '{"ok":false,"reason":"write failed","file":"/x"}' "$out"
assert_eq "and so is its failure" "1" "$rc"
real_cli
sample "$(dev 192.168.0.50 540 65 0)"
assert_contains "the CLI's flush writes the store through the child" '"ok":true' "$(cli flush)"
assert_contains "and clears the error state" '"error":"",' "$(run status)"

# ══════════════════════════════════════════════════════════════════════════
# Interface totals (#102): a SECOND series, not a breakdown of the first.
#
# The bytes are the kernel's own interface counters, so they include the
# router's own traffic and broadcast and legitimately disagree with the sum
# over devices. The reason they exist is the question the device series cannot
# answer: how much left via wan1 versus wan2.
# ══════════════════════════════════════════════════════════════════════════
IFFILE="$STORE/$PERIOD.if.tsv"
ifrow() { grep "^$1" "$IFFILE" 2>/dev/null; }
iffield() { ifrow "$1" | cut -f"$2"; }

ifdev() {
    printf '{"dev":"%s","label":"%s","role":"%s","tunnel":false,"primary":true,"defroute":true,"enslaved":%s,"up":true,"rx_bytes":%s,"tx_bytes":%s}' \
        "$1" "$2" "$3" "${6:-false}" "$4" "$5"
}
ifsample() { printf '[%s]\n' "$(printf '%s' "$*")" > "$IFSAMPLE"; }

: > "$CURSOR"; : > "$IFCURSOR"; rm -f "$STORE"/*.tsv "$ROOT"/tmp/trafficctl_history.ifacc.*
sample "$(dev 192.168.0.50 100 10 0)"
ifsample "$(ifdev eth1 wan wan 5000 500),$(ifdev br-lan lan lan 700 7000)"
run flush >/dev/null

assert_eq "the interface series lands in its own file" "1" \
    "$(test -f "$IFFILE" && echo 1 || echo 0)"
assert_eq "with its own header" "# trafficctl-history-if 1" "$(head -1 "$IFFILE")"
assert_eq "the WAN interface is recorded with its role" "wan" "$(iffield eth1 2)"
assert_eq "its download is the interface rx counter" "5000" "$(iffield eth1 4)"
assert_eq "its upload is the interface tx counter" "500" "$(iffield eth1 5)"
assert_eq "the LAN bridge is recorded too" "lan" "$(iffield br-lan 2)"

assert_not_contains "no interface leaks into the device file" "eth1" "$(cat "$FILE")"
assert_not_contains "and the device reader does not report interfaces" \
    '"ip":"eth1"' "$(run read)"
assert_contains "the interface reader does report them" '"dev":"eth1"' "$(run read-ifaces)"

# Growth is a delta here too.
ifsample "$(ifdev eth1 wan wan 6500 800),$(ifdev br-lan lan lan 700 7000)"
run flush >/dev/null
assert_eq "interface growth is added as a delta" "6500" "$(iffield eth1 4)"
assert_eq "an idle interface gains nothing" "700" "$(iffield br-lan 4)"

# A link that flaps resets its counters. The store must rebaseline instead of
# subtracting, and KEEP what the interface has carried since the restart:
# a /proc/net/dev counter is monotonic for the lifetime of the interface, so
# nothing has counted those bytes (#111).
#   5000  first reading, no cursor yet, so the whole counter
#  +1500  6500 - 5000
#   +120  counter restarted at some point and now reads 120
#   +200  320 - 120, measured from the restarted value
ifsample "$(ifdev eth1 wan wan 120 12),$(ifdev br-lan lan lan 700 7000)"
run flush >/dev/null
assert_eq "a flap keeps what the interface carried since the restart" \
    "6620" "$(iffield eth1 4)"
ifsample "$(ifdev eth1 wan wan 320 30),$(ifdev br-lan lan lan 700 7000)"
run flush >/dev/null
assert_eq "and growth after the flap is measured from the new baseline" \
    "6820" "$(iffield eth1 4)"

# The cursor advances on every sample tick, so a flap costs one sampling
# interval at most. The accumulator is tmpfs, the period file is not, so a
# tick advances the one without writing the other.
BEFORE=$(iffield eth1 4)
ifsample "$(ifdev eth1 wan wan 1320 130),$(ifdev br-lan lan lan 700 7000)"
run sample >/dev/null
assert_eq "a sample tick does not write the durable period file" \
    "$BEFORE" "$(iffield eth1 4)"
ifsample "$(ifdev eth1 wan wan 7 1),$(ifdev br-lan lan lan 700 7000)"
run flush >/dev/null
assert_eq "growth folded in by a tick survives a flap before the next flush" \
    "$((BEFORE + 1000 + 7))" "$(iffield eth1 4)"
# The accumulator is rebuilt from the durable file when it is gone (a boot).
rm -f "$ROOT"/tmp/trafficctl_history.ifacc.*
BEFORE=$(iffield eth1 4)
ifsample "$(ifdev eth1 wan wan 17 1),$(ifdev br-lan lan lan 700 7000)"
run flush >/dev/null
assert_eq "a lost accumulator is reseeded from the durable file" "$((BEFORE + 10))" "$(iffield eth1 4)"

# Every tick path must do it: the keeper and `sample` both, and a flush folds
# in the final interval before publishing. Comment lines stripped: the prose
# names the function being looked for.
fn() { awk -v f="$1" '$0 ~ "^function " f "\\(" { p = 1 } p { print } p && /^}$/ { exit }' "$UC" | grep -v '^[[:space:]]*//'; }
assert_contains "the keeper advances the interface cursor every tick" "if_accumulate()" "$(fn keeper)"
assert_contains "and so does the sample command" "if_accumulate(src)" "$(fn sample)"
assert_contains "a flush folds in the final interval before publishing" "if_accumulate(src)" "$(fn if_flush)"
assert_contains "the keeper flushes through the guard, not in process" "flush()" "$(fn keeper)"
assert_not_contains "the keeper never writes the store itself" "flush_now" "$(fn keeper)"
assert_contains "and prunes through the guard too" "guarded([ 'history', 'prune' ])" "$(fn keeper)"

# Interfaces whose bytes are already counted elsewhere must not be recorded,
# or the month is double-counted.
uciset trafficctl.main main
uciset trafficctl.main.shape_ifb tctl-ifb0
ifsample "$(ifdev eth1 wan wan 320 30),$(ifdev eth0.1 lan lan 999 999 true),$(ifdev lo lo lo 42 42),$(ifdev tctl-ifb0 ifb lan 888 888)"
run flush >/dev/null
assert_eq "a bridge PORT is skipped: the bridge already counts its bytes" "" "$(iffield eth0.1 1)"
assert_eq "loopback is skipped" "" "$(iffield lo 1)"
assert_eq "the shaper's IFB mirror is skipped" "" "$(iffield tctl-ifb0 1)"

# Accuracy is NOT inherited from the device verdict: an interface counter
# comes from the driver, so uncountered offload does not touch it.
be_offload software
st=$(run status)
assert_contains "offload degrades the DEVICE verdict" '"accuracy":"degraded"' "$st"
assert_contains "but not the interface verdict" '"iface_accuracy":"exact"' "$st"
be_offload none

# Retention treats a period as ONE unit of two files.
assert_contains "periods lists a period once, not twice" "1" \
    "$(run periods | grep -o "\"period\":\"$PERIOD\"" | wc -l | tr -d ' ')"
for p in 2025-01 2025-02 2025-03 2025-04; do
    printf '# trafficctl-history 1\n' > "$STORE/$p.tsv"
    printf '# trafficctl-history-if 1\n' > "$STORE/$p.if.tsv"
done
uciset trafficctl.history.keep 2
run prune >/dev/null
assert_eq "pruning a period drops BOTH its files" "0" \
    "$(find "$STORE" -name '2025-01*' | wc -l | tr -d ' ')"
assert_eq "and the current period keeps both of its own" "2" \
    "$(find "$STORE" -name "$PERIOD*" | wc -l | tr -d ' ')"
uciset trafficctl.history.keep 3

# Switchable on its own: a single-WAN router has no use for it.
uciset trafficctl.history.interfaces 0
rm -f "$IFFILE"
ifsample "$(ifdev eth1 wan wan 9999 9999)"
run flush >/dev/null
assert_eq "with interfaces off, no interface file is written" "0" \
    "$(test -f "$IFFILE" && echo 1 || echo 0)"
assert_contains "and status says so" '"interfaces":false' "$(run status)"
uciset trafficctl.history.interfaces 1

# ── the keeper, end to end ─────────────────────────────────────────────────
# What procd runs: live samples (conntrack in the root, /proc/net/dev), the
# flush and the prune as guarded children, and its own stamp to pick up from.
real_cli
rm -f "$STORE"/*.tsv "$ROOT"/tmp/trafficctl_history.*
for p in 2025-05 2025-06; do printf '# trafficctl-history 1\n' > "$STORE/$p.tsv"; done
uciset trafficctl.history.keep 1
printf 'ipv4     2 tcp      6 300 ESTABLISHED src=192.168.1.50 dst=198.18.0.3 sport=40000 dport=443 packets=1 bytes=1000 src=198.18.0.3 dst=203.0.113.2 sport=443 dport=40000 packets=1 bytes=5000 [ASSURED] mark=0 zone=0 use=2\n' > "$BE_CT"
printf 'Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n  wan: 123456 10 0 0 0 0 0 0 654321 10 0 0 0 0 0 0\n' > "$ROOT/proc/net/dev"
ubus_start "$BE_UBUS"
TCTL_ROOT="$ROOT" PATH="$BE_BIN:$PATH" tctl history keeper >/dev/null 2>&1 &
KPID=$!
for _ in $(seq 100); do
    [ -s "$ROOT/tmp/trafficctl_history.stamp" ] && break
    sleep 0.2
done
sleep 1
kill "$KPID" 2>/dev/null; wait "$KPID" 2>/dev/null
ubus_stop
assert_contains "the keeper's first tick flushes the live totals" "192.168.1.50" "$(cat "$FILE" 2>/dev/null)"
assert_eq "and stamps the flush" "1" "$(grep -cE '^[0-9]{10}$' "$ROOT/tmp/trafficctl_history.stamp" 2>/dev/null)"
assert_eq "and prunes past keep, oldest first" "0 1" \
    "$(test -f "$STORE/2025-05.tsv" && echo 1 || echo 0) $(test -f "$STORE/2025-06.tsv" && echo 1 || echo 0)"
uciset trafficctl.history.keep 3

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
