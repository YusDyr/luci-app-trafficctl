#!/bin/bash
# What the limiter takes from outside its own arguments, and from 1.30.x.
#
#   * Device names come from ubus (l3_device), uci, the routing table and
#     sysfs (brif) and go into `nft add chain ... device <name>`, unquoted
#     inside the chain spec, and into a sysfs path. Only a name the kernel
#     could have made (IFNAMSIZ, no space, no '/') goes there; another is
#     skipped and named, masked, in the reply and in syslog.
#   * TCTL_V6SET_TIMEOUT lands in the IPv6 set declaration: a duration, or 1h.
#   * A rules.json rate that is neither a string nor an int (true, an object)
#     is an invalid rate, refused and logged as v1.30.6 did, not skipped as
#     "no rate".
#   * 1.30.x kept a zero-padded mask as typed (10.0.20.0/024), in rules.json
#     and in the comment (rl_ratelimit_10_0_20_0_024). Either spelling of the
#     target reaches those rules and that record, and the restore puts such a
#     record back in its normal form.
#   * `trafficctl restore`: an error in one half (the blocks) does not stop
#     the other (the limits).

PASS=0
FAIL=0

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/limit_env.sh
. "$UC_TESTLIB/limit_env.sh"

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
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$1" "$2" "$3"
    fi
}

assert_not_contains() {
    if printf '%s' "$3" | grep -qF -- "$2"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n  in:\n%s\n" "$1" "$2" "$3"
    else
        PASS=$((PASS + 1))
    fi
}

chains() { lt_table | awk '/^[ \t]*chain /{ print $2 }' | sort | tr '\n' ' '; }

# ── device names ────────────────────────────────────────────────────────────
lt_cfg 0
LT_LAN_IP=192.168.1.1 lt_net br-lan lan1 'lan2;x'
lt_reset
OUT=$(lt_run ratelimit 192.168.1.50 5000)
assert_contains "a port with an invalid name: the limit is applied" '"ok":true' "$OUT"
assert_contains "a port with an invalid name: named, masked, in the reply" 'lan2?x: invalid device name' "$OUT"
assert_eq "a port with an invalid name: no chain for it" "dl_br_lan ul_lan1 " "$(chains)"
assert_not_contains "a port with an invalid name: never in an nft command" 'lan2;x' "$(cat "$NFT_LOG")"
assert_contains "a port with an invalid name: in syslog" 'skipped LAN port with an invalid name: lan2?x' "$(cat "$LOGGER_LOG")"

# The LAN device itself, from ubus: download falls back to WAN ingress.
lt_net 'br-lan }; flush'
lt_reset
OUT=$(lt_run ratelimit 192.168.1.50 5000)
assert_contains "an invalid LAN device: download at WAN ingress" '"ok":true' "$OUT"
assert_contains "an invalid LAN device: upload reported, with the name masked" \
    'DOWNLOAD ONLY — upload rule failed on br-lan????flush: invalid device name' "$OUT"
assert_eq "an invalid LAN device: only the WAN chain" "dl " "$(chains)"
assert_not_contains "an invalid LAN device: never in an nft command" 'flush' "$(cat "$NFT_LOG")"

# The WAN device: ubus, uci and the route all name something unusable.
lt_net br-lan lan1
printf '{"up":true,"l3_device":"../../x"}\n' > "$LT/ubus/network.interface.wan@status.json"
ubus_stop; ubus_start "$LT/ubus"
uc_wan() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.limit wan_device; }
mkdir -p "$ROOT/sys/x"
sed -i "s/option device 'eth1'/option device 'eth 1'/" "$ROOT/etc/config/network"
assert_eq "an invalid WAN name is no WAN device" "" "$(uc_wan)"
sed -i "s/option device 'eth 1'/option device 'eth1'/" "$ROOT/etc/config/network"
assert_eq "a valid WAN name from uci is the WAN device" "eth1" "$(uc_wan)"
lt_cfg 0
lt_net br-lan lan1

# ── the IPv6 set timeout ────────────────────────────────────────────────────
printf '9999999999 02:00:00:00:00:50 192.168.1.50 phone *\n' > "$LEASES"
lt_reset
TCTL_V6SET_TIMEOUT='1h; flush ruleset' lt_run ratelimit 192.168.1.50 5000 >/dev/null
assert_contains "a timeout that is no duration: the default" 'timeout 1h;' "$(grep 'add set' "$NFT_LOG")"
assert_not_contains "a timeout that is no duration: never in nft" 'flush ruleset' "$(cat "$NFT_LOG")"
lt_reset
TCTL_V6SET_TIMEOUT=30s lt_run ratelimit 192.168.1.50 5000 >/dev/null
assert_contains "a duration is taken" 'timeout 30s;' "$(grep 'add set' "$NFT_LOG")"
: > "$LEASES"

# ── restore: rates of another JSON type ─────────────────────────────────────
lt_cfg 1
lt_reset
printf '[{"type":"ratelimit","ip":"192.168.1.60","param":true},{"type":"ratelimit","ip":"192.168.1.61","param":{"a":1}},{"type":"ratelimit","ip":"192.168.1.62","param":"3000","param_up":[1]},{"type":"ratelimit","ip":"192.168.1.63","param":null},{"type":"ratelimit","ip":"192.168.1.64"}]' > "$RULES"
lt_run restore >/dev/null
LOG=$(cat "$LOGGER_LOG")
assert_contains "restore: a boolean rate is refused and logged" "Not restoring ratelimit for 192.168.1.60: invalid rate 'true'/''" "$LOG"
assert_contains "restore: an object rate is refused and logged" "Not restoring ratelimit for 192.168.1.61: invalid rate" "$LOG"
assert_contains "restore: an array upload rate is refused and logged" "Not restoring ratelimit for 192.168.1.62: invalid rate '3000'/'[1]'" "$LOG"
assert_not_contains "restore: a null rate is no rate, not logged" "192.168.1.63" "$LOG"
assert_not_contains "restore: an absent rate is no rate, not logged" "192.168.1.64" "$LOG"
assert_eq "restore: none of them is in the table" "" "$(chains)"

# ── a zero-padded mask, as 1.30.x saved it ──────────────────────────────────
PAD=rl_ratelimit_10_0_20_0_024
NORM=rl_ratelimit_10_0_20_0_24
LT_LAN_IP=10.0.20.1 lt_net br-lan lan1
# The rules 1.30.x made: the comment carries the mask as typed.
seed_padded() {
    lt_reset
    printf '[{"type":"block","ip":"10.0.20.9","param":""},{"type":"ratelimit","ip":"10.0.20.0/024","param":"2000","mode":"each"}]' > "$RULES"
    PATH="$MOCKBIN:$PATH" sh -c '
        nft add table netdev tm_ratelimit
        nft add chain netdev tm_ratelimit dl_br_lan "{ type filter hook egress device br-lan priority 0; policy accept; }"
        nft add chain netdev tm_ratelimit ul_lan1 "{ type filter hook ingress device lan1 priority -200; policy accept; }"
        nft add rule netdev tm_ratelimit dl_br_lan "ip daddr 10.0.20.0/24 meter tctl_m_10_0_20_0_024_dl_br_lan { ip daddr limit rate over 250000 bytes/second } counter drop comment \"'$PAD'\""
        nft add rule netdev tm_ratelimit ul_lan1 "ip saddr 10.0.20.0/24 meter tctl_m_10_0_20_0_024_ul_lan1 { ip saddr limit rate over 250000 bytes/second } counter drop comment \"'$PAD'_ul\""'
}
records() { jq -c '[.[] | select(.type == "ratelimit") | .ip]' "$RULES"; }

seed_padded
assert_eq "padded: seeded as 1.30.x left it" "dl_br_lan tctl_m_10_0_20_0_024_dl_br_lan
ul_lan1 tctl_m_10_0_20_0_024_ul_lan1" "$(lt_rules_of $PAD; lt_rules_of ${PAD}_ul)"
OUT=$(lt_run ratelimit 10.0.20.0/24 0)
assert_contains "padded, removed in the normal form: ok" '"ok":true' "$OUT"
assert_eq "padded, removed in the normal form: no rule left" "" "$(lt_rules_of $PAD; lt_rules_of ${PAD}_ul)"
assert_eq "padded, removed in the normal form: no meter left" "" "$(lt_table | grep -o 'tctl_m_[0-9a-z_]*')"
assert_eq "padded, removed in the normal form: the record is gone, the block kept" \
    '[]|[{"type":"block","ip":"10.0.20.9","param":""}]' "$(records)|$(cat "$RULES")"

seed_padded
lt_run ratelimit 10.0.20.0/024 0 >/dev/null
assert_eq "padded, removed as typed: no rule left" "" "$(lt_rules_of $PAD; lt_rules_of ${PAD}_ul)"
assert_eq "padded, removed as typed: the record is gone" '[]' "$(records)"

seed_padded
OUT=$(lt_run ratelimit 10.0.20.0/24 3000 '' each)
assert_contains "padded, replaced: ok" '"ok":true' "$OUT"
assert_eq "padded, replaced: the old rules are gone" "" "$(lt_rules_of $PAD; lt_rules_of ${PAD}_ul)"
assert_eq "padded, replaced: the new ones are in" "dl_br_lan tctl_m_10_0_20_0_24_dl_br_lan" "$(lt_rules_of $NORM)"
assert_eq "padded, replaced: one record, in the normal form" '["10.0.20.0/24"]' "$(records)"

# After a reboot: back in the normal form, and removable from both spellings.
lt_reset
printf '[{"type":"ratelimit","ip":"10.0.20.0/024","param":"2000","mode":"each"}]' > "$RULES"
lt_run restore >/dev/null
assert_eq "padded, restored: in the normal form" "dl_br_lan tctl_m_10_0_20_0_24_dl_br_lan" "$(lt_rules_of $NORM)"
assert_eq "padded, restored: not as typed" "" "$(lt_rules_of $PAD)"
assert_eq "padded, restored: the record left as it is" '["10.0.20.0/024"]' "$(records)"
lt_run ratelimit 10.0.20.0/024 0 >/dev/null
assert_eq "padded, restored then removed as typed: nothing left" "|[]" "$(lt_rules_of $NORM)|$(records)"

# An ifup without a reboot, the 1.30.x rules still live: replaced, not stacked.
seed_padded
lt_run restore >/dev/null
assert_eq "padded, restored over its live rules: the old ones are gone" "" "$(lt_rules_of $PAD; lt_rules_of ${PAD}_ul)"
assert_eq "padded, restored over its live rules: one copy" "dl_br_lan tctl_m_10_0_20_0_24_dl_br_lan" "$(lt_rules_of $NORM)"

# ── restore: one half failing ───────────────────────────────────────────────
# A blocks half that throws: an unreadable fw4 is not it, so the module is
# replaced for this run by one whose restore dies.
lt_reset
printf '[{"type":"ratelimit","ip":"10.0.20.50","param":"2000"}]' > "$RULES"
SHADOW="$LT/shadow"
mkdir -p "$SHADOW/trafficctl"
cp "$UC_LIB"/trafficctl/*.uc "$SHADOW/trafficctl/"
sed -i 's/^function restore() {$/function restore() {\n\tdie("boom");/' "$SHADOW/trafficctl/ctl.uc"
grep -q 'die("boom")' "$SHADOW/trafficctl/ctl.uc" || echo "FAIL: the shadow ctl.uc was not made"
OUT=$(PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" POSIXLY_CORRECT=1 "$UCODE" -S -L "$SHADOW" -- \
    "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" restore 2>&1)
assert_contains "restore: a failing blocks half is counted" '"ok":false,"restored":1,"failed":1' "$OUT"
assert_eq "restore: the limits are restored anyway" "dl_br_lan -" "$(lt_rules_of rl_ratelimit_10_0_20_50)"
assert_contains "restore: the failing half is in syslog" 'restore: blocks failed: boom' "$(cat "$LOGGER_LOG")"

echo
echo "test_limit_inputs: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
