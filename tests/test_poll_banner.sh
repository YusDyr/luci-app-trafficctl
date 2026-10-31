#!/bin/bash
# The status line, and which code paths are allowed to write to it (#106).
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
# The same mistake had a second, worse consequence that is NOT visible in the
# issue: every action handler calls setStatus(result) and then runQuery(), so
# the refresh overwrote the result one round-trip later. The qualifiers that
# exist precisely to stop a half-applied rule reading as success — "NOT
# PERSISTENT" (#105), the NSS note (#81), "IPv4 only" (#67), "WiFi block NOT in
# effect" — were all replaced by a green ✓ Done before they could be read.
#
# So the rule pinned here is: a timer-driven refresh may report its own FAILURE
# and nothing else, and it may only clear a message it put there itself.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEWS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl"
JS="$VIEWS/status.js"
CSS="$VIEWS/status.css"

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

# The helpers above have been silently absent before now, and a suite whose
# assertions are "command not found" still reports every test as passed. So
# prove they exist AND that a failing one actually registers.
_p=$PASS; _f=$FAIL
assert_eq "self-check: assert_eq can pass" "x" "x"
assert_has "self-check: assert_has can pass" "needle" "a needle here"
assert_lacks "self-check: assert_lacks can pass" "needle" "nothing here"
if [ "$PASS" -ne $((_p + 3)) ] || [ "$FAIL" -ne "$_f" ]; then
    echo "BROKEN SUITE: the assert helpers do not count correctly"
    exit 1
fi
PASS=$_p; FAIL=$_f

# ── extract the two refresh functions, comments stripped ──────────────────
# Stripped because this file's own prose quotes the very calls being forbidden
# below — an earlier test in this repo passed by matching a comment instead of
# the code it described.
extract() {
    python3 - "$JS" "$1" <<'PY'
import io, re, sys
src = io.open(sys.argv[1], encoding='utf-8').read()
start = src.index('function %s(' % sys.argv[2])
i = src.index('{', start)
depth = 0
for j in range(i, len(src)):
    if src[j] == '{': depth += 1
    elif src[j] == '}':
        depth -= 1
        if depth == 0:
            body = src[i:j+1]
            break
body = re.sub(r'//[^\n]*', '', body)
body = re.sub(r'/\*.*?\*/', '', body, flags=re.S)
sys.stdout.write(body)
PY
}

single=$(extract runSingle)
all=$(extract runAll)
query=$(extract runQuery)

# Guard the extraction itself: an empty body would satisfy every "must not
# contain" assertion below and the suite would go green having read nothing.
for pair in "runSingle:$single" "runAll:$all" "runQuery:$query"; do
    name=${pair%%:*}
    body=${pair#*:}
    if [ "${#body}" -gt 200 ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: extraction of %s produced %s chars — the assertions below would be vacuous\n" \
            "$name" "${#body}"
    fi
done

# ── 1. no banner on a timer-driven refresh ────────────────────────────────
for pair in "runSingle:$single" "runAll:$all"; do
    name=${pair%%:*}
    body=${pair#*:}
    assert_lacks "$name does not announce itself with a loading banner" \
        "'loading'" "$body"
    assert_lacks "$name does not paint a success banner on every tick" \
        "'ok'" "$body"
    # The spinner replaces it, and must be driven from the request itself so
    # it reflects a real in-flight call rather than a guessed duration.
    assert_has "$name drives the poll spinner instead" "pollStart()" "$body"
    assert_has "$name stops the spinner when the request settles" "pollEnd" "$body"
done

# ── 2. a refresh must still report its OWN failure ────────────────────────
# Otherwise this is "fixed" by making errors invisible, which is worse than
# the flashing.
# There are two ways a refresh fails and they are not interchangeable: the
# backend answered with an error field, or the call never completed. A bare
# "does it mention setStatus error anywhere" check is satisfied by the second
# while the first has been deleted — which is how the first version of this
# test let exactly that mutation through.
assert_has "runSingle reports an error the backend returned" \
    "setStatus(statusDiv, 'error', (data && data.error)" "$single"
for pair in "runSingle:$single" "runAll:$all"; do
    name=${pair%%:*}
    body=${pair#*:}
    assert_has "$name reports a refresh that never completed" \
        "setStatus(statusDiv, 'error', '✗ '+e.message)" "$body"
    # Every failure it reports must be claimed, or the next successful refresh
    # leaves a stale error on screen forever.
    errs=$(printf '%s' "$body" | grep -c "setStatus(statusDiv, 'error'")
    flags=$(printf '%s' "$body" | grep -c 'statusDiv._fromRefresh = true')
    assert_eq "$name claims every error it reports" "$errs" "$flags"
done

# ── 3. a refresh may only clear a message it put there itself ─────────────
# This is the assertion that protects the backend's qualifiers. An
# unconditional clear here reinstates the original bug in a quieter form: the
# not-persistent / NSS / IPv4-only notes would vanish instead of being
# overwritten, which looks like nothing happened at all.
for pair in "runSingle:$single" "runAll:$all"; do
    name=${pair%%:*}
    body=${pair#*:}
    assert_has "$name clears the status line only when the message is its own" \
        "if (statusDiv._fromRefresh) clearStatus(statusDiv);" "$body"
    got=$(printf '%s' "$body" | grep -c 'clearStatus(statusDiv)')
    assert_eq "$name has no unguarded clearStatus call" "1" "$got"
done

# Only the two refresh functions may ever set that flag. An action handler
# setting it would hand its own result to the next tick to delete. Counted as
# "every occurrence in the file is inside one of the two bodies" rather than
# against a fixed number, so adding a second failure branch to a refresh stays
# legal while an action handler claiming ownership does not.
in_file=$(grep -c '_fromRefresh = true' "$JS")
in_refresh=$(( $(printf '%s' "$single" | grep -c '_fromRefresh = true') \
             + $(printf '%s' "$all"    | grep -c '_fromRefresh = true') ))
assert_eq "only the refresh paths claim ownership of a message" "$in_file" "$in_refresh"

# ── 4. switching devices clears a stale result ────────────────────────────
# The poll used to do this by accident. Now that it does not, a result like
# "Limiting 192.168.0.50…" would otherwise sit over another device's page.
assert_has "runQuery clears the status line when the selected device changes" \
    "clearStatus(statusDiv)" "$query"
assert_has "and remembers which device the message belongs to" \
    "self._statusIp" "$query"

# ── 5. clearStatus must undo what setStatus did ───────────────────────────
# setStatus assigns className, dropping tc-hidden; putting the element back
# out of the layout therefore has to be explicit. Setting innerHTML alone
# would leave an empty alert box occupying space — the reflow, preserved.
clearfn=$(python3 - "$JS" <<'PY'
import io, sys, re
src = io.open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'function clearStatus\(el\) \{.*?\n\}', src, re.S)
sys.stdout.write(m.group(0) if m else '')
PY
)
assert_has "clearStatus puts the element back out of the layout" \
    "el.className = 'tc-hidden'" "$clearfn"
assert_has "clearStatus empties the message" "el.innerHTML = ''" "$clearfn"
assert_has "clearStatus releases ownership of the cleared message" \
    "el._fromRefresh = false" "$clearfn"

# ── 6. the spinner must not be able to shift the layout ───────────────────
# tc-hidden is display:none !important. Toggling the spinner with it would
# reproduce the exact defect being fixed, one element to the left.
spin=$(grep -n 'pollSpinner' "$JS")
assert_lacks "the spinner is never toggled with display:none" "tc-hidden" "$spin"
assert_has "the spinner is faded in instead" "classList.add('is-busy')" "$spin"
# Built and never appended renders nowhere, with no error and no blank space.
assert_has "the spinner is mounted into the page" ", pollSpinner]" "$spin"

css=$(python3 - "$CSS" <<'PY'
import io, sys, re
src = io.open(sys.argv[1], encoding='utf-8').read()
out = re.findall(r'\.tc-poll-spinner[^{]*\{[^}]*\}', src)
sys.stdout.write('\n'.join(out))
PY
)
assert_has "the spinner reserves a fixed-width slot" "flex: 0 0" "$css"
assert_has "with a fixed height too" "height: 12px" "$css"
assert_has "and is shown by opacity, which does not reflow" "opacity: 1" "$css"
assert_lacks "the spinner rule never touches display:none" "display: none" "$css"

# ── 7. the delay before showing it ────────────────────────────────────────
# A spinner that appears for 80ms on every tick is still a flash. On a router
# that answers quickly it must never appear at all.
delay=$(python3 - "$JS" <<'PY'
import io, sys, re
src = io.open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'function pollStart\(\) \{.*?\n\t\t\}', src, re.S)
body = m.group(0) if m else ''
n = re.search(r'\}, (\d+)\);', body)
print(n.group(1) if n else 'none')
PY
)
if [ "$delay" -ge 150 ] 2>/dev/null; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    printf "FAIL: the spinner has no meaningful delay before it appears (got %s)\n" "$delay"
fi

# ── 8. the msgids that lost their only caller ─────────────────────────────
# Left in the template they would be shipped to translators as work that can
# never be seen. tests/test_i18n_msgids.sh enforces template == generator
# output; this states WHY these three are expected to go.
POT="$REPO_ROOT/luci-app-trafficctl/po/templates/luci-app-trafficctl.pot"
for id in 'Running…' 'Scanning all devices…'; do
    n=$(grep -cF "msgid \"$id\"" "$POT")
    assert_eq "the template no longer offers '$id' for translation" "0" "$n"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
