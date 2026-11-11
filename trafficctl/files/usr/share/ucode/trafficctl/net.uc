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
//   offload_mode()       none, software[-counter] or hardware[-counter]
//   ct_each(fn)          fn(rec) per /proc/net/nf_conntrack entry. rec is one
//                        object reused for every entry: { proto ('tcp', 'udp'
//                        or ''), osrc, odst, obytes, rsrc, rdst, rbytes }, o
//                        the original direction and r the reply; bytes are 0
//                        without accounting, rsrc/rdst null when missing
//   bytes()              the `bytes` command: one sample per device, from
//                        conntrack or, under uncountered offload, the nft maps
//   bytes_nft(mode)      the `bytes-nft` command: the nft counter maps; mode
//                        is offload_mode(), looked up when not given
//   totals(all, sample)  the `totals [--all]` command: lifetime totals
//                        accumulated from bytes() (from sample in tests)
//   reset()              drop the cached interface dump and LAN subnets, and
//                        lib.reset(); long-running callers call it per request
//
// Subnet records are "netbase block router" as in tctl_lan_subnets
// (trafficctl-fw.sh), which still serves the shell scripts: the two copies
// are kept equal by tests/equiv.sh until the shell one goes.

import * as lib from 'trafficctl.lib';

let dump, lan_cache;
function iface_dump() {
	dump ??= lib.ubus_call('network.interface', 'dump')?.interface ?? [];
	return dump;
}

function reset() {
	dump = null;
	lan_cache = null;
	lib.reset();
}

// "LAN" = firewall zones that are not internet-facing: named lan, or neither
// wan/wan6 nor masqueraded. That keeps VPN zones (masqueraded) out.
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
			if (ipint == null)
				continue;
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
// Stop well before the lock could be taken as stale; the rest waits for the
// next poll.
const RDNS_MAX_RUN = 240;
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
	return { ip, host: (lib.plain(host) && match(host, /^[a-zA-Z0-9._-]+$/)) ? host : '' };
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
	if (!lib.plain(host) || index(host, 'in-addr.arpa') >= 0 || !match(host, /^[a-zA-Z0-9._-]+$/))
		return '';
	return split(host, '.')[0];
}

// Cache lines "IP HOST TIMESTAMP", HOST '-' = no record. Run detached from the
// summary poll: resolving is slow and must never block the device table.
function cache_put(ip, host, now) {
	let l = filter(lib.file_lines(RDNS_CACHE), (x) => lib.field(x, 0) != ip);
	push(l, sprintf('%s %s %d', ip, (host != '') ? host : '-', now));
	lib.write_atomic(RDNS_CACHE, join('\n', l) + '\n');
}

function rdns_refresh(ips) {
	if (!lib.lock(RDNS_LOCK, 0, RDNS_LOCK_STALE))
		return;
	let servers = lib.uci_words('trafficctl', 'main', 'rdns_server');
	let now = time();
	for (let ip in ips) {
		if (time() - now >= RDNS_MAX_RUN)
			break;
		if (lib.valid_ip(ip))
			cache_put(ip, resolve(ip, servers), now);
	}
	lib.unlock(RDNS_LOCK);
}

// ── conntrack ───────────────────────────────────────────────────────────────

const CONNTRACK = '/proc/net/nf_conntrack';

// The value of the first `key` (' dst=', say) in s, up to the next space;
// null if there is none.
function kv(s, key) {
	let i = index(s, key);
	if (i < 0)
		return null;
	s = substr(s, i + length(key));
	i = index(s, ' ');
	return (i < 0) ? s : substr(s, 0, i);
}

// B of an "A dst=B ..." half, whose words are w: the kernel prints src= and
// dst= side by side, so it is the second word (looked up for anything else).
function ct_dst(h, w) {
	let d = w[1];
	return (d != null && substr(d, 0, 4) == 'dst=') ? substr(d, 4) : kv(h, ' dst=');
}

// A byte count as awk read it: the leading digits, 0 without.
function count(s) {
	let n = (s == null) ? 0 : int(s);
	return (n == n) ? n : 0;
}

// "ipv4 2 tcp 6 431999 ESTABLISHED src=A dst=B ... bytes=N src=B dst=A ...
// bytes=M [ASSURED] ...": the second src= starts the reply direction. Cut
// with index() and split() rather than a regex or a walk over every field:
// this runs for every entry, up to 16k of them, every few seconds. (Measured
// on 16k entries: a regex match per line is ~1.4x and a field walk ~4x the
// time of this.)
function ct_parse(l, rec) {
	let p = index(l, ' src=');
	if (p < 0)
		return false;
	// The protocol is a bare word in the header, before any key=value.
	let head = substr(l, 0, p);
	rec.proto = (index(head, ' tcp ') >= 0) ? 'tcp' : (index(head, ' udp ') >= 0) ? 'udp' : '';
	let h = split(substr(l, p + 5), ' src=', 2), o = h[0], r = h[1];
	let w = split(o, ' ', 3);
	rec.osrc = w[0];
	rec.odst = ct_dst(o, w);
	rec.obytes = count(kv(o, ' bytes='));
	if (r == null) {
		rec.rsrc = null;
		rec.rdst = null;
		rec.rbytes = 0;
		return true;
	}
	w = split(r, ' ', 3);
	rec.rsrc = w[0];
	rec.rdst = ct_dst(r, w);
	rec.rbytes = count(kv(r, ' bytes='));
	return true;
}

function ct_each(fn) {
	let rec = {};
	lib.each_line(CONNTRACK, (l) => {
		if (ct_parse(l, rec))
			fn(rec);
	});
}

// ── per-device byte samples ─────────────────────────────────────────────────
//
// [{ ip, bytes_in, bytes_out, bytes_tcp, bytes_udp, src, degraded }]
//
// src names the counter source, 'ct' or 'nft'. totals() accumulates these, and
// the two have unrelated magnitudes (conntrack covers live flows only, the nft
// maps count since the table was built), so it has to tell a source switch
// from a burst of traffic.
//
// degraded says whether the numbers can be believed at all. It is separate
// from src on purpose: src is about magnitude (and drives the rebaseline),
// degraded is about trust; folding them together would make a change in trust
// look like a change of counter and throw a delta away for nothing.
//
// bytes_tcp/bytes_udp are both directions summed, conntrack only: the nft maps
// are keyed by address alone, so that path reports -1, "unknown", which must
// not render as "no TCP traffic".
//
// Arrays are sorted by address; the shell printed awk hash order.

function offload_mode() {
	let sw, hw;
	lib.uci_foreach('firewall', 'defaults', (s) => {
		sw = s.flow_offloading;
		hw = s.flow_offloading_hw;
		return false;
	});
	if (hw != '1' && sw != '1')
		return 'none';
	// A counter-flagged flowtable syncs offloaded byte counts back to
	// conntrack (kernel 5.7+; fw4 sets it by default), so conntrack stays
	// accurate: worth telling apart, because the nft-map fallback needs
	// dynamic counter maps that many kernels lack.
	let counted = index(lib.run('nft list flowtables'), 'counter') >= 0;
	return ((hw == '1') ? 'hardware' : 'software') + (counted ? '-counter' : '');
}

// Offload whose fast path the conntrack counters never see.
function uncountered(mode) {
	return mode != 'none' && substr(mode, -8) != '-counter';
}

function by_ip(a, b) {
	let x = lib.ip2int(a), y = lib.ip2int(b);
	if (x == null || y == null)
		return (x != null) ? -1 : (y != null) ? 1 : (a < b) ? -1 : (a > b) ? 1 : 0;
	return x - y;
}

function sorted_ips(o) {
	return sort(keys(o), by_ip);
}

function local_ips() {
	let out = {};
	for (let l in lib.lines('ip -4 addr show')) {
		if (index(l, 'inet ') < 0)
			continue;
		let a = split(lib.field(l, 1), '/')[0];
		if (a != '')
			out[a] = true;
	}
	return out;
}

function bytes_ct(degraded) {
	let subs = monitored_subnets();
	if (!length(subs))
		return [];

	// Membership per address, not per entry: the table holds a few hundred
	// addresses in up to 16k entries.
	let lan = {}, locals = null, acc = {};
	let is_lan = (ip) => {
		if (exists(lan, ip))
			return lan[ip];
		let n = lib.ip2int(ip), hit = false;
		if (n != null)
			for (let s in subs)
				if (n - n % s.block == s.base) {
					hit = true;
					break;
				}
		lan[ip] = hit;
		return hit;
	};

	ct_each((c) => {
		let src = is_lan(c.osrc) ? c.osrc : (c.rsrc != null && is_lan(c.rsrc)) ? c.rsrc : null;
		// NAT fallback: SNAT/masqueraded here (reply dst != original src),
		// so the original source is a forwarded client even outside every
		// monitored subnet (behind a downstream router, say). The router's
		// own addresses are not clients; read only when first needed.
		if (src == null && c.rdst != null && c.rdst != c.osrc && lib.ip2int(c.osrc) != null) {
			locals ??= local_ips();
			if (!locals[c.osrc])
				src = c.osrc;
		}
		if (src == null)
			return;
		let a = acc[src];
		if (!a)
			a = acc[src] = [ 0, 0, 0, 0 ];
		a[0] += c.rbytes;
		a[1] += c.obytes;
		// Both directions: the split answers how much of this device's
		// traffic was TCP, which is not a question about direction.
		if (c.proto == 'tcp')
			a[2] += c.obytes + c.rbytes;
		else if (c.proto == 'udp')
			a[3] += c.obytes + c.rbytes;
	});

	return map(sorted_ips(acc), (ip) => ({
		ip, bytes_in: acc[ip][0], bytes_out: acc[ip][1], bytes_tcp: acc[ip][2],
		bytes_udp: acc[ip][3], src: 'ct', degraded: !!degraded
	}));
}

// ── nft counter maps (flow offload) ─────────────────────────────────────────
//
// Hooked at forward priority -200, ahead of the flowtable at -150, so they
// keep counting where conntrack freezes; hence degraded is always false here,
// and when this path is unavailable bytes() says degraded instead of quietly
// handing back frozen numbers.
//
// Direction, as in bytes_ct() and docs/API.md:
//   bytes_in  = toward the device (download), keyed by ip daddr
//   bytes_out = from the device (upload),    keyed by ip saddr

function mon_setup() {
	// The gate matches the current rule orientation, not just "a rule
	// exists": until 1.13.x the maps were keyed the other way round, and a
	// looser check would leave those inverted rules in place for good.
	for (let l in lib.lines('nft list chain inet trafficctl_mon mon_forward')) {
		let i = index(l, 'bytes_in');
		if (i >= 0 && index(substr(l, i), 'daddr') >= 0)
			return;
	}
	// Drop the old table rather than append to it: the previous pair of
	// rules would double-count every packet. That resets the counters once,
	// which costs one speed sample.
	lib.sh('nft delete table inet trafficctl_mon');
	lib.sh('nft add table inet trafficctl_mon');
	lib.sh('nft add map inet trafficctl_mon bytes_in ' + lib.q('{ type ipv4_addr : counter; flags dynamic; }'));
	lib.sh('nft add map inet trafficctl_mon bytes_out ' + lib.q('{ type ipv4_addr : counter; flags dynamic; }'));
	lib.sh('nft add chain inet trafficctl_mon mon_forward ' +
		lib.q('{ type filter hook forward priority -200; policy accept; }'));
	lib.sh('nft add rule inet trafficctl_mon mon_forward ' + lib.q('update @bytes_in { ip daddr counter }'));
	lib.sh('nft add rule inet trafficctl_mon mon_forward ' + lib.q('update @bytes_out { ip saddr counter }'));
}

function add_bytes(m, ip, b) {
	if (type(ip) != 'string' || !lib.valid_ip(ip) || type(b) != 'int')
		return false;
	m[ip] = (m[ip] ?? 0) + b;
	return true;
}

// nft -j: an element is [ key, value ] in a map and the key alone in a set; a
// key carrying a counter is { elem: { val, counter } }. nftables 1.0.2 puts
// the counter in the value ([ key, { counter } ]), 1.1.6 in the key
// ({ elem: { val, counter } }); taken whichever side holds it. False, for the
// text listing to try, when no element was understood: a shape of a later
// nftables must not read as an empty map.
function map_json(text, m) {
	let j;
	try {
		j = json(text);
	}
	catch (e) {
		return false;
	}
	if (type(j?.nftables) != 'array')
		return false;
	let seen = 0, read = 0;
	for (let o in j.nftables) {
		let elems = o?.map?.elem ?? o?.set?.elem;
		for (let e in (type(elems) == 'array') ? elems : []) {
			seen++;
			let pair = (type(e) == 'array');
			let k = pair ? e[0] : e, v = pair ? e[1] : null;
			// No ?. chain across ??: ucode 25.12 lets a null in the first
			// operand short-circuit the whole expression.
			let ke = (type(k) == 'object') ? k.elem : null;
			let ve = (type(v) == 'object') ? v : null;
			let c = ke?.counter;
			if (c == null && ve)
				c = ve.counter ?? ve.elem?.counter;
			if (add_bytes(m, (type(k) == 'string') ? k : ke?.val, c?.bytes))
				read++;
		}
	}
	return seen == 0 || read > 0;
}

// The text listing, for an nftables built without JSON. Elements can share a
// line ("elements = { a : counter packets 1 bytes 2, b : ... }"), so it is cut
// at the separators first.
function map_text(text, m) {
	for (let el in split(text, /[{},\n]/)) {
		let f = split(trim(el), /[ \t]+/), ip = null, b = null;
		for (let i = 0; i < length(f); i++) {
			if (lib.valid_ip(f[i]))
				ip = f[i];
			else if (f[i] == 'bytes' && i + 1 < length(f))
				b = count(f[i + 1]);
		}
		if (ip != null && b != null)
			add_bytes(m, ip, b);
	}
}

// { ip: bytes }, or null when the map does not exist: kernels without dynamic
// counter maps refuse to create it ("Not supported").
function mon_map(name) {
	let m = {};
	let j = lib.run('nft -j list map inet trafficctl_mon ' + lib.q(name));
	if (j != '' && map_json(j, m))
		return m;
	let t = lib.run('nft list map inet trafficctl_mon ' + lib.q(name));
	if (t == '')
		return null;
	map_text(t, m);
	return m;
}

function force_ct() {
	return (getenv('TCTL_FORCE_CONNTRACK') ?? '') != '';
}

function bytes_nft(mode) {
	if (lib.sh('command -v nft') != 0)
		return [];
	mon_setup();
	let bin = mon_map('bytes_in');
	// Without the maps every rule fails and this would return [] for good:
	// per-device speed would just stop. Conntrack instead, flagged.
	if (bin == null)
		return bytes_ct(uncountered(mode ?? offload_mode()));
	let bout = mon_map('bytes_out') ?? {}, all = {};
	for (let ip in bin)
		all[ip] = true;
	for (let ip in bout)
		all[ip] = true;
	return map(sorted_ips(all), (ip) => ({
		ip, bytes_in: bin[ip] ?? 0, bytes_out: bout[ip] ?? 0, bytes_tcp: -1,
		bytes_udp: -1, src: 'nft', degraded: false
	}));
}

// Offload without counter sync bypasses the conntrack counters for fast-path
// packets, so those modes read the nft maps. TCTL_FORCE_CONNTRACK keeps
// conntrack; the numbers are then not just imprecise but frozen for every
// offloaded flow, and a total built from them would stall while looking
// authoritative, hence degraded.
function bytes() {
	let mode = offload_mode();
	if (uncountered(mode) && !force_ct())
		return bytes_nft(mode);
	return bytes_ct(uncountered(mode));
}

// ── lifetime totals ─────────────────────────────────────────────────────────
//
// Neither byte source is a lifetime total (issue #26): conntrack forgets a
// flow's bytes when it expires, and the nft maps restart with their table. So
// positive deltas are accumulated here, the one store behind both the LuCI
// Bytes/TCP/UDP columns and trafficctl_device_bytes_total.
//
// The store is tmpfs, rewritten on every poll and scrape: totals reset on
// reboot, and flash is not worn. One line per device, in the shell's format,
// which the shell writer (still running during an upgrade) and 1.30.x (after
// a downgrade) read too:
//   ip rx_acc tx_acc rx_last tx_last seen tcp_acc udp_acc tcp_last udp_last
//   src since degraded
// Shorter lines from older versions still load: 5 or 6 fields (the exporter's
// own store before this one), 10 (protocol split), 12 (source and start).
//
// Output: the bytes() array plus bytes_in_total, bytes_out_total,
// bytes_tcp_total, bytes_udp_total (-1 while the source cannot split by
// protocol), total_since and live. With all, also devices no longer sampled
// that carry a total, so a Prometheus series does not vanish whenever a quiet
// device's last flow expires; their current readings are -1.
//
// degraded is sticky per device: a total that took in one frozen sample stays
// understated for the rest of its life, so a later healthy sample must not
// re-present it as trustworthy.

const TOTALS_STATE = '/tmp/trafficctl_totals.state';
// The shell's lock directory, held the shell's way (an empty directory) so
// either writer can take it over from the other.
const TOTALS_LOCK = '/tmp/trafficctl_totals.lock.d';
// The shell waited 30 x 100 ms, then took the lock regardless.
const TOTALS_LOCK_TRIES = 30;
const TOTALS_LOCK_STALE = 3;

// What awk's "$n + 0" gave for the shell's numbers.
function snum(s) {
	let n = int(s);
	return (n == n) ? n : 0;
}

function totals_load(now) {
	let st = {};
	for (let l in lib.file_lines(TOTALS_STATE)) {
		let f = split(trim(l), /[ \t]+/), n = length(f);
		if (n < 5)
			continue;
		// Field by field, as awk did: a later line for the same address
		// overwrites what it carries and keeps the rest.
		let r = st[f[0]];
		if (!r)
			r = st[f[0]] = { tca: 0, uda: 0 };
		r.rxa = snum(f[1]);
		r.txa = snum(f[2]);
		r.rxl = snum(f[3]);
		r.txl = snum(f[4]);
		r.seen = (n >= 6) ? snum(f[5]) : now;
		if (n >= 10) {
			r.tca = snum(f[6]);
			r.uda = snum(f[7]);
			r.tcl = snum(f[8]);
			r.udl = snum(f[9]);
		}
		else {
			r.tcl = -1;
			r.udl = -1;
		}
		r.src = (n >= 11) ? f[10] : '?';
		r.since = (n >= 12) ? snum(f[11]) : now;
		r.deg = (n >= 13 && f[12] == 'true');
	}
	return st;
}

// A sample reading: -1 for missing or not a count, as the shell's num().
function reading(v) {
	return (type(v) == 'int' && v >= 0) ? v : -1;
}

// One protocol counter: [ acc, last ] after reading v.
function proto_step(acc, last, v, switched) {
	if (v < 0)
		// Gone unavailable (offload turned on): forget the baseline, or hours
		// of frozen counter land as one fake delta when it returns.
		return [ acc, -1 ];
	if (!switched)
		acc += (last < 0) ? v : (v > last) ? v - last : 0;
	return [ acc, v ];
}

function totals_apply(st, sample, now) {
	let live = {};
	for (let e in sample) {
		let ip = e?.ip;
		if (type(ip) != 'string' || ip == '')
			continue;
		let rx = reading(e.bytes_in), tx = reading(e.bytes_out);
		let tcv = reading(e.bytes_tcp), udv = reading(e.bytes_udp);
		let s = (type(e.src) == 'string' && e.src != '') ? e.src : '?';
		if (rx < 0)
			rx = 0;
		if (tx < 0)
			tx = 0;

		let r = st[ip], known = (r != null);
		// A source switch swaps "bytes of live flows" for "bytes since the
		// table was built", or back: the jump is not traffic, so this tick
		// only takes a new baseline. Trust (degraded) is no part of it:
		// conntrack counters are continuous across a change in trust.
		let switched = known && r.src != '?' && s != '?' && r.src != s;
		if (!known)
			r = st[ip] = { rxa: 0, txa: 0, tca: 0, uda: 0, tcl: -1, udl: -1, deg: false };

		if (known && !switched) {
			// Only upward movement is traffic. A drop means flows expired,
			// and their bytes were counted while they lived.
			if (rx > r.rxl)
				r.rxa += rx - r.rxl;
			if (tx > r.txl)
				r.txa += tx - r.txl;
		}
		else if (!switched) {
			// No baseline yet: the sample is the starting point.
			r.rxa += rx;
			r.txa += tx;
			r.since = now;
		}
		r.rxl = rx;
		r.txl = tx;
		let t = proto_step(r.tca, r.tcl, tcv, switched);
		r.tca = t[0];
		r.tcl = t[1];
		t = proto_step(r.uda, r.udl, udv, switched);
		r.uda = t[0];
		r.udl = t[1];

		r.src = s;
		if (e.degraded === true)
			r.deg = true;
		r.seen = now;
		r.cur = [ rx, tx, tcv, udv ];
		live[ip] = true;
	}
	return live;
}

function totals_text(st, ips, live) {
	let text = '';
	for (let ip in ips) {
		let r = st[ip];
		// A quiet device without a total goes, or the file grows without
		// bound on a busy network.
		if (!live[ip] && r.rxa + r.txa + r.tca + r.uda == 0)
			continue;
		text += sprintf('%s %d %d %d %d %d %d %d %d %d %s %d %s\n', ip, r.rxa, r.txa,
			r.rxl, r.txl, r.seen, r.tca, r.uda, r.tcl, r.udl, r.src,
			r.since, r.deg ? 'true' : 'false');
	}
	return text;
}

function totals(all, sample) {
	// Sampled before the lock: reading conntrack is by far the slowest part,
	// and holding the lock across it would queue every poll behind it (two
	// browser tabs would then hit the steal path, which is for a killed
	// writer, not for load).
	// A failed sample is an empty one, as the shell's empty pipe was: the
	// stored devices still print under --all, and nothing is accumulated.
	if (sample == null) {
		try {
			sample = bytes();
		}
		catch (e) {
			warn(sprintf('trafficctl totals: no sample: %s\n', e.message));
			sample = [];
		}
	}

	// Without the lock a LuCI poll and a metrics scrape landing together
	// read the same state, and the later writer drops the earlier delta. Not
	// getting it within the shell's wait means a killed holder: carry on, as
	// the shell did, rather than stop accumulating.
	let locked = lib.lock(TOTALS_LOCK, TOTALS_LOCK_TRIES, TOTALS_LOCK_STALE, true);
	let now = time(), st, live, ips;
	// Released on an exception too: a bare lock has no pid for the next
	// writer to find dead, so a leak would cost every caller the full wait
	// for TOTALS_LOCK_STALE.
	try {
		st = totals_load(now);
		live = totals_apply(st, sample, now);
		ips = sorted_ips(st);
		lib.write_atomic(TOTALS_STATE, totals_text(st, ips, live));
	}
	catch (e) {
		if (locked)
			lib.unlock(TOTALS_LOCK);
		die(e.message);
	}
	if (locked)
		lib.unlock(TOTALS_LOCK);

	let out = [];
	for (let ip in ips) {
		let r = st[ip], on = !!live[ip];
		if (!on && !all)
			continue;
		// No current reading for a device absent from this sample: its last
		// one would be a frozen number that looks live.
		let c = on ? r.cur : [ -1, -1, -1, -1 ];
		push(out, {
			ip, bytes_in: c[0], bytes_out: c[1], bytes_tcp: c[2], bytes_udp: c[3],
			src: r.src, degraded: r.deg,
			bytes_in_total: r.rxa, bytes_out_total: r.txa,
			// -1, never 0, without a protocol baseline: 0 would claim the
			// device sent no TCP. Keyed off the stored baseline, so a quiet
			// device under --all keeps the history it has.
			bytes_tcp_total: (r.tcl >= 0) ? r.tca : -1,
			bytes_udp_total: (r.udl >= 0) ? r.uda : -1,
			total_since: r.since, live: on
		});
	}
	return out;
}

// 2022-12 needs a ';' after `export function f() {}`; one list avoids it.
export { lan_subnets, lan_devices, lan_device, routed_subnets,
	monitored_subnets, subnets, ifaces, rdns, rdns_refresh, offload_mode, ct_each,
	bytes, bytes_nft, totals, reset };
