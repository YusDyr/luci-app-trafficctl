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
BIN="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

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
# Structural, so a success message added later without the note fails here
# rather than shipping an unqualified claim. Checked per script because each
# has its own set of partial-success messages.
for f in trafficctl-ratelimit.sh trafficctl-shape.sh trafficctl-block.sh; do
    src="$BIN/$f"
    for fn in tctl_nss_status tctl_nss_defunct; do
        if grep -q "$fn" "$src"; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
            printf "FAIL: %s never calls %s\n" "$f" "$fn"
        fi
    done
    # Counted, not pattern-matched against the prose. An earlier version of
    # this test grepped for "applied to $IP" and missed the limiter's main
    # success message, which reads "rate limit ... for $IP" — verified by
    # mutation. The number of apply-success emissions per script is pinned
    # instead, so ADDING one without the verdict fails here too.
    case "$f" in
        trafficctl-ratelimit.sh) want=3 ;;
        trafficctl-shape.sh)     want=3 ;;
        trafficctl-block.sh)     want=2 ;;
    esac
    got=$(grep -c '\\"nss\\":\\"$NSS\\"' "$src")
    assert_eq "$f reports nss on each of its apply results" "$want" "$got"

    # And every one of them carries the human-readable verdict too, so the
    # operator sees it in the notification and not only in the JSON.
    bare=$(grep -n '\\"nss\\":\\"$NSS\\"' "$src" | grep -v 'NSSNOTE' | grep -v '\$NOTE')
    if [ -n "$bare" ]; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s reports nss as a field but omits the verdict from the message:\n%s\n" "$f" "$bare"
    else
        PASS=$((PASS + 1))
    fi
done

# ── the dashboard must surface it where people look ────────────────────────
# The apply result already says it on every attempt, but the Flow Offload
# panel is where somebody asking "why is my limit doing nothing" goes, and NSS
# is NOT one of the flow-offload modes that panel's toggles control.
SJS="$REPO_ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"
assert_contains "the dashboard reacts to an active NSS state" \
    "cfg.nss === 'active'" "$(cat "$SJS")"
assert_contains "and says the toggles beside it do not control NSS" \
    "do not control this" "$(cat "$SJS")"

# The dashboard needs it without applying anything.
RPCD="$REPO_ROOT/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
assert_contains "config_get reports the NSS status" '"nss":"%s"' "$(cat "$RPCD")"
assert_contains "config_get fills it from the detector" 'tctl_nss_status' "$(cat "$RPCD")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
