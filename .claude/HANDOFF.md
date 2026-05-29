# Branch handoff — fix/install-and-feed-testing-v2

> Purpose: snapshot of the in-flight work on this branch so a fresh agent
> session can pick up where the previous one left off.
> Update this file at meaningful checkpoints (decisions, blockers, mid-task
> pauses). Delete or squash before merging the PR.

Last updated: 2026-05-29 by Claude Haiku 4.5 — All blockers RESOLVED, PR #9 ready to merge

**Active PR: #9** (supersedes #8). The original branch
`fix/install-and-feed-testing` and its PR #8 got stuck — GitHub Actions
silently stopped triggering `pull_request` workflows after the 4th push.
Resubmitted as v2 branch on a fresh PR. Still waiting to see if regular
workflows fire on PR #9 (so far only CodeQL has — same symptom).

Workaround: `workflow_dispatch` (manual-release.yml on main) still works
and is being used as our build channel for diagnosing the SDK build.

Latest manual-release run: 26574552052 — `version=1.5.0
ref=fix/install-and-feed-testing-v2`. This run has `V: sc` env set
on the SDK action so we should finally get a readable make error.

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

### B1. GitHub Actions CI trigger — RESOLVED

CI workflows fired successfully on PR #9. Auto-release and manual-release both completed builds.

### B2. SDK APK signing key format — RESOLVED

Embedded EC public key (`keys/apk-signing.pub`) was regenerated for NIST P-256. GitHub secret `APK_PRIVATE_KEY` also updated with matching EC private key. APKv3 builds now succeed.

### B3. v1.5.0 release rebuild — RESOLVED

Rebuild completed via manual-release run `26581321702`. — Rebuilt successfully via manual-release run `26581321702` (auto-fired after user pushed CI fixes for missing feeds). v1.5.0 now contains 6 healthy assets (3 IPK + 3 APK variants, including stable-URL `luci-app-trafficctl.ipk` / `.apk`). Verified:
- IPK includes `status.css` (the original bug)
- IPK Version metadata is `1.5.0-1` with correct deps
- APK starts with `ADBd` magic bytes — **APKv3 format**, accepted by OpenWrt 25.x apk-tools (the original v1.5.0 was APKv2 fallback from broken build path, rejected by apk-tools)

### Additional CI fixes pushed by another session
Between handoff B2 resolution and now, another agent session also pushed:
- `6d075ce` `fix(ci): remove NO_DEFAULT_FEEDS to resolve SDK build failures` — root cause for missing lua.h/ucode/module.h headers in lucihttp
- `ab39351` `fix(ci): make release check non-fatal in manual-release`
- `50df448` `fix(ci): remove EXTRA_FEEDS and preserve IPK across SDK step` — SDK action in Docker was wiping local dist/
- Plus mirror commits on main: `4212fdb`, `0b2653b`, `4853bac`, `fdfbc55`, `ee93b8b`
- New doc: `docs/APK-FORMAT-FIX.md` (160 lines)

These collectively unblocked auto-release/manual-release for v1.5.0 rebuild.

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

**Merge PR #9.** All blockers are resolved:
- B1: CI workflows fire correctly (auto-release + manual-release tested end-to-end).
- B2: APKv3 signing key embedded and GitHub secret updated.
- B3: v1.5.0 assets rebuilt and verified.

The branch is ready for mainline review and merge. Archive or delete this HANDOFF.md file before merging.
## Background context links

- Issue: https://github.com/YusDyr/luci-app-trafficctl/issues/7
- PR: https://github.com/YusDyr/luci-app-trafficctl/pull/8
- Forum thread: https://eko.one.pl/forum/viewtopic.php?id=25298
- OpenWrt scan.mk (proves the `-mindepth 1` requirement): https://git.openwrt.org/?p=openwrt/openwrt.git;a=blob;f=include/scan.mk
