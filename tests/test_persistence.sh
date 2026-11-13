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
# Also pinned here: rules.json itself. 1.30.x reads it after a downgrade and
# writes it while an upgrade runs, so its bytes and its lock stay v1.30's.

PASS=0
FAIL=0

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/fw4_env.sh
. "$UC_TESTLIB/fw4_env.sh"
REPO_ROOT="$UC_REPO"
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
note() { fw_cfg "$1"; TCTL_ROOT="$ROOT" tcall trafficctl.lib persist_note 2>/dev/null; }

assert_eq "nothing is appended when persistence is on" "" "$(note 1)"

out=$(note 0)
assert_contains "the message says the rule is not persistent" "NOT PERSISTENT" "$out"
assert_contains "and that it will be lost on reboot" "lost on reboot" "$out"
# A complaint with no remedy is just a complaint; the exact command is what
# makes it actionable over SSH, where the reporter was.
assert_contains "and names the uci command that fixes it" \
    "uci set trafficctl.main.persist_rules=1" "$out"

# ── every losable apply path must carry it ────────────────────────────────
# Run, not grepped: the limiter (`trafficctl ratelimit`) in
# tests/test_direction.sh, the block here.
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
# A v1.30 package reads the file back after a downgrade: compact, the legacy
# key order, param a string, mode and param_up only when set.
assert_eq "block record: the v1.30 bytes" \
    '[{"type":"block","ip":"192.168.1.50","param":"block_192.168.1.50"}]' "$(cat "$RULES")"

ucw() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.lib "$@" >/dev/null 2>&1; }

# The same edits v1.30's tctl_persist_save/_remove made give its bytes.
rm -f "$RULES"
ucw persist_save '"block"' '"192.168.1.5"' '"lab"'
ucw persist_save '"ratelimit"' '"192.168.20.0/24"' '"20000"' '"each"'
ucw persist_save '"ratelimit"' '"192.168.1.50"' '"5000"' '""' '"1000"'
ucw persist_save '"block"' '"192.168.1.50"' '""'
ucw persist_save '"block"' '"192.168.1.5"' '"relabel"'
ucw persist_remove '"block"' '"192.168.1.50"'
assert_eq "writer: the file v1.30 wrote" \
    '[{"type":"ratelimit","ip":"192.168.20.0/24","param":"20000","mode":"each"},{"type":"ratelimit","ip":"192.168.1.50","param":"5000","param_up":"1000"},{"type":"block","ip":"192.168.1.5","param":"relabel"}]' \
    "$(cat "$RULES")"
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
# Removing the last record leaves an empty array, not an empty file: a
# v1.30 reader and the restore path both take [] as "nothing to restore".
rm -f "$RULES"
ucw persist_save '"block"' '"192.168.1.9"' '""'
ucw persist_remove '"block"' '"192.168.1.9"'
assert_eq "remove: the last record leaves []" "[]" "$(cat "$RULES")"
# A failed write keeps the populated file: the new content goes to a
# temporary file renamed over it only when complete. A zero file-size limit
# (SIGXFSZ ignored, so the write just fails) works as root too, where a
# read-only directory would not.
rm -f "$RULES"
ucw persist_save '"block"' '"192.168.1.10"' '""'
BEFORE=$(cat "$RULES")
ucnowrite() { ( trap '' XFSZ; ulimit -f 0; TCTL_ROOT="$ROOT" tcall trafficctl.lib "$@" 2>&1 ); }
assert_eq "save: the write fails" "false" "$(ucnowrite persist_save '"block"' '"192.168.1.11"' '""')"
assert_eq "save: a failed write keeps the populated file" "$BEFORE" "$(cat "$RULES")"
assert_eq "remove: the write fails" "false" "$(ucnowrite persist_remove '"block"' '"192.168.1.10"')"
assert_eq "remove: a failed write keeps the populated file" "$BEFORE" "$(cat "$RULES")"
assert_eq "a failed write leaves no temporary file" "" \
    "$(ls -a "$(dirname "$RULES")" | grep 'rules\.json\.tmp\.')"
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
# come back after a reboot. The writer takes v1.30's mkdir lock, so a
# 1.30.x writer still running during an upgrade waits for it and it for that.
LOCK="$ROOT/tmp/trafficctl_rules.lock.d"
rm -f "$RULES"
mkdir "$LOCK"
( ucw persist_save '"block"' '"192.168.1.9"' '""' ) &
upid=$!
sleep 1
assert_eq "lock: the writer waits while somebody else holds the lock" "no" \
    "$([ -e "$RULES" ] && echo yes || echo no)"
rmdir "$LOCK"
wait "$upid"
assert_eq "lock: and writes once it is released" '[{"type":"block","ip":"192.168.1.9","param":""}]' "$(cat "$RULES")"
assert_eq "lock: released after the write" "no" "$([ -d "$LOCK" ] && echo yes || echo no)"

# A lock left by a killed writer is taken over, as v1.30's shell did.
mkdir "$LOCK"
touch -d '1 minute ago' "$LOCK" 2>/dev/null || touch -t "$(date -d '1 minute ago' +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$LOCK"
t0=$(date +%s)
ucw persist_save '"block"' '"192.168.1.10"' '""'
t1=$(date +%s)
assert_contains "lock: a stale lock does not stop persistence" '"192.168.1.10"' "$(cat "$RULES")"
assert_eq "lock: nor holds it up for long" "yes" "$([ $((t1 - t0)) -lt 10 ] && echo yes || echo no)"
rmdir "$LOCK" 2>/dev/null

# Writers at once: every record lands.
WLOG="$ROOT/tmp/writers.log"
writers() {   # writers <count> <name>
    local i pids="" n f
    rm -f "$RULES" "$ROOT"/tmp/uc.*.err
    : > "$WLOG"
    for i in $(seq 1 "$1"); do
        ( PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.lib persist_save '"block"' "\"10.2.0.$i\"" '""' \
            >/dev/null 2>"$ROOT/tmp/uc.$i.err"; echo "uc $i rc=$?" >> "$WLOG" ) &
        pids="$pids $!"
    done
    # shellcheck disable=SC2086
    wait $pids
    n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$RULES" 2>&1)
    assert_eq "lock: $2, every record" "$1" "$n"
    if [ "$n" != "$1" ]; then
        # A lost record is a timing fault: say which writer and what it saw.
        cat "$RULES"; echo
        sort "$WLOG"
        for f in "$ROOT"/tmp/uc.*.err; do
            [ -s "$f" ] && { echo "--- $f"; cat "$f"; }
        done
        ls -la "$ROOT/tmp" "$(dirname "$RULES")"
    fi
}
writers 12 "twelve writers at once"

# ── the restore path ──────────────────────────────────────────────────────
# Shapes are restored unconditionally and blocks are restored behind the flag.
# That asymmetry is now harmless because the flag defaults on, but it is still
# the shape of the original bug, so both halves are pinned: if the shape
# restore ever grows a persist guard, shapes stop coming back for anyone who
# turned the flag off, and that is a regression in the other direction. The
# shapes half is `trafficctl restore`, run with persist_rules off in
# tests/test_shape.sh; blocks, limits and port controls are behind the flag.
# The hook is the CLI's restore and nothing else: a second copy of any half
# would apply each saved rule twice.
assert_contains "the hook restores through the CLI" "/usr/sbin/trafficctl restore" "$(cat "$HOOK")"
assert_eq "the hook restores nothing of its own" "" "$(grep -E 'nft|tc |rules\.json|persist' "$HOOK" | grep -v '^#')"

# The blocks, from a file the v1.30 shell writer produced.
fw_flush
printf '%s' '[{"type":"block","ip":"192.168.1.60","param":""},{"type":"pfw_pause","ip":"forward/tcp/192.168.1.61/8080","param":""},{"type":"block","ip":"192.168.1.62","param":"tg"}]' > "$RULES"
fw_cfg 0
assert_eq "restore, persistence off: nothing restored" '{"ok":true,"restored":0,"failed":0}' "$(fw_run restore)"
assert_eq "restore, persistence off: the chain is untouched" "" "$(fw_rules)"
fw_cfg 1
assert_eq "restore: both blocks back, and the port pause" '{"ok":true,"restored":3,"failed":0}' "$(fw_run restore)"
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
assert_eq "restore: no blocks saved, no wait on fw4" "" "$(grep "inet fw4" "$NFT_LOG")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
