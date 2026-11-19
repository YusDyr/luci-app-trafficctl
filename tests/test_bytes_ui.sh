#!/bin/bash
# Byte totals read the same on every tab.
#
# The Devices tab divided by 1024 while History and Port Forwards divide by
# 1000 (SI, as the speeds), so one device's 5 GB read 4.66 GB on one tab and
# 5.00 GB on the next. fmtBytes() of each view is sliced out and run under
# node on the same values.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIEWS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl"

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

if ! command -v node >/dev/null 2>&1; then
    printf "FAIL: node is not installed\n"
    exit 1
fi

# A top-level function of a view, from its line to the first closing brace
# at column 0. String tests, not regexes, so any awk runs it.
slice() {
    awk 'index($0, "function fmtBytes(") == 1 { inside = 1 }
        inside { print }
        inside && $0 == "}" { exit }' "$VIEWS/$1"
}

VALUES='[null, 0, 999, 1000, 1500, 999999, 1000000, 12345678, 999999999, 5000000000, 12345678901, 2500000000000]'
run() {
    slice "$1.js" > "$TMP/$1.js"
    printf 'var out = []; %s.forEach(function(b) { out.push(fmtBytes(b)); }); console.log(out.join("|"));\n' "$VALUES" >> "$TMP/$1.js"
    node "$TMP/$1.js" 2>&1
}
OUT_status=$(run status)
OUT_history=$(run history)
OUT_portfw=$(run portfw)

assert_eq "harness: fmtBytes sliced from status.js" "1" "$(grep -c '^function fmtBytes(' "$TMP/status.js")"
assert_eq "the Devices tab is SI" \
    "—|0 B|999 B|1 KB|2 KB|1000 KB|1.0 MB|12 MB|1000 MB|5.00 GB|12.3 GB|2.50 TB" "$OUT_status"
assert_eq "the Devices and History tabs agree (History has no null)" \
    "${OUT_status#—|}" "${OUT_history#0 B|}"
# Port Forwards shows GB with one decimal and has no TB: compared below 1 GB.
assert_eq "the Devices and Port Forwards tabs agree below 1 GB" \
    "$(printf '%s' "$OUT_status" | cut -d"|" -f2-9)" "$(printf '%s' "$OUT_portfw" | cut -d"|" -f2-9)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
