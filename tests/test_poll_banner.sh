#!/bin/bash
# Who is allowed to write to the status line (#106).
#
# sjurgis: "Flashing banner every few seconds is very annoying. I'd suggest
# adding a subtle spinner instead. Also the layout is constantly shifting -
# sometimes it's pretty hard to click on element you are after."
#
# Both halves came from one mistake. runSingle() and runAll() are READS that
# run on a timer (every poll tick, default 2s), and each announced itself with
# setStatus(statusDiv, 'loading', …) and then setStatus(…, 'ok', '✓ Done').
# Because setStatus rewrites className wholesale it also dropped the tc-hidden
# that statusDiv starts with, so a block-level alert box joined the layout and
# then changed colour and text forever after — directly above the rate chips,
# which is why the elements below it were hard to hit.
#
# The same mistake had a second, worse consequence that is NOT in the issue:
# every action handler calls setStatus(result) and then runQuery(), so the
# refresh overwrote the result one round-trip later. The qualifiers that exist
# precisely to stop a half-applied rule reading as success — "NOT PERSISTENT"
# (#105), the NSS note (#81), "IPv4 only" (#67) — were replaced by a green
# ✓ Done before they could be read.
#
# The rule pinned here is one sentence: a timer-driven refresh never touches
# the status line. It reports its own health in its own indicator instead. The
# other five pollers in this view (bytes, drops, shape stats, ifaces, cut)
# discard their errors outright, so these two were the only writers sharing an
# element with the action handlers — and that sharing was the whole bug.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEWS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl"
JS="$VIEWS/status.js"
CSS="$VIEWS/status.css"

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}
assert_has() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n" "$1" "$2"
    fi
}
assert_lacks() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  must NOT contain: '%s'\n" "$1" "$2"
    else
        PASS=$((PASS + 1))
    fi
}

# Assert helpers have been silently absent in this repo before, and a suite
# whose assertions are "command not found" still reports everything as passed.
_p=$PASS; _f=$FAIL
assert_eq "self-check" "x" "x"
assert_has "self-check" "needle" "a needle here"
assert_lacks "self-check" "needle" "nothing here"
if [ "$PASS" -ne $((_p + 3)) ] || [ "$FAIL" -ne "$_f" ]; then
    echo "BROKEN SUITE: the assert helpers do not count correctly"
    exit 1
fi
PASS=$_p; FAIL=$_f

# One extractor for every block below. Comments are stripped because this
# file's own prose quotes the calls being forbidden, and an earlier test here
# passed by matching a comment instead of the code it described.
jsblock() {
    python3 - "$JS" "$1" <<'PY'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
i = src.index(sys.argv[2])
j = src.index('{', i)
depth = 0
body = ''
for k in range(j, len(src)):
    if src[k] == '{': depth += 1
    elif src[k] == '}':
        depth -= 1
        if depth == 0:
            body = src[j:k+1]
            break
body = re.sub(r'//[^\n]*', '', body)
sys.stdout.write(re.sub(r'/\*.*?\*/', '', body, flags=re.S))
PY
}

single=$(jsblock 'function runSingle(')
all=$(jsblock 'function runAll(')
query=$(jsblock 'function runQuery(')
pollend=$(jsblock 'function pollEnd(')
clearfn=$(jsblock 'function clearStatus(')
inet=$(jsblock "inetBtn.addEventListener('click'")

# An incomplete extraction satisfies every "must not contain" assertion below,
# so the suite would go green having read nothing.
for pair in "runSingle:$single" "runAll:$all" "runQuery:$query" \
            "pollEnd:$pollend" "clearStatus:$clearfn" "inetBtn:$inet"; do
    name=${pair%%:*}; body=${pair#*:}
    case "$body" in
        "{"*"}") PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: extraction of %s is not a complete block (%s chars) — the assertions below would be vacuous\n" \
                "$name" "${#body}"
            ;;
    esac
done

# ── the rule ──────────────────────────────────────────────────────────────
# Not "no loading banner" and "no done banner" separately: a timer-driven
# refresh writes to the status line at all, or it does not.
for pair in "runSingle:$single" "runAll:$all"; do
    name=${pair%%:*}; body=${pair#*:}
    assert_lacks "$name never writes to the status line" "setStatus(" "$body"
    assert_has "$name raises its own indicator instead" "pollStart()" "$body"
    # Exactly one settle per outcome — a missed one leaves the spinner up for
    # good, and a doubled one clears an error that is still true.
    assert_eq "$name settles the indicator on success, once" "1" \
        "$(printf '%s' "$body" | grep -c 'pollEnd();')"
done

# ── a failed refresh must still say so ────────────────────────────────────
# Otherwise this is "fixed" by making errors invisible. The two failure modes
# are not interchangeable — the backend answered with an error field, or the
# call never completed — and a check that accepts either is satisfied by the
# second while the first has been deleted.
assert_has "runSingle passes on an error the backend returned" \
    "pollEnd((data && data.error)" "$single"
for pair in "runSingle:$single" "runAll:$all"; do
    name=${pair%%:*}; body=${pair#*:}
    assert_has "$name passes on a refresh that never completed" \
        "pollEnd(e.message)" "$body"
done
assert_has "the indicator marks a failed refresh" "'is-error', !!err" "$pollend"
assert_has "and carries the message, which is the only place it survives" \
    "pollSpinner.title = err" "$pollend"

# ── the indicator must not be able to shift the layout ────────────────────
# tc-hidden is display:none !important. Toggling the indicator with it would
# reproduce the exact defect being fixed, one element to the left.
spin=$(grep -n 'pollSpinner' "$JS")
assert_lacks "the indicator is never toggled with display:none" "tc-hidden" "$spin"
assert_has "it is faded in instead" "classList.add('is-busy')" "$spin"
assert_has "and it is mounted into the page" ", pollSpinner]" "$spin"

css=$(python3 - "$CSS" <<'PY'
import io, sys, re
src = io.open(sys.argv[1], encoding='utf-8').read()
sys.stdout.write('\n'.join(re.findall(r'\.tc-poll-spinner[^{]*\{[^}]*\}', src)))
PY
)
assert_has "the indicator reserves a fixed-width slot" "flex: 0 0" "$css"
assert_has "with a fixed height too" "height: 12px" "$css"
assert_has "and is shown by opacity, which does not reflow" "opacity: 1" "$css"
assert_lacks "no rule for it touches display" "display: none" "$css"

# A spinner that appears for 80ms on every tick is still a flash: on a router
# that answers quickly it must never appear at all.
delay=$(printf '%s' "$(jsblock 'function pollStart(')" | sed -n 's/.*}, \([0-9]*\));.*/\1/p')
if [ "${delay:-0}" -ge 150 ] 2>/dev/null; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    printf "FAIL: the indicator has no meaningful delay before it appears (got '%s')\n" "$delay"
fi

# ── the status line, which now has one kind of writer ─────────────────────
# setStatus assigns className, dropping tc-hidden; putting the element back
# out of the layout therefore has to be explicit. Setting innerHTML alone
# would leave an empty alert box occupying space — the reflow, preserved.
assert_has "clearStatus puts the element back out of the layout" \
    "el.className = 'tc-hidden'" "$clearfn"
assert_has "clearStatus empties the message" "el.innerHTML = ''" "$clearfn"

# The poll used to clear a stale action result by accident. Now that it does
# not, switching devices has to: otherwise "Limiting 192.168.0.50…" sits over
# the page of a device it was not about.
assert_has "runQuery clears the status line when the selected device changes" \
    "clearStatus(statusDiv)" "$query"
assert_has "and remembers which device the message belongs to" \
    "self._statusIp" "$query"

# ── a block must show what the backend qualified ─────────────────────────
# This is the path the reporter of #105 actually uses. trafficctl-block.sh
# appends the not-persistent note and the NSS note to msg on a SUCCESSFUL
# block, and the handler reported msg only when res.ipv6 === false — so a
# working block said nothing, qualifiers included.
assert_has "a block reports its result unconditionally, qualifiers included" \
    "setStatus(statusDiv, state, (res && res.msg)" "$inet"
assert_lacks "the result is not reported only when IPv6 is uncovered" \
    "if (res && res.ipv6 === false) {" "$inet"
assert_has "an IPv4-only block still reads as an error" \
    "res.ipv6 === false) {" "$inet"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
