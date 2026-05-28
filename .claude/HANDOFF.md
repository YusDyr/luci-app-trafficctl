# Branch handoff — fix/install-and-feed-testing

> Purpose: snapshot of the in-flight work on this branch so a fresh agent
> session can pick up where the previous one left off.
> Update this file at meaningful checkpoints (decisions, blockers, mid-task
> pauses). Delete or squash before merging the PR.

Last updated: 2026-05-28 14:30 UTC by Claude Sonnet 4.6

---

## What this branch is for

Closes #7 — v1.5.0 release was broken (`status.css` missing, APK in invalid
format) AND the feed-based install path documented in README has always
been broken (`target pattern contains no '%'` error reported on the
eko.one.pl forum: https://eko.one.pl/forum/viewtopic.php?id=25298).

The PR is **#8**, currently in **draft**.

## What's already done (committed and pushed)

Commits in order:
- `be79eb6` `test: add feed install, upgrade, removal, and dependency tests`
- `91b7a0b` `fix: include status.css in packages and fix APK release format`
- `293dcd5` `fix: restructure repo to feed-compatible subdirectory layout`
- `b715d35` `fix: point auto-release sed at the new Makefile path`
- `046ca81` `feat: add manual-release workflow for rebuilding existing releases`
- `3b4c01d` `refactor(ci): manual-release defaults to tag, supports legacy layouts`
- `5833e60` `docs: add stable download URLs and asset naming explanation` *(user-authored in another session)*
- `937064c` `ci: commit Makefile version bump before tagging` *(user-authored in another session)*
- `2a43e2b` `fix(test): detect SDK buildroot path, add generic asset names to manual-release`
- `5b0c9f7` `fix(ci): point eslint at htdocs under luci-app-trafficctl/`
- `7988dbf` `ci: force re-trigger workflows` *(empty)*
- `114ecdc` `ci: retrigger workflows` *(README whitespace)*

Functional summary:
1. **Restructure**: `Makefile`, `htdocs/`, `root/`, `po/` moved to `luci-app-trafficctl/` subdirectory — fixes OpenWrt's `find -L … -mindepth 1` feed scan.
2. **build-ipk.sh / build-apk.sh**: include `status.css`, source from `luci-app-trafficctl/` paths.
3. **auto-release.yml**: build APK via OpenWrt SDK (not the broken APKv2 fallback); patch Makefile path under `luci-app-trafficctl/`.
4. **manual-release.yml** (new): `workflow_dispatch` rebuilds artifacts for any released version. Default ref = matching tag; override to a fix-branch when the tag itself shipped broken (our v1.5.0 case). Cherry-picked separately to **main** as `172fbc1` so it's triggerable without merging.
5. **Tests added/extended**:
   - `tests/test_install.sh`: install via `opkg install` (not raw tar) + `apk add`; new removal phase verifies `opkg remove` / `apk del` clean up files.
   - `tests/test_feed_install.sh`: spins up `openwrt/sdk:*` container, adds repo as `src-link` feed, runs `scripts/feeds update/install` + `make package/.../compile`.
   - `tests/test_upgrade.sh`: download previous GitHub release via `gh release download`, install old, then install current build; assert config preserved.
   - `tests/test_dependencies.sh`: install on minimal rootfs (no deps), expect clean failure; then `opkg update` + retry expects success.
6. **compat.yml**: new jobs `feed-install` (×3 SDK versions), `upgrade` (×2), `dependencies` (×3). Removal coverage piggybacks on the existing compat-matrix via `test_install.sh`.
7. **shellcheck.yml** / **eslint.yml** / `tests/test_*.sh`: paths updated for the subdirectory move.

## What's NOT done — open blockers

### B1. GitHub Actions is not triggering CI for the latest commits on this branch
Last commit that has CI runs: `937064c`. All my subsequent pushes
(`2a43e2b`, `5b0c9f7`, `7988dbf`, `114ecdc`) get only a single `event:
dynamic, name: "PR #8"` check and **none of the regular workflows fire**
(ShellCheck, ESLint, Tests, CI, OpenWrt Compatibility).

What I tried that did NOT help:
- Empty commit (`7988dbf`)
- Real commit with whitespace change (`114ecdc`)
- `gh pr close 8 && gh pr reopen 8`
- `gh run cancel` on the stuck in-progress run
- Direct `gh workflow run` (HTTP 422 — workflows don't have `workflow_dispatch`)

What I have NOT tried:
- Pushing the branch under a NEW name and opening a fresh PR
- Adding `workflow_dispatch:` trigger to ci.yml / compat.yml as a temporary unstick mechanism
- Waiting longer (rate-limit hypothesis — never confirmed)

### B2. SDK APK build genuinely fails on our package
Independent from B1. Observed in:
- The cancelled compat.yml run for `937064c` — `Build packages` job hung on `csstidy host-compile` then was cancelled.
- The manual-release run we triggered for v1.5.0 (run id `26571035657`) — failed at `make package/luci-app-trafficctl/compile` after ~7 seconds, no useful log because `gh-action-sdk@main` doesn't enable `V=s`.

Hypotheses worth investigating next:
- The Makefile relies on `include $(TOPDIR)/feeds/luci/luci.mk` — maybe `luci.mk` isn't being resolved during the SDK build context after the restructure.
- The default `Build/Install` template from `luci.mk` may not find files under `./htdocs/` etc. when invoked from the `luci-app-trafficctl/` subdir of the workspace.
- Could enable `OPENWRT_VERBOSE: c` in the SDK action env to actually see the make error.

To debug, the next agent should add `OPENWRT_VERBOSE: c` to the SDK action invocations in compat.yml and manual-release.yml, push, and read the resulting log.

### B3. v1.5.0 release on GitHub is empty
The user deleted the two broken artifacts (`luci-app-trafficctl_1.5.0-1_all.ipk`, `luci-app-trafficctl_1.5.0-r1_noarch.apk`) at user's request. The release v1.5.0 currently has **zero assets**. The plan was to rebuild via manual-release.yml once B2 is fixed.

## Background tasks that may still be running

Haiku-model agents launched earlier to monitor CI. Stop them with
`TaskStop task_id:<id>` if their reports aren't useful anymore:
- `a5509791158363a27` — ESLint + CI watcher (already reported, completed)
- `ad609bfe216b3d822` — original SDK + feed watcher (needed permission, completed)
- `a46c33a0bd4448b1b` — compat matrix watcher (reported, completed)
- `ac8b9b0972a9e565e` — upgrade + dependencies watcher (reported, completed)
- `ac237940c66b3f68b` — retry SDK + feed watcher (reported, completed)

All five are completed at handoff time. If new ones get launched, list
them here.

## Decisions / preferences captured in this session

- User wants per-pipeline subagents for CI monitoring, not a single big one. Use Haiku model with explicit "do not ask for permission" framing — Haiku tends to ask even when it shouldn't.
- User does NOT want auto-appended "rebuild" notes in GitHub Release bodies — they'll write those manually after triggering a rebuild.
- User prefers rebuilds from the original tag by default (verbatim reproduction); override to a fix-branch only when the tag itself is broken.
- User wants `-rN` style suffixes when rebuilding so the broken originals stay alongside as historical record. For v1.5.0 specifically the originals were just deleted (cleaner state), so a fresh `-r1` rebuild is fine.
- Stable URLs `releases/latest/download/luci-app-trafficctl.{ipk,apk}` are produced via hardlinks alongside the versioned files; both auto-release and manual-release do this.

## What to do next

1. Unstick CI (B1) — easiest bet is to push under a new branch name and open a fresh PR. If CI fires there, we know the issue is per-PR or per-branch (cancel buildup) rather than account-wide.
2. With CI flowing, fix the SDK APK build (B2) by enabling verbose mode and reading the actual `make` error.
3. Once `Build packages` and `Feed install` are green, the compat matrix (50+) and Upgrade/Dependencies jobs will finally have something to test against.
4. When everything is green, trigger Manual Release Rebuild → version=1.5.0 → ref=fix/install-and-feed-testing (or whatever branch we ended up on). This re-populates the v1.5.0 release assets.
5. Mark PR #8 ready for review and merge.
6. Verify `apk add` on the user's real router (192.168.0.1) once v1.5.0 is rebuilt.

## Background context links

- Issue: https://github.com/YusDyr/luci-app-trafficctl/issues/7
- PR: https://github.com/YusDyr/luci-app-trafficctl/pull/8
- Forum thread: https://eko.one.pl/forum/viewtopic.php?id=25298
- OpenWrt scan.mk (proves the `-mindepth 1` requirement): https://git.openwrt.org/?p=openwrt/openwrt.git;a=blob;f=include/scan.mk
