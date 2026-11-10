'use strict';
// Calls one exported function of a backend module and prints the result:
// strings as they are, anything else as JSON.
//
// Usage: ucode -S -L <libdir> call.uc <module> <function> [json-arg...]
//   e.g. call.uc trafficctl.net lan_subnets
//
// The modules use `export`, which require() rejects in every ucode version,
// and import takes no run-time name: so the import is compiled at run time.

let mod = loadstring(sprintf('import * as m from %J; return m;', ARGV[0]))();
let fn = mod?.[ARGV[1]];

if (type(fn) != 'function')
	die(sprintf('call.uc: %s has no function %s\n', ARGV[0], ARGV[1]));

let args = map(slice(ARGV, 2), (a) => json(a));
let res = call(fn, mod, null, ...args);

if (type(res) == 'string')
	print(res);
else if (res != null)
	printf('%J\n', res);
