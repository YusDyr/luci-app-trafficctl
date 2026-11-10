// SPDX-License-Identifier: Apache-2.0
'use strict';

// trafficctl.lib: what every backend module and the CLI share.
// Written for ucode 2022-12-02 (OpenWrt 22.03) and later; see the
// limitations list in the repository before using a newer builtin.
//
//   import * as lib from 'trafficctl.lib';
//
// Paths. Every file helper below takes the path as it is on the router and
// prefixes ROOT itself; use path() for anything else.
//   ROOT                          getenv('TCTL_ROOT'), '' on a router (tests only)
//   path(p)                       ROOT + p
//   pid()                         this process id (no getpid() in 2022-12)
// uci and ubus
//   cursor()                      shared uci cursor, confdir/savedir under ROOT
//   uci_get(conf, sect, opt)      value as a string, a list joined by ' ', or null
//   uci_words(conf, sect, opt)    value split on whitespace, [] when unset
//   uci_foreach(conf, stype, fn)  cursor().foreach; fn returning false stops
//   commit(conf)                  commit; trafficctl's file goes back to 0600
//   ubus_call(obj, method, args)  reply, or null on any failure
//                                 (socket: getenv('TCTL_UBUS_SOCKET'))
// External commands. Interpolate every value through q(); nothing else may
// call popen() or system() (tests/test_security.sh enforces this).
//   q(s)                          single-quoted for /bin/sh
//   run(cmd, ms)                  stdout as a string, stderr dropped;
//                                 with ms, cmd is one program, killed after ms
//   lines(cmd, ms)                run() split into lines
//   sh(cmd, ms)                   exit status, all output dropped
// JSON
//   to_json(v)                    compact: no spaces, keys in insertion
//                                 order, integers only, '/' not escaped
// Validation and addresses (the semantics of trafficctl-fw.sh)
//   valid_ip(s)                   dotted quad, octets 0..255
//   valid_int(s, min, max)        digits only, in range: the int, else null
//   norm_mac(s)                   lower-case aa:bb:cc:dd:ee:ff, else null
//   valid_target(t)               host, CIDR /0..32 or all/any, else null
//   cidr_spec(s)                  { base, block, mask } for a.b.c.d[/1..32]
//   ip2int(s), int2ip(n)
// Files
//   readfile(p)                   contents, or null
//   file_lines(p)                 lines without the final empty one, [] if none
//   is_file(p)
//   mkdir_p(dir)
//   write_atomic(p, data, mode)   temp file in the same directory + rename
//   lock(dir, tries, max_age)     mkdir lock: tries x 100 ms, then steal;
//                                 tries 0 = one attempt, no steal; a lock
//                                 older than max_age seconds is stale
//   unlock(dir)
//   field(line, n)                awk's $(n+1)
// Activity log
//   log(action, target, detail, via, src)   port of tctl_log
// Stores (same formats as the shell backend)
//   names_list(), names_map(), names_set(ip, name), names_remove(ip),
//   sanitize_name(s)              /etc/trafficctl/names, "IP NAME" lines
//   seen_known(mac), seen_ready(), seen_count(), seen_mark(mac), seen_seed()
//                                 /etc/trafficctl/seen_macs, one MAC a line

import { popen, readfile as fs_readfile, writefile, open, stat, mkdir, rmdir,
	unlink, rename, chmod, readlink, dirname } from 'fs';
import * as ucimod from 'uci';
import * as ubusmod from 'ubus';

export const ROOT = getenv('TCTL_ROOT') ?? '';

function path(p) {
	return ROOT + p;
}

let my_pid;
function pid() {
	my_pid ??= readlink('/proc/self') ?? sprintf('%d', time());
	return my_pid;
}

// ── uci / ubus ──────────────────────────────────────────────────────────────

let cur;
function cursor() {
	// Passed only under a test root, so a router uses libuci's own defaults.
	cur ??= (ROOT != '')
		? ucimod.cursor(ROOT + '/etc/config', ROOT + '/tmp/.uci')
		: ucimod.cursor();
	return cur;
}

function uci_get(conf, sect, opt) {
	let v = cursor().get(conf, sect, opt);
	if (v == null) {
		// 2022-12 never clears the last error by itself.
		ucimod.error();
		return null;
	}
	return (type(v) == 'array') ? join(' ', v) : '' + v;
}

function uci_words(conf, sect, opt) {
	let v = uci_get(conf, sect, opt);
	return (v == null) ? [] : filter(split(v, /[ \t\n]+/), (w) => w != '');
}

function uci_foreach(conf, stype, fn) {
	if (!cursor().foreach(conf, stype, fn))
		ucimod.error();
}

function commit(conf) {
	// commit() without a name was broken before 2023-04.
	if (!cursor().commit(conf)) {
		ucimod.error();
		return false;
	}
	// The file holds the bot and metrics tokens; uci rewrites it 0644.
	if (conf == 'trafficctl')
		chmod(path('/etc/config/trafficctl'), 0o600);
	return true;
}

let bus;
function ubus_call(obj, method, args) {
	bus ??= ubusmod.connect(getenv('TCTL_UBUS_SOCKET')) ?? false;
	if (!bus) {
		ubusmod.error();
		return null;
	}
	let r = bus.call(obj, method, args ?? {});
	if (r == null)
		ubusmod.error();
	return r;
}

// ── external commands ───────────────────────────────────────────────────────

function q(s) {
	return "'" + replace('' + s, "'", "'\\''") + "'";
}

function run(cmd, ms) {
	if (ms) {
		// system() is the only call with a timeout; exec so the kill reaches
		// the program and not just the shell, and redirect so its output
		// cannot land in ours.
		let tmp = path('/tmp/.trafficctl_run.' + pid());
		system('exec ' + cmd + ' >' + q(tmp) + ' 2>/dev/null', ms);
		let out = fs_readfile(tmp);
		unlink(tmp);
		return out ?? '';
	}
	let p = popen('{ ' + cmd + '\n} 2>/dev/null');
	if (!p)
		return '';
	let out = p.read('all');
	p.close();
	return out ?? '';
}

function lines(cmd, ms) {
	let l = split(run(cmd, ms), '\n');
	if (l[-1] == '')
		pop(l);
	return l;
}

function sh(cmd, ms) {
	if (ms)
		return system('exec ' + cmd + ' >/dev/null 2>&1', ms);
	return system('{ ' + cmd + '\n} >/dev/null 2>&1');
}

// ── JSON ────────────────────────────────────────────────────────────────────
// The shell backend's byte format, which tests and shell readers depend on:
// sprintf('%J') puts a space after ':' and escapes '/'.

const ESC = { '"': '\\"', '\\': '\\\\', '\n': '\\n', '\r': '\\r', '\t': '\\t',
	'\b': '\\b', '\f': '\\f' };

function jstr(s) {
	if (!match(s, /[\x01-\x1f"\\]/))
		return '"' + s + '"';
	return '"' + replace(s, /[\x01-\x1f"\\]/g,
		(c) => ESC[c] ?? sprintf('\\u%04x', ord(c))) + '"';
}

function to_json(v) {
	switch (type(v)) {
	case 'string':
		return jstr(v);
	case 'int':
		return sprintf('%d', v);
	case 'double':
		// Doubles print differently across ucode versions; never emit one.
		v = int(v);
		return (v == v) ? sprintf('%d', v) : '0';
	case 'bool':
		return v ? 'true' : 'false';
	case 'array':
		return '[' + join(',', map(v, to_json)) + ']';
	case 'object':
		return '{' + join(',', map(keys(v), (k) => jstr(k) + ':' + to_json(v[k]))) + '}';
	default:
		return 'null';
	}
}

// ── validation and addresses ────────────────────────────────────────────────

function valid_ip(s) {
	let m = (type(s) == 'string')
		? match(s, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$/) : null;
	if (!m)
		return false;
	for (let i = 1; i <= 4; i++)
		if (int(m[i]) > 255)
			return false;
	return true;
}

function valid_int(s, min, max) {
	if (type(s) == 'int')
		s = '' + s;
	if (type(s) != 'string' || !match(s, /^[0-9]+$/))
		return null;
	let n = int(s);
	if (n != n || (min != null && n < min) || (max != null && n > max))
		return null;
	return n;
}

function norm_mac(s) {
	s = lc('' + (s ?? ''));
	return match(s, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) ? s : null;
}

function ip2int(s) {
	let a = iptoarr(s);
	return (a && length(a) == 4) ? (a[0] << 24) + (a[1] << 16) + (a[2] << 8) + a[3] : null;
}

function int2ip(n) {
	return sprintf('%d.%d.%d.%d', (n >> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255);
}

// tctl_cidr_spec: normalised to the network base, mask 1..32, bare host /32.
function cidr_spec(s) {
	let p = split('' + s, '/');
	if (length(p) > 2 || !valid_ip(p[0]))
		return null;
	let mask = (length(p) == 2) ? valid_int(p[1], 1, 32) : 32;
	if (mask == null)
		return null;
	let ipint = ip2int(p[0]), block = 1 << (32 - mask);
	return { base: ipint - ipint % block, block, mask };
}

// tctl_validate_target: the normalised target, or null.
function valid_target(t) {
	if (t == 'all' || t == 'any')
		return '0.0.0.0/0';
	let p = split('' + t, '/');
	if (length(p) == 1)
		return valid_ip(p[0]) ? p[0] : null;
	if (length(p) != 2 || !valid_ip(p[0]) || valid_int(p[1], 0, 32) == null)
		return null;
	return t;
}

// ── files ───────────────────────────────────────────────────────────────────

function readfile(p) {
	return fs_readfile(path(p));
}

function file_lines(p) {
	let l = split(readfile(p) ?? '', '\n');
	if (l[-1] == '')
		pop(l);
	return l;
}

function is_file(p) {
	return stat(path(p))?.type == 'file';
}

function mkdir_p(dir) {
	let p = path(dir);
	if (stat(p)?.type == 'directory')
		return true;
	let parent = dirname(dir);
	if (parent != dir && parent != '/' && parent != '.')
		mkdir_p(parent);
	return !!mkdir(p) || stat(p)?.type == 'directory';
}

function write_atomic(p, data, mode) {
	// Same directory, so the rename is atomic even on a network mount.
	let dst = path(p), tmp = dst + '.tmp.' + pid();
	let f = open(tmp, 'w');
	if (!f)
		return false;
	let ok = f.write(data) != null;
	f.close();
	if (ok && mode != null)
		chmod(tmp, mode);
	if (!ok || !rename(tmp, dst)) {
		unlink(tmp);
		return false;
	}
	return true;
}

function lock(dir, tries, max_age) {
	let p = path(dir), n = (tries > 0) ? tries : 1;
	for (let i = 0; i < n; i++) {
		if (i)
			sleep(100);
		if (mkdir(p))
			return true;
		// No signal() before 2023-07: a killed holder never cleans up.
		let st = max_age ? stat(p) : null;
		if (st && time() - st.mtime >= max_age) {
			rmdir(p);
			if (mkdir(p))
				return true;
		}
	}
	if (!(tries > 0))
		return false;
	rmdir(p);
	return !!mkdir(p);
}

function unlock(dir) {
	rmdir(path(dir));
}

function field(l, n) {
	return split(ltrim(l, ' \t'), /[ \t]+/)[n] ?? '';
}

function append(p, data) {
	let f = open(path(p), 'a');
	if (!f)
		return false;
	f.write(data);
	f.close();
	return true;
}

// ── activity log (tctl_log) ─────────────────────────────────────────────────

const LOG_DEFAULT = '/tmp/trafficctl/activity.log';

// Writable through the LuCI write ACL and used as an append and a rewrite
// target, so only dedicated log locations with plain characters are taken.
function valid_log_file(f) {
	return type(f) == 'string' && !!match(f, /^\/(tmp\/trafficctl|var\/log)\//) &&
		!match(f, /(\/\.\.\/|\/\.\.$|\/$)/) && !!match(f, /^[A-Za-z0-9._\/-]+$/);
}

function log_max_lines() {
	let n = uci_get('trafficctl', 'logging', 'max_lines');
	if (n == null || !match(n, /^[0-9]+$/))
		return 500;
	n = int(n);
	// Past int64 the shell's test(1) fails, which it read as "below 20".
	return (n != n || n < 20) ? 20 : (n > 100000) ? 100000 : n;
}

function category(action) {
	if (match(action, /^(block|unblock|cut|uncut)$/))
		return 'blocks';
	for (let c in [ 'ratelimit', 'shape', 'telegram' ])
		if (substr(action, 0, length(c)) == c)
			return (c == 'ratelimit') ? 'ratelimits' : (c == 'shape') ? 'shapes' : c;
	return 'config';
}

function env_or(name, dflt) {
	let v = getenv(name);
	return (v == null || v == '') ? dflt : v;
}

function log(action, target, detail, via, src) {
	if (uci_get('trafficctl', 'logging', 'enabled') != '1')
		return;
	if (uci_get('trafficctl', 'logging', 'log_' + category(action)) == '0')
		return;

	let t = localtime();
	let ts = sprintf('%04d-%02d-%02d %02d:%02d:%02d', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
	let user = env_or('TCTL_USER', null) ?? (trim(run('id -un')) || 'unknown');
	let file = uci_get('trafficctl', 'logging', 'log_file');
	if (!file || !valid_log_file(file))
		file = LOG_DEFAULT;
	let max = log_max_lines();
	let msg = sprintf('%s src=%s user=%s via=%s action=%s target=%s%s', ts,
		(src == null || src == '') ? 'local' : src, user,
		(via == null || via == '') ? 'cli' : via, action, target ?? '',
		(detail != null && detail != '') ? ' detail=' + detail : '');

	mkdir_p(dirname(file));
	append(file, '[trafficctl] ' + msg + '\n');

	let l = file_lines(file);
	if (length(l) > max)
		write_atomic(file, join('\n', slice(l, -int(max * 3 / 5))) + '\n');

	if (uci_get('trafficctl', 'logging', 'syslog') == '1')
		sh('logger -t trafficctl ' + q(msg));
}

// ── names store ─────────────────────────────────────────────────────────────

const NAMES = '/etc/trafficctl/names';

// Nothing that could break the line format or the JSON, and short enough
// not to bloat every poll.
function sanitize_name(s) {
	return substr(replace('' + (s ?? ''), /[^a-zA-Z0-9 _.()-]/g, ''), 0, 32);
}

function names_list() {
	let out = [];
	for (let l in file_lines(NAMES)) {
		let ip = field(l, 0);
		if (ip == '' || field(l, 1) == '')
			continue;
		push(out, { ip, name: replace(l, /^[^ ]+ +/, '') });
	}
	return out;
}

function names_map() {
	let m = {};
	for (let e in names_list())
		if (!exists(m, e.ip))
			m[e.ip] = e.name;
	return m;
}

function names_without(ip) {
	return filter(file_lines(NAMES), (l) => field(l, 0) != ip);
}

function names_set(ip, name) {
	if (!valid_ip(ip))
		return { ok: false, msg: 'invalid IP address' };
	name = sanitize_name(name);
	if (name == '')
		return { ok: false, msg: 'name is empty after sanitizing' };
	mkdir_p(dirname(NAMES));
	let l = names_without(ip);
	push(l, ip + ' ' + name);
	write_atomic(NAMES, join('\n', l) + '\n');
	log('config_change', ip, 'name=' + name, getenv('TCTL_VIA'), getenv('TCTL_SRC'));
	return { ok: true, msg: sprintf('named %s as %s', ip, name) };
}

function names_remove(ip) {
	if (!valid_ip(ip))
		return { ok: false, msg: 'invalid IP address' };
	if (!is_file(NAMES))
		return { ok: true, msg: 'no aliases stored' };
	let l = names_without(ip);
	write_atomic(NAMES, length(l) ? join('\n', l) + '\n' : '');
	log('config_change', ip, 'name cleared', getenv('TCTL_VIA'), getenv('TCTL_SRC'));
	return { ok: true, msg: sprintf('name cleared for %s', ip) };
}

// ── new-device ledger ───────────────────────────────────────────────────────
// Wrongly calling a device new applies an unasked-for default limit, so every
// ambiguous case answers "known".

const SEEN = '/etc/trafficctl/seen_macs';
const SEEN_MAX = 1000;

function seen_ready() {
	return is_file(SEEN);
}

function seen_count() {
	return length(file_lines(SEEN));
}

function seen_known(mac) {
	mac = lc('' + (mac ?? ''));
	if (mac == '' || !is_file(SEEN))
		return true;
	return index(file_lines(SEEN), mac) >= 0;
}

function seen_mark(mac) {
	mac = lc('' + (mac ?? ''));
	// Not seen_known() alone: it says "known" for a missing ledger.
	if (mac == '' || (is_file(SEEN) && seen_known(mac)))
		return;
	mkdir_p(dirname(SEEN));
	append(SEEN, mac + '\n');
	let l = file_lines(SEEN);
	if (length(l) > SEEN_MAX)
		write_atomic(SEEN, join('\n', slice(l, -int(SEEN_MAX * 4 / 5))) + '\n');
}

// Baseline from the devices already on the network, so switching the
// default limit on does not declare the existing LAN new.
function seen_seed() {
	if (is_file(SEEN))
		return;
	mkdir_p(dirname(SEEN));
	let macs = map(file_lines('/tmp/dhcp.leases'), (l) => field(l, 1));
	for (let l in lines('ip neigh show'))
		if (index(l, 'lladdr') >= 0)
			push(macs, field(l, 4));
	macs = sort(uniq(filter(map(macs, lc), (m) => !!match(m, /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/))));
	write_atomic(SEEN, length(macs) ? join('\n', macs) + '\n' : '');
}

// 2022-12 needs a ';' after `export function f() {}`; one list avoids it.
export { path, pid, cursor, uci_get, uci_words, uci_foreach, commit,
	ubus_call, q, run, lines, sh, to_json, valid_ip, valid_int, norm_mac, ip2int,
	int2ip, cidr_spec, valid_target, readfile, file_lines, is_file, mkdir_p,
	write_atomic, lock, unlock, field, valid_log_file, log, sanitize_name,
	names_list, names_map, names_set, names_remove, seen_ready, seen_count,
	seen_known, seen_mark, seen_seed };
