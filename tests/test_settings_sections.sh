#!/bin/bash
# The settings UI: which sections exist, and that each one is actually mounted.
#
# Written BEFORE moving settings out of the Devices page into their own tab
# (#90), as the safety net for that move. The failure it guards against is
# losing a section in the shuffle, which nothing else would catch: the page
# still renders, the suite still passes, and the only symptom is that one group
# of settings is no longer reachable from anywhere.
#
# It is deliberately agnostic about WHERE the sections live. Before the move
# they are built inside status.js and mounted into a collapsible panel on the
# Devices view; after it they belong to a settings view of their own. Both
# shapes satisfy this test, so it keeps its meaning across the change instead
# of having to be rewritten with it — which is the point of writing it first.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEWS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl"
MENU="$REPO_ROOT/luci-app-trafficctl/root/usr/share/luci/menu.d/luci-app-trafficctl.json"

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

# Every view file is a candidate home for the sections.
cat "$VIEWS"/*.js > "$TMP/all.js"

# ── the sections that must exist ───────────────────────────────────────────
# Named explicitly rather than counted, so RENAMING one is also a failure that
# has to be acknowledged: a rename changes a user-facing string and a msgid.
grep -oE "mkCollapsible\(_\('[^']+'\)" "$TMP/all.js" \
    | sed "s/mkCollapsible(_('//; s/')$//" | sort -u > "$TMP/have"

cat > "$TMP/want" <<'EOF'
Display
Flow Offload
Logging & Persistence
New Device Defaults
Table & Speed
Telegram Bot
EOF

missing=$(comm -23 "$TMP/want" "$TMP/have" | tr '\n' ' ' | sed 's/ $//')
assert_eq "every known settings section still exists" "" "$missing"

added=$(comm -13 "$TMP/want" "$TMP/have" | tr '\n' ' ' | sed 's/ $//')
assert_eq "no settings section appeared without this test being told" "" "$added"

# ── each section must be MOUNTED, not merely built ────────────────────────
# A section assigned to a variable and never appended renders nowhere. That is
# the exact shape a careless move produces, and it is invisible: no error, no
# blank space, the group simply is not there.
for f in "$VIEWS"/*.js; do
    names=$(grep -oE "var [A-Za-z]+Section = mkCollapsible" "$f" \
            | sed 's/var //; s/ = mkCollapsible//' | sort -u)
    for n in $names; do
        if grep -q "appendChild($n\.el)" "$f" || grep -q "$n\.el" "$f"; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            printf "FAIL: section '%s' in %s is built but never mounted\n" \
                "$n" "$(basename "$f")"
        fi
    done
done

# ── the settings UI must be reachable ─────────────────────────────────────
# Either as the collapsible panel on the Devices view (how it is today) or as
# a view of its own with a menu entry (where #90 is taking it). What must not
# happen is sections that exist with no route to them.
reachable=no
if grep -q "tc-settings-panel" "$TMP/all.js"; then
    reachable="panel"
fi
if python3 - "$MENU" >/dev/null 2>&1 <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert any(k.endswith('/settings') for k in m), "no settings menu entry"
PY
then
    reachable="tab"
fi
case "$reachable" in
    panel|tab) PASS=$((PASS + 1)) ;;
    *)
        FAIL=$((FAIL + 1))
        printf "FAIL: the settings sections have no route to them — no tc-settings-panel and no settings menu entry\n"
        ;;
esac

# ── a section's title is a msgid, so it must be translatable ──────────────
# mkCollapsible(_('X')) and not mkCollapsible('X'): a bare string would drop
# the whole group out of every translation silently.
bare=$(grep -oE "mkCollapsible\('[^']+'" "$TMP/all.js" | sed "s/mkCollapsible('//; s/'$//" | tr '\n' ' ')
assert_eq "no section title bypasses _()" "" "$bare"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
