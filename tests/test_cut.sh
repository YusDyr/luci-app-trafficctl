#!/bin/bash
# Global internet cut (#55): `trafficctl cut` (trafficctl/files/usr/share/ucode/
# trafficctl/cut.uc), run by the ucode CLI against a scratch TCTL_ROOT.
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
# The happy-path test is deliberately the small one. nft and conntrack are
# tests/lib/netfake.sh, procd's service list comes from tests/lib/ubus-mock.uc
# and the init script is a mock that updates it.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PASS=0
FAIL=0

REPO_ROOT="$UC_REPO"
RPCD="$REPO_ROOT/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
ACL="$REPO_ROOT/luci-app-trafficctl/root/usr/share/rpcd/acl.d/luci-app-trafficctl.json"

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

TMP="$UC_TMP"
ROOT="$TMP/root"
MOCKBIN="$TMP/bin"
UBUSDIR="$TMP/ubus"
export NETFAKE="$TMP/net"
CLOCK="$TMP/clock"
INIT_LOG="$TMP/init.log"
LOGGER_LOG="$TMP/logger.log"
CHAIN="$NETFAKE/tctl_cut"       # exists = table exists; contents = what lists back
STATE="$ROOT/var/run/trafficctl/cut.state"
PSTATE="$ROOT/etc/trafficctl/cut.state"
mkdir -p "$MOCKBIN" "$UBUSDIR" "$NETFAKE" "$ROOT/etc/config" "$ROOT/etc/init.d" "$ROOT/tmp/.uci"

for t in nft conntrack; do
    printf '#!/bin/sh\nexec sh "%s" %s "$@"\n' "$UC_TESTLIB/netfake.sh" "$t" > "$MOCKBIN/$t"
done
printf '#!/bin/sh\necho "$*" >> "%s"\n' "$LOGGER_LOG" > "$MOCKBIN/logger"
# No routed subnets and no default route to discover.
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/ip"
chmod +x "$MOCKBIN"/*

# procd's view of the keeper: the init script mock starts and stops the
# instance, and `ubus call service list` reports it, as on a router.
KEEPER_ON='{"trafficctl-cut":{"instances":{"cut":{"running":true,"pid":4242,"command":["/usr/sbin/trafficctl","cut","keeper"]}}}}'
cat > "$ROOT/etc/init.d/trafficctl-cut" <<MOCK
#!/bin/sh
echo "\$*" >> "$INIT_LOG"
case "\$1" in
    start) printf '%s\n' '$KEEPER_ON' > "$UBUSDIR/s.tmp"; mv "$UBUSDIR/s.tmp" "$UBUSDIR/service@list.json" ;;
    stop) echo '{}' > "$UBUSDIR/s.tmp"; mv "$UBUSDIR/s.tmp" "$UBUSDIR/service@list.json" ;;
esac
exit 0
MOCK
chmod +x "$ROOT/etc/init.d/trafficctl-cut"
keeper_gone() { echo '{}' > "$UBUSDIR/service@list.json"; }
keeper_running() { grep -q '"running":true' "$UBUSDIR/service@list.json"; }

cat > "$UBUSDIR/network.interface@dump.json" <<'JSON'
{"interface":[
 {"interface":"lan","up":true,"device":"br-lan","l3_device":"br-lan","ipv4-address":[{"address":"192.168.1.1","mask":24}]},
 {"interface":"wan","up":true,"device":"eth1","l3_device":"eth1","ipv4-address":[{"address":"203.0.113.2","mask":24}]}
]}
JSON
echo '{}' > "$UBUSDIR/service@list.json"
ubus_start "$UBUSDIR"

FIREWALL_LAN="config zone
	option name 'lan'
	option network 'lan'

config zone
	option name 'wan'
	option network 'wan'
	option masq '1'
"
write_config() {   # write_config [default_duration] [persist_rules]
    printf '%s' "$FIREWALL_LAN" > "$ROOT/etc/config/firewall"
    printf "config interface 'lan'\n\toption device 'br-lan'\n\nconfig interface 'wan'\n\toption device 'eth1'\n" \
        > "$ROOT/etc/config/network"
    {
        printf "config trafficctl 'main'\n"
        [ -n "${2:-}" ] && printf "\toption persist_rules '%s'\n" "$2"
        printf "\nconfig logging 'logging'\n\toption enabled '0'\n\nconfig cut 'cut'\n\toption persist '0'\n"
        [ -n "${1:-}" ] && printf "\toption default_duration '%s'\n" "$1"
    } > "$ROOT/etc/config/trafficctl"
}

run_cut() {
    TCTL_ROOT="$ROOT" TCTL_NOW="$(cat "$CLOCK")" PATH="$MOCKBIN:$PATH" tctl cut "$@" 2>&1
}

reset_state() {
    rm -rf "$ROOT/var/run/trafficctl" "$ROOT/etc/trafficctl" "$NETFAKE"
    mkdir -p "$NETFAKE"
    : > "$NETFAKE/calls"; : > "$INIT_LOG"; : > "$LOGGER_LOG"
    keeper_gone
    # A plain router: no transparent proxy anywhere in the ruleset.
    printf 'table inet fw4 {\n\tchain forward {\n\t}\n}\n' > "$NETFAKE/ruleset"
    echo 1700000000 > "$CLOCK"
    write_config 900
}
has_chain() { [ -f "$CHAIN" ] && echo yes || echo no; }
reset_state

# ════════════════════════════════════════════════════════════════════════════
# Refusals — the cases where engaging must NOT happen
# ════════════════════════════════════════════════════════════════════════════

reset_state
OUT=$(run_cut)
assert_contains "no subcommand is rejected" '"ok":false' "$OUT"
assert_contains "no subcommand: the usage keeps the script's wording" \
    'usage: trafficctl-cut.sh engage <seconds|0> [persist] | release | status | restore' "$OUT"

OUT=$(run_cut engage abc)
assert_contains "engage: a non-numeric duration is rejected" '"ok":false' "$OUT"
assert_eq "engage: a non-numeric duration installs no rule" "no" "$(has_chain)"

OUT=$(run_cut engage 5)
assert_contains "engage: a duration below the floor is rejected" '"ok":false' "$OUT"

OUT=$(run_cut engage 99999999)
assert_contains "engage: a duration above the ceiling is rejected" '"ok":false' "$OUT"

OUT=$(run_cut engage 900 2)
assert_contains "engage: a persist flag that is not 0 or 1 is rejected" '"ok":false' "$OUT"
assert_eq "engage: a bad persist flag installs no rule" "no" "$(has_chain)"

# The DEFAULT duration with nothing configured is indefinite, not a timer.
# That is the requester's stated requirement in #55 — hold a new device off the
# internet until it has been configured, which has no predictable length — and
# an auto-release halfway through would quietly let the device out. The thing
# standing between the operator and a permanent lockout is the state living in
# tmpfs, not the timer, so the timer is free to default to "off".
reset_state
write_config ""
OUT=$(run_cut status)
assert_contains "unset default_duration falls back to indefinite, not a timer" \
    '"default_duration":0' "$OUT"

# GUARD: the LAN-device refusal.
#
# The rule reads "drop anything not leaving through a LAN device". With no LAN
# devices that set is empty and the rule becomes "drop everything forwarded" —
# it would black-hole the LAN this feature exists to keep working, including
# the operator's own path to the router. Guessing is not an option here.
reset_state
: > "$ROOT/etc/config/firewall"
OUT=$(run_cut engage 900 0)
assert_contains "no LAN interfaces: refuses instead of cutting" '"ok":false' "$OUT"
assert_contains "no LAN interfaces: says why" "no LAN interfaces" "$OUT"
assert_eq "no LAN interfaces: installs no rule at all" "no" "$(has_chain)"
assert_eq "no LAN interfaces: nothing is loaded into nft" "" "$(grep -c '^nft -f' "$NETFAKE/calls" | grep -v '^0$')"
assert_eq "no LAN interfaces: writes no state, so nothing reads as engaged" "no" \
    "$([ -f "$STATE" ] && echo yes || echo no)"
# The same refusal on a keeper tick that finds the rule gone: a re-assert
# never builds a set out of nothing either.
reset_state
run_cut engage 900 0 >/dev/null
rm -f "$CHAIN"
: > "$ROOT/etc/config/firewall"
run_cut tick >/dev/null
assert_eq "no LAN interfaces: a tick does not re-assert the rule either" "no" "$(has_chain)"

# Unusable nf_tables gets a refusal rather than a button that does nothing:
# a silent no-op is exactly the lying-UI failure this feature is supposed to
# avoid.
reset_state
: > "$NETFAKE/no_nft"
OUT=$(run_cut engage 900 0)
assert_contains "no nftables: refuses rather than pretending" '"ok":false' "$OUT"
assert_contains "no nftables: names the reason" "nftables" "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# The happy path
# ════════════════════════════════════════════════════════════════════════════

reset_state
OUT=$(run_cut engage 900 0)
RC=$?
assert_eq "engage: exits 0" 0 "$RC"
assert_contains "engage: reports ok" '"ok":true' "$OUT"
assert_contains "engage: reports itself active" '"active":true' "$OUT"
assert_contains "engage: confirms the rule is live, not just recorded" '"rule_present":true' "$OUT"
assert_contains "engage: reports the LAN devices it spared" '"lan_devices":"br-lan"' "$OUT"
assert_contains "engage: reports full coverage on a router that supports fib" \
    '"coverage":"full"' "$OUT"
assert_contains "engage: the reply keeps the script's key order" \
    '{"ok":true,"active":true,"rule_present":true,"supported":true,"coverage":"full","expires_at":1700000900,"remaining":900,"started_at":1700000000,"persist":false,"keeper_running":true,"lan_devices":"br-lan","default_duration":900,"default_persist":false,"msg":"internet cut for all devices"}' "$OUT"

RULE=$(cat "$CHAIN")

# The ruleset is v1.30's, byte for byte: a cut engaged by either side lists
# the same, and is released by the other.
EXPECTED='nft -f -
  | add table inet tctl_cut
  | delete table inet tctl_cut
  | table inet tctl_cut {
  | 	chain cut_prerouting {
  | 		type filter hook prerouting priority -300; policy accept;
  | 		fib daddr type { local, broadcast, multicast } accept
  | 		ip6 daddr fe80::/10 accept
  | 		iifname != { "br-lan" } accept
  | 		fib daddr . iif oifname { "br-lan" } accept
  | 		counter drop comment "tctl_cut"
  | 	}
  | 	chain cut_forward {
  | 		type filter hook forward priority -190; policy accept;
  | 		oifname != { "br-lan" } counter drop comment "tctl_cut"
  | 	}
  | }'
assert_eq "engage: the ruleset text is the shell's, byte for byte" "$EXPECTED" \
    "$(awk '/^nft -f -$/ { on = 1; print; next } on && /^  \| / { print; next } { on = 0 }' "$NETFAKE/calls")"

# The prerouting chain is the one that matters on a router running a
# transparent proxy: TPROXY intercepts at prerouting and delivers the packet
# LOCALLY, so it is never forwarded and a forward-only rule never sees it.
assert_contains "engage: hooks prerouting ahead of everything else (raw, -300)" \
    "type filter hook prerouting priority -300" "$RULE"

# Ordering is a safety property. Router-addressed traffic is accepted FIRST,
# before any rule that depends on the LAN device list being right — otherwise a
# prerouting drop takes LuCI with it and the lockout needs physical access.
LOCAL_LINE=$(grep -n 'fib daddr type' "$CHAIN" | head -1 | cut -d: -f1)
DROP_LINE=$(grep -n 'counter drop' "$CHAIN" | head -1 | cut -d: -f1)
LANSET_LINE=$(grep -n 'iifname !=' "$CHAIN" | head -1 | cut -d: -f1)
assert_contains "engage: accepts anything addressed to the router — LuCI, SSH, DNS, DHCP" \
    "fib daddr type { local, broadcast, multicast } accept" "$RULE"
assert_eq "engage: ...and does so BEFORE the drop" "yes" \
    "$([ "$LOCAL_LINE" -lt "$DROP_LINE" ] && echo yes || echo no)"
assert_eq "engage: ...and before anything that trusts the LAN device list" "yes" \
    "$([ "$LOCAL_LINE" -lt "$LANSET_LINE" ] && echo yes || echo no)"
assert_contains "engage: IPv6 link-local is spared explicitly (ND, SLAAC)" \
    "ip6 daddr fe80::/10 accept" "$RULE"
assert_contains "engage: the forward chain is still installed as a second layer" \
    "type filter hook forward priority -190" "$RULE"

NFT=$(cat "$NETFAKE/calls")
assert_contains "engage: the ruleset is loaded as ONE atomic nft -f transaction" "nft -f -" "$NFT"
assert_not_contains "engage: never rule-by-rule, which could apply a drop without its accepts" \
    "add rule inet tctl_cut" "$NFT"
assert_not_contains "engage: nothing is written into fw4's own table" "inet fw4" "$NFT"

# Established flows outlive a new drop rule, and an offloaded flow bypasses the
# forward hook entirely — without this the toggle reads ON while the TV
# finishes its download.
assert_contains "engage: probes conntrack first" "conntrack -C" "$NFT"
assert_contains "engage: flushes conntrack for the LAN subnet as source" "conntrack -D -s 192.168.1.0/24" "$NFT"
assert_contains "engage: flushes conntrack for the LAN subnet as destination" "conntrack -D -d 192.168.1.0/24" "$NFT"
assert_not_contains "engage: does not flush conntrack globally" "conntrack -F" "$NFT"

assert_eq "engage: starts the keeper through its init script" "start" "$(cat "$INIT_LOG")"
assert_contains "engage: the state file has the script's format" \
    "$(printf 'expires_at=1700000900\npersist=0\nstarted_at=1700000000')" "$(cat "$STATE")"

OUT=$(run_cut status)
assert_contains "status: still active" '"active":true' "$OUT"
assert_contains "status: still live" '"rule_present":true' "$OUT"
assert_contains "status: reports the remaining time" '"remaining":900' "$OUT"
assert_contains "status: reports it is not persistent" '"persist":false' "$OUT"
assert_contains "status: procd reports the keeper running" '"keeper_running":true' "$OUT"
assert_eq "status: a running keeper is not started twice" "start" "$(cat "$INIT_LOG")"

OUT=$(run_cut release)
assert_contains "release: reports ok" '"ok":true' "$OUT"
assert_contains "release: says so" '"msg":"internet restored for all devices"' "$OUT"
assert_eq "release: the table is gone" "no" "$(has_chain)"
assert_eq "release: the keeper is stopped" "$(printf 'start\nstop')" "$(cat "$INIT_LOG")"
OUT=$(run_cut status)
assert_contains "release: status reads off" '"active":false' "$OUT"
assert_contains "release: and confirms no rule is live" '"rule_present":false' "$OUT"
assert_contains "release: and no keeper" '"keeper_running":false' "$OUT"

# Whether the flush WORKED cannot be read off `conntrack -D`: it fails both
# when the tool is broken and when there was simply nothing to delete. The
# capability is probed with -C instead, and when it is unavailable the cut
# still goes on — but says so, rather than leaving the operator believing
# established flows were torn down.
reset_state
: > "$NETFAKE/no_conntrack"
OUT=$(run_cut engage 900 0)
assert_contains "no conntrack: the cut still engages" '"ok":true' "$OUT"
assert_contains "no conntrack: and admits older connections may linger" \
    "conntrack unavailable" "$OUT"
assert_not_contains "no conntrack: no deletes are attempted once the probe failed" \
    "conntrack -D" "$(cat "$NETFAKE/calls")"

# ════════════════════════════════════════════════════════════════════════════
# Transparent proxies — the case where a forward-only cut is a lie
#
# podkop/sing-box, passwall and homeproxy TPROXY at prerouting and deliver the
# packet LOCALLY. It is never forwarded, so a forward-hook rule never sees it:
# on such a router the cut would read ON, the rule would genuinely be present,
# and the device would keep browsing. That is the one failure this whole
# feature exists to avoid, so it is covered from both ends — the prerouting
# chain catches the traffic, and if that chain cannot be installed the cut
# refuses rather than pretending.
# ════════════════════════════════════════════════════════════════════════════

PODKOP_RULESET='table inet PodkopTable {
	chain proxy {
		type filter hook prerouting priority dstnat; policy accept;
		meta l4proto tcp tproxy ip to 127.0.0.1:1602 counter packets 7801573 bytes 2963495755
	}
}'

reset_state
printf '%s\n' "$PODKOP_RULESET" > "$NETFAKE/ruleset"
OUT=$(run_cut engage 900 0)
assert_contains "tproxy router: the cut engages" '"ok":true' "$OUT"
assert_contains "tproxy router: with full coverage" '"coverage":"full"' "$OUT"
assert_contains "tproxy router: because the prerouting chain sits ahead of the TPROXY hook" \
    "hook prerouting priority -300" "$(cat "$CHAIN")"

# GUARD: no prerouting chain + a transparent proxy = refuse.
reset_state
: > "$NETFAKE/no_fib"
printf '%s\n' "$PODKOP_RULESET" > "$NETFAKE/ruleset"
OUT=$(run_cut engage 900 0)
RC=$?
assert_contains "tproxy router without fib: refuses rather than cutting nothing" '"ok":false' "$OUT"
assert_eq "tproxy router without fib: exits 1" 1 "$RC"
assert_contains "tproxy router without fib: names the transparent proxy as the reason" \
    "transparent proxy" "$OUT"
assert_eq "tproxy router without fib: leaves no table behind" "no" "$(has_chain)"
assert_eq "tproxy router without fib: and nothing reads as engaged" "no" \
    "$([ -f "$STATE" ] && echo yes || echo no)"
assert_empty "tproxy router without fib: and no keeper was started" "$(cat "$INIT_LOG")"

# The same kernel WITHOUT a transparent proxy is fine on forward-only — but it
# says so, rather than implying the stronger guarantee.
reset_state
: > "$NETFAKE/no_fib"
OUT=$(run_cut engage 900 0)
assert_contains "plain router without fib: still engages" '"ok":true' "$OUT"
assert_contains "plain router without fib: reports the reduced coverage" \
    '"coverage":"forward"' "$OUT"
assert_contains "plain router without fib: falls back to the forward chain" \
    "hook forward priority -190" "$(cat "$CHAIN")"
# GUARD: the install is atomic. A kernel that rejects part of the ruleset must
# end up with NONE of it — a prerouting drop applied without its preceding
# accepts would black-hole the LAN, LuCI included.
assert_not_contains "atomic install: no half-built prerouting chain survives" \
    "hook prerouting" "$(cat "$CHAIN")"
assert_eq "atomic install: two transactions, the full one and the fallback" 2 \
    "$(grep -c '^nft -f -$' "$NETFAKE/calls")"

# GUARD: the installed chain is inspected, not assumed.
#
# The worst shape of partial support is a load that reports success while the
# router-local accept did not make it into the chain — a prerouting drop
# without its escape hatch black-holes the LAN, LuCI included, and the only
# remedy left is physical access. A successful exit status is not evidence.
reset_state
: > "$NETFAKE/strip_local"
OUT=$(run_cut engage 900 0)
assert_not_contains "verify: a prerouting chain missing its escape hatch is torn down, never kept" \
    "hook prerouting" "$(cat "$CHAIN" 2>/dev/null)"
assert_contains "verify: the forward-only fallback is used in its place" \
    '"coverage":"forward"' "$OUT"
assert_contains "verify: and what remains is complete" 'comment "tctl_cut"' "$(cat "$CHAIN")"

# GUARD: the escape hatch has to come FIRST, not merely be there. A chain
# that lists back with the local accept after the drop still black-holes
# LuCI; v1.30 only looked for the text anywhere in the table.
reset_state
printf '#!/bin/sh\nexec sh "%s" nft "$@"\n' "$UC_TESTLIB/netfake.sh" > "$TMP/nft.real"
cat > "$MOCKBIN/nft" <<MOCK
#!/bin/sh
sh "$TMP/nft.real" "\$@"; rc=\$?
if [ "\$*" = "-f -" ] && [ -f "$CHAIN" ]; then
    awk '/fib daddr type/ { held = \$0; next } /counter drop/ && held != "" { print; print held; held = ""; next } { print }' \
        "$CHAIN" > "$CHAIN.tmp" && mv "$CHAIN.tmp" "$CHAIN"
fi
exit \$rc
MOCK
chmod +x "$MOCKBIN/nft"
OUT=$(run_cut engage 900 0)
assert_contains "verify: a local accept listed after the drop is not taken as the escape hatch" \
    '"coverage":"forward"' "$OUT"
assert_not_contains "verify: and that chain is not left in place" "hook prerouting" "$(cat "$CHAIN")"
printf '#!/bin/sh\nexec sh "%s" nft "$@"\n' "$UC_TESTLIB/netfake.sh" > "$MOCKBIN/nft"
chmod +x "$MOCKBIN/nft"

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
write_config 900 1
run_cut engage 900 0 >/dev/null
assert_eq "persist: NOT inherited from the global persist_rules flag" "no" \
    "$([ -f "$PSTATE" ] && echo yes || echo no)"
assert_eq "persist: the runtime state still exists, so the cut is live" "yes" \
    "$([ -f "$STATE" ] && echo yes || echo no)"

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
rm -rf "$ROOT/var/run/trafficctl"
rm -f "$CHAIN"
keeper_gone
echo 1700000300 > "$CLOCK"           # 300s of the 900 elapsed, incl. downtime
OUT=$(run_cut restore)
assert_empty "restore: prints nothing on success, as the hotplug hook expects" "$OUT"
assert_eq "restore: puts the rule back" "yes" "$(has_chain)"
OUT=$(run_cut status)
assert_contains "restore: keeps the original deadline, it does not restart the clock" \
    '"expires_at":1700000900' "$OUT"
assert_contains "restore: so the remaining time has shrunk" '"remaining":600' "$OUT"

# A deadline that passed while the router was down is honoured, not revived.
rm -rf "$ROOT/var/run/trafficctl"
rm -f "$CHAIN"
echo 1700009999 > "$CLOCK"
: > "$LOGGER_LOG"
run_cut restore >/dev/null
assert_eq "restore: an expired cut is not re-engaged" "no" "$(has_chain)"
assert_eq "restore: and its /etc state is cleaned up" "no" \
    "$([ -f "$PSTATE" ] && echo yes || echo no)"
assert_contains "restore: and says so in syslog" "global internet cut expired while down" "$(cat "$LOGGER_LOG")"

# A stale /etc file that does not actually carry the opt-in is not consent.
reset_state
mkdir -p "$(dirname "$PSTATE")"
printf 'expires_at=0\npersist=0\nstarted_at=1700000000\n' > "$PSTATE"
run_cut restore >/dev/null
assert_eq "restore: a state file without the opt-in engages nothing" "no" "$(has_chain)"
assert_eq "restore: and is discarded" "no" "$([ -f "$PSTATE" ] && echo yes || echo no)"

# Restore with no LAN to spare: the same refusal as engage, and its reply.
reset_state
mkdir -p "$(dirname "$PSTATE")"
printf 'expires_at=0\npersist=1\nstarted_at=1700000000\n' > "$PSTATE"
: > "$ROOT/etc/config/firewall"
OUT=$(run_cut restore)
assert_contains "restore with no LAN devices: refuses" "no LAN interfaces" "$OUT"
assert_eq "restore with no LAN devices: installs nothing" "no" "$(has_chain)"

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
keeper_gone                          # the keeper is gone; nothing else will act
OUT=$(run_cut status)
assert_contains "expiry: status reports the cut as off once the deadline passed" '"active":false' "$OUT"
assert_contains "expiry: and confirms no rule is live" '"rule_present":false' "$OUT"
assert_contains "expiry: and says why" '"msg":"the cut expired and the internet was restored"' "$OUT"
assert_eq "expiry: the table really was removed" "no" "$(has_chain)"
assert_eq "expiry: the state file is cleared" "no" "$([ -f "$STATE" ] && echo yes || echo no)"

# The keeper reaches the same conclusion on its own.
reset_state
run_cut engage 900 0 >/dev/null
echo 1700000901 > "$CLOCK"
: > "$LOGGER_LOG"
run_cut tick >/dev/null
RC=$?
assert_eq "expiry: a keeper tick past the deadline restores the internet" "no" "$(has_chain)"
assert_eq "expiry: and ends the keeper (tick exits 2)" 2 "$RC"
assert_contains "expiry: and says so in syslog" "global internet cut expired — internet restored" "$(cat "$LOGGER_LOG")"

# Indefinite means indefinite: no deadline, so no amount of elapsed time ends it.
reset_state
OUT=$(run_cut engage 0 0)
assert_contains "indefinite: accepted" '"ok":true' "$OUT"
assert_contains "indefinite: recorded as having no deadline" '"expires_at":0' "$OUT"
echo 1799999999 > "$CLOCK"
OUT=$(run_cut status)
assert_contains "indefinite: still on much later" '"active":true' "$OUT"
assert_contains "indefinite: and still live" '"rule_present":true' "$OUT"
run_cut tick >/dev/null
assert_eq "indefinite: a tick keeps it (exits 0)" "0 yes" "$? $(has_chain)"

# A cut that is on but has lost its keeper gets a new one, so the auto-revert
# is not staked on a single process surviving. procd is asked, not the
# process list: a v1.30 keeper orphaned by an upgrade, or anything else named
# alike, is not this service's instance.
reset_state
run_cut engage 900 0 >/dev/null
keeper_gone
: > "$INIT_LOG"
OUT=$(run_cut status)
assert_eq "keeper: status restarts one that died" "start" "$(cat "$INIT_LOG")"
assert_contains "keeper: and reports it running" '"keeper_running":true' "$OUT"
echo '{"trafficctl-cut":{"instances":{"cut":{"running":false}}}}' > "$UBUSDIR/service@list.json"
: > "$INIT_LOG"
run_cut status >/dev/null
assert_eq "keeper: an instance procd lists as not running is restarted too" "start" "$(cat "$INIT_LOG")"

# The keeper itself: a loop of ticks, five seconds apart, that ends with the
# cut. Run for real: it re-asserts a rule taken away under it, and exits
# when the cut is released.
reset_state
run_cut engage 0 0 >/dev/null
(TCTL_ROOT="$ROOT" TCTL_NOW=1700000000 PATH="$MOCKBIN:$PATH" tctl cut keeper >/dev/null 2>&1; echo "exit $?" > "$TMP/keeper.rc") &
KPID=$!
sleep 1
rm -f "$CHAIN"
for _ in $(seq 70); do [ -f "$CHAIN" ] && break; sleep 0.1; done
assert_eq "keeper: re-asserts a rule removed under it within a tick" "yes" "$(has_chain)"
rm -f "$STATE"
for _ in $(seq 70); do [ -f "$TMP/keeper.rc" ] && break; sleep 0.1; done
assert_eq "keeper: ends once the cut is gone" "exit 0" "$(cat "$TMP/keeper.rc" 2>/dev/null)"
assert_eq "keeper: and took the orphaned rule with it" "no" "$(has_chain)"
kill "$KPID" 2>/dev/null
wait "$KPID" 2>/dev/null

# ════════════════════════════════════════════════════════════════════════════
# The rule lapsing — the failure the UI must never paper over
# ════════════════════════════════════════════════════════════════════════════

# GUARD: reported state comes from the kernel, not from the state file.
reset_state
run_cut engage 900 0 >/dev/null
rm -f "$CHAIN"                        # somebody flushed the whole ruleset
OUT=$(run_cut status)
assert_contains "lapsed rule: the state file still says engaged" '"active":true' "$OUT"
assert_contains "lapsed rule: but the live check says it is NOT in force" '"rule_present":false' "$OUT"
assert_contains "lapsed rule: and the coverage reads none" '"coverage":"none"' "$OUT"

# And the keeper puts it back.
: > "$LOGGER_LOG"
run_cut tick >/dev/null
assert_eq "lapsed rule: a keeper tick re-asserts it" "yes" "$(has_chain)"
assert_contains "lapsed rule: the re-asserted rule is the same rule" 'comment "tctl_cut"' "$(cat "$CHAIN")"
assert_contains "lapsed rule: and says so in syslog" "re-asserted after the rule disappeared" "$(cat "$LOGGER_LOG")"
OUT=$(run_cut status)
assert_contains "lapsed rule: and status reads live again" '"rule_present":true' "$OUT"

# A rule left behind with no state is the mirror image, and just as wrong: the
# internet would stay off with nothing claiming to be holding it off.
reset_state
echo 'oifname != { "br-lan" } counter drop comment "tctl_cut"' > "$CHAIN"
run_cut tick >/dev/null
assert_eq "orphaned rule: a tick with no state removes it" "no" "$(has_chain)"

# ════════════════════════════════════════════════════════════════════════════
# v1.30 state, and the integers it could not keep
# ════════════════════════════════════════════════════════════════════════════

# A state file the shell wrote is read as it was written, deadline included.
reset_state
mkdir -p "$(dirname "$STATE")"
printf 'expires_at=1700000600\npersist=1\nstarted_at=1699999000\n' > "$STATE"
run_cut tick >/dev/null
OUT=$(run_cut status)
assert_contains "v1.30 state: honoured, deadline and all" '"expires_at":1700000600,"remaining":600,"started_at":1699999000,"persist":true' "$OUT"
# Epochs are numbers in the reply. The shell printed the file's digits as
# they were, so "060" made the reply invalid JSON.
printf 'expires_at=0\npersist=0\nstarted_at=0099\n' > "$STATE"
OUT=$(run_cut status)
assert_contains "a leading zero in the state is still a JSON number" '"started_at":99' "$OUT"
printf 'expires_at=junk\npersist=0\nstarted_at=1\n' > "$STATE"
OUT=$(run_cut status)
assert_contains "an unreadable deadline is never taken as expired" '"active":true' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# Wiring — a method rpcd does not list is a method that does not exist
# ════════════════════════════════════════════════════════════════════════════

SIGS=$(cat "$RPCD")
assert_contains "rpcd: cut_status is in the signature table" 'cut_status: {},' "$SIGS"
assert_contains "rpcd: cut_set is declared with its parameters" \
    "cut_set: { active: 'bool', duration: 'int', persist: 'bool' }," "$SIGS"

ACLTXT=$(cat "$ACL")
assert_contains "acl: cut_status is granted" '"cut_status"' "$ACLTXT"
assert_contains "acl: cut_set is granted" '"cut_set"' "$ACLTXT"
# Both sit under write: cut_status is not observational, it reconciles.
WRITE_BLOCK=$(awk '/"write"/,0' "$ACL")
assert_contains "acl: cut_status is a write method, like activity_log" '"cut_status"' "$WRITE_BLOCK"

INIT="$REPO_ROOT/trafficctl/files/etc/init.d/trafficctl-cut"
assert_contains "init: procd runs the ucode keeper" \
    "procd_set_param command /usr/sbin/trafficctl cut keeper" "$(cat "$INIT")"
assert_contains "init: the instance procd is asked about is named cut" \
    "procd_open_instance cut" "$(cat "$INIT")"
assert_eq "shim: trafficctl-cut.sh hands over to the CLI" \
    "$(printf '#!/bin/sh\nexec /usr/sbin/trafficctl cut "$@"')" \
    "$(cat "$REPO_ROOT/trafficctl/files/usr/libexec/trafficctl/trafficctl-cut.sh")"

# ── The boot hook ───────────────────────────────────────────────────────────
#
# GUARD: the restore must key off the cut's OWN state file, never off the
# global persist_rules flag. The hotplug script restores blocks and rate limits
# inside an `if ... tctl_persist_enabled` block; if the cut were restored from
# in there, anybody who enabled that flag for their rate limits would get a
# persistent internet kill out of an unrelated decision. Asserted by running
# the hook with persist_rules OFF and a cut state file present: the cut must
# still come back, which can only happen from outside that block.
BIN="$REPO_ROOT/trafficctl/files/usr/libexec/trafficctl"
HOTPLUG="$REPO_ROOT/trafficctl/files/etc/hotplug.d/iface/99-trafficctl-shapes"
HP="$TMP/hotplug"
CUT_CALL_LOG="$TMP/cutcall.log"
sed -e "s|\\. /usr/libexec/trafficctl/trafficctl-fw.sh|. $BIN/trafficctl-fw.sh|" \
    -e "s|/usr/sbin/trafficctl cut|$MOCKBIN/cut-stub|" \
    -e "s|/etc/trafficctl/cut.state|$PSTATE|" \
    "$HOTPLUG" > "$HP"
assert_contains "hotplug: the restore is the CLI's" "$MOCKBIN/cut-stub restore" "$(cat "$HP")"

cat > "$MOCKBIN/cut-stub" <<MOCK
#!/bin/sh
echo "\$*" >> "$CUT_CALL_LOG"
exit 0
MOCK
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/tc"
# The hook's own uci reads: persist_rules is explicitly OFF here.
printf '#!/bin/sh\ncase "$*" in *persist_rules*) echo 0 ;; *) exit 1 ;; esac\n' > "$MOCKBIN/uci"
chmod +x "$MOCKBIN/cut-stub" "$MOCKBIN/tc" "$MOCKBIN/uci"

run_hotplug() {
    : > "$CUT_CALL_LOG"
    PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HP" >/dev/null 2>&1
    cat "$CUT_CALL_LOG" 2>/dev/null
}

reset_state
mkdir -p "$(dirname "$PSTATE")"
printf 'expires_at=0\npersist=1\nstarted_at=1700000000\n' > "$PSTATE"
assert_contains "hotplug: restores the cut even with persist_rules off" \
    "restore" "$(run_hotplug)"

# ...and with no state file there is nothing to restore, so it is not called.
rm -f "$PSTATE"
assert_empty "hotplug: no state file means the cut is not touched at all" "$(run_hotplug)"

# A cut that outlives a firmware upgrade is strictly worse than one that
# outlives a reboot, so its state deliberately is not preserved by sysupgrade.
KEEPD="$REPO_ROOT/trafficctl/files/lib/upgrade/keep.d/trafficctl"
assert_empty "keep.d: the cut state is deliberately NOT carried across a sysupgrade" \
    "$(grep -F 'cut.state' "$KEEPD")"

# ════════════════════════════════════════════════════════════════════════════

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
