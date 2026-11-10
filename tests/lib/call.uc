'use strict';
// Calls one exported function of a backend module and prints the result:
// strings as they are, anything else as JSON.
//
// Usage: ucode -S -L <libdir> call.uc <module> <function> [json-arg...]
//   e.g. call.uc trafficctl.net lan_subnets
//
// require(), not import: ucode 2022-12 cannot load a module by a name known
// only at run time any other way, and its require() rejects files that use
// `export`. Backend modules therefore end in `return { ... };`, as fw4 does.

let mod = require(ARGV[0]);
let fn = mod?.[ARGV[1]];

if (type(fn) != 'function')
	die(sprintf('call.uc: %s has no function %s\n', ARGV[0], ARGV[1]));

let args = map(slice(ARGV, 2), (a) => json(a));
let res = call(fn, mod, null, ...args);

if (type(res) == 'string')
	print(res);
else if (res != null)
	printf('%J\n', res);
