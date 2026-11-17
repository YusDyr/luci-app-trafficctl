'use strict';
// A stateful nft for `inet fw4 forward`, the chain the block writes to: rules
// are inserted, deleted by handle and listed back as text (with -a) and as
// `nft -j`, the way nftables 1.0 prints them, so the writers and the JSON
// readers meet the same state. Handles come from a counter and survive
// deletes, as the kernel's do: a mock that renumbered would hide a removal
// that collects handles and then invalidates them as it goes.
//
// Usage (tests/lib/fw4_env.sh): ucode -S nft-fw4.uc -- <nft arguments>
//   NFT_STATE   JSON file { next, rules: [{ handle, text }] }, made on first use
//   NFT_LOG     every call appended, arguments joined by spaces
//   NFT_FAIL    an ERE: a call whose argument line matches it exits 1
//   NFT_NOFW4   `list table inet fw4` fails (fw4 not loaded yet): always, or
//               while the file it names holds a count above 0, one less
//               each time
//   NFT_FIXTURES  a directory: a call with no state of its own here prints
//               <dir>/<arguments, spaces as _> when that file exists (another
//               table, such as the limiter's netdev tm_ratelimit)
// Every other command exits 0 and prints nothing.

import { readfile, writefile, open } from 'fs';

const argv = ARGV;
const line = join(' ', argv);
const statef = getenv('NFT_STATE');

if (getenv('NFT_LOG')) {
	let f = open(getenv('NFT_LOG'), 'a');
	f.write(line + '\n');
	f.close();
}
if (getenv('NFT_FAIL') && match(line, regexp(getenv('NFT_FAIL'))))
	exit(1);

let st;
try {
	st = json(readfile(statef) ?? '');
}
catch (e) {
	st = null;
}
st ??= { next: 1, rules: [] };

function save() {
	writefile(statef, sprintf('%J', st));
}

function words(t) {
	return filter(split(t, /[ \t]+/), (w) => w != '');
}

function addr(v) {
	let m = match(v, /^([^\/]+)\/([0-9]+)$/);
	return m ? { prefix: { addr: m[1], len: int(m[2]) } } : v;
}

function payload(proto, fld, v) {
	return { match: { op: '==', left: { payload: { protocol: proto, field: fld } }, right: addr(v) } };
}

// The rule text as `nft -j` lists it: matches, counter, verdict, comment.
function rule_json(r) {
	let w = words(r.text), expr = [], comment = null;
	for (let i = 0; i < length(w); i++) {
		let a = w[i];
		if ((a == 'ip' || a == 'ether') && (w[i + 1] == 'saddr' || w[i + 1] == 'daddr')) {
			push(expr, payload(a, w[i + 1], w[i + 2]));
			i += 2;
		}
		else if (a == 'meta' && w[i + 1] == 'nfproto') {
			push(expr, { match: { op: '==', left: { meta: { key: 'nfproto' } }, right: w[i + 2] } });
			i += 2;
		}
		else if (a == 'counter') {
			let p = 0, b = 0;
			if (w[i + 1] == 'packets') {
				p = int(w[i + 2]);
				b = int(w[i + 4]);
				i += 4;
			}
			push(expr, { counter: { packets: p, bytes: b } });
		}
		else if (index([ 'drop', 'accept', 'reject', 'return' ], a) >= 0)
			push(expr, { [a]: null });
		else if (a == 'comment') {
			comment = replace(join(' ', slice(w, i + 1)), /^"|"$/g, '');
			break;
		}
	}
	let o = { family: 'inet', table: 'fw4', chain: 'forward', handle: r.handle, expr };
	if (comment != null)
		o.comment = comment;
	return { rule: o };
}

// Listed with a zeroed counter filled in, as nft does for `counter`.
function rule_text(r) {
	return replace(r.text, /counter( |$)/, 'counter packets 0 bytes 0$1');
}

const CHAIN = 'inet fw4 forward';
let m;

if (line == 'list table inet fw4' || line == 'list tables') {
	let nf = getenv('NFT_NOFW4');
	if (nf) {
		let n = int(trim(readfile(nf) ?? 'x'));
		if (n != n)
			exit(1);
		if (n > 0) {
			writefile(nf, '' + (n - 1));
			exit(1);
		}
	}
	print((line == 'list tables') ? 'table inet fw4\n' : 'table inet fw4 {\n}\n');
}
else if ((m = match(line, /^(insert|add) rule inet fw4 forward (.+)$/))) {
	let r = { handle: st.next++, text: m[2] };
	// Not unshift(): on ucode 2022-12 it leaves an empty array empty.
	if (m[1] == 'insert')
		st.rules = [ r, ...st.rules ];
	else
		push(st.rules, r);
	save();
}
else if ((m = match(line, /^delete rule inet fw4 forward handle ([0-9]+)$/))) {
	let n = length(st.rules);
	st.rules = filter(st.rules, (r) => r.handle != int(m[1]));
	if (length(st.rules) == n)
		exit(1);
	save();
}
else if (line == 'list chain ' + CHAIN || line == '-a list chain ' + CHAIN) {
	let a = (argv[0] == '-a');
	print('table inet fw4 {\n\tchain forward {\n');
	for (let r in st.rules)
		print('\t\t', rule_text(r), a ? ' # handle ' + r.handle : '', '\n');
	print('\t}\n}\n');
}
else if (line == '-j list chain ' + CHAIN) {
	let out = [ { metainfo: { version: '1.0.2', release_name: 'Lester Gooch', json_schema_version: 1 } },
		{ chain: { family: 'inet', table: 'fw4', name: 'forward', handle: 2 } } ];
	for (let r in st.rules)
		push(out, rule_json(r));
	print(sprintf('%J', { nftables: out }), '\n');
}
else if (getenv('NFT_FIXTURES')) {
	let f = readfile(getenv('NFT_FIXTURES') + '/' + replace(line, / /g, '_'));
	if (f != null)
		print(f);
}
exit(0);
