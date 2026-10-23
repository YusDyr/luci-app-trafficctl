#!/bin/bash
# Whether a per-device restriction survives a reboot, and whether the app says
# so when it will not (#105).
#
# The reported defect was an inconsistency, not a missing feature. A traffic
# SHAPE persists unconditionally — the shaper has to record which HTB class
# belongs to which device, so shapes.json is always written and the ifup hook
# always restores it. A block or a rate limit only persisted when
# persist_rules was on, and that shipped OFF. Since the default mode is the
# limiter, the out-of-the-box path was the one that forgot.
#
# So the same intention behaved two ways depending on which control the
# operator reached for, and the only visible "keep after reboot" toggle
# belonged to a different feature (the global cut, whose opt-in is separate on
# purpose: it can lock out whoever administers the router through a LAN host).
#
# Two things are pinned here: the default, and the honesty of the result when
# the default has been turned off.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin"
CONF="$REPO_ROOT/luci-app-trafficctl/root/etc/config/trafficctl"
HOOK="$REPO_ROOT/luci-app-trafficctl/root/etc/hotplug.d/iface/99-trafficctl-shapes"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"

assert_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$1" "$2" "$3"
    fi
}
assert_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in: %s\n" "$1" "$2" "$3"
    fi
}

# ── the shipped default ────────────────────────────────────────────────────
# A new install must behave the way the reporter expected. Asserted on the
# shipped file because that is what a new install gets; an existing install
# keeps its own copy (conffile), which is correct — a deliberate 0 is
# indistinguishable from an untouched one, so upgrades must not overwrite it.
shipped=$(awk '/^[[:space:]]*option persist_rules/ { gsub(/[^0-9]/, "", $3); print $3; exit }' "$CONF")
assert_eq "blocks and limits persist by default in the shipped config" "1" "$shipped"

# The global cut keeps its OWN opt-in, and it must stay off: it is the one
# control that can lock out its own operator, so a reboot has to undo it.
cutpersist=$(awk '/^config cut/ { inc = 1 } inc && /^[[:space:]]*option persist/ { gsub(/[^0-9]/, "", $3); print $3; exit }' "$CONF")
assert_eq "the global cut does NOT persist by default" "0" "$cutpersist"

# ── the qualifier ─────────────────────────────────────────────────────────
cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
while [ "\$1" = "-q" ]; do shift; done
[ "\$1" = "get" ] || exit 1
[ "\$2" = "trafficctl.main.persist_rules" ] && { cat "$TMPDIR/persist"; exit 0; }
exit 1
MOCK
cat > "$MOCKBIN/nft" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN"/*

note() { PATH="$MOCKBIN:$PATH" sh -c ". '$BIN/trafficctl-fw.sh'; tctl_persist_note" 2>/dev/null; }

printf '1\n' > "$TMPDIR/persist"
assert_eq "nothing is appended when persistence is on" "" "$(note)"

printf '0\n' > "$TMPDIR/persist"
out=$(note)
assert_contains "the message says the rule is not persistent" "NOT PERSISTENT" "$out"
assert_contains "and that it will be lost on reboot" "lost on reboot" "$out"
# A complaint with no remedy is just a complaint; the exact command is what
# makes it actionable over SSH, where the reporter was.
assert_contains "and names the uci command that fixes it" \
    "uci set trafficctl.main.persist_rules=1" "$out"

# ── every losable apply path must carry it ────────────────────────────────
# Counted rather than grepped for prose: adding a success message without the
# qualifier should fail here too. The numbers match the apply results each
# script emits (3 for the limiter, 2 for block).
for pair in "trafficctl-ratelimit.sh:3" "trafficctl-block.sh:2"; do
    f=${pair%%:*}; want=${pair##*:}
    got=$(grep -c '\\"persist\\":\$PERSIST' "$BIN/$f")
    assert_eq "$f reports persist on each of its apply results" "$want" "$got"
    if grep -q 'tctl_persist_note' "$BIN/$f"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s does not append the persistence qualifier\n" "$f"
    fi
done

# ── the restore path ──────────────────────────────────────────────────────
# Shapes are restored unconditionally and blocks are restored behind the flag.
# That asymmetry is now harmless because the flag defaults on, but it is still
# the shape of the original bug, so both halves are pinned: if the shape
# restore ever grows a persist guard, shapes stop coming back for anyone who
# turned the flag off, and that is a regression in the other direction.
shapes_block=$(awk '/^# Restore shaping rules/ { f = 1 } f { print } f && /^fi$/ { exit }' "$HOOK")
case "$shapes_block" in
    *tctl_persist_enabled*)
        FAIL=$((FAIL + 1))
        printf "FAIL: shape restore is now gated on persist_rules — shapes used to come back regardless\n"
        ;;
    *) PASS=$((PASS + 1)) ;;
esac

rules_block=$(awk '/^# Restore blocks and ratelimits/ { f = 1 } f { print } f && /^fi$/ { exit }' "$HOOK")
case "$rules_block" in
    *tctl_persist_enabled*) PASS=$((PASS + 1)) ;;
    *)
        FAIL=$((FAIL + 1))
        printf "FAIL: the block/ratelimit restore no longer checks persist_rules\n"
        ;;
esac
for kind in block ratelimit; do
    case "$rules_block" in
        *"$kind)"*) PASS=$((PASS + 1)) ;;
        *)
            FAIL=$((FAIL + 1))
            printf "FAIL: the restore hook does not handle a persisted '%s' record\n" "$kind"
            ;;
    esac
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
