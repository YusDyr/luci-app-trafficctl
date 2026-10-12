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

# ── and every mode must get its own BANNER copy, not inherit someone else's ──
#
# This is the same defect one layer down (#77). mkOffloadBanner branched on
# hardware-counter and hardware and let everything else fall into the
# software-offload text, so when tctl_get_offload_mode learned
# software-counter the banner told the operator their speeds came from
# nftables counters installed before the flowtable — a path that is NOT
# producing the numbers when the counter flag is set, because the flowtable
# syncs byte counts back to conntrack and the conntrack source is used.
#
# The badge assertion above would not have caught it: the badge had a label.
# Only the prose was wrong, so the prose is checked too.
awk '/var mkOffloadBanner = function/ { inf = 1 }
     inf && /^\t\t\};$/ { exit }
     inf' "$JS" \
    | grep -oE "mode === '[a-z-]+'" | sed "s/mode === '//; s/'//" | sort -u > "$TMP/banner"

# 'none' is handled by an early return rather than a branch, so it is excluded
# from the comparison on purpose.
grep -vx 'none' "$TMP/modes" > "$TMP/modes_banner"

missing_banner=$(awk 'NR == FNR { have[$0] = 1; next } !($0 in have)' \
    "$TMP/banner" "$TMP/modes_banner" | tr '\n' ' ' | sed 's/ $//')
assert_eq "every offload mode has its own banner text" "" "$missing_banner"

# The early return must stay, or 'none' would render a "flow offloading is
# active" banner on a router that has none.
banner_src=$(awk '/var mkOffloadBanner = function/ { inf = 1 }
                  inf && /^\t\t\};$/ { exit }
                  inf' "$JS")
case "$banner_src" in
    *"mode === 'none'"*) PASS=$((PASS + 1)) ;;
    *)
        FAIL=$((FAIL + 1))
        printf "FAIL: mkOffloadBanner no longer short-circuits on 'none'\n"
        ;;
esac

# And the two software modes must not share wording: that identity IS the bug.
# Matched on a phrase that is contiguous in the source — the sentence about the
# counter flag is split across two _() calls with an E('code') between them, so
# a pattern spanning that boundary silently never matches (it did not, first
# time round).
# Checked PER BRANCH, not across the whole function: asserting that both
# phrases appear somewhere passes just as well when one branch holds both and
# the other holds neither, which is the copy-paste version of this same bug.
branch_of() {
    printf '%s\n' "$banner_src" \
        | awk -v m="mode === '$1'" '$0 ~ m { inb = 1; next } inb && /} else/ { exit } inb'
}
sc_branch=$(branch_of 'software-counter')
sw_branch=$(branch_of 'software')

case "$sc_branch" in
    *'synced back to conntrack'*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); printf "FAIL: the software-counter branch does not say counts are synced back to conntrack\n" ;;
esac
case "$sc_branch" in
    *'bypassing conntrack byte updates'*)
        FAIL=$((FAIL + 1))
        printf "FAIL: the software-counter branch claims conntrack updates are bypassed — that is the plain-software mechanism\n"
        ;;
    *) PASS=$((PASS + 1)) ;;
esac
case "$sw_branch" in
    *'nftables counters installed at a higher priority'*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); printf "FAIL: the plain-software branch no longer describes the nftables counter path\n" ;;
esac
case "$sw_branch" in
    *'synced back to conntrack'*)
        FAIL=$((FAIL + 1))
        printf "FAIL: the plain-software branch claims counter sync, which is what distinguishes the other mode\n"
        ;;
    *) PASS=$((PASS + 1)) ;;
esac
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
