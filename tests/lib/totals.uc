'use strict';
// `trafficctl totals` over a recorded byte sample instead of a live bytes()
// read, so the accumulator can be driven sample by sample.
//
// Usage: ucode -S -L <libdir> totals.uc <sample.json> [--all]
// A missing or unreadable sample file is the empty sample.
//
// TCTL_TEST_FAIL makes one step throw, through the global builtin the module
// resolves at run time (nothing in the data can make ucode throw there):
//   sample  bytes() itself is read (the sample file is ignored) and dies in
//           its offload check; needs an uncountered offload mode
//   write   formatting a state line dies, inside the locked section; prints
//           {"error": msg} instead of the result

import * as lib from 'trafficctl.lib';
import * as net from 'trafficctl.net';
import { readfile } from 'fs';

let fail = getenv('TCTL_TEST_FAIL') ?? '';
let all = (ARGV[1] == '--all');

if (fail == 'sample') {
	let real = global.substr;
	global.substr = function(...a) {
		if (a[1] === -8)
			die('test: bytes() fails');
		return call(real, null, null, ...a);
	};
	print(lib.to_json(net.totals(all)), '\n');
	exit(0);
}
if (fail == 'write') {
	let real = global.sprintf;
	global.sprintf = function(...a) {
		if (index(a[0], '%s %d %d') == 0)
			die('test: the state write fails');
		return call(real, null, null, ...a);
	};
}

let text = readfile(ARGV[0]) ?? '';
let sample = [];
try {
	sample = json(text) ?? [];
}
catch (e) {
	sample = [];
}
try {
	print(lib.to_json(net.totals(all, sample)), '\n');
}
catch (e) {
	print(lib.to_json({ error: e.message }), '\n');
}
