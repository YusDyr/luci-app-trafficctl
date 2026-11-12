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
//   reset()                       drop the cached uci cursor and ubus
//                                 connection; a long-running caller (rpcd
//                                 plugin, bot, keepers) calls it, and
//                                 net.reset(), once per request or tick
// uci and ubus
//   cursor()                      shared uci cursor, confdir/savedir under ROOT
//   uci_get(conf, sect, opt)      value as a string, a list joined by ' ', or null
//   uci_words(conf, sect, opt)    value split on whitespace, [] when unset
//   uci_foreach(conf, stype, fn)  cursor().foreach; fn returning false stops
//   commit(conf)                  commit; trafficctl's file goes back to 0600
//   ubus_call(obj, method, args)  reply, or null on any failure; a failed
//                                 connect is retried on the next call
//                                 (socket: getenv('TCTL_UBUS_SOCKET'))
// External commands. Interpolate every value through q(); nothing else may
// call popen() or system() (tests/test_security.sh enforces this).
//   q(s)                          single-quoted for /bin/sh; dies on
//                                 anything but a string or an int
//   qv(argv)                      q() of each element, joined by spaces
//   run(cmd, ms)                  stdout as a string, stderr dropped, no stdin;
//                                 with ms, cmd is one program, killed after ms
//   run_rc(cmd, ms)               run() with a timeout: { out, rc }, rc the
//                                 exit status, -9 when it was killed
//   lines(cmd, ms)                run() split into lines
//   sh(cmd, ms)                   exit status, all output dropped
//   pipe(cmd, input)              run() with input on cmd's stdin, so a
//                                 secret need not be in anybody's argv
//   passthru(argv)                argv[0] run directly (no shell) on our
//                                 stdin/stdout/stderr: its exit status
// JSON
//   to_json(v)                    compact: no spaces, keys in insertion
//                                 order, integers only, '/' not escaped
// Validation and addresses (the semantics of trafficctl-fw.sh). match() and
// replace() stop at a NUL byte, so every check refuses strings holding one.
//   plain(s)                      a string without a NUL byte
//   valid_ip(s)                   dotted quad, octets 0..255, no leading zeros
//   valid_int(s, min, max)        digits only, in range: the int, else null
//   norm_mac(s)                   lower-case aa:bb:cc:dd:ee:ff, else null
//   valid_target(t)               host, CIDR /0..32 or all/any, as ip[/n]
//   cidr_spec(s)                  { base, block, mask } for a.b.c.d[/1..32]
//   ip2int(s), int2ip(n)
// Files
//   readfile(p)                   contents, or null
//   file_lines(p)                 lines without the final empty one, [] if none
//   each_line(p, fn)              fn(line) for every line, read in chunks so a
//                                 large file (conntrack) is never held whole;
//                                 false when p cannot be opened
//   is_file(p)
//   mkdir_p(dir)
//   write_atomic(p, data, mode)   temp file in the same directory + rename;
//                                 mode defaults to the current file's
//   create_once(p, data)          exclusive create + write: true for exactly one
//                                 of several racing callers, false if p exists
//                                 or the write came up short
//   remove(p)                     unlink; false if p was not there
//   lock(dir, tries, max_age, bare)
//                                 mkdir lock holding our pid: tries x 100 ms
//                                 (0 = one attempt). Taken over only when its
//                                 holder is gone or it is max_age seconds old.
//                                 bare: an empty directory, for a lock the
//                                 shell scripts share (they rmdir it); stale
//                                 by age only, ours by its inode. Steals
//                                 take turns under <dir>.steal (a leftover
//                                 older than 10 s is ignored); a steal
//                                 renames the stale directory aside and
//                                 removes it only if it is the inode judged
//                                 stale, anything else goes back unless a
//                                 new lock took the path meanwhile
//   unlock(dir)                   only a lock this process holds
//   field(line, n)                awk's $(n+1)
// Activity log
//   log(action, target, detail, via, src)   port of tctl_log
//   set_context({ via, src, user })   what log() records when its caller
//                                 passes no via/src (and instead of
//                                 TCTL_USER): the rpcd plugin's caller
// Stores (same formats as the shell backend)
//   names_list(), names_map(), names_set(ip, name), names_remove(ip),
//   sanitize_name(s)              /etc/trafficctl/names, "IP NAME" lines
//   seen_known(mac), seen_ready(), seen_count(), seen_mark(mac), seen_seed()
//                                 /etc/trafficctl/seen_macs, one MAC a line

import { popen, readfile as fs_readfile, writefile, open, stat, mkdir, rmdir,
	unlink, rename, chmod, readlink, dirname, basename, lsdir } from 'fs';
import * as ucimod from 'uci';
import * as ubusmod from 'ubus';

export const ROOT = getenv('TCTL_ROOT') ?? '';

function path(p) {
	return ROOT + p;
}

const NUL = chr(0);

function plain(s) {
	return type(s) == 'string' && index(s, NUL) < 0;
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

let bus;
function ubus_call(obj, method, args) {
	bus ??= ubusmod.connect(getenv('TCTL_UBUS_SOCKET'));
	if (!bus) {
		ubusmod.error();
		return null;
	}
	let r = bus.call(obj, method, args ?? {});
	if (r == null)
		ubusmod.error();
	return r;
}

function reset() {
	cur = null;
	bus = null;
}

// ── external commands ───────────────────────────────────────────────────────

function q(s) {
	if (type(s) == 'int')
		s = '' + s;
	// Anything else is a caller bug that '' + s would hide (and replace()
	// would cut the string at a NUL).
	if (!plain(s))
		die('q(): not a string: ' + type(s));
	return "'" + replace(s, "'", "'\\''") + "'";
}

function qv(argv) {
	if (type(argv) != 'array')
		die('qv(): not an array: ' + type(argv));
	return join(' ', map(argv, q));
}

function run(cmd, ms) {
	if (ms) {
		// system() is the only call with a timeout; exec so the kill reaches
		// the program and not just the shell, and redirect so its output
		// cannot land in ours.
		// Redirect first: a redirect after cmd would bind to its last word.
		let tmp = path('/tmp/.trafficctl_run.' + pid());
		unlink(tmp);
		system('exec >' + q(tmp) + ' 2>/dev/null </dev/null; exec ' + cmd, ms);
		let out = fs_readfile(tmp);
		unlink(tmp);
		return out ?? '';
	}
	let p = popen('{ ' + cmd + '\n} 2>/dev/null </dev/null');
	if (!p)
		return '';
	let out = p.read('all');
	p.close();
	return out ?? '';
}

// run() with a timeout and the exit status: the rpcd plugin has to answer
// before rpcd kills it, and has to tell a timeout from an empty reply.
function run_rc(cmd, ms) {
	// Created here and exclusively, as in pipe().
	let tmp = path('/tmp/.trafficctl_run.' + pid());
	unlink(tmp);
	let f = open(tmp, 'wx', 0o600);
	if (!f)
		return { out: '', rc: -1 };
	f.close();
	let rc = system('exec >' + q(tmp) + ' 2>/dev/null </dev/null; exec ' + cmd, ms);
	let out = fs_readfile(tmp);
	unlink(tmp);
	return { out: out ?? '', rc };
}

function lines(cmd, ms) {
	let l = split(run(cmd, ms), '\n');
	if (l[-1] == '')
		pop(l);
	return l;
}

function sh(cmd, ms) {
	if (ms)
		return system('exec >/dev/null 2>&1 </dev/null; exec ' + cmd, ms);
	return system('{ ' + cmd + '\n} >/dev/null 2>&1 </dev/null');
}

function commit(conf) {
	// After the command helpers: it needs sh() and q().
	let c = cursor();
	if (!c.commit(conf)) {
		ucimod.error();
		// Before 2023 commit() and save() refuse a name (EINVAL), and a bare
		// commit() rewrites every loaded file, comments lost. A bare save()
		// writes only the changed packages' deltas; the uci CLI then commits
		// this one, and the cursor reloads it on the next read.
		if (!c.save()) {
			ucimod.error();
			return false;
		}
		if (sh('uci ' + ((ROOT != '') ? '-c ' + q(ROOT + '/etc/config') + ' -t ' + q(ROOT + '/tmp/.uci') + ' ' : '') +
				'commit ' + q(conf)) != 0) {
			// Not left staged, or the next reader would take it for saved:
			// what `uci revert <conf>` does, without having to rewrite a
			// delta file that inherited a read-only config's mode.
			unlink(path('/tmp/.uci/' + conf));
			c.unload(conf);
			return false;
		}
		c.unload(conf);
	}
	// The file holds the bot and metrics tokens; uci rewrites it 0644.
	if (conf == 'trafficctl')
		chmod(path('/etc/config/trafficctl'), 0o600);
	return true;
}

function pipe(cmd, input) {
	// Created here and exclusively, so the redirect below cannot follow a
	// planted symlink and the output is never readable by anybody else.
	let tmp = path('/tmp/.trafficctl_pipe.' + pid());
	unlink(tmp);
	let f = open(tmp, 'wx', 0o600);
	if (!f)
		return '';
	f.close();
	let p = popen('{ ' + cmd + '\n} >' + q(tmp) + ' 2>/dev/null', 'w');
	if (p) {
		p.write('' + (input ?? ''));
		p.close();
	}
	let out = fs_readfile(tmp);
	unlink(tmp);
	return out ?? '';
}

function passthru(argv) {
	if (type(argv) != 'array' || !length(argv) || !plain(argv[0]))
		die('passthru(): no program');
	return system(map(argv, (a) => '' + a));
}

// ── JSON ────────────────────────────────────────────────────────────────────
// The shell backend's byte format, which tests and shell readers depend on:
// sprintf('%J') puts a space after ':' and escapes '/'.

const ESC = { '"': '\\"', '\\': '\\\\', '\n': '\\n', '\r': '\\r', '\t': '\\t',
	'\b': '\\b', '\f': '\\f' };

function jesc(s) {
	if (!match(s, /[\x01-\x1f"\\]/))
		return s;
	return replace(s, /[\x01-\x1f"\\]/g, (c) => ESC[c] ?? sprintf('\\u%04x', ord(c)));
}

function jstr(s) {
	// match() and replace() stop at a NUL: escape the pieces between them.
	if (index(s, NUL) >= 0)
		return '"' + join('\\u0000', map(split(s, NUL), jesc)) + '"';
	return '"' + jesc(s) + '"';
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

// No leading zeros: iptoarr() refuses them, and the shell would read 010 as
// octal.
const OCTET = '(0|[1-9][0-9]{0,2})';
const IPV4 = regexp(sprintf('^%s\\.%s\\.%s\\.%s$', OCTET, OCTET, OCTET, OCTET));

function valid_ip(s) {
	let m = plain(s) ? match(s, IPV4) : null;
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
	if (!plain(s) || !match(s, /^[0-9]+$/))
		return null;
	let n = int(s);
	if (n != n || (min != null && n < min) || (max != null && n > max))
		return null;
	return n;
}

function norm_mac(s) {
	// Before lc(), which also stops at a NUL.
	if (!plain(s))
		return null;
	s = lc(s);
	return match(s, /^[0-9a-f]{2}(:[0-9a-f]{2}){5}$/) ? s : null;
}

// A prefix length as written by ip(8) and the shell: no leading zeros.
function prefix_len(s, min) {
	return (plain(s) && match(s, /^(0|[1-9][0-9]?)$/)) ? valid_int(s, min, 32) : null;
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
	let mask = (length(p) == 2) ? prefix_len(p[1], 1) : 32;
	let ipint = ip2int(p[0]);
	if (mask == null || ipint == null)
		return null;
	let block = 1 << (32 - mask);
	return { base: ipint - ipint % block, block, mask };
}

// tctl_validate_target: the normalised target, or null.
function valid_target(t) {
	if (t == 'all' || t == 'any')
		return '0.0.0.0/0';
	if (!plain(t))
		return null;
	let p = split(t, '/');
	if (length(p) == 1)
		return valid_ip(p[0]) ? p[0] : null;
	let mask = (length(p) == 2 && valid_ip(p[0])) ? prefix_len(p[1], 0) : null;
	return (mask == null) ? null : sprintf('%s/%d', p[0], mask);
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

// Chunked, so a 16k-entry conntrack table costs one chunk of memory and not
// the whole file plus its split. A final line without '\n' still counts.
const CHUNK = 65536;

function each_line(p, fn) {
	let f = open(path(p));
	if (!f)
		return false;
	let rest = '', c;
	while (length(c = f.read(CHUNK))) {
		let l = split(rest + c, '\n');
		rest = pop(l);
		for (let x in l)
			fn(x);
	}
	f.close();
	if (rest != '')
		fn(rest);
	return true;
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

// Temp files of writers killed before their rename.
function sweep_tmp(dst) {
	let dir = dirname(dst), pre = basename(dst) + '.tmp.', now = time();
	for (let e in lsdir(dir) ?? []) {
		if (substr(e, 0, length(pre)) != pre)
			continue;
		let st = stat(dir + '/' + e);
		if (st?.type == 'file' && now - st.mtime > 60)
			unlink(dir + '/' + e);
	}
}

function write_atomic(p, data, mode) {
	// Same directory, so the rename is atomic even on a network mount.
	let dst = path(p), tmp = dst + '.tmp.' + pid();
	data = '' + data;
	mode ??= stat(dst)?.mode ?? 0o644;
	sweep_tmp(dst);
	unlink(tmp);
	// 'x' is O_EXCL: a file or symlink planted at tmp is refused, not followed.
	let f = open(tmp, 'wx', 0o600);
	if (!f)
		return false;
	// Before the data, and exact: open()'s mode is masked by the umask.
	chmod(tmp, mode);
	f.write(data);
	f.close();
	// close() reports no write error and 2022-12's flush() none either, so a
	// full disk shows only as a short file.
	if (stat(tmp)?.size != length(data) || !rename(tmp, dst)) {
		unlink(tmp);
		return false;
	}
	return true;
}

// O_EXCL, so of several runs racing for the same p exactly one gets true:
// the one-off action it guards (a log line) happens once. A short write
// (full disk) is undone and reported as false, so the caller tries again later
// instead of acting without a record of it.
function create_once(p, data) {
	let dst = path(p);
	data = '' + data;
	let f = open(dst, 'wx', 0o644);
	if (!f)
		return false;
	f.write(data);
	f.close();
	if (stat(dst)?.size != length(data)) {
		unlink(dst);
		return false;
	}
	return true;
}

function remove(p) {
	return !!unlink(path(p));
}

function lock_owner(p) {
	return trim(fs_readfile(p + '/pid') ?? '');
}

// Bare locks this process holds: path -> inode of the directory it made.
let held = {};

function lock_take(p, bare) {
	if (!mkdir(p))
		return false;
	if (bare)
		held[p] = stat(p)?.inode;
	else
		writefile(p + '/pid', pid());
	return true;
}

// No signal() before 2023-07: a killed holder never cleans up. A lock is
// stale when its holder is gone, or past max_age (pid reused, or a holder
// that never wrote its pid). Returns the stat of the stale directory, so a
// steal can tell it from one made since.
function lock_stale(p, max_age) {
	let st = stat(p), owner = lock_owner(p);
	if (!st)
		return null;
	if (owner != '' && owner != '' + pid() && !stat('/proc/' + owner))
		return st;
	return (max_age > 0 && time() - st.mtime >= max_age) ? st : null;
}

function lock_discard(d) {
	unlink(d + '/pid');
	rmdir(d);
}

// Aside directories left by a stealer that died between its two renames.
function sweep_aside(p) {
	let dir = dirname(p), pre = basename(p) + '.stale.';
	for (let e in lsdir(dir) ?? []) {
		if (substr(e, 0, length(pre)) != pre)
			continue;
		let owner = substr(e, length(pre));
		if (owner != '' + pid() && !stat('/proc/' + owner))
			lock_discard(dir + '/' + e);
	}
}

// A guard left by a stealer killed inside its steal, after this long.
const STEAL_GUARD_AGE = 10;

function steal_guard(g) {
	if (mkdir(g))
		return true;
	let st = stat(g);
	if (!st || time() - st.mtime < STEAL_GUARD_AGE)
		return false;
	rmdir(g);
	return !!mkdir(g);
}

function lock_steal(p, max_age, bare) {
	// One stealer at a time, and it judges the lock again once it is alone:
	// another stealer may have replaced the stale lock with its own fresh one
	// since we looked, and moving that aside would make two holders.
	let guard = p + '.steal';
	if (!steal_guard(guard))
		return false;
	let ok = false, st = lock_stale(p, max_age);
	sweep_aside(p);
	let aside = p + '.stale.' + pid();
	if (st && rename(p, aside)) {
		if (stat(aside)?.inode == st.inode) {
			lock_discard(aside);
			ok = lock_take(p, bare) && (bare || lock_owner(p) == '' + pid());
		}
		// Not the directory judged stale: its holder let go and a new lock
		// was made in between. Put it back, but never over a lock made at p
		// meanwhile: rename() replaces an empty directory without a word. A
		// placeholder from mkdir() claims p first, so the only directory
		// replaced is our own.
		else if (!mkdir(p))
			// p is someone else's now. The moved lock's holder cannot
			// release it (unlock checks p), so nobody would remove it.
			lock_discard(aside);
		else if (!rename(aside, p)) {
			rmdir(p);
			lock_discard(aside);
		}
	}
	rmdir(guard);
	return ok;
}

function lock(dir, tries, max_age, bare) {
	let p = path(dir), n = (tries > 0) ? tries : 1;
	for (let i = 0; i < n; i++) {
		if (i)
			sleep(100);
		if (lock_take(p, bare) || (lock_stale(p, max_age) && lock_steal(p, max_age, bare)))
			return true;
	}
	return false;
}

function unlock(dir) {
	let p = path(dir);
	if (exists(held, p)) {
		// Stolen and taken again since: that directory is someone else's.
		let ino = held[p];
		delete held[p];
		return ino != null && stat(p)?.inode == ino && !!rmdir(p);
	}
	if (lock_owner(p) != pid())
		return false;
	unlink(p + '/pid');
	return !!rmdir(p);
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

let ctx = {};
function set_context(c) {
	ctx = (type(c) == 'object') ? c : {};
}

// Writable through the LuCI write ACL and used as an append and a rewrite
// target, so only dedicated log locations with plain characters are taken.
function valid_log_file(f) {
	return plain(f) && !!match(f, /^\/(tmp\/trafficctl|var\/log)\//) &&
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

// One line per entry: a CR or LF in a value would forge a second one.
function one_line(s) {
	return join(' ', map(split('' + (s ?? ''), NUL), (x) => replace(x, /[\x01-\x1f\x7f]/g, ' ')));
}

function count_lines(p) {
	let f = open(path(p)), n = 0, c;
	if (!f)
		return 0;
	while (length(c = f.read(65536)))
		n += length(split(c, '\n')) - 1;
	f.close();
	return n;
}

// The last n lines, skipping the rest a line at a time.
function last_lines(p, total, n) {
	let f = open(path(p));
	if (!f)
		return null;
	for (let i = n; i < total; i++)
		if (f.read('line') == null)
			break;
	let out = f.read('all') ?? '';
	f.close();
	return out;
}

function rotate_log(file, max) {
	// A line is at least its '\n', so a file this small is under the cap.
	// Counted in chunks: the log may be far larger than ucode should hold.
	if ((stat(path(file))?.size ?? 0) <= max)
		return;
	let n = count_lines(file);
	if (n <= max)
		return;
	let keep = last_lines(file, n, int(max * 3 / 5));
	if (keep != null)
		write_atomic(file, keep);
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
	let user = one_line(ctx.user ?? env_or('TCTL_USER', null) ?? (trim(run('id -un')) || 'unknown'));
	let file = uci_get('trafficctl', 'logging', 'log_file');
	if (!file || !valid_log_file(file))
		file = LOG_DEFAULT;
	let max = log_max_lines();
	let msg = sprintf('%s src=%s user=%s via=%s action=%s target=%s%s', ts,
		one_line((src == null || src == '') ? (ctx.src || 'local') : src), user,
		(via == null || via == '') ? (ctx.via || 'cli') : via, action, one_line(target),
		(detail != null && detail != '') ? ' detail=' + one_line(detail) : '');

	mkdir_p(dirname(file));
	append(file, '[trafficctl] ' + msg + '\n');
	rotate_log(file, max);

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
	if (!write_atomic(NAMES, join('\n', l) + '\n'))
		return { ok: false, msg: 'cannot write ' + NAMES };
	log('config_change', ip, 'name=' + name, getenv('TCTL_VIA'), getenv('TCTL_SRC'));
	return { ok: true, msg: sprintf('named %s as %s', ip, name) };
}

function names_remove(ip) {
	if (!valid_ip(ip))
		return { ok: false, msg: 'invalid IP address' };
	if (!is_file(NAMES))
		return { ok: true, msg: 'no aliases stored' };
	let l = names_without(ip);
	if (!write_atomic(NAMES, length(l) ? join('\n', l) + '\n' : ''))
		return { ok: false, msg: 'cannot write ' + NAMES };
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
	mac = norm_mac(mac);
	if (mac == null || !is_file(SEEN))
		return true;
	return index(file_lines(SEEN), mac) >= 0;
}

function seen_mark(mac) {
	mac = norm_mac(mac);
	// Not seen_known() alone: it says "known" for a missing ledger.
	if (mac == null || (is_file(SEEN) && seen_known(mac)))
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
	macs = sort(uniq(filter(map(macs, norm_mac), (m) => m != null)));
	write_atomic(SEEN, length(macs) ? join('\n', macs) + '\n' : '');
}

// 2022-12 needs a ';' after `export function f() {}`; one list avoids it.
export { path, pid, reset, plain, cursor, uci_get, uci_words, uci_foreach, commit,
	ubus_call, q, run, lines, sh, to_json, valid_ip, valid_int, norm_mac, ip2int,
	int2ip, cidr_spec, valid_target, readfile, file_lines, each_line, is_file, mkdir_p,
	write_atomic, create_once, remove, lock, unlock, field, valid_log_file, log, sanitize_name,
	names_list, names_map, names_set, names_remove, seen_ready, seen_count,
	seen_known, seen_mark, seen_seed };
// What the rpcd plugin and the CLI's legacy commands need.
export { qv, pipe, passthru, set_context, run_rc };
