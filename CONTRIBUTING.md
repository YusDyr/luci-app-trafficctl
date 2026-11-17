# Contributing

Thanks for helping out. This is an OpenWrt LuCI package, which constrains what
the code may use rather more than a typical web project — most review comments
on first-time PRs are about the two constraints below, so please skim them
before you write anything.

## The two hard constraints

**Shell scripts are POSIX sh, running under BusyBox ash/dash — not bash.**
No arrays, no `[[ ]]`, no `<<<`, no `${var^^}`, no `local -a`. `awk` is BusyBox
awk, so gawk extensions (`match()` with an array, `gensub`, `asort`) are not
available. A bashism does not fail in CI's shell — it fails on the user's
router, at runtime, in a code path you did not test.

**Frontend JavaScript is ES5.** `var` and the `function` keyword only: no
`let`/`const`, arrow functions, template literals, destructuring, spread,
`class`, `async`/`await`, `Object.assign`, `Array.prototype.includes`. LuCI
serves these files to the browser on whatever device the user administers the
router from, some of which are old. ESLint is configured with
`ecmaVersion: 5` plus `no-restricted-syntax`, so a slip fails CI rather than
reaching a user.

## Before you open a PR

```sh
# JavaScript: syntax and lint
node --check luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js
npm install && npm run lint

# Shell (hooks, init scripts, the CGI): syntax and static analysis
F=trafficctl/files
for f in $F/etc/hotplug.d/*/* $F/etc/init.d/* $F/etc/uci-defaults/* $F/www/cgi-bin/*; do sh -n "$f" || echo "FAIL $f"; done
shellcheck -s sh $F/etc/hotplug.d/*/* $F/www/cgi-bin/*

# Tests — see docs/DEVELOPMENT.md for the full list and what each covers.
# The ucode ones need an interpreter: tools/ci/build-ucode.sh 2022-12-02
export UCODE_PREFIX=~/.cache/trafficctl-ucode/2022-12-02
bash tests/test_direction.sh
bash tests/test_security.sh
```

CI runs the whole `tests/` suite, shellcheck, ESLint, and a compatibility matrix
that installs the built package inside real OpenWrt rootfs containers from
22.03 through 25.12.

## Writing tests

A test must exercise the real code. The suite historically contained tests
that redefined a local copy of the function they were checking, which meant
deleting the production validation entirely left them green — so a test that
does not fail when you break the code it names is worse than no test.

The pattern to copy is `tests/test_direction.sh`: put a fake `nft`/`tc`/`ip`/
`curl` on `PATH`, point `TCTL_ROOT` at a scratch root (uci config, state files,
sysfs), run the real CLI through `tctl` from `tests/lib/ucode.sh`, then assert
on the arguments the fakes recorded. One module function at a time goes
through `tcall`.

Verify your test by breaking the production code on purpose, watching the test
go red, and restoring the file.

## Anything touching the firewall, the shaper, or rpcd

These run as root with parameters that came from a browser, so:

- Validate at the boundary and re-validate in the backend (`lib.valid_ip`,
  `lib.valid_target`, `portfw.valid_port`, `limit.valid_rate`). Never interpolate an
  unvalidated value into an `nft`/`tc` command line, and quote every value with
  `lib.q()` (`tests/lib/uc_cmd_lint.py` checks it).
- Identify rules by the target, not by a caller-supplied label
  (`ctl.block_comment`, `limit.comment`), and match the **full**
  comment on removal — an unanchored match on `192.168.1.1` also hits
  `192.168.1.10`.
- A control that cannot be applied must report that. Reporting success for a
  rule that was never installed is the worst outcome available, because the user
  believes a device is blocked when it is not.
- New rpcd methods need an entry in
  `root/usr/share/rpcd/acl.d/luci-app-trafficctl.json`. Anything that changes
  state — or that returns the contents of a file — goes under `write`, never
  `read`: the read group is granted to unprivileged LuCI users.

## Commits and releases

Conventional Commits, because the release is automatic: `feat:` bumps the minor
version, `fix:`/`perf:`/`refactor:`/`ci:` the patch, a `!` (e.g. `feat(rpcd)!:`)
or a `BREAKING CHANGE:` footer the major. `docs:`/`chore:`/`style:` do not
release.

The footer is recognised only at the start of a line, followed by `:` or ` #`
(`BREAKING-CHANGE:` also works, per the spec). So you can discuss the footer in
a commit body — as this sentence does — without triggering a major release.

Merging to `main` tags, builds and publishes on its own, so a commit message
with a stray `;` or `)` is not merely untidy — the message is baked into a
generated shell script by the bundle pipeline.

Update `CHANGELOG.md` and the relevant file under `docs/` in the same PR as the
change.
