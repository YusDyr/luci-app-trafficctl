#!/bin/bash
# The dashboard's decision about which subnet targets are safe to offer (#64).
#
# The warning that a subnet is not monitored is the only thing standing between
# an operator and a limit that is accepted and then never matches a packet —
# the case a guest VLAN with masq=1 produces. Getting it wrong in either
# direction is bad: a missing warning hides a dead rule, and a false one on a
# working config teaches people to ignore the warning.
#
# The functions are SLICED OUT OF status.js rather than copied here, so this
# cannot drift into testing a stale duplicate. Node is used only as an ES5
# interpreter: the slices touch no DOM and no LuCI runtime.

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

if ! command -v node >/dev/null 2>&1; then
    printf "SKIP: node is not installed — the frontend slices cannot be run here.\n"
    printf "0 passed, 0 failed\n"
    exit 0
fi

# Top-level function declarations, taken from the opening line to the closing
# brace in column 1.
slice() {
    awk -v fn="$1" '
        $0 ~ "^function " fn "\\(" { inside = 1 }
        inside { print }
        inside && /^}/ { exit }
    ' "$JS"
}

{
    slice parseCidr
    slice cidrOverlaps
    slice isSubnetTarget
} > "$TMP/slices.js"

# A silently empty slice would make every assertion below vacuous.
for fn in parseCidr cidrOverlaps isSubnetTarget; do
    if grep -q "^function $fn(" "$TMP/slices.js"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: harness: %s was not sliced out of status.js\n" "$fn"
    fi
done
if [ "$FAIL" -ne 0 ]; then
    printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
    exit 1
fi

# The caller in status.js, reproduced as its own function only because it is
# defined inside render() and cannot be sliced. Kept to the exact shape of the
# original; the logic it is here to exercise lives in the slices above.
cat > "$TMP/driver.js" <<'DRIVER'
function targetIsMonitored(t, list) {
	if (!t || t === 'all' || t === 'any' || t === '0.0.0.0/0') { return true; }
	var want = parseCidr(t);
	if (!want) { return true; }
	if (!list.length) { return true; }
	for (var i = 0; i < list.length; i++) {
		if (cidrOverlaps(want, parseCidr(list[i]))) { return true; }
	}
	return false;
}
// The monitored list arrives as one space-separated argument, so the shell
// side needs no word splitting to build it.
var argv = process.argv.slice(2);
var target = argv[0];
var list = (argv[1] || '').split(/\s+/).filter(function(s) { return s.length > 0; });
if (target === '--is-subnet') {
	console.log(isSubnetTarget(argv[1]) ? 'subnet' : 'device');
} else {
	console.log(targetIsMonitored(target, list) ? 'quiet' : 'warn');
}
DRIVER
cat "$TMP/slices.js" "$TMP/driver.js" > "$TMP/run.js"

# The reporter's own configuration from #64: an IoT VLAN and a guest VLAN that
# are demonstrably being policed today. A warning on either of these would be
# a false alarm on a working setup.
PP="192.168.1.0/24 192.168.10.0/24 10.0.0.0/24"

check() {
    local desc="$1" expected="$2" target="$3" list="$4"
    assert_eq "$desc" "$expected" "$(node "$TMP/run.js" "$target" "$list")"
}

check "his IoT cap is not warned about"            quiet "192.168.10.0/24" "$PP"
check "his Guest cap is not warned about"          quiet "10.0.0.0/24"     "$PP"
check "the main LAN is not warned about"           quiet "192.168.1.0/24"  "$PP"
check "a host inside a monitored subnet is fine"   quiet "192.168.10.55"   "$PP"
check "half of a monitored subnet is fine"         quiet "192.168.10.0/25" "$PP"
check "a supernet of monitored subnets is fine"    quiet "192.168.0.0/16"  "$PP"

# The #64 case: a guest VLAN whose zone masquerades is not monitored, so a
# limit on it would be accepted and never enforced.
check "an unmonitored guest VLAN is warned about"  warn  "192.168.30.0/24" "$PP"
check "an unrelated block is warned about"         warn  "172.16.0.0/16"   "$PP"

# "all"/0.0.0.0/0 is a legitimate target that is not a subnet at all.
check "the whole network keyword is never warned"  quiet "all"             "$PP"
check "the whole network CIDR is never warned"     quiet "0.0.0.0/0"       "$PP"

# Two ways to know nothing: a malformed target (the backend rejects it, and
# guessing here would warn about typos) and an empty list (the read failed, or
# nothing is monitored yet). Both must stay silent rather than cry wolf.
check "a malformed target does not warn"           quiet "nonsense"        "$PP"
check "an empty subnet list does not warn"         quiet "192.168.30.0/24" ""

# A non-octet boundary: the containment test is arithmetic, not string prefix.
check "a host inside a monitored /25 is fine"      quiet "10.10.4.130"     "10.10.4.128/25"
check "a host in the other half is warned about"   warn  "10.10.4.5"       "10.10.4.128/25"

# Which targets get a row in the Active subnet limits list rather than in the
# device table. A /32 is one host written in CIDR form.
assert_eq "the whole network counts as a subnet" "subnet" \
    "$(node "$TMP/run.js" --is-subnet "0.0.0.0/0")"
assert_eq "a block counts as a subnet"           "subnet" \
    "$(node "$TMP/run.js" --is-subnet "192.168.10.0/24")"
assert_eq "a bare address is a device"           "device" \
    "$(node "$TMP/run.js" --is-subnet "192.168.10.55")"
assert_eq "a /32 is a device, not a subnet"      "device" \
    "$(node "$TMP/run.js" --is-subnet "192.168.10.55/32")"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
