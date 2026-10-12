#!/bin/bash
# The History tab against the backend that feeds it.
#
# Every assertion here reads BOTH sides out of the real files rather than
# restating either, because this is the exact shape of a bug this project has
# already shipped twice: the UI was written against a snapshot of what the
# backend emits, the backend learned a new value, and the view fell through to
# a fallback and printed the raw string at the user (the offload badge's '?',
# see test_offload_ui.sh).
#
# The stakes are higher here than cosmetic. The accuracy verdict is what tells
# a reader whether a number is a measurement or a floor; a verdict the view
# does not recognise must produce a warning, never silence.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/history.js"
SH="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin/trafficctl-history.sh"
RPCD="$REPO_ROOT/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
ACL="$REPO_ROOT/luci-app-trafficctl/root/usr/share/rpcd/acl.d/luci-app-trafficctl.json"
MENU="$REPO_ROOT/luci-app-trafficctl/root/usr/share/luci/menu.d/luci-app-trafficctl.json"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for f in "$JS" "$SH" "$RPCD" "$ACL" "$MENU"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: missing $f"
        exit 1
    fi
done

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
    local desc="$1" needle="$2" file="$3"
    if grep -qF -- "$needle" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s (looked for '%s' in %s)\n" "$desc" "$needle" "$(basename "$file")"
    fi
}

# ── every verdict the backend can emit must be a verdict the view knows ─────
awk '/^hist_accuracy\(\)/ { inf = 1 }
     inf && /^}/ { exit }
     inf { print }' "$SH" \
    | grep -oE "printf '[a-z]+" | sed "s/printf '//" | sort -u > "$TMP/verdicts"

awk "/^var ACCURACY = \{/ { inl = 1; next }
     inl && /^\};/ { exit }
     inl" "$JS" \
    | grep -oE "^\s*'[a-z]+'" | sed "s/^[[:space:]]*'//; s/'\$//" | sort -u > "$TMP/known"

assert_eq "the backend emits exactly the three accuracy verdicts" \
    "counter degraded sampled" \
    "$(tr '\n' ' ' < "$TMP/verdicts" | sed 's/ $//')"

missing=$(awk 'NR == FNR { have[$0] = 1; next } !($0 in have)' "$TMP/known" "$TMP/verdicts" \
    | tr '\n' ' ' | sed 's/ $//')
assert_eq "every verdict the backend emits has an entry in the view's ACCURACY table" \
    "" "$missing"

# An UNKNOWN verdict must warn. Defaulting to the reassuring case is the
# failure that matters: it would present an unverified figure as exact.
accfn=$(awk '/^function accuracyOf\(/ { inf = 1 }
             inf { print }
             inf && /^}/ { exit }' "$JS")
case "$accfn" in
    *"tc-c-warn"*) PASS=$((PASS + 1)) ;;
    *)
        FAIL=$((FAIL + 1))
        printf "FAIL: accuracyOf()'s fallback for an unrecognised verdict is not a warning\n"
        ;;
esac
case "$accfn" in
    *"tc-c-ok"*)
        FAIL=$((FAIL + 1))
        printf "FAIL: accuracyOf()'s fallback treats an unrecognised verdict as exact\n"
        ;;
    *) PASS=$((PASS + 1)) ;;
esac

# ── a floor must never be rendered as a measurement ─────────────────────────
assert_contains "the degraded verdict says the figure is a lower bound" \
    "Lower bound, not a measurement" "$JS"
assert_contains "a degraded row is marked in the table" "undercounted" "$JS"
# The total over a set containing a degraded row is itself a floor. Rendering
# it bare is the one place the caveat silently disappears, so this is checked
# STRUCTURALLY inside renderTable: a grep for the flag's name elsewhere in the
# file passed while the computation had been renamed away (verified by
# mutation), because the use site still mentioned it.
rt=$(awk '/^\trenderTable: function/ { inf = 1; next }
          inf && /^\t},/ { exit }
          inf { print }' "$JS")
for needle in '.degraded' '.some(' 'tc-c-warn'; do
    case "$rt" in
        *"$needle"*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: renderTable does not derive the total's lower-bound caveat (missing %s)\n" "$needle"
            ;;
    esac
done

# ── an IP-keyed row must say so ─────────────────────────────────────────────
# History keyed on an address rather than a MAC is only as stable as the lease.
# The backend marks it; the view has to surface it or the distinction is lost.
assert_contains "the backend reports the key kind" 'key_kind' "$SH"
assert_contains "the view distinguishes an IP-keyed row" "IP-keyed" "$JS"

# ── every method the view calls must exist and be permitted ────────────────
grep -oE "method: '[a-z_]+'" "$JS" | sed "s/method: '//; s/'//" | sort -u > "$TMP/called"
while read -r m; do
    [ -n "$m" ] || continue
    if grep -q "\"$m\":{" "$RPCD"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: the view calls '%s' but rpcd does not declare it\n" "$m"
    fi
    # A method missing from the ACL fails at runtime as a permission error,
    # which looks like a backend bug and is invisible to every other test.
    if grep -q "\"$m\"" "$ACL"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: the view calls '%s' but it is in no ACL list\n" "$m"
    fi
done < "$TMP/called"

assert_eq "the view calls the expected history methods" \
    "history_config_set history_flush history_periods history_read history_status" \
    "$(tr '\n' ' ' < "$TMP/called" | sed 's/ $//')"

# The two that write must be in the WRITE list, not merely present somewhere.
write_block=$(awk '/"write":/ { inw = 1 } inw { print }' "$ACL")
for m in history_config_set history_flush; do
    case "$write_block" in
        *"\"$m\""*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: '%s' changes state but is not in the ACL write list\n" "$m"
            ;;
    esac
done

# ── ES5 only, as everywhere else in this package ───────────────────────────
# Strip string and comment content first: a prose mention of "const" or an
# arrow in a tooltip is not an ES6 construct, and matching the raw file makes
# this assertion fire on documentation.
node -e '
var fs = require("fs");
var src = fs.readFileSync(process.argv[1], "utf8");
var out = src
  .replace(/\/\*[\s\S]*?\*\//g, " ")
  .replace(/(^|[^:])\/\/.*$/gm, "$1 ")
  .replace(/'"'"'(?:[^'"'"'\\\n]|\\.)*'"'"'/g, "@")
  .replace(/"(?:[^"\\\n]|\\.)*"/g, "@");
fs.writeFileSync(process.argv[2], out);
' "$JS" "$TMP/stripped.js"

for pat in '\blet\b' '\bconst\b' '=>' '\bclass\b' '\.\.\.' '`'; do
    hits=$(grep -cE "$pat" "$TMP/stripped.js" 2>/dev/null || true)
    assert_eq "no ES6 construct /$pat/ in the view" "0" "$hits"
done

# ── the tab is actually reachable ──────────────────────────────────────────
python3 - "$MENU" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
e = m.get("admin/status/trafficctl/history")
assert e, "no menu entry for the history tab"
assert e["action"]["path"] == "trafficctl/history", e["action"]
assert "luci-app-trafficctl" in e["depends"]["acl"], e["depends"]
orders = sorted((v.get("order"), k) for k, v in m.items() if k.count("/") == 3)
assert len(set(o for o, _ in orders)) == len(orders), "two tabs share an order: %r" % (orders,)
PY
if [ $? -eq 0 ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    printf "FAIL: the history tab is not reachable from the menu, or tab orders collide\n"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
