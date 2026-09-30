#!/bin/bash
# The dashboard's rendering of things the backend hands it verbatim.
#
# Two defects of the same shape live here. Both are cases where the UI was
# written against a snapshot of what the backend emits and then drifted:
#
#   1. tctl_get_offload_mode learned to report "software-counter", and the
#      offload badge — which looks the mode up in a literal table — fell
#      through to its '?' fallback and printed the raw string at the user.
#   2. A stray unary + in front of an E() child turned the Telegram keyboard
#      preset buttons into NaN. ESLint now bans unary + outright; this pins
#      the rendering itself, so the guard survives a lint config rewrite.
#
# Nothing here needs a DOM or the LuCI runtime: the slices are plain ES5.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"
FW="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin/trafficctl-fw.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

# --- every mode the backend can emit must have a badge label ---------------
#
# Read both sides out of the real files rather than restating them here, so
# that adding a mode to the shell and forgetting the UI fails this test.

awk '/^tctl_get_offload_mode\(\)/ { inf = 1 }
     inf && /^}/ { exit }
     inf { print }' "$FW" \
    | grep -oE 'echo "[a-z-]+"' | sed 's/echo "//; s/"//' | sort -u > "$TMP/modes"

awk '/var modeLabels = \{/ { inl = 1; next }
     inl && /^[[:space:]]*\};/ { exit }
     inl' "$JS" \
    | grep -oE "^[[:space:]]*'[a-z-]+'" | sed "s/^[[:space:]]*'//; s/'\$//" | sort -u > "$TMP/labels"

assert_eq "backend emits at least the five known offload modes" \
    "hardware hardware-counter none software software-counter" \
    "$(tr '\n' ' ' < "$TMP/modes" | sed 's/ $//')"

missing=$(awk 'NR == FNR { have[$0] = 1; next } !($0 in have)' "$TMP/labels" "$TMP/modes" | tr '\n' ' ' | sed 's/ $//')
assert_eq "every offload mode has a badge label in status.js" "" "$missing"

# --- the Telegram keyboard preset buttons must not render NaN -------------
#
# RATE_PRESETS is sliced out whole; the expression under test is the one the
# preview builds its limit buttons from.

sed -n '/^var RATE_PRESETS = \[/,/^\];/p' "$JS" > "$TMP/presets.js"
[ -s "$TMP/presets.js" ] || { echo "FAIL: could not slice RATE_PRESETS out of status.js"; exit 1; }

cat > "$TMP/run.js" <<'NODE'
function _(s) { return s; }
NODE
cat "$TMP/presets.js" >> "$TMP/run.js"
grep -n "limitBtns.push" "$JS" | head -1 | sed 's/^[0-9]*://' \
    | sed "s/.*E('span', {'class':'tg-kbd-btn'},//; s/));[[:space:]]*$//" > "$TMP/expr.txt"
{
    printf 'var out = RATE_PRESETS.filter(function (p) {\n'
    printf '    return p.v !== "0" && p.v !== "custom";\n'
    printf '}).map(function (p) {\n'
    printf '    return String(%s);\n' "$(cat "$TMP/expr.txt")"
    printf '});\n'
    printf 'console.log(out.join(","));\n'
} >> "$TMP/run.js"

labels=$(node "$TMP/run.js" 2>&1)
assert_eq "limit preset buttons render their rate, not NaN" \
    "1M,2M,5M,10M,25M,50M,100M" "$labels"

# The shaper row builds its labels the same way, from the same presets.
shape=$(grep -c "shapeBtns.push(E('span', {'class':'tg-kbd-btn'}, '🔧 ' + p.l" "$JS")
assert_eq "shaper preset buttons concatenate rather than coerce" "1" "$shape"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
