## What this changes and why

## Checklist

- [ ] Shell code is POSIX sh / BusyBox ash — no arrays, no `[[ ]]`, no gawk extensions
- [ ] JavaScript is ES5 — `npm run lint` passes
- [ ] `sh -n` passes on every script touched; `shellcheck` is clean
- [ ] Tests exercise the real scripts (not a local copy of the function), and I
      confirmed a new test fails when I break the code it covers
- [ ] A new rpcd method has an ACL entry, with anything state-changing or
      file-reading under `write`
- [ ] `CHANGELOG.md` and the relevant `docs/` page updated
- [ ] Commit messages follow Conventional Commits (the release is automatic)

## How you verified it

Say what you actually ran. If it was tested on a real router, give the OpenWrt
version (fw4/nftables); if it was only
tested against the mocked suite, say that instead — that is useful to know at
review time rather than after a release.
