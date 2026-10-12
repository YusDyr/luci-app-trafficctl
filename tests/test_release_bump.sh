#!/bin/bash
# Tests the version-bump decision in .github/workflows/auto-release.yml.
#
# The four regexes are EXTRACTED FROM THE WORKFLOW rather than copied here, so
# editing the workflow either keeps these tests passing or breaks them. A test
# holding its own copy of the patterns would keep passing while the released
# version went wrong — the exact failure mode several tests in this suite had.

PASS=0
FAIL=0

WF="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows/auto-release.yml"

if [ ! -f "$WF" ]; then
    echo "FAIL: cannot find auto-release.yml at $WF"
    exit 1
fi

# Extract the decision block VERBATIM and execute it, rather than extracting
# the regexes and re-implementing the chain here. Which variable each regex is
# applied to is part of the logic: a version that matched the subject-anchored
# regexes against FULL_MSGS would let a body line quoting "feat!:" fake a major.
# A harness that only lifted the patterns would score that mutation as passing.
COND_BLOCK=$(awk '/^ *BUMP="none"$/{f=1} f{print} f&&/^ *fi$/{exit}' "$WF")

if [ -z "$COND_BLOCK" ] || ! printf '%s\n' "$COND_BLOCK" | grep -q 'BUMP="major"'; then
    echo "FAIL: could not extract the bump decision block from $WF."
    echo "Expected a block starting with BUMP=\"none\" and ending at 'fi'. Got:"
    printf '%s\n' "$COND_BLOCK"
    exit 1
fi

echo "Decision block under test (read verbatim from auto-release.yml):"
printf '%s\n' "$COND_BLOCK" | sed 's/^ */  /'
echo

# Run the real block with SUBJECTS/FULL_MSGS built the way the workflow builds
# them from git log --pretty=format:"%s" and "%s%n%b".
bump_for() {
    local full="$1"
    local SUBJECTS FULL_MSGS BUMP
    # Records are separated by a blank line; the first line of each is the
    # subject, matching what %s emits per commit.
    # shellcheck disable=SC2034  # both are read by the eval'd block below
    SUBJECTS=$(printf '%s\n' "$full" | awk 'BEGIN{RS="";FS="\n"}{print $1}')
    # shellcheck disable=SC2034
    FULL_MSGS="$full"
    eval "$COND_BLOCK"
    printf '%s' "$BUMP"
}

assert_bump() {
    local desc="$1" expected="$2" msg="$3" actual
    actual=$(bump_for "$msg")
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected bump: %s\n  actual bump:   %s\n  message:\n%s\n\n" \
            "$desc" "$expected" "$actual" "$msg"
    fi
}

# ── A real BREAKING CHANGE footer must still produce a major ────────────────
assert_bump "footer with colon" major 'fix: drop the legacy endpoint
BREAKING CHANGE: the v1 rpcd method is gone'

assert_bump "footer spelled with a hyphen (allowed by the spec)" major 'fix: drop it
BREAKING-CHANGE: gone'

assert_bump "footer referencing an issue" major 'fix: drop it
BREAKING CHANGE #42'

assert_bump "footer after other footers" major 'fix: drop it
Co-Authored-By: Someone <s@example.com>
BREAKING CHANGE: gone'

# ── Prose that merely mentions the footer must NOT produce a major ──────────
# Would have failed before: the search was unanchored, so any of these shipped
# a major release. The commit that fixed this workflow tripped it on itself.
assert_bump "prose mentioning the footer mid-sentence" patch 'ci: fix the release state machine
BREAKING CHANGE was grepped for in a subject-only commit list, and by spec
it lives in the footer.'

assert_bump "indented bullet mentioning the footer" patch 'ci: fix the release state machine
  - BREAKING CHANGE was grepped for in a subject-only list'

assert_bump "footer name quoted in prose with a colon later" none 'docs: explain versioning
Use BREAKING CHANGE in a footer to force a major: it is documented in
CONTRIBUTING.md.'

# ── Subject-anchored types ──────────────────────────────────────────────────
assert_bump "feat with scope and bang" major 'feat(rpcd)!: replace the dispatch table'
assert_bump "fix with bang, no scope" major 'fix!: change the config format'
assert_bump "plain feat" minor 'feat: add a per-device graph'
assert_bump "feat with scope" minor 'feat(ui): add a per-device graph'
assert_bump "plain fix" patch 'fix: stop leaking the popup'
assert_bump "perf" patch 'perf: cache the device list'
assert_bump "refactor is a patch per CONTRIBUTING.md" patch 'refactor: split the shaper helpers'
assert_bump "ci is a patch per CONTRIBUTING.md" patch 'ci: pin the SDK action'
assert_bump "docs alone releases nothing" none 'docs: document the rpcd methods'
assert_bump "chore alone releases nothing" none 'chore: bump the changelog'
assert_bump "style alone releases nothing" none 'style: reindent the awk'
assert_bump "test alone releases nothing" none 'test: cover the shaper'

# ── A body line must not be read as a subject ──────────────────────────────
# Would have failed before the SUBJECTS/FULL_MSGS split: a body quoting a
# commit prefix satisfied the subject-anchored regex and faked a bump.
assert_bump "body quoting feat: does not fake a minor" patch 'fix: correct the parser
The old code treated
feat: something
as a subject, which was wrong.'

assert_bump "body quoting feat!: does not fake a major" patch 'fix: correct the parser
A line reading
feat!: whatever
in the body is not a subject.'

# ── Highest type across a range wins ───────────────────────────────────────
assert_bump "feat beats fix in a mixed range" minor 'fix: one thing

feat: another thing

docs: a third'

assert_bump "bang beats feat in a mixed range" major 'feat: one thing

fix(api)!: another thing'

# ── This branch itself ─────────────────────────────────────────────────────
# The bug this file guards was found by simulating the workflow on this very
# branch, which resolved to major (v2.0.0) off fix:/ci:/docs:/test: commits.
assert_bump "this branch's own commit set resolves to patch" patch 'fix(shaper): allocate classids instead of deriving them from the address

fix(fw): identify rules by target and match their comments in full

fix(rpcd): constrain the activity log path and move activity_log to write

ci: pin the signing action and fix the release state machine
Four bugs in the version-bump logic, all of which fail quietly:
  - BREAKING CHANGE was grepped for in a subject-only commit list, and by spec
    it lives in the footer.

docs: document every rpcd method and add contributor guidance

test: exercise the real scripts and cover what had no tests'

# ── Step order is what prevents two runs from racing (#85) ──────────────────
#
# The release job computes a version and then edits PKG_VERSION and CHANGELOG.md
# to match. When two merges land within the ~50 minutes the SDK matrix takes,
# two runs each build a bump commit touching those same two files; the second
# one then rebased onto a main that already carried the first, conflicted on
# both and died — which is how a feat: shipped inside a patch release with its
# changelog entry lost. The defence is ordering, not conflict resolution: sync
# to the tip BEFORE deciding anything, and never replay the bump commit.
#
# Asserted structurally because the failure only reproduces with two merges
# landing minutes apart, which a unit test cannot stage.

step_line() { grep -n "^      - name: $1\$" "$WF" | head -1 | cut -d: -f1; }

sync_at=$(step_line "Sync to the tip of main")
bump_at=$(step_line "Determine version bump")
chlog_at=$(step_line "Generate changelog")

if [ -z "$sync_at" ]; then
    FAIL=$((FAIL + 1))
    printf "FAIL: the release job no longer syncs to the tip of main before computing the bump\n"
else
    PASS=$((PASS + 1))
fi

if [ -n "$sync_at" ] && [ -n "$bump_at" ] && [ "$sync_at" -lt "$bump_at" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    printf "FAIL: the sync step must come BEFORE the version bump is decided (sync=%s bump=%s)\n" \
        "$sync_at" "$bump_at"
fi

if [ -n "$sync_at" ] && [ -n "$chlog_at" ] && [ "$sync_at" -lt "$chlog_at" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    printf "FAIL: the sync step must come BEFORE the changelog is generated (sync=%s changelog=%s)\n" \
        "$sync_at" "$chlog_at"
fi

# The bump commit must not be replayed over whatever else reached main: that is
# the operation that conflicted on CHANGELOG.md and Makefile.
if grep -qE '^ *git (pull --rebase|rebase)' "$WF"; then
    FAIL=$((FAIL + 1))
    printf "FAIL: the release job rebases its bump commit again — that is the #85 failure\n"
    grep -nE '^ *git (pull --rebase|rebase)' "$WF"
else
    PASS=$((PASS + 1))
fi

# ── Cancelling runs must never be able to kill a release ────────────────────
#
# ci.yml and compat.yml cancel superseded runs on a pull request. Both are also
# reached through workflow_call from auto-release.yml, so an unconditional
# cancel-in-progress there would let a later push to main abort a release that
# is already tagging — the worst failure this pipeline has. The gating is the
# safety property, so it is asserted rather than trusted to review.

WF_DIR="$(dirname "$WF")"

for wf in ci.yml compat.yml; do
    f="$WF_DIR/$wf"
    cip=$(awk '/^concurrency:/{f=1;next} f&&/^[a-z]/{exit} f&&/cancel-in-progress:/{sub(/^ *cancel-in-progress: */,"");print;exit}' "$f")

    if [ -z "$cip" ]; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s declares no cancel-in-progress under concurrency\n" "$wf"
    elif [ "$cip" = "true" ]; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s cancels unconditionally — a push to main could abort a release mid-tag\n" "$wf"
    else
        case "$cip" in
            *"github.event_name == 'pull_request'"*) PASS=$((PASS + 1)) ;;
            *)
                FAIL=$((FAIL + 1))
                printf "FAIL: %s gates cancellation on something other than a pull_request event: %s\n" "$wf" "$cip"
                ;;
        esac
    fi

    # A shared group across the standalone and the nested run would make one
    # queue behind the other rather than run alongside it.
    grp=$(awk '/^concurrency:/{f=1;next} f&&/^[a-z]/{exit} f&&/group:/{sub(/^ *group: */,"");print;exit}' "$f")
    case "$grp" in
        *"github.run_id"*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: %s has no per-run fallback in its concurrency group: %s\n" "$wf" "$grp"
            ;;
    esac
done

# The release workflow must keep serialising releases without cancelling them.
rel_cip=$(awk '/^concurrency:/{f=1;next} f&&/^[a-z]/{exit} f&&/cancel-in-progress:/{sub(/^ *cancel-in-progress: */,"");print;exit}' "$WF")
if [ "$rel_cip" = "false" ]; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
    printf "FAIL: auto-release.yml must not cancel in-progress releases (got '%s')\n" "$rel_cip"
fi

# ── The release is split in three; the split must stay safe ─────────────────
#
# `build` runs the ~26-minute OpenWrt SDK build PARALLEL to ci and compat rather
# than after them, which is where the release's wall clock went. That is only
# safe while three things hold, and none of them is visible from a diff:
#
#   1. `build` writes nowhere but the artifact store — no commit, no tag, no
#      push. Otherwise an unverified tree would reach main before the checks.
#   2. `publish` waits for ci AND compat as well as prepare and build.
#   3. `build` and `publish` operate on the SAME commit. If either re-resolved
#      origin/main, the tag could name commit A while the shipped artifact was
#      built from commit B, with both jobs green.

job_block() { awk -v j="  $1:" '$0==j{f=1;next} /^  [a-z_-]+:$/{if(f)exit} f' "$WF"; }

build_block=$(job_block build)
publish_block=$(job_block publish)

if [ -z "$build_block" ] || [ -z "$publish_block" ]; then
    FAIL=$((FAIL + 1))
    printf "FAIL: could not find the build and publish jobs in auto-release.yml\n"
else
    PASS=$((PASS + 1))

    if printf '%s\n' "$build_block" | grep -qE '^ *git (commit|tag|push)'; then
        FAIL=$((FAIL + 1))
        printf "FAIL: the build job commits/tags/pushes — it runs BEFORE ci and compat are green\n"
        printf '%s\n' "$build_block" | grep -nE '^ *git (commit|tag|push)'
    else
        PASS=$((PASS + 1))
    fi

    # Both halves must be pinned to the commit prepare measured.
    for j in build publish; do
        blk=$(job_block "$j")
        case "$blk" in
            *"needs.prepare.outputs.sha"*) PASS=$((PASS + 1)) ;;
            *)
                # publish checks out `main` by name and then asserts the SHA,
                # which is equivalent as long as the assertion is there.
                if [ "$j" = publish ] && printf '%s\n' "$blk" | grep -q 'Refuse to publish if main moved'; then
                    PASS=$((PASS + 1))
                else
                    FAIL=$((FAIL + 1))
                    printf "FAIL: the %s job is not pinned to the commit prepare measured\n" "$j"
                fi
                ;;
        esac
    done
fi

# publish must wait for the checks, not just for the build.
pub_needs=$(awk '/^  publish:/{f=1;next} f&&/^ *needs:/{print;exit}' "$WF")
for dep in ci compat feeds prepare build; do
    case "$pub_needs" in
        *"$dep"*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: publish does not depend on '%s' (needs: %s)\n" "$dep" "$pub_needs"
            ;;
    esac
done

# ──────────────────────────────────────────────────────────────────────────────
# The release build is handed to the compatibility matrix instead of the matrix
# making its own copy. Every assertion below guards a way for that to go wrong
# SILENTLY — a release that publishes an untested package while every job in
# the run is green.
# ──────────────────────────────────────────────────────────────────────────────
CWF="$(dirname "$WF")/compat.yml"

# Comment lines are STRIPPED before matching. Without that, the assertions
# below are satisfied by the prose explaining the guard rather than by the
# guard — verified by mutation: deleting the real `if: ${{ !cancelled() }}`
# left a comment containing the same literal and the test stayed green.
compat_call=$(awk '/^  compat:/{f=1;next} f&&/^  [a-z]/{exit} f{print}' "$WF" \
    | grep -vE '^[[:space:]]*#')

# 1. The matrix must still run when there is nothing to release. A plain
#    dependency on `build` would skip it on every docs:/chore: push — those
#    land on main unverified, and a chore: commit touching tools/ or the
#    Makefile can absolutely break the package build.
case "$compat_call" in
    *'!cancelled()'*) PASS=$((PASS + 1)) ;;
    *)
        FAIL=$((FAIL + 1))
        printf "FAIL: compat is gated on build without !cancelled() — a push with no release skips the whole matrix\n"
        ;;
esac

# 2. It must only reuse a build that actually produced the APK. Without the
#    have_apk check, a fork with no signing secrets gets a matrix addressing
#    an APK alias that was never created.
for needle in 'needs: [prepare, build]' "needs.build.result == 'success'" 'needs.build.outputs.have_apk'; do
    case "$compat_call" in
        *"$needle"*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: the compat call is missing '%s'\n" "$needle"
            ;;
    esac
done

case "$(awk '/^  build:/{f=1;next} f&&/^  [a-z]/{exit} f{print}' "$WF" | grep -vE '^[[:space:]]*#')" in
    *'have_apk: ${{ steps.apk_secrets.outputs.have }}'*) PASS=$((PASS + 1)) ;;
    *)
        FAIL=$((FAIL + 1))
        printf "FAIL: the build job does not expose have_apk, so compat cannot tell a signed build from the unsigned fallback\n"
        ;;
esac

if [ ! -f "$CWF" ]; then
    FAIL=$((FAIL + 1))
    printf "FAIL: cannot find compat.yml next to auto-release.yml\n"
else
    # 3. THE DANGEROUS ONE. build-packages is skipped in the reuse case, and a
    #    job whose `needs` was skipped is skipped too. Without an explicit
    #    guard every consumer silently disappears and the matrix reports green
    #    by absence — the release would be gated on nothing at all.
    for job in compat upgrade dependencies; do
        blk=$(awk -v j="^  $job:" '$0 ~ j {f=1;next} f&&/^  [a-z]/{exit} f{print}' "$CWF" \
            | grep -vE '^[[:space:]]*#')
        case "$blk" in
            *"needs.build-packages.result != 'failure'"*) PASS=$((PASS + 1)) ;;
            *)
                FAIL=$((FAIL + 1))
                printf "FAIL: compat.yml job '%s' depends on build-packages without guarding against it being SKIPPED — the matrix would go green by absence on every release\n" "$job"
                ;;
        esac
        # And each must read whichever artifact is in play, not the hardcoded one.
        case "$blk" in
            *"inputs.package_artifact || 'packages'"*) PASS=$((PASS + 1)) ;;
            *)
                FAIL=$((FAIL + 1))
                printf "FAIL: compat.yml job '%s' downloads a fixed artifact name, so it cannot consume the release build\n" "$job"
                ;;
        esac
    done

    # 4. No consumer may address a version-bearing filename. The release build
    #    has a real version and this workflow's own build has 0.0.0-test, so a
    #    hardcoded name is either a missing file or, worse, the wrong one.
    stray=$(grep -nE '/dist/luci-app-trafficctl_[0-9]' "$CWF" || true)
    if [ -n "$stray" ]; then
        FAIL=$((FAIL + 1))
        printf "FAIL: compat.yml still addresses a versioned package path:\n%s\n" "$stray"
    else
        PASS=$((PASS + 1))
    fi

    # 4b. The upgrade job must not move the previous release's package into
    #     the directory holding the new one. A release's assets include the
    #     version-free alias, so `mv` put the OLD package on top of the NEW
    #     one and the test upgraded a version to itself — green build, zero
    #     coverage. Caught on PR #91 by the matrix itself; pinned here.
    upg=$(awk '/^  upgrade:/{f=1;next} f&&/^  [a-z]/{exit} f{print}' "$CWF" \
        | grep -vE '^[[:space:]]*#')
    if printf '%s\n' "$upg" | grep -qE 'mv "\$OLD_PKG" "dist/'; then
        FAIL=$((FAIL + 1))
        printf "FAIL: the upgrade job moves the previous release into dist/, where its alias collides with the new package\n"
    else
        PASS=$((PASS + 1))
    fi
    case "$upg" in
        *'/dist-old:'*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: the upgrade job does not mount the previous release in its own directory\n"
            ;;
    esac

    # 5. Both builders must create the same two aliases, or "address it through
    #    the alias" only works on one of the two paths.
    for alias in 'dist/luci-app-trafficctl.ipk' 'dist/luci-app-trafficctl.apk'; do
        for f in "$WF" "$CWF"; do
            if grep -q "ln -f .*$alias" "$f"; then
                PASS=$((PASS + 1))
            else
                FAIL=$((FAIL + 1))
                printf "FAIL: %s never creates the alias %s\n" "$(basename "$f")" "$alias"
            fi
        done
    done

    # 6. build-packages must be skipped ONLY on reuse. Any other condition
    #    there would stop a pull request from building its packages at all.
    bp=$(awk '/^  build-packages:/{f=1;next} f&&/^  [a-z]/{exit} f{print}' "$CWF" \
        | grep -vE '^[[:space:]]*#')
    case "$bp" in
        *"if: \${{ inputs.package_artifact == '' }}"*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: compat.yml build-packages is not gated exactly on an empty package_artifact\n"
            ;;
    esac
fi

# ──────────────────────────────────────────────────────────────────────────────
# The feed-install check must stay OFF the critical path.
#
# It consumes nothing any other job builds — no artifact, no needs — and it had
# always run alongside the package build. It lived inside compat.yml, so when
# compat started waiting for `build` in order to reuse its packages, this got
# dragged behind the build too and the release went from ~32 minutes of
# overlapping work to ~46 of serialised work. Measured on run 38086343117.
# These assertions exist so that regression cannot be reintroduced by moving
# the job back or by gating the workflow that holds it.
# ──────────────────────────────────────────────────────────────────────────────
FWF="$(dirname "$WF")/feed-install.yml"

if [ ! -f "$FWF" ]; then
    FAIL=$((FAIL + 1))
    printf "FAIL: feed-install.yml is missing — if it moved back into compat.yml it is gated on the build again\n"
else
    PASS=$((PASS + 1))

    # Nothing in it may wait for anything.
    if grep -qE '^[[:space:]]+needs:' "$FWF"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: feed-install.yml has a needs: — it must not wait for any other job\n"
    else
        PASS=$((PASS + 1))
    fi
    # And it must not have acquired a dependency on built packages, which is
    # what would justify gating it in the first place.
    if grep -qE 'download-artifact|package_artifact' "$FWF"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: feed-install.yml now consumes a built artifact; the independence claim no longer holds\n"
    else
        PASS=$((PASS + 1))
    fi

    # The call site must be ungated too: a `needs:` on the reusable-workflow
    # call is exactly how the serialisation happened the first time.
    feeds_call=$(awk '/^  feeds:/{f=1;next} f&&/^  [a-z]/{exit} f{print}' "$WF" \
        | grep -vE '^[[:space:]]*#')
    case "$feeds_call" in
        *needs:*)
            FAIL=$((FAIL + 1))
            printf "FAIL: the feeds job in auto-release.yml is gated; it must run parallel to the build\n"
            ;;
        *) PASS=$((PASS + 1)) ;;
    esac
    case "$feeds_call" in
        *feed-install.yml*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: the feeds job does not call feed-install.yml\n"
            ;;
    esac
fi

# Matched as a JOB KEY, not as the string: the comment in compat.yml explaining
# why the job was moved out mentions it by name, and a bare grep fired on that
# prose. Third time this session an assertion was satisfied by the words
# describing the guard rather than by the guard.
if [ -f "$CWF" ] && grep -qE '^  feed-install:' "$CWF"; then
    FAIL=$((FAIL + 1))
    printf "FAIL: compat.yml holds feed-install again, so it inherits compat's gate on the build\n"
else
    PASS=$((PASS + 1))
fi

# ──────────────────────────────────────────────────────────────────────────────
# A superseded release must stand down GREEN; a rewritten history must not.
#
# The guard is EXTRACTED AND EXECUTED against a real repository rather than
# pattern-matched, the same way the bump decision above is, because the
# distinction it draws is a git question and a test that only greps for
# "merge-base" would pass on an inverted condition.
#
# Why green matters: a run superseded by a later merge is not a problem — the
# newer commit's own run syncs to the tip and its range covers this one's
# commits too (#86). Failing red there taught the maintainer that a failed
# release run is normal. Observed on run 38275308881.
# ──────────────────────────────────────────────────────────────────────────────
# This file counts PASS/FAIL inline and has no assert helpers; the block below
# needs them. Defined here rather than at the top so the existing assertions
# stay exactly as they were. NB: the first version of this block called
# helpers that did not exist — every call printed "command not found", not one
# assertion ran, and the suite still reported "68 passed, 0 failed". Hence the
# self-check immediately after.
assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: %s\n" "$1" "$2" "$3"
    fi
}
assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n  in: %s\n" "$1" "$2" "$3"
    else
        PASS=$((PASS + 1))
    fi
}
assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}
# The helpers must actually be callable and must actually be able to fail.
_before=$FAIL
# Output suppressed: this assertion is MEANT to fail, and printing its FAIL
# line makes a green run look broken in the CI log.
assert_contains "self-check" "absent" "present" >/dev/null 2>&1
if [ "$FAIL" -eq $((_before + 1)) ]; then
    FAIL=$_before
    PASS=$((PASS + 1))
else
    printf "FAIL: the assertion helpers in this block are not wired up\n"
    FAIL=$((_before + 1))
fi

GUARD=$(awk '/^      - name: Stand down if main moved/{f=1;next}
             f && /^        run: \|$/{g=1;next}
             g && /^      - /{exit}
             g{sub(/^          /,""); print}' "$WF")

if [ -z "$GUARD" ] || ! printf '%s\n' "$GUARD" | grep -q 'merge-base'; then
    FAIL=$((FAIL + 1))
    printf "FAIL: could not extract the stand-down guard from %s\n" "$WF"
else
    PASS=$((PASS + 1))
    GTMP=$(mktemp -d)
    (
        cd "$GTMP" || exit 1
        git init -q .
        git config user.email t@t; git config user.name t
        echo a > f; git add f; git commit -qm a       # A
        A=$(git rev-parse HEAD)
        echo b > f; git commit -qam b                 # B, child of A
        B=$(git rev-parse HEAD)
        git checkout -q --orphan other
        git rm -q -rf .; echo c > g; git add g; git commit -qm c   # unrelated
        C=$(git rev-parse HEAD)
        git checkout -q main 2>/dev/null || git checkout -q master
        printf '%s %s %s\n' "$A" "$B" "$C" > shas
    ) || { FAIL=$((FAIL + 1)); printf "FAIL: could not build the guard fixture\n"; }
    read -r A B C < "$GTMP/shas"

    # The workflow expression is the only thing the harness has to supply.
    run_guard() {
        local want="$1" head_sha="$2" out rc
        printf '%s\n' "$GUARD" \
            | sed "s|\${{ needs.prepare.outputs.sha }}|$want|" > "$GTMP/guard.sh"
        out=$( cd "$GTMP" && git checkout -q "$head_sha" && \
               GITHUB_OUTPUT="$GTMP/out" sh "$GTMP/guard.sh" 2>&1 )
        rc=$?
        printf '%s\n--rc=%s\n--out=%s\n' "$out" "$rc" "$(cat "$GTMP/out" 2>/dev/null)"
        : > "$GTMP/out"
    }

    # 1. unchanged tip: publish
    r=$(run_guard "$B" "$B")
    assert_contains "an unmoved tip proceeds to publish" "proceed=1" "$r"
    assert_contains "and exits zero" "--rc=0" "$r"

    # 2. superseded by a descendant: stand down, but GREEN
    r=$(run_guard "$A" "$B")
    assert_contains "being overtaken by a later merge does not publish" "proceed=0" "$r"
    assert_contains "and is not a failure" "--rc=0" "$r"
    assert_contains "and says it was superseded" "Superseded" "$r"
    assert_not_contains "and is not reported as an error" "::error::" "$r"

    # 3. history rewritten: that still fails, because nothing guarantees any
    #    later run covers this range.
    r=$(run_guard "$C" "$B")
    assert_contains "a tip that is not a descendant fails" "--rc=1" "$r"
    assert_contains "and is reported as an error" "::error::" "$r"
    assert_not_contains "and does not claim it was merely superseded" "Superseded" "$r"

    rm -rf "$GTMP"
fi

# Every step after the guard MUST be gated on its verdict. Without this a
# superseded run would tag and publish a stale tree, which is far worse than
# the red build this change removes.
ungated=$(python3 - "$WF" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d["jobs"]["publish"]["steps"]
bad = []
seen_guard = False
for st in steps:
    if not seen_guard:
        if str(st.get("name", "")).startswith("Stand down"):
            seen_guard = True
        continue
    if "steps.tip.outputs.proceed" not in str(st.get("if", "")):
        bad.append(st.get("name") or st.get("uses"))
print(", ".join(bad))
PYEOF
)
assert_eq "every publish step after the guard is gated on its verdict" "" "$ungated"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
