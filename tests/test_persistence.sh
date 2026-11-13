#!/bin/bash
# Whether a per-device restriction survives a reboot, and whether the app says
# so when it will not (#105).
#
# The reported defect was an inconsistency, not a missing feature. A traffic
# SHAPE persists unconditionally — the shaper has to record which HTB class
# belongs to which device, so shapes.json is always written and the ifup hook
# always restores it. A block or a rate limit only persisted when
# persist_rules was on, and that shipped OFF. Since the default mode is the
# limiter, the out-of-the-box path was the one that forgot.
#
# So the same intention behaved two ways depending on which control the
# operator reached for, and the only visible "keep after reboot" toggle
# belonged to a different feature (the global cut, whose opt-in is separate on
# purpose: it can lock out whoever administers the router through a LAN host).
#
# Two things are pinned here: the default, and the honesty of the result when
# the default has been turned off.

#
# Also pinned here: rules.json itself. The ucode block and the shell limiter
# write the same file, so their bytes and their lock must agree.

PASS=0
FAIL=0

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/fw4_env.sh
. "$UC_TESTLIB/fw4_env.sh"
REPO_ROOT="$UC_REPO"
BIN="$REPO_ROOT/trafficctl/files/usr/libexec/trafficctl"
CONF="$REPO_ROOT/trafficctl/files/etc/config/trafficctl"
HOOK="$REPO_ROOT/trafficctl/files/etc/hotplug.d/iface/99-trafficctl-shapes"
TMPDIR="$FW_T/q"
QBIN="$TMPDIR/bin"
mkdir -p "$QBIN"

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}
assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: %s\n" "$1" "$2" "$3"
    fi
}
assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$1" "$2"
    else
        PASS=$((PASS + 1))
    fi
}

# ── the shipped default ────────────────────────────────────────────────────
# A new install must behave the way the reporter expected. Asserted on the
# shipped file because that is what a new install gets; an existing install
# keeps its own copy (conffile), which is correct — a deliberate 0 is
# indistinguishable from an untouched one, so upgrades must not overwrite it.
shipped=$(awk '/^[[:space:]]*option persist_rules/ { gsub(/[^0-9]/, "", $3); print $3; exit }' "$CONF")
assert_eq "blocks and limits persist by default in the shipped config" "1" "$shipped"

# The global cut keeps its OWN opt-in, and it must stay off: it is the one
# control that can lock out its own operator, so a reboot has to undo it.
cutpersist=$(awk '/^config cut/ { inc = 1 } inc && /^[[:space:]]*option persist/ { gsub(/[^0-9]/, "", $3); print $3; exit }' "$CONF")
assert_eq "the global cut does NOT persist by default" "0" "$cutpersist"

# ── the qualifier ─────────────────────────────────────────────────────────
cat > "$QBIN/uci" <<MOCK
#!/bin/sh
while [ "\$1" = "-q" ]; do shift; done
[ "\$1" = "get" ] || exit 1
[ "\$2" = "trafficctl.main.persist_rules" ] && { cat "$TMPDIR/persist"; exit 0; }
exit 1
MOCK
cat > "$QBIN/nft" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$QBIN"/*

note() { PATH="$QBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_persist_note" 2>/dev/null; }

printf '1\n' > "$TMPDIR/persist"
assert_eq "nothing is appended when persistence is on" "" "$(note)"

printf '0\n' > "$TMPDIR/persist"
out=$(note)
assert_contains "the message says the rule is not persistent" "NOT PERSISTENT" "$out"
assert_contains "and that it will be lost on reboot" "lost on reboot" "$out"
# A complaint with no remedy is just a complaint; the exact command is what
# makes it actionable over SSH, where the reporter was.
assert_contains "and names the uci command that fixes it" \
    "uci set trafficctl.main.persist_rules=1" "$out"

# ── every losable apply path must carry it ────────────────────────────────
# Counted rather than grepped for prose: adding a success message without the
# qualifier should fail here too. The limiter emits 3 apply results.
# shellcheck disable=SC2043  # one script left; the loop takes the next
for pair in "trafficctl-ratelimit.sh:3"; do
    f=${pair%%:*}; want=${pair##*:}
    got=$(grep -c '\\"persist\\":\$PERSIST' "$BIN/$f")
    assert_eq "$f reports persist on each of its apply results" "$want" "$got"
    if grep -q 'tctl_persist_note' "$BIN/$f"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s does not append the persistence qualifier\n" "$f"
    fi
done

# The block (`trafficctl block` since the ucode port), by running it.
fw_cfg 0
OUT=$(fw_run block 192.168.1.50)
assert_contains "block, persistence off: says persist:false" '"persist":false' "$OUT"
assert_contains "block, persistence off: the message says NOT PERSISTENT" "NOT PERSISTENT" "$OUT"
assert_contains "block, persistence off: and names the uci command" \
    "uci set trafficctl.main.persist_rules=1" "$OUT"
assert_eq "block, persistence off: nothing saved" "no" "$([ -e "$RULES" ] && echo yes || echo no)"
fw_run unblock 192.168.1.50 >/dev/null
fw_cfg 1
OUT=$(fw_run block 192.168.1.50)
assert_contains "block, persistence on: says persist:true" '"persist":true' "$OUT"
assert_not_contains "block, persistence on: no qualifier" "NOT PERSISTENT" "$OUT"

# ── rules.json: the bytes v1.30 wrote ─────────────────────────────────────
# The shell writers (limits, port forwards) still edit the same file as text,
# and a v1.30 package reads it back after a downgrade: compact, the legacy
# key order, param a string, mode and param_up only when set.
assert_eq "block record: the v1.30 bytes" \
    '[{"type":"block","ip":"192.168.1.50","param":"block_192.168.1.50"}]' "$(cat "$RULES")"

FW="$FW_T/fw.sh"
sed -e "s|TCTL_RULES_FILE=\"/etc/trafficctl/rules.json\"|TCTL_RULES_FILE=\"$RULES\"|" \
    -e "s|TCTL_RULES_LOCK=\"/tmp/trafficctl_rules.lock.d\"|TCTL_RULES_LOCK=\"$ROOT/tmp/trafficctl_rules.lock.d\"|" \
    "$BIN/trafficctl-fw.sh" > "$FW"
assert_eq "harness: the shell writer's paths were redirected" "2" \
    "$(grep -c "$ROOT" "$FW")"
shw() { PATH="$MOCKBIN:$PATH" sh -c ". '$FW' >/dev/null 2>&1; $1" 2>/dev/null; }
ucw() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.lib "$@" >/dev/null 2>&1; }

# The same edits through each writer give the same file, byte for byte.
seq_shell() {
    rm -f "$RULES"
    shw 'tctl_persist_save block 192.168.1.5 lab'
    shw 'tctl_persist_save ratelimit 192.168.20.0/24 20000 each'
    shw 'tctl_persist_save ratelimit 192.168.1.50 5000 "" 1000'
    shw 'tctl_persist_save block 192.168.1.50 ""'
    shw 'tctl_persist_save block 192.168.1.5 relabel'
    shw 'tctl_persist_remove block 192.168.1.50'
    cat "$RULES"
}
seq_ucode() {
    rm -f "$RULES"
    ucw persist_save '"block"' '"192.168.1.5"' '"lab"'
    ucw persist_save '"ratelimit"' '"192.168.20.0/24"' '"20000"' '"each"'
    ucw persist_save '"ratelimit"' '"192.168.1.50"' '"5000"' '""' '"1000"'
    ucw persist_save '"block"' '"192.168.1.50"' '""'
    ucw persist_save '"block"' '"192.168.1.5"' '"relabel"'
    ucw persist_remove '"block"' '"192.168.1.50"'
    cat "$RULES"
}
SH_BYTES=$(seq_shell)
UC_BYTES=$(seq_ucode)
assert_eq "writers: the ucode writer's file equals the shell writer's" "$SH_BYTES" "$UC_BYTES"
assert_eq "writers: and is what v1.30 wrote" \
    '[{"type":"ratelimit","ip":"192.168.20.0/24","param":"20000","mode":"each"},{"type":"ratelimit","ip":"192.168.1.50","param":"5000","param_up":"1000"},{"type":"block","ip":"192.168.1.5","param":"relabel"}]' \
    "$UC_BYTES"
# Removing a record by type and address: the same address under another type
# stays, and so does an address the target is a prefix of.
rm -f "$RULES"
ucw persist_save '"block"' '"192.168.1.5"' '""'
ucw persist_save '"ratelimit"' '"192.168.1.5"' '"100"'
ucw persist_save '"block"' '"192.168.1.50"' '""'
ucw persist_remove '"block"' '"192.168.1.5"'
assert_eq "remove: by type and the whole address" \
    '[{"type":"ratelimit","ip":"192.168.1.5","param":"100"},{"type":"block","ip":"192.168.1.50","param":""}]' "$(cat "$RULES")"
# A zero-length file is what an old failed save left behind.
: > "$RULES"
ucw persist_save '"block"' '"192.168.1.7"' '""'
assert_eq "save: a zero-length file starts over" '[{"type":"block","ip":"192.168.1.7","param":""}]' "$(cat "$RULES")"
: > "$RULES"
ucw persist_remove '"block"' '"192.168.1.7"'
assert_eq "remove: a zero-length file is left alone" "" "$(cat "$RULES")"
# The shell interpolated the label as it came; one with a quote made the file
# unparseable for every reader. Escaped now (a declared difference).
rm -f "$RULES"
ucw persist_save '"block"' '"192.168.1.8"' '"kid\"s tablet"'
assert_eq "save: a quote in the label is escaped, the file stays JSON" "kid\"s tablet" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["param"])' "$RULES" 2>&1)"

# ── one lock for both writers ─────────────────────────────────────────────
# Each writer reads the file, edits the text and renames a new file over it.
# Two at once read the same file and the later rename drops the earlier
# record: a rate limit set from the bot while LuCI blocks a device would not
# come back after a reboot. The shell's mkdir lock is the one both take.
LOCK="$ROOT/tmp/trafficctl_rules.lock.d"
rm -f "$RULES"
mkdir "$LOCK"
( ucw persist_save '"block"' '"192.168.1.9"' '""' ) &
upid=$!
sleep 1
assert_eq "lock: the ucode writer waits while the shell holds the lock" "no" \
    "$([ -e "$RULES" ] && echo yes || echo no)"
rmdir "$LOCK"
wait "$upid"
assert_eq "lock: and writes once it is released" '[{"type":"block","ip":"192.168.1.9","param":""}]' "$(cat "$RULES")"
assert_eq "lock: released after the write" "no" "$([ -d "$LOCK" ] && echo yes || echo no)"

# A lock left by a killed writer is taken over, as the shell does.
mkdir "$LOCK"
touch -d '1 minute ago' "$LOCK" 2>/dev/null || touch -t "$(date -d '1 minute ago' +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$LOCK"
t0=$(date +%s)
ucw persist_save '"block"' '"192.168.1.10"' '""'
t1=$(date +%s)
assert_contains "lock: a stale lock does not stop persistence" '"192.168.1.10"' "$(cat "$RULES")"
assert_eq "lock: nor holds it up for long" "yes" "$([ $((t1 - t0)) -lt 10 ] && echo yes || echo no)"
rmdir "$LOCK" 2>/dev/null

# Writers at once: every record lands. Each kind alone first, so a lost
# record says whose lock let it through.
WLOG="$ROOT/tmp/writers.log"
writers() {   # writers <shell writers> <ucode writers> <name>
    local i pids="" n f
    rm -f "$RULES" "$ROOT"/tmp/sh.*.err "$ROOT"/tmp/uc.*.err
    : > "$WLOG"
    for i in $(seq 1 "$1"); do
        ( PATH="$MOCKBIN:$PATH" sh -c ". '$FW' >/dev/null 2>&1; tctl_persist_save ratelimit 10.1.0.$i 100" \
            >/dev/null 2>"$ROOT/tmp/sh.$i.err"; echo "sh $i rc=$?" >> "$WLOG" ) &
        pids="$pids $!"
    done
    for i in $(seq 1 "$2"); do
        ( PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.lib persist_save '"block"' "\"10.2.0.$i\"" '""' \
            >/dev/null 2>"$ROOT/tmp/uc.$i.err"; echo "uc $i rc=$?" >> "$WLOG" ) &
        pids="$pids $!"
    done
    # shellcheck disable=SC2086
    wait $pids
    n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$RULES" 2>&1)
    assert_eq "lock: $3, every record" "$(($1 + $2))" "$n"
    if [ "$n" != "$(($1 + $2))" ]; then
        # A lost record is a timing fault: say which writer and what it saw.
        cat "$RULES"; echo
        sort "$WLOG"
        for f in "$ROOT"/tmp/sh.*.err "$ROOT"/tmp/uc.*.err; do
            [ -s "$f" ] && { echo "--- $f"; cat "$f"; }
        done
        ls -la "$ROOT/tmp" "$(dirname "$RULES")"
    fi
}
writers 12 0 "twelve shell writers at once"
writers 0 12 "twelve ucode writers at once"
writers 6 6 "six of each at once"

# ── the restore path ──────────────────────────────────────────────────────
# Shapes are restored unconditionally and blocks are restored behind the flag.
# That asymmetry is now harmless because the flag defaults on, but it is still
# the shape of the original bug, so both halves are pinned: if the shape
# restore ever grows a persist guard, shapes stop coming back for anyone who
# turned the flag off, and that is a regression in the other direction.
shapes_block=$(awk '/^# Restore shaping rules/ { f = 1 } f { print } f && /^fi$/ { exit }' "$HOOK")
case "$shapes_block" in
    *tctl_persist_enabled*)
        FAIL=$((FAIL + 1))
        printf "FAIL: shape restore is now gated on persist_rules — shapes used to come back regardless\n"
        ;;
    *) PASS=$((PASS + 1)) ;;
esac

rules_block=$(awk '/^# Restore ratelimits/ { f = 1 } f { print } f && /^fi$/ { exit }' "$HOOK")
case "$rules_block" in
    *tctl_persist_enabled*) PASS=$((PASS + 1)) ;;
    *)
        FAIL=$((FAIL + 1))
        printf "FAIL: the ratelimit restore no longer checks persist_rules\n"
        ;;
esac
case "$rules_block" in
    *"ratelimit)"*) PASS=$((PASS + 1)) ;;
    *)
        FAIL=$((FAIL + 1))
        printf "FAIL: the restore hook does not handle a persisted 'ratelimit' record\n"
        ;;
esac
assert_contains "the hook restores the blocks through the CLI" "/usr/sbin/trafficctl restore" "$(cat "$HOOK")"

# The blocks, from a file the v1.30 shell writer produced.
fw_flush
rm -f "$RULES"
shw 'tctl_persist_save block 192.168.1.60 ""'
shw 'tctl_persist_save ratelimit 192.168.1.61 5000'
shw 'tctl_persist_save block 192.168.1.62 tg'
fw_cfg 0
assert_eq "restore, persistence off: nothing restored" '{"ok":true,"restored":0,"failed":0}' "$(fw_run restore)"
assert_eq "restore, persistence off: the chain is untouched" "" "$(fw_rules)"
fw_cfg 1
assert_eq "restore: both blocks back" '{"ok":true,"restored":2,"failed":0}' "$(fw_run restore)"
assert_eq "restore: with the comment from the address, as the block writes it" \
    'ip saddr 192.168.1.62 counter drop comment "tctl_block_192_168_1_62"
ip saddr 192.168.1.60 counter drop comment "tctl_block_192_168_1_60"' "$(fw_rules)"
# lan going up again without a fw4 reload: the blocks are still there.
fw_run restore >/dev/null
assert_eq "restore twice: no duplicate rules" "2" "$(fw_rules | grep -c .)"
# A record nobody could have written through the CLI is refused, logged, and
# does not stop the rest.
fw_flush
fw_clear
printf '[{"type":"block"},{"type":"block","ip":"1.2.3.4 counter accept; x"},{"type":"block","ip":"192.168.1.77","param":""}]' > "$RULES"
assert_eq "restore: a bad record fails, the next is restored" '{"ok":false,"restored":1,"failed":1}' "$(fw_run restore)"
assert_eq "restore: only the valid address reached nft" \
    'ip saddr 192.168.1.77 counter drop comment "tctl_block_192_168_1_77"' "$(fw_rules)"
assert_contains "restore: the refused one is logged" "Failed to restore block for 1.2.3.4 counter accept; x" "$(cat "$LOGGER_LOG")"
# At boot fw4 can load after ifup lan: the restore waits for its table.
fw_flush
printf '[{"type":"block","ip":"192.168.1.60","param":""}]' > "$RULES"
fw_clear
echo 2 > "$STATE/fw4_late"
NFT_NOFW4="$STATE/fw4_late" fw_run restore >/dev/null
assert_eq "restore: waits for inet fw4 before restoring a block" \
    "list table inet fw4|list table inet fw4|list table inet fw4|insert rule inet fw4 forward" \
    "$(grep -E '^(list table inet fw4|insert rule)' "$NFT_LOG" | sed 's/^\(insert rule inet fw4 forward\).*/\1/' | paste -sd'|' -)"
# With nothing saved there is nothing to wait for.
fw_clear
printf '[{"type":"ratelimit","ip":"192.168.1.61","param":"5000"}]' > "$RULES"
NFT_NOFW4=always fw_run restore >/dev/null
assert_eq "restore: no blocks saved, no wait on fw4" "" "$(cat "$NFT_LOG")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
