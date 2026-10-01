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

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
