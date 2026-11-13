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
# The fake nft below keeps state and reproduces both behaviours (NFT_EMU=1.0 /
# 1.1), as verified on the OpenWrt 22.03.7 (nftables 1.0.2) and 25.12.4
# (nftables 1.1.6) rootfs images.

PASS=0
FAIL=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/trafficctl/files/usr/libexec/trafficctl"
HOTPLUG="$ROOT/trafficctl/files/etc/hotplug.d/iface/99-trafficctl-shapes"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
MOCKBIN="$TMP/bin"
STATE="$TMP/nft"
RULES="$TMP/rules.json"
LOGGER_LOG="$TMP/logger.log"
mkdir -p "$MOCKBIN" "$STATE"

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

# ── a stateful nft ──────────────────────────────────────────────────────────
# State: chains (one name per line), rules ("<handle> <chain> <text>"),
# sets (named sets, 1.1 meters among them), bound (1.0 meters, each bound to
# the handle of the rule that declared it).
cat > "$MOCKBIN/nft" <<'MOCK'
#!/bin/sh
S="$NFT_STATE"
touch "$S/chains" "$S/rules" "$S/sets" "$S/bound"
[ -n "$NFT_LOG" ] && echo "$*" >> "$NFT_LOG"
fail() { echo "Error: Could not process rule: $1" >&2; echo "$2" >&2; exit 1; }
list=0
[ "$1" = "-a" ] && { list=1; shift; }
case "$1 $2 $3" in
    "list tables "*) echo "table inet fw4"; exit 0 ;;
    "add table netdev") exit 0 ;;
    "add set netdev")
        grep -qx "$5" "$S/sets" || echo "$5" >> "$S/sets"; exit 0 ;;
    "add chain netdev")
        # A device that is not there (hostapd re-creating phy0-ap0 under the
        # restore): the chain, and so every rule in it, fails.
        case " $NFT_FAIL_HOOKS " in *" $5 "*) fail "No such file or directory" "add chain $5" ;; esac
        grep -qx "$5" "$S/chains" || echo "$5" >> "$S/chains"; exit 0 ;;
    "add rule netdev")
        chain="$5"; text="$6"
        grep -qx "$chain" "$S/chains" || fail "No such file or directory" "add rule $chain $text"
        case " $NFT_FAIL_CHAINS " in *" $chain "*) fail "Operation not supported" "add rule $chain $text" ;; esac
        # NFT_FAIL_RULE="<chain> <text fragment>": that one rule only.
        if [ -n "$NFT_FAIL_RULE" ] && [ "$chain" = "${NFT_FAIL_RULE%% *}" ]; then
            case "$text" in *"${NFT_FAIL_RULE#* }"*) fail "Operation not supported" "add rule $chain $text" ;; esac
        fi
        h=$(( $(cat "$S/handle" 2>/dev/null || echo 3) + 1 )); echo "$h" > "$S/handle"
        m=$(printf '%s\n' "$text" | sed -n 's/.* meter \([A-Za-z0-9_]*\) .*/\1/p')
        if [ -n "$m" ]; then
            if [ "$NFT_EMU" = "1.1" ]; then
                grep -qx "$m" "$S/sets" || echo "$m" >> "$S/sets"
                text=$(printf '%s\n' "$text" | sed "s/ meter $m / add @$m /")
            else
                grep -q " $m\$" "$S/bound" && fail "Resource busy" "add rule $chain $text"
                echo "$h $m" >> "$S/bound"
                text=$(printf '%s\n' "$text" | sed "s/ meter $m / meter $m size 65535 /")
            fi
        fi
        echo "$h $chain $text" >> "$S/rules"
        exit 0 ;;
    "delete rule netdev")
        h="$7"
        grep -q "^$h " "$S/rules" || exit 1
        grep -v "^$h " "$S/rules" > "$S/r.tmp"; mv "$S/r.tmp" "$S/rules"
        grep -v "^$h " "$S/bound" > "$S/b.tmp"; mv "$S/b.tmp" "$S/bound"
        exit 0 ;;
    "delete set netdev")
        grep -qx "$5" "$S/sets" || exit 1
        grep -qF "@$5 " "$S/rules" && exit 1
        grep -vx "$5" "$S/sets" > "$S/s.tmp"; mv "$S/s.tmp" "$S/sets"
        exit 0 ;;
    "list table netdev")
        [ -s "$S/chains" ] || [ -s "$S/sets" ] || exit 1
        echo "table netdev tm_ratelimit {"
        while read -r s; do
            [ -n "$s" ] && printf '\tset %s {\n\t\ttype ipv4_addr\n\t\tflags dynamic\n\t}\n' "$s"
        done < "$S/sets"
        while read -r c; do
            printf '\tchain %s {\n' "$c"
            awk -v c="$c" -v a="$list" '$2 == c {
                h = $1; $1 = ""; $2 = ""; sub(/^  /, "")
                printf "\t\t%s%s\n", $0, (a ? " # handle " h : "")
            }' "$S/rules"
            printf '\t}\n'
        done < "$S/chains"
        echo "}"
        exit 0 ;;
esac
exit 0
MOCK

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    network.wan.device) echo "eth1" ;;
    network.lan.device) echo "br-lan" ;;
    "firewall.@zone[0].name") echo "lan" ;;
    "firewall.@zone[0].network") echo "lan" ;;
    trafficctl.main.persist_rules) echo "1" ;;
    *) exit 1 ;;
esac
MOCK

cat > "$MOCKBIN/ubus" <<'MOCK'
#!/bin/sh
case "$2" in
    network.interface.wan) echo '{"l3_device":"eth1"}' ;;
    *) echo '{"l3_device":"br-lan","ipv4-address":[{"address":"10.0.20.1","mask":24}]}' ;;
esac
MOCK

# ubus status objects on stdin, the persisted rules file with -i.
cat > "$MOCKBIN/jsonfilter" <<'MOCK'
#!/bin/sh
file="" expr=""
while [ $# -gt 0 ]; do
    case "$1" in
        -i) file="$2"; shift 2 ;;
        -e) expr="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [ -n "$file" ]; then [ -f "$file" ] || exit 1; input=$(cat "$file"); else input=$(cat); fi
case "$expr" in
    '@.l3_device') echo "$input" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].address') echo "$input" | sed -n 's/.*"address":"\([^"]*\)".*/\1/p' ;;
    '@["ipv4-address"][0].mask') echo "$input" | sed -n 's/.*"mask":\([0-9]*\).*/\1/p' ;;
    '@['*'].'*)
        idx=$(echo "$expr" | sed -n 's/^@\[\([0-9]*\)\]\..*/\1/p')
        key=$(echo "$expr" | sed -n 's/^@\[[0-9]*\]\.\(.*\)$/\1/p')
        printf '%s' "$input" | awk -v n="$idx" -v k="$key" '{
            gsub(/^\[/, ""); gsub(/\]$/, "")
            m = split($0, a, "},{")
            if (n + 1 > m) exit
            if (match(a[n + 1], "\"" k "\":\"[^\"]*\"")) {
                t = substr(a[n + 1], RSTART, RLENGTH)
                sub("\"" k "\":\"", "", t); sub("\"$", "", t); print t
            }
        }' ;;
esac
MOCK

cat > "$MOCKBIN/logger" <<MOCK
#!/bin/sh
echo "\$*" >> "$LOGGER_LOG"
MOCK

for c in ip tc conntrack; do
    printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/$c"
done
chmod +x "$MOCKBIN"/*

# br-lan with three ports: the first one always took the rule, so it takes
# at least two to see the bug, and three to see that it is not just "the
# second".
mkdir -p "$TMP/sys/class/net/eth1" "$TMP/sys/class/net/br-lan/brif/lan1" \
         "$TMP/sys/class/net/br-lan/brif/lan2" "$TMP/sys/class/net/br-lan/brif/lan3"
export TCTL_SYSFS_NET="$TMP/sys/class/net" NFT_STATE="$STATE"

# The library with its lease file and rules file pointed into the scratch dir:
# the IPv6 checks below need a host with a MAC.
FW="$TMP/trafficctl-fw.sh"
sed -e "s|^TCTL_LEASES_FILE=\"/tmp/dhcp.leases\"|TCTL_LEASES_FILE=\"$TMP/leases\"|" \
    -e "s|/etc/trafficctl/rules.json|$RULES|g" \
    "$BIN/trafficctl-fw.sh" > "$FW"
: > "$TMP/leases"
RL="$TMP/ratelimit.sh"
sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FW|" \
    -e "s|/etc/trafficctl/rules.json|$RULES|" \
    "$BIN/trafficctl-ratelimit.sh" > "$RL"
HOOK="$TMP/99-trafficctl-shapes"
sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$FW|" \
    -e "s|RULES_FILE=\"/etc/trafficctl/rules.json\"|RULES_FILE=\"$RULES\"|" \
    -e "s|SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|SHAPES_FILE=\"$TMP/shapes.json\"|" \
    -e "s|/etc/trafficctl/cut.state|$TMP/cut.state|" \
    "$HOTPLUG" > "$HOOK"

reset() {
    rm -f "$STATE"/*
    : > "$LOGGER_LOG"
    printf '[]\n' > "$RULES"
}
run() { PATH="$MOCKBIN:$PATH" TCTL_RULES_FILE="$RULES" sh "$@" 2>&1; }
table() { PATH="$MOCKBIN:$PATH" nft -a list table netdev tm_ratelimit 2>/dev/null; }
# The rules with this exact comment, as "<chain> <meter>" lines.
rules_of() {
    table | awk -v c="\"$1\"" '
        /^[ \t]*chain / { chain = $2; next }
        {
            for (i = 1; i < NF; i++) if ($i == "comment" && $(i+1) == c) {
                m = "-"
                for (j = 1; j < NF; j++) {
                    if ($j == "meter") m = $(j+1)
                    if ($j == "add" && substr($(j+1), 1, 1) == "@") m = substr($(j+1), 2)
                }
                print chain, m
            }
        }'
}
CMT=rl_ratelimit_10_0_20_0_24

for EMU in 1.0 1.1; do
    export NFT_EMU="$EMU"

    # ── each mode: one rule, with its own meter, on every port ──────────────
    reset
    OUT=$(run "$RL" 10.0.20.0/24 5000 "" each 1000)
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
    OUT=$(run "$RL" 10.0.20.0/24 8000 "" each 2000)
    assert_contains "nft $EMU: re-set at a new rate" 'both directions, each' "$OUT"
    assert_eq "nft $EMU: still one upload rule per port after the re-set" "3" \
        "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"
    assert_contains "nft $EMU: the re-set carries the new rate" \
        "limit rate over 250000 bytes/second" "$(table | grep "\"${CMT}_ul\"")"

    # ── removal takes the meters too ────────────────────────────────────────
    OUT=$(run "$RL" 10.0.20.0/24 0)
    assert_contains "nft $EMU: removed" '"ok":true' "$OUT"
    assert_eq "nft $EMU: no rule left" "" "$(rules_of "$CMT"; rules_of "${CMT}_ul")"
    assert_not_contains "nft $EMU: no meter set left behind" "set tctl_" "$(table)"

    # ── a port that refuses the rule ────────────────────────────────────────
    # Not a meter clash: anything nft turns down on one port. The clients
    # behind it are not limited, which the result must say; the other ports
    # keep their rules, so the limit stays applied where it could be.
    reset
    OUT=$(NFT_FAIL_CHAINS="ul_lan2" run "$RL" 10.0.20.0/24 5000 "" each)
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
    OUT=$(run "$RL" 10.0.20.0/24 5000 "" each)
    assert_contains "nft $EMU: re-applied with the port back: complete" '"partial":false' "$OUT"
    assert_eq "nft $EMU: re-applied: an upload rule on every port" "3" \
        "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"

    # A port whose chain cannot be created at all (the device is gone).
    reset
    OUT=$(NFT_FAIL_HOOKS="ul_lan3" run "$RL" 10.0.20.0/24 5000 "" each)
    assert_contains "nft $EMU: a missing port: ok, partial" '"ok":true,"partial":true' "$OUT"
    assert_contains "nft $EMU: a missing port is named" 'upload rule failed on lan3: No such file or directory' "$OUT"
    assert_eq "nft $EMU: a missing port: the others keep their rules" "2" \
        "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"

    # Upload fails everywhere: download only, and the IPv6 note is what the
    # kernel holds, not a constant.
    reset
    OUT=$(NFT_FAIL_CHAINS="ul_lan1 ul_lan2 ul_lan3" run "$RL" 10.0.20.0/24 5000 "" each)
    assert_contains "nft $EMU: no upload anywhere: download only" 'DOWNLOAD ONLY — upload rule failed on lan1' "$OUT"

    reset
    OUT=$(NFT_FAIL_CHAINS="ul_lan1 ul_lan2 ul_lan3 dl_br_lan dl" run "$RL" 10.0.20.0/24 5000 "" each)
    assert_contains "nft $EMU: nothing went in: not ok" '"ok":false' "$OUT"
    assert_contains "nft $EMU: nothing went in: the reason is given" 'Operation not supported' "$OUT"

    # ── the restore hook ────────────────────────────────────────────────────
    # ifup lan runs again without a reboot (a network restart), with the
    # rules of the first run still in place.
    reset
    printf '[{"type":"ratelimit","ip":"10.0.20.0/24","param":"5000","mode":"each"}]\n' > "$RULES"
    PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HOOK" >/dev/null 2>&1
    PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HOOK" >/dev/null 2>&1
    assert_eq "nft $EMU: restore twice: one upload rule per port" "3" \
        "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"
    assert_eq "nft $EMU: restore twice: one download rule" "1" \
        "$(rules_of "$CMT" | wc -l | tr -d ' ')"
    assert_eq "nft $EMU: restore twice: no failure logged" "" "$(cat "$LOGGER_LOG")"

    # A boot restore that meets a port mid-re-creation keeps the others, says
    # so, and the next ifup fills the port in.
    : > "$LOGGER_LOG"
    rm -f "$STATE"/*
    NFT_FAIL_HOOKS="ul_lan3" PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HOOK" >/dev/null 2>&1
    assert_contains "nft $EMU: a restore that misses a port is logged as partial, with the port" \
        "Restored ratelimit for 10.0.20.0/24 (5000kbit) PARTIALLY: upload rule failed on lan3: No such file or directory" "$(cat "$LOGGER_LOG")"
    assert_eq "nft $EMU: and keeps the other ports" "2" "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"
    : > "$LOGGER_LOG"
    PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HOOK" >/dev/null 2>&1
    assert_eq "nft $EMU: the next ifup fills the port in" "3" "$(rules_of "${CMT}_ul" | wc -l | tr -d ' ')"
    assert_eq "nft $EMU: the next ifup: one download rule" "1" "$(rules_of "$CMT" | wc -l | tr -d ' ')"
    assert_eq "nft $EMU: the next ifup: nothing logged" "" "$(cat "$LOGGER_LOG")"
done

# ── upgrade: meters named by releases before 1.30.4 ─────────────────────────
# On nftables 1.1 the old per-target set is shared by every port's rule and
# outlives them. Removing a limit set by an older release takes it as well.
export NFT_EMU=1.1
reset
printf 'dl_br_lan\nul_lan1\nul_lan2\nul_lan3\n' > "$STATE/chains"
printf 'tctl_d_10_0_20_0_24\ntctl_u_10_0_20_0_24\n' > "$STATE/sets"
{
    echo "4 dl_br_lan ip daddr 10.0.20.0/24 add @tctl_d_10_0_20_0_24 { ip daddr limit rate over 625000 bytes/second } counter packets 0 bytes 0 drop comment \"$CMT\""
    for i in 1 2 3; do
        echo "$((4 + i)) ul_lan$i ip saddr 10.0.20.0/24 add @tctl_u_10_0_20_0_24 { ip saddr limit rate over 625000 bytes/second } counter packets 0 bytes 0 drop comment \"${CMT}_ul\""
    done
} > "$STATE/rules"
echo 8 > "$STATE/handle"
OUT=$(run "$RL" 10.0.20.0/24 0)
assert_contains "upgrade: an old-named limit is removed" '"ok":true' "$OUT"
assert_eq "upgrade: its rules are gone" "" "$(rules_of "$CMT"; rules_of "${CMT}_ul")"
assert_not_contains "upgrade: its shared meter sets are gone" "set tctl_" "$(table)"

# Re-setting one target leaves the other target's meters alone.
reset
run "$RL" 10.0.30.0/24 3000 "" each >/dev/null
OUT=$(NFT_FAIL_CHAINS="ul_lan3" run "$RL" 10.0.20.0/24 5000 "" each)
OUT=$(run "$RL" 10.0.20.0/24 0)
assert_eq "other target: keeps every upload rule" "3" \
    "$(rules_of rl_ratelimit_10_0_30_0_24_ul | wc -l | tr -d ' ')"
assert_contains "other target: and its meter sets" "set tctl_m_10_0_30_0_24_ul_lan3" "$(table)"

# ── IPv6 flags follow the kernel ────────────────────────────────────────────
# A host with a lease gets the MAC-keyed v6 rules. When only its IPv4 upload
# rule fails, on every port, the v6 upload, feed and download rules are in:
# the result must say so instead of a hardcoded "IPv4 only".
CMTH=rl_ratelimit_10_0_20_50
printf '1794381090 02:00:00:00:00:50 10.0.20.50 tablet *\n' > "$TMP/leases"
reset
OUT=$(NFT_FAIL_RULE="ul_lan1 ip saddr 10.0.20.50" run "$RL" 10.0.20.50 5000)
assert_contains "v6: the host got its v6 rules" "ul_lan1" "$(rules_of "${CMTH}_ul6")"
assert_contains "v6: one port's v4 upload failing is partial, not 'DOWNLOAD ONLY'" \
    'PARTIAL: upload rule failed on lan1: Operation not supported' "$OUT"
assert_contains "v6: flags match the loaded rules" '"ipv6_upload":true,"ipv6_download":true' "$OUT"
assert_contains "v6: so does the note" '[IPv6: both directions]' "$OUT"
reset
OUT=$(NFT_FAIL_RULE="ul_lan1 ip saddr 10.0.20.50" \
    NFT_FAIL_CHAINS="ul_lan2 ul_lan3" run "$RL" 10.0.20.50 5000)
assert_contains "v6: no v4 upload anywhere: download only" 'DOWNLOAD ONLY' "$OUT"
ul6=$(rules_of "${CMTH}_ul6"); dl6=$(rules_of "${CMTH}_dl6"); fd6=$(rules_of "${CMTH}_v6")
assert_eq "v6: the kernel then holds the v6 upload rule on lan1 only" "ul_lan1 -" "$ul6"
assert_contains "v6: ... and the v6 download rule" "dl_br_lan" "$dl6"
assert_contains "v6: ... fed from lan1" "ul_lan1" "$fd6"
assert_contains "v6: download-only result reports the v6 rules that are live" \
    '"ipv6_upload":true,"ipv6_download":true' "$OUT"
assert_not_contains "v6: download-only result does not say IPv4 only" '[IPv4 only]' "$OUT"
: > "$TMP/leases"

# ── the restore hook matches comments exactly ───────────────────────────────
# 10.0.20.1's comment is a prefix of 10.0.20.10's. With only .10 live, the
# restore of .1 has nothing of its own to replace and must not go deleting.
reset
run "$RL" 10.0.20.10 4000 >/dev/null
printf '[{"type":"ratelimit","ip":"10.0.20.1","param":"5000"}]\n' > "$RULES"
: > "$TMP/nft.log"
NFT_LOG="$TMP/nft.log" PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HOOK" >/dev/null 2>&1
assert_eq "restore .1 with .10 live: no removal is attempted" "" "$(grep '^delete\|^-a list' "$TMP/nft.log")"
assert_eq "restore .1 with .10 live: .1 restored" "3" \
    "$(rules_of rl_ratelimit_10_0_20_1_ul | wc -l | tr -d ' ')"
# And with .1, .10 and .1/24 all live, the restore replaces only .1's rules.
reset
run "$RL" 10.0.20.10 4000 >/dev/null
run "$RL" 10.0.20.1/24 4000 "" shared >/dev/null
printf '[{"type":"ratelimit","ip":"10.0.20.1","param":"5000"}]\n' > "$RULES"
PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HOOK" >/dev/null 2>&1
assert_eq "restore .1: .10 keeps its upload rules" "3" \
    "$(rules_of rl_ratelimit_10_0_20_10_ul | wc -l | tr -d ' ')"
assert_eq "restore .1: .1/24 keeps its upload rules" "3" \
    "$(rules_of rl_ratelimit_10_0_20_1_24_ul | wc -l | tr -d ' ')"
assert_eq "restore .1: .1 itself restored once" "3" \
    "$(rules_of rl_ratelimit_10_0_20_1_ul | wc -l | tr -d ' ')"
# Restoring .1 again (ifup without reboot) replaces exactly its own rules.
PATH="$MOCKBIN:$PATH" ACTION=ifup INTERFACE=lan sh "$HOOK" >/dev/null 2>&1
assert_eq "restore .1 twice: still one rule per port" "3" \
    "$(rules_of rl_ratelimit_10_0_20_1_ul | wc -l | tr -d ' ')"
# Counting removals: the hook may only have deleted .1's own rules.
assert_eq "restore .1 twice: .10 untouched" "3" \
    "$(rules_of rl_ratelimit_10_0_20_10_ul | wc -l | tr -d ' ')"

# ── a shared legacy label: removing one target's limit keeps the other's ────
# Limits set before v1.13.2 carry the caller's label in the comment, so every
# target limited from Telegram shares rl_ratelimit_tg (upload _ul). v1.30.5
# removed that comment through tctl_ratelimit_remove, which matches on the
# comment alone: turning off 10.0.20.40's limit from Telegram lifted
# 10.0.20.4's as well, and deleted its meters.
export NFT_EMU=1.1
reset
printf 'dl_br_lan\nul_lan1\nul_lan2\nul_lan3\n' > "$STATE/chains"
printf 'tctl_d_10_0_20_40\ntctl_u_10_0_20_40\ntctl_d_10_0_20_4\ntctl_u_10_0_20_4\n' > "$STATE/sets"
{
    h=4
    for t in 10.0.20.40 10.0.20.4; do
        s=$(printf '%s' "$t" | tr '.' '_')
        echo "$h dl_br_lan ip daddr $t add @tctl_d_$s { ip daddr limit rate over 625000 bytes/second } counter packets 0 bytes 0 drop comment \"rl_ratelimit_tg\""
        h=$((h + 1))
        for i in 1 2 3; do
            echo "$h ul_lan$i ip saddr $t add @tctl_u_$s { ip saddr limit rate over 625000 bytes/second } counter packets 0 bytes 0 drop comment \"rl_ratelimit_tg_ul\""
            h=$((h + 1))
        done
    done
    echo "$h" > "$STATE/handle"
} > "$STATE/rules"
OUT=$(run "$RL" 10.0.20.40 0 tg)
assert_contains "shared legacy label: the limit is removed" '"ok":true' "$OUT"
assert_eq "shared legacy label: the target's own rules are gone" "" \
    "$(table | grep -E 'ip [ds]addr 10\.0\.20\.40 ')"
assert_eq "shared legacy label: the other target keeps its download rule" "1" \
    "$(rules_of rl_ratelimit_tg | wc -l | tr -d ' ')"
assert_eq "shared legacy label: and every upload rule" "3" \
    "$(table | grep -c 'ip saddr 10\.0\.20\.4 .*"rl_ratelimit_tg_ul"')"
assert_not_contains "shared legacy label: the target's meters are gone" "set tctl_u_10_0_20_40 " "$(table)"
assert_contains "shared legacy label: the other target's meters stay" "set tctl_u_10_0_20_4 " "$(table)"

# ── the meter name ──────────────────────────────────────────────────────────
NAME=$(PATH="$MOCKBIN:$PATH" sh -c ". '$FW' >/dev/null 2>&1; tctl_rl_meter_name \"\$(tctl_target_slug 255.255.255.255/32)\" \"\$(tctl_ingress_chain wlan-guest-5gx)\"")
assert_eq "name: deterministic" "tctl_m_255_255_255_255_32_ul_wlan_guest_5gx" "$NAME"
[ "${#NAME}" -le 64 ] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); echo "FAIL: name: ${#NAME} characters"; }

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
