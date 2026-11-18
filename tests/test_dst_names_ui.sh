#!/bin/bash
# Names for private destinations in the device view, and the rDNS hint (#172).
#
# Private (LAN) destinations are never sent to rDNS, so the connection table
# showed "—" for them even when the router knew the host: by a manual alias
# (/etc/trafficctl/names) or a DHCP lease. The host cell now takes the name
# from those, in that order, and shows the bare address when neither has one.
# The sources are re-read at most once a minute, not on every 3 s poll.
#
# The rDNS switch sits in the toolbar and is off by default; in #165 the
# reporter only saw hostnames after finding it. While it is off, the table
# footer says so and links to it.
#
# The functions are SLICED OUT OF status.js and run under node, so the test
# cannot drift into testing a copy.

# shellcheck source=tests/lib/assert.sh
. "$(dirname "$0")/lib/assert.sh"
# shellcheck source=tests/lib/js_slice.sh
. "$(dirname "$0")/lib/js_slice.sh"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"
ACL="$REPO_ROOT/luci-app-trafficctl/root/usr/share/rpcd/acl.d/luci-app-trafficctl.json"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FNS="localNames localName localNamesCache hostLabel rdnsHint"
for fn in $FNS; do
    assert_eq "status.js defines $fn" "1" "$(grep -c "^function $fn(" "$JS")"
done

# Static wiring, checked without node.
assert_eq "the connection table is built with the local names" "1" \
    "$(grep -c 'buildTable(data.connections, .*, local);' "$JS")"
assert_eq "a locally named destination is not sent to rDNS" "1" \
    "$(grep -c 'PRIVATE_RE.test(dst) || localName(local, dst)) return;' "$JS")"
assert_eq "the device poll reads the names through the cache" "1" \
    "$(grep -c 'self._localNames.get(Date.now())' "$JS")"
assert_eq "the table footer carries the rDNS hint" "1" \
    "$(grep -c 'var hint = rdnsHint(!!o.rdns);' "$JS")"
assert_eq "the rDNS switch shows or hides the hint at once" "1" \
    "$(grep -c "querySelectorAll('.tc-rdns-hint')" "$JS")"
assert_eq "the hint links to the switch it names" "11" \
    "$(grep -c "mkToggle('tm-rdns'" "$JS")$(grep -c "'href': '#tm-rdns'" "$JS")"
assert_eq "the read ACL grants luci-rpc getDHCPLeases" "getDHCPLeases" \
    "$(jq -r '."luci-app-trafficctl".read.ubus."luci-rpc"[]?' "$ACL" 2>/dev/null)"
assert_eq "no write grant on luci-rpc" "" \
    "$(jq -r '."luci-app-trafficctl".write.ubus."luci-rpc"[]?' "$ACL" 2>/dev/null)"

if ! command -v node >/dev/null 2>&1; then
    printf "SKIP: node is not installed — the frontend slices cannot be run here.\n"
    summary
fi

{
    echo 'function _(s) { return s; }'
    echo 'function E(tag, attrs, kids) { return { tag: tag, attrs: attrs || {}, kids: kids || [] }; }'
    grep -E '^var (PRIVATE_RE|LOCAL_NAMES_TTL) = ' "$JS"
    for fn in $FNS; do js_slice "$JS" "$fn"; done
} > "$TMP/slices.js"

cat > "$TMP/sim.js" <<'EOF'
var aliases = [ { ip: '192.168.1.20', name: 'nas-alias' }, { ip: '8.8.8.8', name: 'my-dns' } ];
var leases = {
    dhcp_leases: [
        { ipaddr: '192.168.1.20', hostname: 'nas-lease', macaddr: 'aa:bb:cc:00:00:01' },
        { ipaddr: '192.168.1.30', hostname: 'printer', macaddr: 'aa:bb:cc:00:00:02' },
        { ipaddr: '192.168.1.40', hostname: '*', macaddr: 'aa:bb:cc:00:00:03' }
    ],
    dhcp6_leases: [
        { ip6addr: 'fd00::30/128', ip6addrs: [ 'fd00::30/128', 'FD00::31/128' ], hostname: 'printer6' }
    ]
};
var raw4 = '1700000000 aa:bb:cc:00:00:09 10.0.0.9 tv *\n1700000000 aa:bb:cc:00:00:01 192.168.1.20 nas-file *\n';

function show(dst, rdns, m) { var h = hostLabel({ dst: dst }, rdns, m); return h.kind + ':' + h.text; }

var mode = process.argv[2];
(async function() {
    var m = localNames(aliases, leases, raw4);
    if (mode === 'lease') {
        console.log([show('192.168.1.30', false, m), show('192.168.1.30', true, m)].join(' '));
    } else if (mode === 'lease6') {
        console.log([localName(m, 'fd00::30'), localName(m, 'fd00::31')].join(' '));
    } else if (mode === 'alias') {
        console.log(show('192.168.1.20', true, m));
    } else if (mode === 'alias-public') {
        console.log(show('8.8.8.8', true, m));
    } else if (mode === 'fallback-ip') {
        console.log([show('192.168.1.99', false, m), show('192.168.1.40', true, m)].join(' '));
    } else if (mode === 'leasefile') {
        // luci-rpc denied or failed: the lease file read at render stands in.
        var f = localNames([], {}, raw4);
        console.log([show('10.0.0.9', false, f), show('192.168.1.20', false, f)].join(' '));
    } else if (mode === 'public') {
        console.log([show('1.1.1.1', false, m), show('1.1.1.1', true, m)].join(' '));
    } else if (mode === 'backend-host') {
        var h = hostLabel({ dst: '192.168.1.30', host: 'from-backend' }, false, m);
        console.log(h.kind + ':' + h.text);
    } else if (mode === 'cache') {
        // The device poll: every 3 s for 120 s. One fetch per TTL, not per poll.
        var calls = 0;
        var c = localNamesCache(function() { calls++; return Promise.resolve({ '192.168.1.30': 'n' + calls }); });
        var seen = [];
        for (var t = 0; t < 120000; t += 3000) {
            var got = await c.get(t);
            seen.push(got['192.168.1.30']);
        }
        console.log([calls, seen[0], seen[seen.length - 1]].join(' '));
    } else if (mode === 'cache-concurrent') {
        var n = 0, release;
        var cc = localNamesCache(function() { n++; return new Promise(function(r) { release = r; }); });
        var p1 = cc.get(0), p2 = cc.get(10);
        await new Promise(function(r) { setImmediate(r); });
        release({ a: 'x' });
        var r1 = await p1, r2 = await p2;
        console.log([n, r1.a, r2.a].join(' '));
    } else if (mode === 'cache-fail') {
        // A failed re-read keeps the names already shown and waits the TTL.
        var k = 0;
        var cf = localNamesCache(function() {
            k++;
            return k === 1 ? Promise.resolve({ a: 'kept' }) : Promise.reject(new Error('denied'));
        });
        await cf.get(0);
        var a1 = await cf.get(LOCAL_NAMES_TTL);
        var a2 = await cf.get(LOCAL_NAMES_TTL + 3000);
        console.log([k, a1.a, a2.a].join(' '));
    } else if (mode === 'hint') {
        var off = rdnsHint(false), on = rdnsHint(true);
        var link = off.kids[1];
        console.log([/tc-hidden/.test(off.attrs['class']) ? 'hidden' : 'shown',
                     /tc-hidden/.test(on.attrs['class']) ? 'hidden' : 'shown',
                     link.tag, link.attrs.href].join(' '));
    }
})().catch(function(e) { console.log('ERROR ' + e.message); });
EOF

run() { cat "$TMP/slices.js" "$TMP/sim.js" > "$TMP/all.js"; node "$TMP/all.js" "$1" 2>&1 | tail -1; }

assert_eq "a private destination with a DHCPv4 lease shows the lease name, rDNS on or off" \
    "local:printer local:printer" "$(run lease)"
assert_eq "DHCPv6 lease addresses name the host, prefix length and case ignored" \
    "printer6 printer6" "$(run lease6)"
assert_eq "the manual alias wins over the lease" \
    "local:nas-alias" "$(run alias)"
assert_eq "an aliased public destination is named without rDNS" \
    "local:my-dns" "$(run alias-public)"
assert_eq "a private destination nobody named (or a '*' lease) shows its bare IP" \
    "ip:192.168.1.99 ip:192.168.1.40" "$(run fallback-ip)"
assert_eq "without luci-rpc the lease file read at render names the hosts" \
    "local:tv local:nas-file" "$(run leasefile)"
assert_eq "a public destination is unchanged: '—' with rDNS off, resolving with it on" \
    "none:— resolving:" "$(run public)"
assert_eq "a name from the backend still wins" \
    "name:from-backend" "$(run backend-host)"
assert_eq "40 polls over 120 s read the names twice (TTL 60 s), and the new map is used" \
    "2 n1 n2" "$(run cache)"
assert_eq "two polls while a read is in flight share it" \
    "1 x x" "$(run cache-concurrent)"
assert_eq "a failed re-read keeps the previous names and is not retried before the TTL" \
    "2 kept kept" "$(run cache-fail)"
assert_eq "the hint shows with rDNS off, hides with it on, and links to the switch" \
    "shown hidden a #tm-rdns" "$(run hint)"

summary
