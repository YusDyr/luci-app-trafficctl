#!/bin/bash
# Per-device ("each") limits on a bridge with several ports.
#
# The upload rule goes on every bridge port's ingress chain and the download
# rule on every LAN device's egress chain. In each mode the rule carries an
# nft meter, and every copy used to carry the SAME meter name, tctl_u_<slug>.
# nftables before 1.1 (OpenWrt 22.03 ships 1.0.2) binds a meter to the one
# rule that declares it, so the second port's rule failed with "Could not
# process rule: Resource busy". The error went to /dev/null and the success
# flag was set by the first port, so clients on lan2..lanN uploaded at full
# rate while the limit was reported, and listed in the Rules tab, as applied.
#
# nftables 1.1 makes the meter an ordinary named set: shared by every chain,
# and left in the table after the limit was removed, still holding each
# address's bucket at the old rate.
#
# The fake nft (tests/lib/nft-netdev.sh) keeps state and reproduces both
# behaviours (NFT_EMU=1.0 / 1.1), as verified on the OpenWrt 22.03.7
# (nftables 1.0.2) and 25.12.4 (nftables 1.1.6) rootfs images. The limiter is
# `trafficctl ratelimit` and its restore on ifup lan `trafficctl restore`.

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

# br-lan with three ports: the first one always took the rule, so it takes
# at least two to see the bug, and three to see that it is not just "the
# second". The address plan is 10.0.20.0/24; persistence is on, as the
# restore needs it.
lt_cfg 1
LT_LAN_IP=10.0.20.1 lt_net br-lan lan1 lan2 lan3

reset() { lt_reset; }
run() { lt_run "$@"; }
table() { lt_table; }
rules_of() { lt_rules_of "$1"; }
restore() { lt_run restore >/dev/null; }
CMT=rl_ratelimit_10_0_20_0_24

for EMU in 1.0 1.1; do
    export NFT_EMU="$EMU"

    # ── each mode: one rule, with its own meter, on every port ──────────────
    reset
    OUT=$(run ratelimit 10.0.20.0/24 5000 "" each 1000)
    assert_contains "nft $EMU: applied in both directions" '"ok":true' "$OUT"
    assert_contains "nft $EMU: reported as both directions" 'both directions, each' "$OUT"
    assert_eq "nft $EMU: an upload rule on every port, each with its own meter" \
        "ul_lan1 tctl_m_10_0_20_0_24_ul_lan1
ul_lan2 tctl_m_10_0_20_0_24_ul_lan2
ul_lan3 tctl_m_10_0_20_0_24_ul_lan3" "$(rules_of "${CMT}_ul" | sort)"
    assert_eq "nft $EMU: the download rule on the bridge, its meter named for the chain" \
        "dl_br_lan tctl_m_10_0_20_0_24_dl_br_lan" "$(rules_of "$CMT")"
    assert_eq "nft $EMU: nothing logged" "" "$(cat "$LOGGER_LOG")"
    # Reading it back as "each" (both nft forms) is the ucode reader's job,
    # checked by tests/test_readers.sh on the JSON listings.

    # Setting it again (a new rate) replaces it instead of failing on the
    # meters of the first one.
    OUT=$(run ratelimit 10.0.20.0/24 8000 "" each 2000)
    assert_contains "nft $EMU: re-set at a new rate" 'both directions, each' "$OUT"
    assert_eq "nft $EMU: still one upload rule per port after the re-set" "3" \
        "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"
    assert_contains "nft $EMU: the re-set carries the new rate" \
        "limit rate over 250000 bytes/second" "$(table | grep "\"${CMT}_ul\"")"

    # ── removal takes the meters too ────────────────────────────────────────
    OUT=$(run ratelimit 10.0.20.0/24 0)
    assert_contains "nft $EMU: removed" '"ok":true' "$OUT"
    assert_eq "nft $EMU: no rule left" "" "$(rules_of "$CMT"; rules_of "${CMT}_ul")"
    assert_not_contains "nft $EMU: no meter set left behind" "set tctl_" "$(table)"

    # ── a port that refuses the rule ────────────────────────────────────────
    # Not a meter clash: anything nft turns down on one port. The clients
    # behind it are not limited, which the result must say; the other ports
    # keep their rules, so the limit stays applied where it could be.
    reset
    OUT=$(NFT_FAIL_CHAINS="ul_lan2" run ratelimit 10.0.20.0/24 5000 "" each)
    assert_contains "nft $EMU: one failed port: still ok" '"ok":true,"partial":true' "$OUT"
    assert_contains "nft $EMU: one failed port: reported as partial, naming the port and nft's reason" \
        'PARTIAL: upload rule failed on lan2: Operation not supported' "$OUT"
    assert_eq "nft $EMU: the other ports keep their upload rules" \
        "ul_lan1 tctl_m_10_0_20_0_24_ul_lan1
ul_lan3 tctl_m_10_0_20_0_24_ul_lan3" "$(rules_of "${CMT}_ul" | sort)"
    assert_eq "nft $EMU: download stays" "dl_br_lan tctl_m_10_0_20_0_24_dl_br_lan" "$(rules_of "$CMT")"
    assert_contains "nft $EMU: the failure is logged" \
        "upload rule for 10.0.20.0/24 failed on lan2: Operation not supported" "$(cat "$LOGGER_LOG")"
    # Applying it again, with the port back, fills the gap.
    OUT=$(run ratelimit 10.0.20.0/24 5000 "" each)
    assert_contains "nft $EMU: re-applied with the port back: complete" '"partial":false' "$OUT"
    assert_eq "nft $EMU: re-applied: an upload rule on every port" "3" \
        "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"

    # A port whose chain cannot be created at all (the device is gone).
    reset
    OUT=$(NFT_FAIL_HOOKS="ul_lan3" run ratelimit 10.0.20.0/24 5000 "" each)
    assert_contains "nft $EMU: a missing port: ok, partial" '"ok":true,"partial":true' "$OUT"
    assert_contains "nft $EMU: a missing port is named" 'upload rule failed on lan3: No such file or directory' "$OUT"
    assert_eq "nft $EMU: a missing port: the others keep their rules" "2" \
        "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"

    # Upload fails everywhere: download only, and the IPv6 note is what the
    # kernel holds, not a constant.
    reset
    OUT=$(NFT_FAIL_CHAINS="ul_lan1 ul_lan2 ul_lan3" run ratelimit 10.0.20.0/24 5000 "" each)
    assert_contains "nft $EMU: no upload anywhere: download only" 'DOWNLOAD ONLY — upload rule failed on lan1' "$OUT"

    reset
    OUT=$(NFT_FAIL_CHAINS="ul_lan1 ul_lan2 ul_lan3 dl_br_lan dl" run ratelimit 10.0.20.0/24 5000 "" each)
    assert_contains "nft $EMU: nothing went in: not ok" '"ok":false' "$OUT"
    assert_contains "nft $EMU: nothing went in: the reason is given" 'Operation not supported' "$OUT"

    # ── the restore hook ────────────────────────────────────────────────────
    # ifup lan runs again without a reboot (a network restart), with the
    # rules of the first run still in place.
    reset
    printf '[{"type":"ratelimit","ip":"10.0.20.0/24","param":"5000","mode":"each"}]\n' > "$RULES"
    restore
    restore
    assert_eq "nft $EMU: restore twice: one upload rule per port" "3" \
        "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"
    assert_eq "nft $EMU: restore twice: one download rule" "1" \
        "$(rules_of "$CMT" | wc -l | tr -d ' ')"
    assert_eq "nft $EMU: restore twice: no failure logged" "" "$(cat "$LOGGER_LOG")"

    # A boot restore that meets a port mid-re-creation keeps the others, says
    # so, and the next ifup fills the port in.
    : > "$LOGGER_LOG"
    rm -f "$NFT_STATE"/*
    NFT_FAIL_HOOKS="ul_lan3" lt_run restore >/dev/null
    assert_contains "nft $EMU: a restore that misses a port is logged as partial, with the port" \
        "Restored ratelimit for 10.0.20.0/24 (5000kbit) PARTIALLY: upload rule failed on lan3: No such file or directory" "$(cat "$LOGGER_LOG")"
    assert_eq "nft $EMU: and keeps the other ports" "2" "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"
    : > "$LOGGER_LOG"
    restore
    assert_eq "nft $EMU: the next ifup fills the port in" "3" "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"
    assert_eq "nft $EMU: the next ifup: one download rule" "1" "$(rules_of "$CMT" | wc -l | tr -d ' ')"
    assert_eq "nft $EMU: the next ifup: nothing logged" "" "$(cat "$LOGGER_LOG")"
done

# ── upgrade: meters named by releases before 1.30.4 ─────────────────────────
# On nftables 1.1 the old per-target set is shared by every port's rule and
# outlives them. Removing a limit set by an older release takes it as well.
export NFT_EMU=1.1
reset
printf 'dl_br_lan\nul_lan1\nul_lan2\nul_lan3\n' > "$NFT_STATE/chains"
printf 'tctl_d_10_0_20_0_24\ntctl_u_10_0_20_0_24\n' > "$NFT_STATE/sets"
{
    echo "4 dl_br_lan ip daddr 10.0.20.0/24 add @tctl_d_10_0_20_0_24 { ip daddr limit rate over 625000 bytes/second } counter packets 0 bytes 0 drop comment \"$CMT\""
    for i in 1 2 3; do
        echo "$((4 + i)) ul_lan$i ip saddr 10.0.20.0/24 add @tctl_u_10_0_20_0_24 { ip saddr limit rate over 625000 bytes/second } counter packets 0 bytes 0 drop comment \"${CMT}_ul\""
    done
} > "$NFT_STATE/rules"
echo 8 > "$NFT_STATE/handle"
OUT=$(run ratelimit 10.0.20.0/24 0)
assert_contains "upgrade: an old-named limit is removed" '"ok":true' "$OUT"
assert_eq "upgrade: its rules are gone" "" "$(rules_of "$CMT"; rules_of "${CMT}_ul")"
assert_not_contains "upgrade: its shared meter sets are gone" "set tctl_" "$(table)"

# Re-setting one target leaves the other target's meters alone.
reset
run ratelimit 10.0.30.0/24 3000 "" each >/dev/null
OUT=$(NFT_FAIL_CHAINS="ul_lan3" run ratelimit 10.0.20.0/24 5000 "" each)
OUT=$(run ratelimit 10.0.20.0/24 0)
assert_eq "other target: keeps every upload rule" "3" \
    "$(rules_of rl_ratelimit_10_0_30_0_24_ul | wc -l | tr -d ' ')"
assert_contains "other target: and its meter sets" "set tctl_m_10_0_30_0_24_ul_lan3" "$(table)"

# ── IPv6 flags follow the kernel ────────────────────────────────────────────
# A host with a lease gets the MAC-keyed v6 rules. When only its IPv4 upload
# rule fails, on every port, the v6 upload, feed and download rules are in:
# the result must say so instead of a hardcoded "IPv4 only".
CMTH=rl_ratelimit_10_0_20_50
printf '1794381090 02:00:00:00:00:50 10.0.20.50 tablet *\n' > "$LEASES"
reset
OUT=$(NFT_FAIL_RULE="ul_lan1 ip saddr 10.0.20.50" run ratelimit 10.0.20.50 5000)
assert_contains "v6: the host got its v6 rules" "ul_lan1" "$(rules_of "${CMTH}_ul6")"
assert_contains "v6: one port's v4 upload failing is partial, not 'DOWNLOAD ONLY'" \
    'PARTIAL: upload rule failed on lan1: Operation not supported' "$OUT"
assert_contains "v6: flags match the loaded rules" '"ipv6_upload":true,"ipv6_download":true' "$OUT"
assert_contains "v6: so does the note" '[IPv6: both directions]' "$OUT"
reset
OUT=$(NFT_FAIL_RULE="ul_lan1 ip saddr 10.0.20.50" \
    NFT_FAIL_CHAINS="ul_lan2 ul_lan3" run ratelimit 10.0.20.50 5000)
assert_contains "v6: no v4 upload anywhere: download only" 'DOWNLOAD ONLY' "$OUT"
ul6=$(rules_of "${CMTH}_ul6"); dl6=$(rules_of "${CMTH}_dl6"); fd6=$(rules_of "${CMTH}_v6")
assert_eq "v6: the kernel then holds the v6 upload rule on lan1 only" "ul_lan1 -" "$ul6"
assert_contains "v6: ... and the v6 download rule" "dl_br_lan" "$dl6"
assert_contains "v6: ... fed from lan1" "ul_lan1" "$fd6"
assert_contains "v6: download-only result reports the v6 rules that are live" \
    '"ipv6_upload":true,"ipv6_download":true' "$OUT"
assert_not_contains "v6: download-only result does not say IPv4 only" '[IPv4 only]' "$OUT"
: > "$LEASES"

# ── the restore hook matches comments exactly ───────────────────────────────
# 10.0.20.1's comment is a prefix of 10.0.20.10's. With only .10 live, the
# restore of .1 has nothing of its own to replace and must not go deleting.
reset
run ratelimit 10.0.20.10 4000 >/dev/null
printf '[{"type":"ratelimit","ip":"10.0.20.1","param":"5000"}]\n' > "$RULES"
: > "$NFT_LOG"
restore
assert_eq "restore .1 with .10 live: no removal is attempted" "" "$(grep '^delete\|^-a list' "$NFT_LOG")"
assert_eq "restore .1 with .10 live: .1 restored" "3" \
    "$(rules_of rl_ratelimit_10_0_20_1_ul | wc -l | tr -d ' ')"
# And with .1, .10 and .1/24 all live, the restore replaces only .1's rules.
reset
run ratelimit 10.0.20.10 4000 >/dev/null
run ratelimit 10.0.20.1/24 4000 "" shared >/dev/null
printf '[{"type":"ratelimit","ip":"10.0.20.1","param":"5000"}]\n' > "$RULES"
restore
assert_eq "restore .1: .10 keeps its upload rules" "3" \
    "$(rules_of rl_ratelimit_10_0_20_10_ul | wc -l | tr -d ' ')"
assert_eq "restore .1: .1/24 keeps its upload rules" "3" \
    "$(rules_of rl_ratelimit_10_0_20_1_24_ul | wc -l | tr -d ' ')"
assert_eq "restore .1: .1 itself restored once" "3" \
    "$(rules_of rl_ratelimit_10_0_20_1_ul | wc -l | tr -d ' ')"
# Restoring .1 again (ifup without reboot) replaces exactly its own rules.
restore
assert_eq "restore .1 twice: still one rule per port" "3" \
    "$(rules_of rl_ratelimit_10_0_20_1_ul | wc -l | tr -d ' ')"
# Counting removals: the hook may only have deleted .1's own rules.
assert_eq "restore .1 twice: .10 untouched" "3" \
    "$(rules_of rl_ratelimit_10_0_20_10_ul | wc -l | tr -d ' ')"

# ── the meter name ──────────────────────────────────────────────────────────
# The longest: an 18-character slug and a 15-character device.
lt_net br-lan wlan-guest-5gx
reset
run ratelimit 255.255.255.255/32 1000 "" each >/dev/null
NAME=$(rules_of rl_ratelimit_255_255_255_255_32_ul | awk '{print $2}')
assert_eq "name: deterministic" "tctl_m_255_255_255_255_32_ul_wlan_guest_5gx" "$NAME"
[ "${#NAME}" -le 64 ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: name: ${#NAME} characters"; }

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
