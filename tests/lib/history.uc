'use strict';
// `trafficctl history <cmd>` over recorded samples instead of live reads, so a
// flush can be driven sample by sample without conntrack or /proc/net/dev.
//
// Usage: ucode -S -L <libdir> -L <testlib> history.uc <totals.json> <ifaces.json> <cmd> [args]
//   <totals.json>  what net.totals(true) returns; '-' reads it live
//   <ifaces.json>  what net.ifaces() returns; '-' reads it live
// `flush` runs the flush in this process (flush-now): the guarded child of the
// real `flush` would read live samples, which a test has none of.
// An empty sample file is a reader that printed nothing (the shell skipped
// that step); a missing or unreadable one is the empty list.

import * as lib from 'trafficctl.lib';
import * as history from 'trafficctl.history';
import { readfile } from 'fs';

function load(p) {
	if (p == '-')
		return null;
	let text = readfile(p);
	if (text == '')
		return false;
	try {
		return json(text ?? '[]') ?? [];
	}
	catch (e) {
		return [];
	}
}

let src = { totals: load(ARGV[0]), ifaces: load(ARGV[1]) };
let args = slice(ARGV, 2);
if (args[0] == 'flush')
	args[0] = 'flush-now';

let r = history.main(args, src);
if (type(r.out) == 'string')
	print(r.out);
else if (r.out != null)
	print(lib.to_json(r.out), '\n');
exit(r.rc);
