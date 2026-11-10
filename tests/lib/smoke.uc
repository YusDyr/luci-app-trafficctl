'use strict';
// Throwaway stand-in for net.uc so the harness has one real case before any
// backend module exists: trafficctl-subnets.sh, rewritten against the uci and
// ubus modules and the TCTL_ROOT / TCTL_UBUS_SOCKET seams. Replaced in PR2.

let uci = require('uci');
let ubus = require('ubus');
let fs = require('fs');

let root = getenv('TCTL_ROOT') ?? '';

function words(v) {
	return type(v) == 'array' ? v : split(trim(v ?? ''), /[ \t]+/);
}

function ip2int(a) {
	let o = iptoarr(a);
	return (length(o) == 4) ? ((o[0] << 24) | (o[1] << 16) | (o[2] << 8) | o[3]) : null;
}

function spec(dev, cidr, router) {
	let p = split(cidr, '/'), ip = ip2int(p[0]), mask = int(p[1] ?? 32);
	if (ip == null || mask < 1 || mask > 32)
		return null;
	let block = 1 << (32 - mask);
	return { dev, base: ip - ip % block, block, mask, router };
}

function subnets() {
	let cur = uci.cursor(root + '/etc/config', root + '/tmp/.uci');
	let conn = ubus.connect(getenv('TCTL_UBUS_SOCKET'));
	let out = [], devs = [];

	cur.foreach('firewall', 'zone', (z) => {
		if (z.name == 'wan' || z.name == 'wan6' || (z.name != 'lan' && z.masq == '1'))
			return;
		for (let net in words(z.network)) {
			let st = conn?.call('network.interface.' + net, 'status', {});
			let a = st?.['ipv4-address']?.[0];
			let s = (st?.l3_device && a) ? spec(st.l3_device, a.address + '/' + a.mask, ip2int(a.address)) : null;
			if (s)
				push(out, s);
		}
	});

	for (let s in out)
		if (index(devs, s.dev) < 0)
			push(devs, s.dev);

	if (length(devs)) {
		let p = fs.popen('ip route show 2>/dev/null');
		for (let line = p.read('line'); length(line); line = p.read('line')) {
			let f = split(trim(line), /[ \t]+/), dev = null;
			if (f[0] == 'default' || index(f, 'via') < 0)
				continue;
			for (let i = 0; i < length(f) - 1; i++)
				if (f[i] == 'dev')
					dev = f[i + 1];
			let s = (index(devs, dev) >= 0) ? spec(dev, f[0], 0) : null;
			if (s)
				push(out, s);
		}
		p.close();
	}

	let lan = cur.get('network', 'lan', 'device') ?? cur.get('network', 'lan', 'ifname') ?? 'br-lan';
	for (let c in words(cur.get('trafficctl', 'main', 'extra_subnets'))) {
		let s = length(c) ? spec(lan, c, 0) : null;
		if (s)
			push(out, s);
	}

	let seen = {}, res = [];
	for (let s in out) {
		let k = s.base + ':' + s.block;
		if (seen[k])
			continue;
		seen[k] = true;
		push(res, { cidr: arrtoip([(s.base >> 24) & 255, (s.base >> 16) & 255, (s.base >> 8) & 255, s.base & 255]) + '/' + s.mask,
		            device: s.dev, kind: s.router ? 'lan' : 'routed' });
	}
	return res;
}

return { subnets };
