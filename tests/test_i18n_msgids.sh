#!/bin/bash
# The msgids themselves, as opposed to the packaging of them
# (tests/test_i18n_packaging.sh covers that).
#
# Two defect classes live here, and both shipped this month:
#
#   1. EDGE WHITESPACE. po2lmo hashes the raw msgid with sfh_hash() while the
#      runtime lmo loader canonicalises the lookup key with lmo_canon_hash(),
#      trimming trailing whitespace and collapsing runs. A msgid with leading
#      or trailing whitespace therefore can NEVER match its own entry, and the
#      string stays English however complete the translation is. @ntbowen
#      documented the rule in #73/#99; an audit then found four offenders, two
#      of them added days earlier in #96.
#
#   2. ESCAPING THAT CANNOT MATCH. `_('style=\"x\"')` in a single-quoted JS
#      literal calls _() with a PLAIN quote — \" and " are the same character
#      there — so the lookup key holds a plain quote. A .po msgid written as
#      \\\" parses to backslash-quote and never matches it. Six translations in
#      the Chinese .po were dead for exactly this reason.
#
# Neither is visible by reading a diff, neither breaks a build, and both fail
# by silently showing English. Hence a test rather than a documented rule.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEWS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl"
POT="$REPO_ROOT/luci-app-trafficctl/po/templates/luci-app-trafficctl.pot"
GEN="$REPO_ROOT/tools/genpot.py"

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

for f in "$POT" "$GEN"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: missing $f"
        exit 1
    fi
done

# ── 1. no msgid may carry leading or trailing whitespace ───────────────────
# The real msgid is the CONCATENATION of the literals in the _() call, so the
# first literal's edges are not the msgid's edges. Checking the literals
# individually over-reports by an order of magnitude — the first version of
# this audit claimed 15 offenders where there were 4.
offenders=$(python3 - "$VIEWS" <<'PY'
import re, sys, glob, os
LIT = r"'(?:[^'\\]|\\.)*'|\"(?:[^\"\\]|\\.)*\""
CALL = re.compile(r"_\(\s*((?:%s)(?:\s*\+\s*(?:%s))*)\s*[,)]" % (LIT, LIT))
bad=[]
for path in sorted(glob.glob(os.path.join(sys.argv[1], '*.js'))):
    src=open(path).read()
    for m in CALL.finditer(src):
        joined=''.join(p[1:-1] for p in re.findall(LIT, m.group(1)))
        if joined and joined != joined.strip():
            bad.append("%s:%d %r" % (os.path.basename(path), src[:m.start()].count('\n')+1, joined[:60]))
print('\n'.join(bad))
PY
)
assert_eq "no msgid in any view carries edge whitespace" "" "$offenders"

# ── 2. no .po msgid may hold an escape the runtime never produces ──────────
# A lookup key coming from `_('x=\"y\"')` contains a plain quote. A .po msgid
# containing backslash-quote is a key nothing will ever ask for.
for po in "$REPO_ROOT"/luci-app-trafficctl/po/*/*.po; do
    [ -f "$po" ] || continue
    name=$(basename "$(dirname "$po")")
    # grep -c prints 0 AND exits 1 when there is no match, so a `|| echo 0`
    # fallback appends a second zero and the comparison sees "0\n0".
    dead=$(grep -c '\\\\\\"' "$po" 2>/dev/null)
    dead=${dead:-0}
    assert_eq "$name: no msgid holds a backslash-quote the runtime never asks for" "0" "$dead"
done

# ── 3. the template must cover every string the views expose ───────────────
# A stale template is invisible: the app works, translators simply never see
# the new strings. That is how the template drifted to 118 entries against 434
# calls before #99.
python3 "$GEN" "$TMP/fresh.pot" >/dev/null 2>&1
missing=$(python3 - "$TMP/fresh.pot" "$POT" <<'PY'
import re, sys
def ids(p):
    return set(re.findall(r'^msgid "((?:[^"\\]|\\.)*)"', open(p).read(), re.M)) - {''}
fresh, have = ids(sys.argv[1]), ids(sys.argv[2])
gap = sorted(fresh - have)
print("%d missing" % len(gap) if gap else "")
for g in gap[:5]: print("   ", g[:70])
PY
)
assert_eq "the template covers every msgid the views expose" "" "$missing"

# And nothing the views no longer expose should linger in the template.
stale=$(python3 - "$TMP/fresh.pot" "$POT" <<'PY'
import re, sys
def ids(p):
    return set(re.findall(r'^msgid "((?:[^"\\]|\\.)*)"', open(p).read(), re.M)) - {''}
fresh, have = ids(sys.argv[1]), ids(sys.argv[2])
gap = sorted(have - fresh)
print("%d stale" % len(gap) if gap else "")
PY
)
assert_eq "the template holds no msgid the views have dropped" "" "$stale"

# ── 4. the template must be exactly what the generator produces ────────────
# Regenerating is the documented way to refresh it, so a hand-edit that the
# generator would undo is a trap for whoever refreshes it next.
if diff -q "$TMP/fresh.pot" "$POT" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    printf "FAIL: the committed template differs from tools/genpot.py output — run it and commit the result\n"
    diff "$TMP/fresh.pot" "$POT" | head -10
fi

# ── 5. every .po must survive the tool that actually ships it ─────────────
for po in "$REPO_ROOT"/luci-app-trafficctl/po/*/*.po; do
    [ -f "$po" ] || continue
    name=$(basename "$(dirname "$po")")
    if python3 "$REPO_ROOT/tools/po2lmo.py" "$po" "$TMP/$name.lmo" >/dev/null 2>&1 \
       && [ -s "$TMP/$name.lmo" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s does not compile with tools/po2lmo.py\n" "$name"
    fi
    # An EMPTY msgstr is worse than a missing entry: po2lmo keeps it, and the
    # runtime then renders an empty string where the source text should be.
    empty=$(python3 - "$po" <<'PY'
import re, sys
s=open(sys.argv[1]).read()
pairs=re.findall(r'^msgid "((?:[^"\\]|\\.)*)"\nmsgstr "((?:[^"\\]|\\.)*)"', s, re.M)
print(sum(1 for i,m in pairs if i and not m))
PY
)
    assert_eq "$name: no entry has an empty msgstr" "0" "$empty"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
