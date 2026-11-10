// SPDX-License-Identifier: Apache-2.0
'use strict';

// trafficctl.net: what the router's network looks like to trafficctl.
//
//   lan_subnets()        [{ dev, base, block, router }], one per LAN L3 interface
//   lan_devices()        their devices, sorted and unique
//   lan_device()         network.lan's device, 'br-lan' by default
//   routed_subnets()     downstream subnets (via a LAN next hop) and
//                        trafficctl.main.extra_subnets; router is 0
//   monitored_subnets()  both, first entry per prefix wins
//   subnets()            the `subnets` command: [{ cidr, device, kind }]
//   ifaces()             the `ifaces` command: per-interface counters + roles
//   rdns(ip)             the `rdns` command: { ip, host }, null on bad input
//   rdns_refresh(ips)    the `rdns-refresh` command: fills the PTR cache
//
// Subnet records are "netbase block router" as in tctl_lan_subnets
// (trafficctl-fw.sh), which still serves the shell scripts: the two copies
// are kept equal by tests/equiv.sh until the shell one goes.

import * as lib from 'trafficctl.lib';

let dump;
function iface_dump() {
	dump ??= lib.ubus_call('network.interface', 'dump')?.interface ?? [];
	return dump;
}

// "LAN" = firewall zones that are not internet-facing: named lan, or neither
// wan/wan6 nor masqueraded. That keeps VPN zones (masqueraded) out.
let lan_cache;
function lan_subnets() {
	if (lan_cache)
		return lan_cache;

	let zones = [];
	// The shell walks @zone[i] until a name is missing; so does this.
	lib.uci_foreach('firewall', 'zone', (s) => {
		if (type(s.name) != 'string' || s.name == '')
			return false;
		push(zones, s);
	});

	let byname = {};
	for (let e in iface_dump())
		if (type(e?.interface) == 'string' && !exists(byname, e.interface))
			byname[e.interface] = e;

	let out = [];
	for (let z in zones) {
		if (z.name == 'wan' || z.name == 'wan6' || (z.name != 'lan' && z.masq == '1'))
			continue;
		let nets = (type(z.network) == 'array') ? join(' ', z.network) : '' + (z.network ?? '');
		for (let net in split(nets, /[ \t\n]+/)) {
			let e = (net != '') ? byname[net] : null;
			let a = e?.['ipv4-address']?.[0];
			let l3 = e?.l3_device, mask = a?.mask;
			if (type(l3) != 'string' || l3 == '' || !lib.valid_ip(a?.address) ||
			    type(mask) != 'int' || mask < 1 || mask > 32)
				continue;
			let ipint = lib.ip2int(a.address), block = 1 << (32 - mask);
			push(out, { dev: l3, base: ipint - ipint % block, block, router: ipint });
		}
	}
	lan_cache = out;
	return out;
}

function lan_devices() {
	return sort(uniq(map(lan_subnets(), (s) => s.dev)));
}

function lan_device() {
	let d = lib.uci_get('network', 'lan', 'device');
	if (d == null || d == '')
		d = lib.uci_get('network', 'lan', 'ifname');
	return (d == null || d == '') ? 'br-lan' : d;
}

function routed_subnets() {
	let devs = lan_devices(), out = [];

	if (length(devs)) {
		for (let l in lib.lines('ip route show')) {
			let f = split(ltrim(l, ' \t'), /[ \t]+/);
			if (f[0] == 'default' || index(l, ' via ') < 0)
				continue;
			let dev = '';
			for (let i = 0; i < length(f); i++)
				if (f[i] == 'dev')
					dev = f[i + 1] ?? '';
			let spec = (dev != '' && index(devs, dev) >= 0) ? lib.cidr_spec(f[0]) : null;
			if (spec)
				push(out, { dev, base: spec.base, block: spec.block, router: 0 });
		}
	}

	let extras = lib.uci_words('trafficctl', 'main', 'extra_subnets');
	if (length(extras)) {
		let dev = lan_device();
		for (let c in extras) {
			let spec = lib.cidr_spec(c);
			if (spec)
				push(out, { dev, base: spec.base, block: spec.block, router: 0 });
		}
	}
	return out;
}

function monitored_subnets() {
	let seen = {}, out = [];
	for (let s in [ ...lan_subnets(), ...routed_subnets() ]) {
		let k = s.base + ':' + s.block;
		if (!exists(seen, k)) {
			seen[k] = true;
			push(out, s);
		}
	}
	return out;
}

// Exactly the set a limit can be enforced on: the policing hooks attach to
// the devices these subnets resolve to.
function subnets() {
	return map(monitored_subnets(), (s) => {
		let mask = 32;
		for (let b = s.block; b > 1; b = b >> 1)
			mask--;
		return {
			cidr: lib.int2ip(s.base) + '/' + mask,
			device: s.dev,
			kind: (s.router == 0) ? 'routed' : 'lan'
		};
	});
}

// ── ifaces: per-interface counters for the global overview ──────────────────
//
// The hot path is one read of /proc/net/dev plus sysfs operstate. Roles need
// uci, ubus and `ip route`, so they are memoised in tmpfs for TTL seconds in
// the format trafficctl-device.sh also reads:
//   # <epoch>
//   <dev> <role> <tunnel> <primary> <defroute> <enslaved> <label|->

const IFROLES = '/tmp/trafficctl_ifroles';
const IFROLES_TTL = 60;
const SYSFS = '/sys/class/net';

// ppp* is absent on purpose: pppoe-wan is the usual DSL uplink, not a VPN.
const TUN_RE = /^(wg|awg|tun|tap|gre|sit|vti|ipsec|ip6tnl|xfrm|zt|nordlynx|tailscale|l2tp|pptp)/;

function netdev_rows(text) {
	let rows = [], l = split(text, '\n');
	for (let i = 2; i < length(l); i++) {
		let c = index(l[i], ':');
		if (c < 0)
			continue;
		let dev = replace(substr(l[i], 0, c), /[ \t]/g, '');
		if (dev != '' && dev != 'lo')
			push(rows, { dev, rest: substr(l[i], c + 1) });
	}
	return rows;
}

// Which of several uci interfaces on one device names it: wan over wan6 over
// wan6_alias0, whatever order the dump uses. Lower wins.
function label_score(n) {
	return (index(n, '_alias') >= 0 ? 4 : 0) + (match(n, /6$|6_/) ? 2 : 0);
}

function label_better(n, old, s, olds) {
	return s < olds || (s == olds && (length(n) < length(old) ||
		(length(n) == length(old) && n < old)));
}

function build_roles(rows, now) {
	let isdef = {}, islan = {}, isuciwan = {}, lbl = {}, lblscore = {};

	for (let d in lan_devices())
		islan[d] = true;

	// Default-route holders, v4 or v6. Not the same as the WAN: a full-tunnel
	// router routes via awg0 while the uplink carries the encapsulated bytes.
	for (let l in lib.lines('ip -4 route show default; ip -6 route show default')) {
		let f = split(ltrim(l, ' \t'), /[ \t]+/);
		for (let i = 0; i < length(f) - 1; i++)
			if (f[i] == 'dev')
				isdef[f[i + 1]] = true;
	}

	for (let e in iface_dump()) {
		let d = e?.l3_device, n = e?.interface;
		if (type(d) != 'string' || d == '' || type(n) != 'string' || n == '')
			continue;
		// Any uci wan/wan6 (or alias) marks the uplink, even if something else
		// holds the default route now.
		if (match(n, /^wan6?$|^wan6?_/))
			isuciwan[d] = true;
		let s = label_score(n);
		if (!exists(lbl, d) || label_better(n, lbl[d], s, lblscore[d])) {
			lbl[d] = n;
			lblscore[d] = s;
		}
	}

	let roles = {}, nwan = 0;
	for (let r in rows) {
		let d = r.dev;
		let tun = !!match(d, TUN_RE);
		// A bridge port reports the same bytes as its bridge.
		let ens = length(lib.readfile(SYSFS + '/' + d + '/master/ifindex') ?? '') > 0;
		let role = 'other';
		// Tunnels before default routes; see above.
		if (ens)
			role = 'other';
		else if (islan[d])
			role = 'lan';
		else if (tun)
			role = 'vpn';
		else if (isuciwan[d] || isdef[d]) {
			role = 'wan';
			nwan++;
		}
		roles[d] = { role, tun, prim: false, dfr: !!isdef[d], ens, lbl: lbl[d] ?? '-' };
	}

	// No uplink at all (tunnel-only router): promote the route holder, or
	// the overview has no headline row.
	if (!nwan)
		for (let r in rows)
			if (isdef[r.dev] && !roles[r.dev].ens)
				roles[r.dev].role = 'wan';

	// Exactly one primary: the headline graph shows it rather than a sum,
	// which would double-count a failover pair.
	let prim = null;
	for (let test in [ (d) => isuciwan[d], (d) => isdef[d], (d) => true ]) {
		for (let r in rows)
			if (roles[r.dev].role == 'wan' && test(r.dev)) {
				prim = r.dev;
				break;
			}
		if (prim != null)
			break;
	}
	if (prim != null)
		roles[prim].prim = true;

	let text = sprintf('# %d\n', now);
	for (let r in rows) {
		let x = roles[r.dev];
		text += sprintf('%s %s %d %d %d %d %s\n', r.dev, x.role,
			x.tun ? 1 : 0, x.prim ? 1 : 0, x.dfr ? 1 : 0, x.ens ? 1 : 0, x.lbl);
	}
	lib.write_atomic(IFROLES, text);
	return roles;
}

// awk's string-to-number: the leading digits, 0 if none. Declared before its
// callers: ucode resolves names at compile time, without hoisting.
function num(s) {
	let m = match(s, /^[0-9]+/);
	return m ? int(m[0]) : 0;
}

function read_roles() {
	let l = lib.file_lines(IFROLES), roles = {};
	// "# <epoch>": the shell read it with `read -r _hash TS`.
	let m = match(l[0] ?? '', /^[ \t]*[^ \t]+[ \t]+(.*)$/);
	let ts = lib.valid_int(rtrim(m?.[1] ?? '', ' \t')) ?? 0;
	for (let x in l) {
		if (substr(x, 0, 1) == '#')
			continue;
		let f = split(trim(x, ' \t'), /[ \t]+/);
		if (length(f) < 7)
			continue;
		roles[f[0]] = { role: f[1], tun: num(f[2]) != 0, prim: num(f[3]) != 0,
			dfr: num(f[4]) != 0, ens: num(f[5]) != 0, lbl: f[6] };
	}
	return { ts, roles };
}

function emit(rows, roles) {
	let out = [], miss = false;
	for (let r in rows) {
		// Split after the colon: a name that fills the padded column leaves
		// no space before rx_bytes.
		let c = split(ltrim(r.rest, ' \t'), /[ \t]+/);
		if (length(c) < 16)
			continue;
		let x = roles[r.dev];
		if (!x)
			miss = true;
		let state = split(lib.readfile(SYSFS + '/' + r.dev + '/operstate') ?? '', '\n')[0];
		let name = replace(r.dev, /["\\]/g, '');
		let label = (x && x.lbl != '' && x.lbl != '-') ? replace(x.lbl, /["\\]/g, '') : name;
		push(out, {
			dev: name,
			label,
			role: x ? x.role : 'other',
			tunnel: !!x?.tun,
			primary: !!x?.prim,
			defroute: !!x?.dfr,
			enslaved: !!x?.ens,
			// A tunnel that is down but still holds counters is worth showing.
			up: state == 'up' || state == 'unknown',
			rx_bytes: num(c[0]),
			tx_bytes: num(c[8])
		});
	}
	return { out, miss };
}

function ifaces() {
	let text = lib.readfile('/proc/net/dev');
	if (text == null)
		return [];
	let rows = netdev_rows(text), now = time();
	let cache = read_roles();
	let roles = (now - cache.ts >= IFROLES_TTL) ? build_roles(rows, now) : cache.roles;
	let r = emit(rows, roles);
	// A device the cached map has never seen (a tunnel came up): classify it
	// now rather than after the TTL. One rebuild covers every current device.
	if (r.miss)
		r = emit(rows, build_roles(rows, now));
	return r.out;
}

// ── reverse DNS ─────────────────────────────────────────────────────────────

const RDNS_CACHE = '/tmp/trafficctl_rdns_cache';
const RDNS_LOCK = '/tmp/trafficctl_rdns.lock';
// A refresher killed mid-run leaves its lock behind (no signal handling).
const RDNS_LOCK_STALE = 300;
const NSLOOKUP_MS = 5000;
const NAME_LINE = regexp('^Name:[ \t]*(.*)$');

function rrdns(ip) {
	let r = lib.ubus_call('network.rrdns', 'lookup', { addrs: [ ip ], timeout: 2000, limit: 1 });
	return (type(r?.[ip]) == 'string') ? r[ip] : '';
}

function nslookup(ip, srv) {
	return lib.lines('nslookup ' + lib.q(ip) + (srv ? ' ' + lib.q(srv) : ''), NSLOOKUP_MS);
}

function rdns(ip) {
	if (!lib.valid_ip(ip))
		return null;
	let host = rrdns(ip);
	if (host == '')
		for (let l in nslookup(ip)) {
			let m = match(l, /^.*name = (.*)\.$/);
			if (m) {
				host = m[1];
				break;
			}
		}
	return { ip, host: match(host, /^[a-zA-Z0-9._-]+$/) ? host : '' };
}

function ptr_name(ls) {
	for (let l in ls) {
		let m = match(l, /^.*name = ([^ ]*)\.$/) ?? match(l, NAME_LINE);
		if (m)
			return m[1];
	}
	return '';
}

// trafficctl.main.rdns_server first (point it at a downstream router), then
// the system resolver. Bare host names, '' when there is none.
function resolve(ip, servers) {
	let host = '';
	for (let srv in servers) {
		host = ptr_name(nslookup(ip, srv));
		if (host != '')
			break;
	}
	if (host == '')
		host = rrdns(ip);
	if (host == '')
		host = ptr_name(nslookup(ip));
	// Some resolvers echo the reverse zone instead of NXDOMAIN.
	if (index(host, 'in-addr.arpa') >= 0 || !match(host, /^[a-zA-Z0-9._-]+$/))
		return '';
	return split(host, '.')[0];
}

// Cache lines "IP HOST TIMESTAMP", HOST '-' = no record. Run detached from the
// summary poll: resolving is slow and must never block the device table.
function rdns_refresh(ips) {
	if (!lib.lock(RDNS_LOCK, 0, RDNS_LOCK_STALE))
		return;
	let servers = lib.uci_words('trafficctl', 'main', 'rdns_server');
	let now = time();
	for (let ip in ips) {
		if (!lib.valid_ip(ip))
			continue;
		let host = resolve(ip, servers);
		let l = filter(lib.file_lines(RDNS_CACHE), (x) => lib.field(x, 0) != ip);
		push(l, sprintf('%s %s %d', ip, (host != '') ? host : '-', now));
		lib.write_atomic(RDNS_CACHE, join('\n', l) + '\n');
	}
	lib.unlock(RDNS_LOCK);
}

// 2022-12 needs a ';' after `export function f() {}`; one list avoids it.
export { lan_subnets, lan_devices, lan_device, routed_subnets,
	monitored_subnets, subnets, ifaces, rdns, rdns_refresh };
