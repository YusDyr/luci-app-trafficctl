'use strict';
// Publishes recorded replies on a private ubusd, so the code under test meets
// real ubus semantics: unknown objects fail, undeclared arguments are refused.
//
// Usage: ucode -S ubus-mock.uc <socket> <dir> [log]
//   <dir>/<object>@<method>.json  reply for that call (missing file: no object)
//   [log]                         one line per call: object method args-json

let fs = require('fs');
let ubus = require('ubus');
let uloop = require('uloop');

let sock = ARGV[0], dir = ARGV[1], logpath = ARGV[2];

// ubus refuses any argument a method does not declare, so the mock has to
// declare what the callers send. Keys are "<object>.<method>", "*" = any.
const ARGS = {
	'service.list': { name: '', verbose: true },
	'network.rrdns.lookup': { addrs: [], timeout: 0, limit: 0, server: [] },
	'hostapd.*.del_client': { addr: '', reason: 0, deauth: true, ban_time: 0 },
	'session.info': { ubus_rpc_session: '' },
};

function argspec(obj, method) {
	let wild = match(obj, /^([^.]+)\./);
	return ARGS[obj + '.' + method] ?? (wild ? ARGS[wild[1] + '.*.' + method] : null) ?? {};
}

function log(obj, method, args) {
	if (!logpath)
		return;
	let f = fs.open(logpath, 'a');
	f.write(sprintf('%s %s %J\n', obj, method, args));
	f.close();
}

uloop.init();

let conn = ubus.connect(sock);
if (!conn)
	die(sprintf('ubus-mock: connect %s: %s\n', sock, ubus.error()));

let objects = {};
for (let path in fs.glob(dir + '/*@*.json')) {
	let m = match(fs.basename(path), /^(.+)@([^@]+)\.json$/);
	if (!m)
		continue;
	objects[m[1]] ??= {};
	objects[m[1]][m[2]] = json(fs.readfile(path));
}

let published = [];
for (let obj in objects) {
	let methods = {};
	for (let method in objects[obj]) {
		let reply = objects[obj][method], o = obj, me = method;
		methods[method] = {
			args: argspec(obj, method),
			call: function(req) {
				log(o, me, req.args);
				// procd filters "service list" by name itself.
				if (o == 'service' && me == 'list' && req.args.name)
					return exists(reply, req.args.name) ? { [req.args.name]: reply[req.args.name] } : {};
				return reply;
			}
		};
	}
	let p = conn.publish(obj, methods);
	if (!p)
		die(sprintf('ubus-mock: publish %s: %s\n', obj, ubus.error()));
	push(published, p);
}

// Readiness marker for the shell side: every object is registered.
print('ready\n');
fs.stdout.flush();
uloop.run();
