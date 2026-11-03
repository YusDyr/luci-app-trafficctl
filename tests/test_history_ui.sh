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

# ── the interface series has its OWN verdict (#102, #111) ──────────────────
# It must not inherit the device verdict, and the reason is not stylistic: the
# device figures come from conntrack and go DEGRADED under flow offloading,
# while interface figures come from /proc/net/dev and are unaffected. Under
# offload this table is the more trustworthy of the two, so inheriting would be
# wrong in the direction that matters — it would mark exact numbers as a floor,
# and a reader who learned to distrust the mark would distrust the right ones.
awk '/^hist_if_accuracy\(\)/ { inf = 1 }
     inf && /^}/ { exit }
     inf { print }' "$SH" \
    | grep -oE "printf '[a-z]+" | sed "s/printf '//" | sort -u > "$TMP/ifverdicts"
awk "/^var IF_ACCURACY = \{/ { inl = 1; next }
     inl && /^\};/ { exit }
     inl" "$JS" \
    | grep -oE "^\s*'[a-z]+'" | sed "s/^[[:space:]]*'//; s/'\$//" | sort -u > "$TMP/ifknown"

assert_eq "the backend emits exactly one interface verdict" "exact" \
    "$(tr '\n' ' ' < "$TMP/ifverdicts" | sed 's/ $//')"
ifmissing=$(awk 'NR == FNR { have[$0] = 1; next } !($0 in have)' "$TMP/ifknown" "$TMP/ifverdicts" \
    | tr '\n' ' ' | sed 's/ $//')
assert_eq "it has an entry in the view's own IF_ACCURACY table" "" "$ifmissing"

# Same fallback rule as the device table: an unknown verdict warns.
ifaccfn=$(awk '/^function ifAccuracyOf\(/ { inf = 1 }
               inf { print }
               inf && /^}/ { exit }' "$JS")
case "$ifaccfn" in
    *"tc-c-warn"*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); printf "FAIL: ifAccuracyOf()'s fallback is not a warning\n" ;;
esac
case "$ifaccfn" in
    *"tc-c-ok"*)
        FAIL=$((FAIL + 1))
        printf "FAIL: ifAccuracyOf()'s fallback treats an unrecognised verdict as exact\n"
        ;;
    *) PASS=$((PASS + 1)) ;;
esac

# The section must read iface_accuracy and not the device verdict.
ifsec=$(awk '/^\trenderIfSection: function/ { inf = 1; next }
             inf && /^\t},/ { exit }
             inf { print }' "$JS")
case "$ifsec" in
    *"st.iface_accuracy"*) PASS=$((PASS + 1)) ;;
    *) FAIL=$((FAIL + 1)); printf "FAIL: the interface section does not read iface_accuracy\n" ;;
esac
case "$ifsec" in
    *"st.accuracy"*|*"accuracyOf("*)
        FAIL=$((FAIL + 1))
        printf "FAIL: the interface section reads the DEVICE accuracy verdict\n"
        ;;
    *) PASS=$((PASS + 1)) ;;
esac

# Nor may the interface rows carry the device table's marks. 'degraded' is not
# even a field of this series, so a mention could only be copied code.
ifrender=$(awk '/^\trenderIfRow: function/ { inf = 1 }
                inf { print }
                inf && /^\trenderIfSection/ { exit }' "$JS")
for bad in 'degraded' 'undercounted' 'ACCURACY['; do
    case "$ifrender" in
        *"$bad"*)
            FAIL=$((FAIL + 1))
            printf "FAIL: the interface renderers carry the device series' '%s'\n" "$bad"
            ;;
        *) PASS=$((PASS + 1)) ;;
    esac
done

# No total row. These rows overlap on purpose — a VPN tunnel's bytes also
# travelled over its WAN, and the LAN bridge sees the same traffic from the
# other side — so a sum would be a meaningless number presented as a period
# total. The device table's total is computed with .some(); this one must not.
ift=$(awk '/^\trenderIfTable: function/ { inf = 1; next }
           inf && /^\t},/ { exit }
           inf { print }' "$JS")
case "$ift" in
    *"_('Total')"*)
        FAIL=$((FAIL + 1))
        printf "FAIL: the interface table renders a total row over overlapping rows\n"
        ;;
    *) PASS=$((PASS + 1)) ;;
esac

# Direction is relative to the INTERFACE, so Download/Upload would be wrong on
# the LAN bridge, where received bytes are what the devices sent.
assert_contains "the interface columns are named from the interface's side" \
    "_('Received')" "$JS"
for bad in "_('Download')" "_('Upload')"; do
    n=$(grep -cF -- "$bad" "$JS")
    # The device table legitimately uses both; the interface header must not
    # add more. Counted so adding one to the interface table trips this.
    assert_eq "no extra $bad column appeared" "1" "$n"
done

# Every field the view reads must be one the backend actually prints.
# Backslashes stripped: the keys live inside a double-quoted awk printf, so
# the literal text in the script is \"dev\" rather than "dev".
ifread=$(awk '/^hist_if_read\(\)/ { inf = 1 }
              inf { print }
              inf && /^}/ { exit }' "$SH" | tr -d '\\')
for fld in dev role label bytes_in bytes_out last_seen; do
    case "$ifread" in
        *"\"$fld\""*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: the view reads '%s' but hist_if_read does not emit it\n" "$fld"
            ;;
    esac
done

# The store's placeholders must not reach the screen: the file is
# tab-separated, so an absent label is '-' and an unknown role is '?'.
assert_contains "the view translates the store's placeholders" "function ifText" "$JS"

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
    "history_config_set history_flush history_periods history_read history_read_ifaces history_status" \
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
