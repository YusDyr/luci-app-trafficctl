'use strict';
// rpcd-mod-ucode in a test: loads a plugin the way rpcd's ucode.c does and
// calls one method, so the plugin meets rpcd's contract without an rpcd.
//
// Usage: ucode -S -L <lib> rpcd.uc <plugin.uc> list
//        ucode -S -L <lib> rpcd.uc <plugin.uc> call <method>   (args JSON on stdin)
//
// list    prints {method: {arg: "str"|"int"|"bool"|...}} from the signature.
// call    validates the arguments as rpcd's strict policy does (an undeclared
//         argument, a null or another type: INVALID_ARGUMENT; ubus_rpc_session
//         may always come as a string), calls the method, waits for a
//         deferred reply, and prints the reply as compact JSON. A status other
//         than OK goes to stderr as the ubus CLI says it ("Command failed:
//         Invalid argument") and is the exit status.
//
// The plugin's own ubus calls go to TCTL_UBUS_SOCKET, where this process
// publishes rpcd's file.exec (command, params, env; no shell; output over
// 256 KiB: NOT_SUPPORTED; killed after TCTL_RPCD_EXEC_TIMEOUT_MS: TIMEOUT).
// session and the rest come from tests/lib/ubus-mock.uc.
// The command runs synchronously: the plugin's deferred-call timeout fires
// when it is done, before its reply is read, as a real one would have meanwhile.

import { readfile, stdin, unlink, stat, open } from 'fs';
import * as ubus from 'ubus';
import * as uloop from 'uloop';
import * as lib from 'trafficctl.lib';

const STATUS = [ 'Success', 'Invalid command', 'Invalid argument', 'Method not found', 'Not found',
	'No response', 'Permission denied', 'Request timed out', 'Operation not supported',
	'Unknown error', 'Connection failed' ];

const FILE_MAX = 4096 * 64;

function env_ms(name, dflt) {
	return lib.valid_int(getenv(name) ?? '', 1, 3600000) ?? dflt;
}

const EXEC_TIMEOUT_MS = env_ms('TCTL_RPCD_EXEC_TIMEOUT_MS', 120000);

let plugin = ARGV[0], mode = ARGV[1], method = ARGV[2];

// rpcd's parse config (ucode.c): raw mode, block trimming, no strict mode.
let entry = loadfile(plugin, { raw_mode: true, lstrip_blocks: true, trim_blocks: true,
	strict_declarations: false });
let sig = entry();

if (type(sig) != 'object')
	die('rpcd.uc: the plugin returned no signature object\n');

let objname = keys(sig)[0], methods = sig[objname];
if (length(keys(sig)) != 1 || type(methods) != 'object')
	die('rpcd.uc: the signature must hold exactly one object\n');

for (let m, d in methods)
	if (type(d) != 'object' || index([ 'function', 'cfunction' ], type(d.call)) < 0 ||
	    (d.args != null && type(d.args) != 'object'))
		die(sprintf('rpcd.uc: method %s is not { args, call }\n', m));

// The blobmsg type rpcd's policy gets from a sample value (ucode.c).
function hint_type(v) {
	switch (type(v)) {
	case 'bool': return 'bool';
	case 'int': return (v == 8) ? 'int8' : (v == 16) ? 'int16' : (v == 64) ? 'int64' : 'int32';
	case 'double': return 'double';
	case 'array': return 'array';
	case 'object': return 'table';
	default: return 'string';
	}
}

// The blobmsg type a JSON value arrives as (libubox blobmsg_json).
function value_type(v) {
	switch (type(v)) {
	case 'bool': return 'bool';
	case 'int': return (v >= -2147483648 && v <= 2147483647) ? 'int32' : 'int64';
	case 'double': return 'double';
	case 'array': return 'array';
	case 'object': return 'table';
	case 'string': return 'string';
	default: return 'unspec';
	}
}

const SHORT = { string: 'str', int32: 'int', bool: 'bool' };

if (mode == 'list') {
	let out = {};
	for (let m, d in methods) {
		let a = {};
		for (let k, v in d.args ?? {})
			a[k] = SHORT[hint_type(v)] ?? hint_type(v);
		out[m] = a;
	}
	print(lib.to_json(out), '\n');
	exit(0);
}

if (mode != 'call')
	die('usage: rpcd.uc <plugin> list | call <method>\n');

function finish(code, data) {
	if (data != null)
		print(lib.to_json(data), '\n');
	if (code != 0)
		warn(sprintf('Command failed: %s\n', STATUS[code] ?? 'Unknown error'));
	exit(code);
}

let args = null;
try {
	let raw = stdin.read('all') ?? '';
	args = length(trim(raw)) ? json(raw) : {};
}
catch (e) {
	args = null;
}
if (type(args) != 'object')
	finish(2);

if (!exists(methods, method))
	finish(3);

let policy = methods[method].args ?? {};
for (let k, v in args) {
	if (k == 'ubus_rpc_session' && type(v) == 'string' && !exists(policy, k))
		continue;
	if (!exists(policy, k) || hint_type(policy[k]) != value_type(v))
		finish(2);
}

// ── file.exec ───────────────────────────────────────────────────────────────

function lookup(cmd) {
	if (index(cmd, '/') >= 0)
		return (stat(cmd)?.type == 'file') ? cmd : null;
	for (let d in split(getenv('PATH') ?? '/bin:/usr/bin:/sbin:/usr/sbin', ':'))
		if (stat(d + '/' + cmd)?.type == 'file')
			return d + '/' + cmd;
	return null;
}


// TCTL_RPCD_EXEC_LOG: one line per file.exec call, its arguments as JSON.
function exec_log(a) {
	let p = getenv('TCTL_RPCD_EXEC_LOG');
	if (p == null || p == '')
		return;
	let f = open(p, 'a');
	if (f) {
		f.write(lib.to_json(a) + '\n');
		f.close();
	}
}

function file_exec(req) {
	exec_log(req.args ?? {});
	let a = req.args ?? {}, cmd = (type(a.command) == 'string') ? lookup(a.command) : null;
	if (type(a.command) != 'string')
		return 2;
	if (cmd == null)
		return 4;
	let argv = [ cmd ], env = [];
	for (let p in (type(a.params) == 'array') ? a.params : [])
		if (type(p) == 'string')
			push(argv, p);
	for (let k, v in (type(a.env) == 'object') ? a.env : {})
		if (type(v) == 'string')
			push(env, k + '=' + v);
	let out = '/tmp/.rpcd-uc.out.' + lib.pid(), err = '/tmp/.rpcd-uc.err.' + lib.pid();
	let rc = system('exec >' + lib.q(out) + ' 2>' + lib.q(err) + ' </dev/null; exec env ' +
		lib.qv(env) + ' ' + lib.qv(argv), EXEC_TIMEOUT_MS);
	let so = readfile(out) ?? '', se = readfile(err) ?? '';
	unlink(out);
	unlink(err);
	if (rc < 0)
		return 7;
	if (length(so) >= FILE_MAX || length(se) >= FILE_MAX)
		return 8;
	let r = { code: rc };
	if (length(so))
		r.stdout = so;
	if (length(se))
		r.stderr = se;
	return r;
}

uloop.init();

let conn = ubus.connect(getenv('TCTL_UBUS_SOCKET'));
if (!conn)
	die(sprintf('rpcd.uc: no ubus at %s: %s\n', getenv('TCTL_UBUS_SOCKET'), ubus.error()));
let fileobj = conn.publish('file', {
	exec: { call: file_exec, args: { command: '', params: [], env: {} } },
});
if (!fileobj)
	die(sprintf('rpcd.uc: cannot publish file: %s\n', ubus.error()));

// ── the call ────────────────────────────────────────────────────────────────

let result = { done: false, code: 0, data: null };

function complete(code, data) {
	if (result.done)
		die('Reply has already been sent\n');
	result.done = true;
	result.code = code;
	result.data = data;
	uloop.end();
}

let req = {
	args: args,
	info: { acl: { user: null, group: null, object: null },
		object: { id: 0, name: objname }, method: method },
	reply: function(data, code) {
		if (data != null && type(data) != 'object')
			die('First argument to reply() must be null or an object\n');
		if (code != null && type(code) != 'int')
			die('Second argument to reply() must be null or an integer\n');
		complete(code ?? 0, data);
		return true;
	},
	error: function(code) {
		if (type(code) != 'int')
			die('First argument to error() must be an integer\n');
		complete(code, null);
		return true;
	},
};

let guard = null;

uloop.timer(0, () => {
	let res = null;
	try {
		res = methods[method].call(req);
	}
	catch (e) {
		warn(sprintf("Unhandled ucode exception in '%s' method!\n%s\n", method, e.message));
		if (!result.done)
			complete(9, null);
		return;
	}
	if (type(res) == 'resource' && index(sprintf('%s', res), 'ubus.deferred') >= 0) {
		if (!result.done)
			guard = uloop.timer(EXEC_TIMEOUT_MS, () => {
				if (!result.done)
					complete(7, null);
			});
	}
	else if (type(res) == 'object') {
		if (result.done)
			die('Reply has already been sent\n');
		complete(0, res);
	}
	else if (!result.done)
		complete(5, null);
});

uloop.run();
fileobj.remove();
finish(result.code, result.data);
