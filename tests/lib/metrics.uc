'use strict';
// `trafficctl metrics` over recorded sources: the accumulator runs for real
// on a byte sample (as tests/lib/totals.uc drives it), the summary, port
// forwards and DPI apps are the text of files.
//
// Usage: ucode -S -L <libdir> metrics.uc <sample.json> <dir>
//   <dir>/summary.json, portfw.json, netify.json   the other sources' output;
//   a missing file is a source that printed nothing

import * as net from 'trafficctl.net';
import * as report from 'trafficctl.report';
import { readfile } from 'fs';

let sample = [];
try {
	sample = json(readfile(ARGV[0]) ?? '[]') ?? [];
}
catch (e) {
	sample = [];
}
let dir = ARGV[1];
let text = (name) => readfile(dir + '/' + name) ?? '';

print(report.metrics({
	totals: () => net.totals(true, sample),
	summary: () => text('summary.json'),
	portfw: () => text('portfw.json'),
	netify: () => text('netify.json')
}));
