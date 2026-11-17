#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Capture a read-only snapshot of a live router as test fixtures, masked.
#
# Usage: tools/capture-fixtures.sh [root@192.168.0.1] [tests/fixtures/router-24.10]
#
# Layout of the output directory:
#   root/<path>                  files at their router path (TCTL_ROOT target)
#   cmd/<argv>                   stdout of that command line (replayed by mocks)
#   ubus/<object>@<method>.json  replies for tests/lib/ubus-mock.uc
#   versions                     relevant package versions
#
# The router side only reads: no uci set, no nft/tc changes, no files written.
# Its login shell may be fish, so the script goes to `sh -s` on stdin.
#
# Masking happens here, before anything touches the disk: MACs, IPv6 interface
# ids and public addresses are mapped consistently (the same device keeps the
# same masked MAC in every file), host names and SSIDs are replaced, and uci
# options that can hold a secret are dropped. The run fails if any original
# value survives in the output.
set -eu

HOST="${1:-root@192.168.0.1}"
OUT="${2:-tests/fixtures/router-24.10}"

remote() {
    ssh -o BatchMode=yes "$HOST" sh -s <<'REMOTE'
sec() { printf '@@@TCTL@@@ %s\n' "$1"; }
end() { printf '\n@@@TCTL-RC@@@ %s\n' "$1"; }
file() { [ -r "$2" ] || return 0; sec "$1"; cat "$2"; end $?; }
run() { sec "cmd/$*"; "$@" 2>/dev/null; end $?; }
jcall() { sec "ubus/$1@$2.json"; ubus call "$1" "$2" ${3:+"$3"} 2>/dev/null; end $?; }

# Not a fixture: names the masker must find and replace.
sec '!names'; uci -q get system.@system[0].hostname; cat /proc/sys/kernel/hostname; end 0

file root/etc/openwrt_release /etc/openwrt_release
for c in network firewall wireless dhcp trafficctl; do
    sec "root/etc/config/$c"; uci export "$c" 2>/dev/null; end $?
done
for f in /etc/trafficctl/*; do [ -f "$f" ] && file "root$f" "$f"; done
file root/tmp/dhcp.leases /tmp/dhcp.leases
file root/tmp/trafficctl_totals.state /tmp/trafficctl_totals.state
file root/tmp/trafficctl_rdns_cache /tmp/trafficctl_rdns_cache
file root/proc/net/nf_conntrack /proc/net/nf_conntrack
file root/proc/net/dev /proc/net/dev

tcdevs="$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.l3_device')"
for d in /sys/class/net/*/brif /sys/class/net/ifb* /sys/class/net/tctl-ifb*; do
    [ -e "$d" ] || continue
    case "$d" in */brif) b=${d%/brif}; tcdevs="$tcdevs ${b##*/} $(ls "$d" | tr "\n" " ")" ;; *) tcdevs="$tcdevs ${d##*/}" ;; esac
done
for d in /sys/class/net/*; do
    n=${d##*/}
    for a in address ifindex mtu operstate type; do file "root$d/$a" "$d/$a"; done
    [ -r "$d/master/ifindex" ] && file "root$d/master/ifindex" "$d/master/ifindex"
    for p in "$d"/brif/*; do
        [ -e "$p" ] && file "root$d/brif/${p##*/}/state" "$p/state"
    done
    # tc only where trafficctl attaches: bridges, their ports, WAN, IFB.
    case " $tcdevs " in *" $n "*) ;; *) continue ;; esac
    for v in "" "-s "; do
        # shellcheck disable=SC2086 # $v is one optional flag
        run tc $v qdisc show dev "$n"
        # shellcheck disable=SC2086
        run tc $v class show dev "$n"
    done
    run tc -j -s qdisc show dev "$n"
    run tc -j -s class show dev "$n"
    run tc filter show dev "$n" parent 1:
    run tc filter show dev "$n" parent ffff:
done

for a in "" "-4 " "-6 "; do
    for o in "addr show" "route show" "neigh show"; do
        # shellcheck disable=SC2086 # split into argv on purpose
        run ip $a$o
    done
done
# Asked for separately by the interface role map.
run ip -4 route show default
run ip -6 route show default
run ip link show

run nft list tables
run nft list ruleset
run nft -j list ruleset
run nft list flowtables
run nft list chain inet fw4 forward
run nft -j list chain inet fw4 forward
for t in "netdev tm_ratelimit" "inet tctl_cut" "inet tctl_pfw"; do
    # shellcheck disable=SC2086
    nft list table $t >/dev/null 2>&1 || continue
    # shellcheck disable=SC2086
    run nft list table $t
    # shellcheck disable=SC2086
    run nft -j list table $t
done

run iw dev
for w in $(iw dev 2>/dev/null | awk '$1 == "Interface" { print $2 }'); do
    run iw dev "$w" info
    run iw dev "$w" station dump
done
run brctl show
for d in /sys/class/net/*/brif; do
    b=${d%/brif}; run brctl showmacs "${b##*/}"
done

jcall network.interface dump
for o in $(ubus list 'network.interface.*' 2>/dev/null); do jcall "$o" status; done
for o in $(ubus list 'hostapd.*' 2>/dev/null); do
    jcall "$o" get_clients
    jcall "$o" list_bans
done
for s in trafficctl-telegram trafficctl-history trafficctl-cut; do
    jcall service list "{\"name\":\"$s\"}"
done

sec versions
{ opkg list-installed 2>/dev/null || apk info -v 2>/dev/null; } | grep -E '^(ucode|nftables|tc-|tc |ip-|iproute2|firewall4|rpcd|busybox|hostapd|wpad|iw |iw-|conntrack|kmod-sched|kmod-ifb|kmod-nft|libubox|ubus|uci|jsonfilter)'
end 0
REMOTE
}

# The masker reads the capture on stdin, so its source comes in on fd 3.
remote | python3 /dev/fd/3 "$OUT" 3<<'PY'
import ipaddress, json, os, re, sys

out = sys.argv[1]
# uci options dropped outright: anything that can hold a credential, plus free
# text and VPN obfuscation parameters that identify the owner's setup.
DROP = re.compile(r'key|pass|secret|token|psk|chat|user|auth|cred|hash|pin|sae|eap|identity|endpoint|account'
                  r'|description|awg_', re.I)
MAC = re.compile(r'(?<![0-9A-Fa-f:])[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}(?![0-9A-Fa-f:])')
V4 = re.compile(r'(?<![\d.])\d{1,3}(?:\.\d{1,3}){3}(?![\d.])')
V6 = re.compile(r'(?<![0-9A-Fa-f:])[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?![0-9A-Fa-f:])')
TGTOKEN = re.compile(r'\b\d{6,12}:[A-Za-z0-9_-]{30,}\b')

sections, cur, buf = [], None, []
for line in sys.stdin.read().split('\n'):
    if line.startswith('@@@TCTL@@@ '):
        cur, buf = line[11:], []
    elif line.startswith('@@@TCTL-RC@@@ ') and cur is not None:
        body = '\n'.join(buf)
        sections.append((cur, body, line[14:].strip()))
        cur = None
    elif cur is not None:
        buf.append(line)

maps, originals = {}, set()
def mapped(kind, key, make):
    m = maps.setdefault(kind, {})
    if key not in m:
        m[key] = make(len(m) + 1)
    return m[key]

# Names: router host name, lease and static-lease names, aliases, SSIDs.
names, labels = set(), set()
for path, body, rc in sections:
    if path == '!names':
        names.update(w for w in body.split() if w)
    elif path == 'root/tmp/dhcp.leases':
        names.update(f[3] for f in (l.split() for l in body.splitlines()) if len(f) > 3 and f[3] != '*')
    elif path in ('root/etc/config/dhcp', 'root/etc/config/wireless'):
        names.update(m.group(2) for m in re.finditer(r"option (name|ssid|hostname|domain) '([^']+)'", body))
    elif path.startswith('ubus/network.interface'):
        # the ISP's DHCP search domain
        for m in re.finditer(r'"dns-search":\s*\[([^\]]*)\]', body):
            names.update(re.findall(r'"([^"]+)"', m.group(1)))
    elif path == 'root/etc/config/firewall':
        # Rule names are free text and reappear as fw4 comments in the ruleset.
        for sec in re.split(r'\n(?=config )', body):
            m = re.match(r"config (\S+)", sec)
            n = re.search(r"option name '([^']+)'", sec)
            if m and n and m.group(1) != 'zone' and not re.fullmatch(r'Allow-[A-Za-z0-9-]+', n.group(1)):
                labels.add(n.group(1))
    elif path == 'root/etc/trafficctl/names':
        names.update(l.split(None, 1)[1].strip() for l in body.splitlines() if len(l.split(None, 1)) > 1)
    elif path == 'root/tmp/trafficctl_rdns_cache':
        names.update(f[1] for f in (l.split('\t') for l in body.splitlines()) if len(f) > 1 and f[1] not in ('', '-'))
    elif path == 'root/etc/trafficctl/telegram_known.json':
        names.update(re.findall(r'"(?:name|hostname)":"([^"]+)"', body))
names = sorted((n for n in names if len(n) > 2 and n.lower() not in ('lan', 'wan', 'loopback', 'openwrt')),
               key=len, reverse=True)
labels = sorted(labels, key=len, reverse=True)
def word(n):
    return re.compile(r'(?<![A-Za-z0-9_-])%s(?![A-Za-z0-9_-])' % re.escape(n))

def mask_v6(a):
    try:
        ip = ipaddress.IPv6Address(a)
    except ValueError:
        return a
    ula = ip in ipaddress.IPv6Network('fc00::/7')
    if not (ip.is_global or ula or ip.is_link_local):
        return a
    n = int(ip)
    hi, sub, iid = n >> 80, (n >> 64) & 0xffff, n & ((1 << 64) - 1)
    if iid or not ip.is_link_local:
        originals.add(str(ip))
    if iid:
        iid = mapped('iid', iid, lambda i: i)
    if ip.is_link_local:
        top = 0xfe80 << 32
    else:
        site = mapped('site6', hi, lambda i: i)
        top = ((0xfd00 << 32) if ula else (0x20010db8 << 16)) | site
    return str(ipaddress.IPv6Address((top << 80) | (sub << 64) | iid))

def mask_v4(a):
    try:
        ip = ipaddress.IPv4Address(a)
    except ValueError:
        return a
    # Carrier-grade NAT space is what VPN providers hand out: as identifying as
    # a public address, so it is mapped too, but kept inside 100.64.0.0/10.
    cgn = ip in ipaddress.IPv4Network('100.64.0.0/10')
    if not (ip.is_global or cgn) or ip in ipaddress.IPv4Network('198.18.0.0/15'):
        return a
    originals.add(a)
    base = '100.64.0.0' if cgn else '198.18.0.0'
    return mapped('cgn' if cgn else 'v4', a, lambda i: str(ipaddress.IPv4Address(int(ipaddress.IPv4Address(base)) + i)))

def mask_mac(m):
    mac = m.group(0).lower()
    if mac in ('00:00:00:00:00:00', 'ff:ff:ff:ff:ff:ff') or mac.startswith(('01:00:5e', '33:33')):
        return m.group(0)
    originals.add(mac)
    return mapped('mac', mac, lambda i: '02:00:00:00:%02x:%02x' % (i >> 8, i & 255))

def mask(path, body):
    if path.startswith('root/etc/config/'):
        body = '\n'.join(l for l in body.split('\n')
                         if not re.match(r"\s*(option|list)\s+\S*(%s)" % DROP.pattern, l, re.I)
                         and not re.match(r"\s*list (address|server) '/", l))
    if path == 'root/tmp/dhcp.leases':
        # field 5 is the client id: "01:" + MAC, or a DUID that embeds one
        body = '\n'.join(' '.join(f[:4] + ['01:' + MAC.sub(mask_mac, f[4][3:]) if MAC.fullmatch(f[4][3:]) else '*'] + f[5:])
                         if len(f) > 4 else ' '.join(f) for f in (l.split(' ') for l in body.split('\n')))
    body = TGTOKEN.sub('REDACTED', body)
    body = MAC.sub(mask_mac, body)
    body = V6.sub(lambda m: mask_v6(m.group(0)), body)
    if path != 'versions':
        body = V4.sub(lambda m: mask_v4(m.group(0)), body)
    for n in names:
        body = word(n).sub(mapped('name', n, lambda i: 'host-%02d' % i), body)
    for n in labels:
        body = word(n).sub(mapped('label', n, lambda i: 'rule-%02d' % i), body)
    return body

files = {}
for path, body, rc in sections:
    if path == '!names' or (rc != '0' and path.startswith(('cmd/', 'ubus/'))):
        continue
    if path.startswith('root/etc/config/') and not body.strip():
        continue
    body = mask(path, body)
    if path in files and path.startswith('ubus/'):
        # "service list" is captured once per service name, filtered by procd
        merged = json.loads(files[path])
        merged.update(json.loads(body))
        body = json.dumps(merged, indent='\t')
    files[path] = body

leaks = sorted({p for p, b in files.items()
                if TGTOKEN.search(b) or any(v in b.lower() for v in originals)
                or any(word(n).search(b) for n in names + labels)})
if leaks:
    sys.exit('capture: unmasked values survive in %s (nothing written)' % ', '.join(leaks))

for path, body in sorted(files.items()):
    dest = os.path.join(out, path)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with open(dest, 'w') as f:
        f.write(body)
print('%d files in %s; masked %s' % (len(files), out,
      ', '.join('%d %s' % (len(v), k) for k, v in sorted(maps.items()))))
PY
