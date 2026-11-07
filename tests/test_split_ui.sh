#!/bin/bash
# The "Split up/down" control and the split ceiling it sets (#66).
#
# From #83 to this fix the upload row was built and toggled but never put into
# the panel: the chip lit up and nothing appeared, so a split ceiling could not
# be set from the UI at all. Every backend test passed, because the backend
# took rate_kbit_up correctly; nothing ever sent it. The panel also had no way
# to show a split ceiling, since neither the summary nor the device view
# reported the upload figure.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"

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

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n" "$desc" "$needle"
    fi
}

# ── every row built for the Speed Limit panel is in the panel ────────────────

# The panel's children, from "var rateLimitRow = E(" to its closing "]);".
PANEL=$(awk '/var rateLimitRow = E\(/ { inside = 1 } inside { print } inside && /\]\);/ { exit }' "$JS")
assert_contains "harness: the panel definition was found" "Speed Limit" "$PANEL"
assert_contains "the custom row is in the panel" "customRow," "$PANEL"
assert_contains "the upload row is in the panel" "upRow," "$PANEL"

# The general form of the bug: a "tc-custom-row" built and never attached.
for row in $(grep -oE "var [A-Za-z]+Row = E\('div', \{'class':'tc-custom-row" "$JS" | awk '{ print $2 }'); do
    if printf '%s' "$PANEL" | grep -qE "(^|[^A-Za-z])$row,"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s is built but never added to the Speed Limit panel\n" "$row"
    fi
done

# ── the poll shows the installed upload ceiling ──────────────────────────────

SRC=$(cat "$JS")
assert_contains "poll reads the shaper's upload ceiling" "data.shape_kbit_up" "$SRC"
assert_contains "poll reads the limiter's upload ceiling" "data.rate_limit_kbit_up" "$SRC"
assert_contains "the table reads the upload ceiling" "r.rate_limit_kbit_up" "$SRC"
assert_contains "Enter in the upload field applies" "upInput.addEventListener('keydown'" "$SRC"

# ── fmtCeiling ───────────────────────────────────────────────────────────────

if ! command -v node >/dev/null 2>&1; then
    printf "SKIP: node is not installed — fmtCeiling cannot be run here.\n"
else
    slice() {
        awk -v fn="$1" '
            $0 ~ "^function " fn "\\(" { inside = 1 }
            inside { print }
            inside && /^}/ { exit }
        ' "$JS"
    }
    { echo 'function _(s) { return s; }'; slice fmtRate; slice fmtCeiling; } > "$TMP/slices.js"
    run() { node -e "$(cat "$TMP/slices.js"); console.log($1);"; }
    assert_eq "symmetric: one figure" "5 Mbit/s" "$(run 'fmtCeiling(5000, 5000)')"
    assert_eq "no upload figure: download alone" "5 Mbit/s" "$(run 'fmtCeiling(5000, 0)')"
    assert_eq "split: both figures" "↓ 10 Mbit/s / ↑ 2 Mbit/s" "$(run 'fmtCeiling(10000, 2000)')"
    assert_eq "split below 1 Mbit/s" "↓ 2 Mbit/s / ↑ 512 kbit/s" "$(run 'fmtCeiling(2000, 512)')"
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
