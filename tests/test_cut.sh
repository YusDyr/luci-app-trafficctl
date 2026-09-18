#!/bin/bash
# Global internet cut (#55).
#
# This control has two failure directions and they pull against each other, so
# most of what follows tests refusals and reconciliation rather than the happy
# path:
#
#   * Too sticky — it is the one control in the app that can lock out its own
#     operator. Anyone administering the router through a LAN host loses that
#     path while it is on, so the engaged state must not survive a reboot
#     unless someone explicitly asked for that, and must never inherit the
#     unrelated global persist_rules flag.
#   * Too leaky — a cut whose rule quietly lapsed while the UI still reads ON
#     is worse than no cut at all, because the device it was protecting is on
#     the internet and nobody knows.
#
# The happy-path test is deliberately the small one.

PASS=0
FAIL=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin"
RPCD="$REPO_ROOT/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
ACL="$REPO_ROOT/luci-app-trafficctl/root/usr/share/rpcd/acl.d/luci-app-trafficctl.json"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MOCKBIN="$TMP/bin"
mkdir -p "$MOCKBIN" "$TMP/run" "$TMP/etc"

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
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
    fi
}

assert_empty() {
    local desc="$1" actual="$2"
    if [ -z "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected nothing, got:\n%s\n" "$desc" "$actual"
    fi
}

# ════════════════════════════════════════════════════════════════════════════
# Harness
# ════════════════════════════════════════════════════════════════════════════

CLOCK="$TMP/clock"
NFT_LOG="$TMP/nft.log"
CT_LOG="$TMP/conntrack.log"
INIT_LOG="$TMP/init.log"
KEEPER_FLAG="$TMP/keeper.running"
CHAIN="$TMP/nft_chain"          # exists = table exists; contents = its rules
UCIVALS="$TMP/uci.vals"
STATE="$TMP/run/cut.state"
PSTATE="$TMP/etc/cut.state"

echo 1700000000 > "$CLOCK"

# Controllable clock. Everything else falls through to the real date, because
# tctl_log formats timestamps with it.
cat > "$MOCKBIN/date" <<MOCK
#!/bin/sh
if [ "\$1" = "+%s" ]; then cat "$CLOCK"; exit 0; fi
exec /bin/date "\$@"
MOCK

# nft mock backed by a single file that stands in for our own table: the file
# existing means \`inet tctl_cut\` exists, its lines are the rules in the chain.
# That is enough to model the two situations that matter — the rule being
# there, and the table having been taken out from under us.
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
echo "\$*" >> "$NFT_LOG"
case "\$*" in
    "list tables")
        [ -f "$TMP/no_nft" ] && exit 0
        echo "table inet fw4"
        ;;
    "add table inet tctl_cut")
        [ -f "$CHAIN" ] || : > "$CHAIN"
        ;;
    "add chain inet tctl_cut cut_forward"*)
        [ -f "$CHAIN" ] || : > "$CHAIN"
        ;;
    "flush chain inet tctl_cut cut_forward")
        [ -f "$CHAIN" ] && : > "$CHAIN"
        ;;
    "add rule inet tctl_cut cut_forward"*)
        [ -f "$CHAIN" ] || exit 1
        shift 5
        echo "\$*" >> "$CHAIN"
        ;;
    "list chain inet tctl_cut cut_forward")
        [ -f "$CHAIN" ] || exit 1
        cat "$CHAIN"
        ;;
    "delete table inet tctl_cut")
        rm -f "$CHAIN"
        ;;
esac
exit 0
MOCK

# -C is the capability probe: cheap, and it fails when nf_conntrack is not
# loaded. -D cannot serve that purpose because it also fails when there was
# simply nothing to delete.
cat > "$MOCKBIN/conntrack" <<MOCK
#!/bin/sh
echo "\$*" >> "$CT_LOG"
if [ "\$1" = "-C" ]; then
    [ -f "$TMP/no_conntrack" ] && exit 1
    echo 42
fi
exit 0
MOCK

cat > "$MOCKBIN/pgrep" <<MOCK
#!/bin/sh
[ -f "$KEEPER_FLAG" ] && exit 0
exit 1
MOCK

# Stands in for /etc/init.d/trafficctl-cut.
cat > "$MOCKBIN/cut-init" <<MOCK
#!/bin/sh
echo "\$*" >> "$INIT_LOG"
case "\$1" in
    start) : > "$KEEPER_FLAG" ;;
    stop)  rm -f "$KEEPER_FLAG" ;;
esac
exit 0
MOCK

printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/logger"

# uci keys carry [0], which is a glob character class to case/grep — matched
# literally with awk instead.
cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
key=""
for a in "\$@"; do
    case "\$a" in trafficctl.*|firewall.*|network.*) key="\$a" ;; esac
done
[ -n "\$key" ] || exit 1
awk -v k="\$key" 'index(\$0, k "=") == 1 { sub(/^[^=]*=/, ""); print; exit; ok=1 }' "$UCIVALS" | {
    read -r v || exit 1
    [ -n "\$v" ] || exit 1
    printf '%s\n' "\$v"
}
MOCK

cat > "$MOCKBIN/ubus" <<'MOCK'
#!/bin/sh
case "$2" in
    network.interface.wan) echo '{"l3_device":"eth1"}' ;;
    *) echo '{"l3_device":"br-lan","ipv4-address":[{"address":"192.168.1.1","mask":24}]}' ;;
esac
MOCK

cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
input=$(cat)
case "$2" in
    '@.l3_device') echo "$input" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].address') echo "$input" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].mask') echo "$input" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p' ;;
esac
MOCK

# No routed subnets and no default route to discover.
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/ip"

chmod +x "$MOCKBIN"/*

cat > "$UCIVALS" <<'VALS'
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan
network.lan.device=br-lan
network.wan.device=eth1
trafficctl.logging.enabled=0
trafficctl.cut.default_duration=900
trafficctl.cut.persist=0
VALS

# The script names its state files by absolute path, as it must on the router.
# They are rewritten into the scratch directory rather than adding test-only
# override variables to the shipped code (the approach test_newdevice.sh takes).
CUT="$TMP/cut.sh"
sed -e "s|\\. /usr/local/bin/trafficctl-fw.sh|. $BIN/trafficctl-fw.sh|" \
    -e "s|CUT_RUN_DIR=\"/var/run/trafficctl\"|CUT_RUN_DIR=\"$TMP/run\"|" \
    -e "s|CUT_STATE=\"/var/run/trafficctl/cut.state\"|CUT_STATE=\"$STATE\"|" \
    -e "s|CUT_PERSIST_STATE=\"/etc/trafficctl/cut.state\"|CUT_PERSIST_STATE=\"$PSTATE\"|" \
    -e "s|CUT_INIT=\"/etc/init.d/trafficctl-cut\"|CUT_INIT=\"$MOCKBIN/cut-init\"|" \
    "$BIN/trafficctl-cut.sh" > "$CUT"

# A silently unpatched copy would touch the real /etc and /var/run and make
# every assertion below meaningless.
assert_contains "harness: the runtime state path was redirected" "$STATE" "$(cat "$CUT")"
assert_contains "harness: the persist state path was redirected" "$PSTATE" "$(cat "$CUT")"
assert_empty "harness: no production state path survived the rewrite" \
    "$(grep -n '"/var/run/trafficctl\|"/etc/trafficctl/cut.state\|"/etc/init.d/trafficctl-cut' "$CUT")"

run_cut() {
    PATH="$MOCKBIN:$PATH" sh "$CUT" "$@" 2>&1
}

reset_state() {
    rm -f "$STATE" "$PSTATE" "$CHAIN" "$KEEPER_FLAG" "$TMP/no_nft"
    : > "$NFT_LOG"; : > "$CT_LOG"; : > "$INIT_LOG"
    echo 1700000000 > "$CLOCK"
}

# ════════════════════════════════════════════════════════════════════════════
# Refusals — the cases where engaging must NOT happen
# ════════════════════════════════════════════════════════════════════════════

reset_state
OUT=$(run_cut)
assert_contains "no subcommand is rejected" '"ok":false' "$OUT"

OUT=$(run_cut engage abc)
assert_contains "engage: a non-numeric duration is rejected" '"ok":false' "$OUT"
assert_eq "engage: a non-numeric duration installs no rule" "no" \
    "$([ -f "$CHAIN" ] && echo yes || echo no)"

OUT=$(run_cut engage 5)
assert_contains "engage: a duration below the floor is rejected" '"ok":false' "$OUT"

OUT=$(run_cut engage 99999999)
assert_contains "engage: a duration above the ceiling is rejected" '"ok":false' "$OUT"

OUT=$(run_cut engage 900 2)
assert_contains "engage: a persist flag that is not 0 or 1 is rejected" '"ok":false' "$OUT"
assert_eq "engage: a bad persist flag installs no rule" "no" \
    "$([ -f "$CHAIN" ] && echo yes || echo no)"

# GUARD: the LAN-device refusal.
#
# The rule reads "drop anything not leaving through a LAN device". With no LAN
# devices that set is empty and the rule becomes "drop everything forwarded" —
# it would black-hole the LAN this feature exists to keep working, including
# the operator's own path to the router. Guessing is not an option here.
reset_state
cat > "$TMP/uci.empty" <<'VALS'
trafficctl.logging.enabled=0
VALS
OUT=$(PATH="$MOCKBIN:$PATH" sh -c "UCIVALS_OVERRIDE=1; cp '$TMP/uci.empty' '$UCIVALS'; sh '$CUT' engage 900 0" 2>&1)
assert_contains "no LAN interfaces: refuses instead of cutting" '"ok":false' "$OUT"
assert_contains "no LAN interfaces: says why" "no LAN interfaces" "$OUT"
assert_eq "no LAN interfaces: installs no rule at all" "no" \
    "$([ -f "$CHAIN" ] && echo yes || echo no)"
assert_eq "no LAN interfaces: writes no state, so nothing reads as engaged" "no" \
    "$([ -f "$STATE" ] && echo yes || echo no)"

# restore the working uci
cat > "$UCIVALS" <<'VALS'
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan
network.lan.device=br-lan
network.wan.device=eth1
trafficctl.logging.enabled=0
trafficctl.cut.default_duration=900
trafficctl.cut.persist=0
VALS

# An iptables-only router gets a refusal rather than a button that does
# nothing: a silent no-op is exactly the lying-UI failure this feature is
# supposed to avoid.
reset_state
: > "$TMP/no_nft"
OUT=$(run_cut engage 900 0)
assert_contains "iptables backend: refuses rather than pretending" '"ok":false' "$OUT"
assert_contains "iptables backend: names the reason" "nftables" "$OUT"
rm -f "$TMP/no_nft"

# ════════════════════════════════════════════════════════════════════════════
# The happy path
# ════════════════════════════════════════════════════════════════════════════

reset_state
OUT=$(run_cut engage 900 0)
assert_contains "engage: reports ok" '"ok":true' "$OUT"
assert_contains "engage: reports itself active" '"active":true' "$OUT"
assert_contains "engage: confirms the rule is live, not just recorded" '"rule_present":true' "$OUT"
assert_contains "engage: reports the LAN devices it spared" '"lan_devices":"br-lan"' "$OUT"

RULE=$(cat "$CHAIN")
assert_contains "engage: the rule spares traffic leaving via a LAN device" 'oifname != { "br-lan" }' "$RULE"
assert_contains "engage: the rule drops, with a counter" "counter drop" "$RULE"
assert_contains "engage: the rule carries the full comment used to find it" 'comment "tctl_cut"' "$RULE"

NFT=$(cat "$NFT_LOG")
assert_contains "engage: the chain hooks forward, not input — the router stays reachable" \
    "type filter hook forward priority -190" "$NFT"
assert_not_contains "engage: nothing is written into fw4's own table" "inet fw4 forward" "$NFT"

# Established flows outlive a new drop rule, and an offloaded flow bypasses the
# forward hook entirely — without this the toggle reads ON while the TV
# finishes its download.
CT=$(cat "$CT_LOG")
assert_contains "engage: flushes conntrack for the LAN subnet as source" "-D -s 192.168.1.0/24" "$CT"
assert_contains "engage: flushes conntrack for the LAN subnet as destination" "-D -d 192.168.1.0/24" "$CT"
assert_not_contains "engage: does not flush conntrack globally" "-F" "$CT"

assert_contains "engage: starts the keeper" "start" "$(cat "$INIT_LOG")"

OUT=$(run_cut status)
assert_contains "status: still active" '"active":true' "$OUT"
assert_contains "status: still live" '"rule_present":true' "$OUT"
assert_contains "status: reports the remaining time" '"remaining":900' "$OUT"
assert_contains "status: reports it is not persistent" '"persist":false' "$OUT"

OUT=$(run_cut release)
assert_contains "release: reports ok" '"ok":true' "$OUT"
assert_eq "release: the table is gone" "no" "$([ -f "$CHAIN" ] && echo yes || echo no)"
OUT=$(run_cut status)
assert_contains "release: status reads off" '"active":false' "$OUT"
assert_contains "release: and confirms no rule is live" '"rule_present":false' "$OUT"

# Whether the flush WORKED cannot be read off `conntrack -D`: it fails both
# when the tool is broken and when there was simply nothing to delete. The
# capability is probed with -C instead, and when it is unavailable the cut
# still goes on — but says so, rather than leaving the operator believing
# established flows were torn down.
reset_state
: > "$TMP/no_conntrack"
OUT=$(run_cut engage 900 0)
assert_contains "no conntrack: the cut still engages" '"ok":true' "$OUT"
assert_contains "no conntrack: and admits older connections may linger" \
    "conntrack unavailable" "$OUT"
assert_not_contains "no conntrack: no deletes are attempted once the probe failed" \
    "-D -s" "$(cat "$CT_LOG")"
rm -f "$TMP/no_conntrack"
run_cut release >/dev/null

# ════════════════════════════════════════════════════════════════════════════
# Persistence — its own opt-in, never inherited
# ════════════════════════════════════════════════════════════════════════════

# GUARD: the persist opt-in.
#
# persist_rules (Settings → Logging & Persistence) is a global flag somebody
# may have turned on so their per-device rate limits survive a reboot. If the
# cut inherited it, that operator would get a persistent internet kill out of
# an unrelated decision — a lockout reached by accident. The state in /etc is
# written only when this call says so, explicitly.
reset_state
echo 'trafficctl.main.persist_rules=1' >> "$UCIVALS"
run_cut engage 900 0 >/dev/null
assert_eq "persist: NOT inherited from the global persist_rules flag" "no" \
    "$([ -f "$PSTATE" ] && echo yes || echo no)"
assert_eq "persist: the runtime state still exists, so the cut is live" "yes" \
    "$([ -f "$STATE" ] && echo yes || echo no)"
run_cut release >/dev/null

reset_state
run_cut engage 900 1 >/dev/null
assert_eq "persist: an explicit opt-in does write the /etc copy" "yes" \
    "$([ -f "$PSTATE" ] && echo yes || echo no)"
assert_contains "persist: the /etc copy records the opt-in" "persist=1" "$(cat "$PSTATE")"
assert_contains "persist: the /etc copy stores an absolute deadline" "expires_at=1700000900" "$(cat "$PSTATE")"
OUT=$(run_cut status)
assert_contains "persist: status reports it" '"persist":true' "$OUT"

# Restore must honour the ORIGINAL deadline. Storing a remaining duration and
# counting down again from boot would silently extend the cut by a full
# duration on every reboot.
rm -f "$STATE" "$CHAIN" "$KEEPER_FLAG"
echo 1700000300 > "$CLOCK"           # 300s of the 900 elapsed, incl. downtime
run_cut restore >/dev/null
assert_eq "restore: puts the rule back" "yes" "$([ -f "$CHAIN" ] && echo yes || echo no)"
OUT=$(run_cut status)
assert_contains "restore: keeps the original deadline, it does not restart the clock" \
    '"expires_at":1700000900' "$OUT"
assert_contains "restore: so the remaining time has shrunk" '"remaining":600' "$OUT"

# A deadline that passed while the router was down is honoured, not revived.
rm -f "$STATE" "$CHAIN"
echo 1700009999 > "$CLOCK"
run_cut restore >/dev/null
assert_eq "restore: an expired cut is not re-engaged" "no" \
    "$([ -f "$CHAIN" ] && echo yes || echo no)"
assert_eq "restore: and its /etc state is cleaned up" "no" \
    "$([ -f "$PSTATE" ] && echo yes || echo no)"

# A stale /etc file that does not actually carry the opt-in is not consent.
reset_state
printf 'expires_at=0\npersist=0\nstarted_at=1700000000\n' > "$PSTATE"
run_cut restore >/dev/null
assert_eq "restore: a state file without the opt-in engages nothing" "no" \
    "$([ -f "$CHAIN" ] && echo yes || echo no)"
assert_eq "restore: and is discarded" "no" "$([ -f "$PSTATE" ] && echo yes || echo no)"

# Remove the persist_rules line again for the remaining cases.
grep -v '^trafficctl.main.persist_rules=' "$UCIVALS" > "$UCIVALS.tmp" && mv "$UCIVALS.tmp" "$UCIVALS"

# ════════════════════════════════════════════════════════════════════════════
# Auto-revert — the safety net that must not depend on anyone remembering
# ════════════════════════════════════════════════════════════════════════════

# GUARD: status reconciles against the deadline.
#
# The keeper normally performs the auto-revert, but it is one process and it
# can die. Reporting "on" for a cut whose time ran out would strand the
# operator, so status enforces the deadline itself on every poll.
reset_state
run_cut engage 900 0 >/dev/null
echo 1700000901 > "$CLOCK"
rm -f "$KEEPER_FLAG"                  # the keeper is gone; nothing else will act
OUT=$(run_cut status)
assert_contains "expiry: status reports the cut as off once the deadline passed" '"active":false' "$OUT"
assert_contains "expiry: and confirms no rule is live" '"rule_present":false' "$OUT"
assert_eq "expiry: the table really was removed" "no" "$([ -f "$CHAIN" ] && echo yes || echo no)"
assert_eq "expiry: the state file is cleared" "no" "$([ -f "$STATE" ] && echo yes || echo no)"

# The keeper reaches the same conclusion on its own.
reset_state
run_cut engage 900 0 >/dev/null
echo 1700000901 > "$CLOCK"
run_cut tick >/dev/null
assert_eq "expiry: a keeper tick past the deadline restores the internet" "no" \
    "$([ -f "$CHAIN" ] && echo yes || echo no)"

# Indefinite means indefinite: no deadline, so no amount of elapsed time ends it.
reset_state
OUT=$(run_cut engage 0 0)
assert_contains "indefinite: accepted" '"ok":true' "$OUT"
assert_contains "indefinite: recorded as having no deadline" '"expires_at":0' "$OUT"
echo 1799999999 > "$CLOCK"
OUT=$(run_cut status)
assert_contains "indefinite: still on much later" '"active":true' "$OUT"
assert_contains "indefinite: and still live" '"rule_present":true' "$OUT"

# A cut that is on but has lost its keeper gets a new one, so the auto-revert
# is not staked on a single process surviving.
reset_state
run_cut engage 900 0 >/dev/null
rm -f "$KEEPER_FLAG"
: > "$INIT_LOG"
run_cut status >/dev/null
assert_contains "keeper: status restarts one that died" "start" "$(cat "$INIT_LOG")"

# ════════════════════════════════════════════════════════════════════════════
# The rule lapsing — the failure the UI must never paper over
# ════════════════════════════════════════════════════════════════════════════

# GUARD: reported state comes from the kernel, not from the state file.
#
# Rules in `inet fw4` are flushed whenever fw4 rebuilds; the cut lives in its
# own table for that reason, but a wholesale `nft flush ruleset` still takes it.
# If that happens, the honest answer is "switched on, but not in force" — never
# a plain ON, because the device this was protecting is on the internet.
reset_state
run_cut engage 900 0 >/dev/null
rm -f "$CHAIN"                        # somebody flushed the whole ruleset
OUT=$(run_cut status)
assert_contains "lapsed rule: the state file still says engaged" '"active":true' "$OUT"
assert_contains "lapsed rule: but the live check says it is NOT in force" '"rule_present":false' "$OUT"

# And the keeper puts it back.
run_cut tick >/dev/null
assert_eq "lapsed rule: a keeper tick re-asserts it" "yes" \
    "$([ -f "$CHAIN" ] && echo yes || echo no)"
assert_contains "lapsed rule: the re-asserted rule is the same rule" 'comment "tctl_cut"' "$(cat "$CHAIN")"
OUT=$(run_cut status)
assert_contains "lapsed rule: and status reads live again" '"rule_present":true' "$OUT"

# A rule left behind with no state is the mirror image, and just as wrong: the
# internet would stay off with nothing claiming to be holding it off.
reset_state
: > "$CHAIN"
echo 'oifname != { "br-lan" } counter drop comment "tctl_cut"' >> "$CHAIN"
run_cut tick >/dev/null
assert_eq "orphaned rule: a tick with no state removes it" "no" \
    "$([ -f "$CHAIN" ] && echo yes || echo no)"

# ════════════════════════════════════════════════════════════════════════════
# Wiring — a method rpcd does not list is a method that does not exist
# ════════════════════════════════════════════════════════════════════════════

RPCD_SH="$TMP/rpcd"
sed "s|\\. /usr/local/bin/trafficctl-fw.sh|. $BIN/trafficctl-fw.sh|" "$RPCD" > "$RPCD_SH"
LIST=$(PATH="$MOCKBIN:$PATH" sh "$RPCD_SH" list 2>/dev/null)
assert_contains "rpcd: cut_status is advertised by the list case" '"cut_status"' "$LIST"
assert_contains "rpcd: cut_set is advertised with its parameters" \
    '"cut_set":{"active":"bool","duration":"int","persist":"bool"}' "$LIST"

ACLTXT=$(cat "$ACL")
assert_contains "acl: cut_status is granted" '"cut_status"' "$ACLTXT"
assert_contains "acl: cut_set is granted" '"cut_set"' "$ACLTXT"
# Both sit under write: cut_status is not observational, it reconciles.
WRITE_BLOCK=$(awk '/"write"/,0' "$ACL")
assert_contains "acl: cut_status is a write method, like activity_log" '"cut_status"' "$WRITE_BLOCK"

# ── The boot hook ───────────────────────────────────────────────────────────
#
# GUARD: the restore must key off the cut's OWN state file, never off the
# global persist_rules flag. The hotplug script restores blocks and rate limits
# inside an `if ... tctl_persist_enabled` block; if the cut were restored from
# in there, anybody who enabled that flag for their rate limits would get a
# persistent internet kill out of an unrelated decision. Asserted by running
# the hook with persist_rules OFF and a cut state file present: the cut must
# still come back, which can only happen from outside that block.
HOTPLUG="$REPO_ROOT/luci-app-trafficctl/root/etc/hotplug.d/iface/99-trafficctl-shapes"
HP="$TMP/hotplug"
CUT_CALL_LOG="$TMP/cutcall.log"
sed -e "s|\\. /usr/local/bin/trafficctl-fw.sh|. $BIN/trafficctl-fw.sh|" \
    -e "s|/usr/local/bin/trafficctl-cut.sh|$MOCKBIN/cut-stub|" \
    -e "s|/etc/trafficctl/cut.state|$PSTATE|" \
    "$HOTPLUG" > "$HP"

cat > "$MOCKBIN/cut-stub" <<MOCK
#!/bin/sh
echo "\$*" >> "$CUT_CALL_LOG"
exit 0
MOCK
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/tc"
chmod +x "$MOCKBIN/cut-stub" "$MOCKBIN/tc"

run_hotplug() {
    : > "$CUT_CALL_LOG"
    PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HP" >/dev/null 2>&1
    cat "$CUT_CALL_LOG" 2>/dev/null
}

# persist_rules is explicitly OFF here — its absence must not matter.
reset_state
grep -v '^trafficctl.main.persist_rules=' "$UCIVALS" > "$UCIVALS.tmp" && mv "$UCIVALS.tmp" "$UCIVALS"
echo 'trafficctl.main.persist_rules=0' >> "$UCIVALS"
printf 'expires_at=0\npersist=1\nstarted_at=1700000000\n' > "$PSTATE"
assert_contains "hotplug: restores the cut even with persist_rules off" \
    "restore" "$(run_hotplug)"

# ...and with no state file there is nothing to restore, so it is not called.
rm -f "$PSTATE"
assert_empty "hotplug: no state file means the cut is not touched at all" "$(run_hotplug)"

# A cut that outlives a firmware upgrade is strictly worse than one that
# outlives a reboot, so its state deliberately is not preserved by sysupgrade.
KEEPD="$REPO_ROOT/luci-app-trafficctl/root/lib/upgrade/keep.d/luci-app-trafficctl"
assert_empty "keep.d: the cut state is deliberately NOT carried across a sysupgrade" \
    "$(grep -F 'cut.state' "$KEEPD")"

# ════════════════════════════════════════════════════════════════════════════

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
