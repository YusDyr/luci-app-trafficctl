#!/bin/bash
# Qualcomm NSS / ECM detection and the honesty of what we report on such a
# router (issue #81).
#
# On an NSS build the Enhanced Connection Manager pushes flow rules into the
# NSS firmware cores and an accelerated flow never traverses the Linux stack.
# Every enforcement path in this package therefore does nothing there: the
# nftables netdev policer never sees the packets and Linux HTB never queues
# them. The reporter applied WiFi client limits and nothing was limited, while
# the UI said it had worked.
#
# None of this makes limits work on NSS — that needs nsshtb/nsstbl and
# hardware to develop against. What is tested here is that we stop claiming
# success, and that we do not overcorrect: somebody who has turned
# acceleration OFF must not be told their limits are broken.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/trafficctl/files/usr/libexec/trafficctl"

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
TMPDIR="$UC_TMP/nss"
mkdir -p "$TMPDIR"

ECM="$TMPDIR/ecm"

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" 2>/dev/null | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: %s\n" "$desc" "$needle" "$haystack"
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected nothing, got: '%s'\n" "$desc" "$actual"
    fi
}

# fw.sh names the debugfs root by absolute path, as it must on the router; the
# tests sed it into their scratch directory.
sed -e "s|TCTL_ECM_DEBUGFS=\"/sys/kernel/debug/ecm\"|TCTL_ECM_DEBUGFS=\"$ECM\"|" \
    "$BIN/trafficctl-fw.sh" > "$TMPDIR/fw.sh"
assert_contains "the debugfs root was redirected into the script under test" \
    "$ECM" "$(cat "$TMPDIR/fw.sh")"
assert_empty "no production debugfs path survives the rewrite" \
    "$(grep -n 'TCTL_ECM_DEBUGFS="/sys' "$TMPDIR/fw.sh")"

run() { sh -c ". '$TMPDIR/fw.sh'; $1" 2>/dev/null; }

# ── absent: an ordinary router must not be told anything ────────────────────
assert_eq "no ECM directory means absent" "absent" "$(run 'tctl_nss_status')"
assert_empty "nothing is appended to a message on a non-NSS router" \
    "$(run 'tctl_nss_note')"
assert_eq "tctl_nss_active is false when absent" "no" \
    "$(run 'tctl_nss_active && echo yes || echo no')"
assert_eq "defunct is a silent no-op when there is no ECM" "0" \
    "$(run 'tctl_nss_defunct; echo $?')"

# ── present and accelerating ───────────────────────────────────────────────
mkdir -p "$ECM"
assert_eq "an ECM directory with no stop knobs is treated as active" \
    "active" "$(run 'tctl_nss_status')"
assert_contains "the message says the rule is not enforced" \
    "NOT ENFORCED" "$(run 'tctl_nss_note')"
assert_contains "the message names the knob that turns acceleration off" \
    "front_end_ipv4_stop" "$(run 'tctl_nss_note')"

# A build whose debugfs layout we do not recognise is STILL accelerating.
# Reading a missing knob as "stopped" would restore exactly the false success
# this exists to remove, so it is pinned.
printf '0\n' > "$ECM/front_end_ipv4_stop"
assert_eq "v4 running is active" "active" "$(run 'tctl_nss_status')"
printf '1\n' > "$ECM/front_end_ipv4_stop"
assert_eq "v4 stopped but v6 knob missing is still active" \
    "active" "$(run 'tctl_nss_status')"
printf '0\n' > "$ECM/front_end_ipv6_stop"
assert_eq "v4 stopped but v6 running is still active" \
    "active" "$(run 'tctl_nss_status')"

# ── stopped: do not cry wolf ───────────────────────────────────────────────
# Somebody who turned acceleration off to get working QoS must not be told
# their limits do not work.
printf '1\n' > "$ECM/front_end_ipv6_stop"
assert_eq "both front ends stopped means the Linux datapath is whole" \
    "stopped" "$(run 'tctl_nss_status')"
assert_empty "nothing is appended once acceleration is stopped" \
    "$(run 'tctl_nss_note')"
assert_eq "tctl_nss_active is false when stopped" "no" \
    "$(run 'tctl_nss_active && echo yes || echo no')"

# ── defunct_all ────────────────────────────────────────────────────────────
# The NSS counterpart of the conntrack flush every rule change already does:
# an ALREADY accelerated flow is not re-evaluated against a rule that appeared
# afterwards, which presents as "the limit works sometimes".
mkdir -p "$ECM/ecm_db"
printf '' > "$ECM/ecm_db/defunct_all"
assert_eq "defunct writes to the knob when it is there" "0" \
    "$(run 'tctl_nss_defunct; echo $?')"
assert_eq "and what it writes is 1" "1" \
    "$(tr -d '\n' < "$ECM/ecm_db/defunct_all")"
# Must never fail the operation the caller is performing. Two separate
# guards, and both are exercised: the -w test (a knob that is not writable at
# all) and the `|| true` behind it (a path that passes -w but cannot be
# written to — a directory does exactly that, and is the only way to reach
# the second guard, which a chmod alone does not).
chmod 444 "$ECM/ecm_db/defunct_all"
assert_eq "a non-writable knob is still a success for the caller" "0" \
    "$(run 'tctl_nss_defunct; echo $?')"
rm -f "$ECM/ecm_db/defunct_all"
mkdir -p "$ECM/ecm_db/defunct_all"
assert_eq "a write that passes -w and then fails is still a success" "0" \
    "$(run 'tctl_nss_defunct; echo $?')"
rmdir "$ECM/ecm_db/defunct_all"
printf '' > "$ECM/ecm_db/defunct_all"

# ── every apply path must carry the verdict ────────────────────────────────
# Each apply path runs against an active ECM: the block in tests/test_block.sh,
# the shaper in tests/test_shape.sh, the limiter below. The shell helpers above
# have no caller left; they stay, pinned here, until trafficctl-fw.sh goes.

# ── the limiter, against an active ECM ─────────────────────────────────────
# Each of its three apply results (both directions, upload only, download
# only) carries the field and the verdict, and the flows ECM holds are
# defuncted.
# shellcheck source=tests/lib/limit_env.sh
. "$UC_TESTLIB/limit_env.sh"
lt_net br-lan lan1
LECM="$ROOT/sys/kernel/debug/ecm"
mkdir -p "$LECM/ecm_db"
for c in both:: up:dl_br_lan: down::ul_lan1; do
    IFS=: read -r name hooks chains <<EOF
$c
EOF
    lt_reset
    : > "$LECM/ecm_db/defunct_all"
    OUT=$(NFT_FAIL_HOOKS="$hooks dl" NFT_FAIL_CHAINS="$chains" lt_run ratelimit 192.168.1.50 5000)
    [ "$name" = both ] && OUT=$(lt_run ratelimit 192.168.1.50 5000)
    assert_contains "limiter $name: reports nss" '"nss":"active"' "$OUT"
    assert_contains "limiter $name: the message says the limit is not enforced" "NOT ENFORCED" "$OUT"
    assert_eq "limiter $name: accelerated flows are defuncted" "1" "$(tr -d '\n' < "$LECM/ecm_db/defunct_all")"
done
assert_contains "limiter: the last case was the download-only result" "DOWNLOAD ONLY" "$OUT"
echo 1 > "$LECM/front_end_ipv4_stop"
echo 1 > "$LECM/front_end_ipv6_stop"
lt_reset
OUT=$(lt_run ratelimit 192.168.1.50 5000)
assert_contains "limiter, acceleration stopped: reported" '"nss":"stopped"' "$OUT"
if printf '%s' "$OUT" | grep -q 'NOT ENFORCED'; then
    FAIL=$((FAIL + 1)); printf "FAIL: limiter, acceleration stopped: warned anyway\n"
else
    PASS=$((PASS + 1))
fi

# ── the dashboard must surface it where people look ────────────────────────
# The apply result already says it on every attempt, but the Flow Offload
# panel is where somebody asking "why is my limit doing nothing" goes, and NSS
# is NOT one of the flow-offload modes that panel's toggles control.
# The Flow Offload panel — and the NSS warning inside it — moved to the
# Settings view in #90.
SJS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/settings.js"
assert_contains "the dashboard reacts to an active NSS state" \
    "cfg.nss === 'active'" "$(cat "$SJS")"
assert_contains "and says the toggles beside it do not control NSS" \
    "do not control this" "$(cat "$SJS")"

# The dashboard needs it without applying anything.
RPCD="$REPO_ROOT/luci-app-trafficctl/root/usr/share/rpcd/ucode/luci.trafficctl.uc"
# The plugin reads the same ECM knobs through lib.nss_status (the block's
# reader too); tests/test_rpcd.sh drives it.
LIBUC="$REPO_ROOT/trafficctl/files/usr/share/ucode/trafficctl/lib.uc"
assert_contains "config_get reports the NSS status" 'nss: lib.nss_status(),' "$(cat "$RPCD")"
assert_contains "lib.uc reads the ECM debugfs directory" "'/sys/kernel/debug/ecm'" "$(cat "$LIBUC")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
