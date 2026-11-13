#!/bin/bash
# Default limits for devices seen for the first time (#28, part 2), done by
# `trafficctl newdevice` since the ucode port: the DHCP hotplug hook passes
# its environment on to it.
#
# The feature has one dangerous direction and one harmless one. Calling a
# device NEW when it is not applies a limit nobody asked for — and because the
# trigger is a DHCP lease, getting it wrong does that to the whole LAN as
# leases renew. Calling a device KNOWN when it is new merely does nothing.
#
# So most of what follows tests refusals: the cases where the code must decide
# NOT to act. The one test that proves the feature works at all is small by
# comparison, which is the intended ratio.

PASS=0
FAIL=0

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/fw4_env.sh
. "$UC_TESTLIB/fw4_env.sh"
HOTPLUG="$UC_REPO/trafficctl/files/etc/hotplug.d/dhcp/99-trafficctl-newdevice"

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
# The seen-MAC ledger
# ════════════════════════════════════════════════════════════════════════════

LEDGER="$ROOT/etc/trafficctl/seen_macs"
SHAPES="$ROOT/etc/trafficctl/shapes.json"
printf '192.168.1.9 dev br-lan lladdr AA:BB:CC:DD:EE:03 REACHABLE\n192.168.1.8 dev br-lan  FAILED\n' > "$STATE/neigh"
printf '1700000000 aa:bb:cc:dd:ee:01 192.168.1.5 host-a *\n' > "$LEASES"
printf '1700000001 AA:BB:CC:DD:EE:02 192.168.1.6 host-b *\n' >> "$LEASES"
: > "$SHAPES"
printf '[]\n' > "$RULES"
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/tc"
chmod +x "$MOCKBIN/tc"
fw_cfg 0

lib() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.lib "$@" 2>&1; }
known() { [ "$(lib seen_known "\"$1\"")" = "true" ] && echo yes || echo no; }

rm -f "$LEDGER"
assert_eq "no ledger: seen_ready is false" "false" "$(lib seen_ready)"

# The safe answer, so a caller that ignores seen_ready still cannot mass-limit.
assert_eq "no ledger: an unknown MAC still answers 'known'" "yes" "$(known aa:bb:cc:dd:ee:99)"

lib seen_seed >/dev/null
assert_eq "seed: picks up both leases and the neighbour table" "3" \
    "$(wc -l < "$LEDGER" | tr -d ' ')"
assert_contains "seed: lowercases a MAC from the leases" "aa:bb:cc:dd:ee:02" "$(cat "$LEDGER")"
assert_contains "seed: lowercases a MAC from ip neigh" "aa:bb:cc:dd:ee:03" "$(cat "$LEDGER")"
assert_empty "seed: drops the neighbour entry with no lladdr" \
    "$(grep -i 'FAILED\|192.168' "$LEDGER")"

assert_eq "seeded ledger: a listed MAC is known" "yes" "$(known AA:BB:CC:DD:EE:01)"
assert_eq "seeded ledger: an unlisted MAC is not known" "no" "$(known aa:bb:cc:dd:ee:99)"
# Nothing to compare an invalid MAC with, so it answers the safe way.
assert_eq "seeded ledger: an invalid MAC answers 'known'" "yes" "$(known 'aa:bb;x')"

# Re-seeding must not wipe a ledger that already carries history.
printf 'aa:bb:cc:dd:ee:77\n' >> "$LEDGER"
lib seen_seed >/dev/null
assert_contains "seed: leaves an existing ledger alone" "aa:bb:cc:dd:ee:77" "$(cat "$LEDGER")"

lib seen_mark '"aa:bb:cc:dd:ee:99"' >/dev/null
assert_eq "mark: appends an unseen MAC" "yes" "$(known aa:bb:cc:dd:ee:99)"
before=$(wc -l < "$LEDGER" | tr -d ' ')
lib seen_mark '"AA:BB:CC:DD:EE:99"' >/dev/null
assert_eq "mark: is idempotent, and case-insensitively so" "$before" \
    "$(wc -l < "$LEDGER" | tr -d ' ')"

# The cap keeps the file from growing without bound on a guest network.
rm -f "$LEDGER"
i=0
while [ "$i" -lt 1005 ]; do
    printf 'aa:bb:cc:%02x:%02x:%02x\n' $((i / 65536)) $(((i / 256) % 256)) $((i % 256)) >> "$LEDGER"
    i=$((i + 1))
done
lib seen_mark '"ff:ff:ff:ff:ff:ff"' >/dev/null
count=$(wc -l < "$LEDGER" | tr -d ' ')
assert_eq "cap: the ledger is trimmed once it passes 1000 entries" "800" "$count"
assert_eq "cap: the most recent MAC survives the trim" "yes" "$(known ff:ff:ff:ff:ff:ff)"

# ════════════════════════════════════════════════════════════════════════════
# has_limit — "is this address already under somebody's control?"
#
# Live nft/tc state is not enough. After a reboot the restore hook runs on
# `ifup lan` and only when persist_rules is on, so a device carrying a manual
# limit reads as unlimited until then; a default limit applied in that window
# would overwrite a deliberate choice. The persisted files are checked too.
# ════════════════════════════════════════════════════════════════════════════

has_limit() {
    [ "$(PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tcall trafficctl.ctl has_limit "\"$1\"" 2>&1)" = "true" ] \
        && echo yes || echo no
}

printf '[{"type":"ratelimit","ip":"192.168.1.50","param":"2000"}]\n' > "$RULES"
assert_eq "has_limit: sees a persisted rate limit while nft is empty" "yes" "$(has_limit 192.168.1.50)"
assert_eq "has_limit: says no for an address nothing mentions" "no" "$(has_limit 192.168.1.51)"
# Matched on the whole quoted address: .5 is a prefix of .50.
assert_eq "has_limit: a prefix of a limited address is not limited" "no" "$(has_limit 192.168.1.5)"

printf '[]\n' > "$RULES"
printf '[{"ip":"192.168.1.60","rate_kbit":5000}]\n' > "$SHAPES"
assert_eq "has_limit: sees a persisted shape" "yes" "$(has_limit 192.168.1.60)"

# Live state is consulted first; a limiter rule for the address wins even with
# both files empty.
printf '[]\n' > "$RULES"
: > "$SHAPES"
mkdir -p "$STATE/nftfix"
cp "$UC_REPO/tests/fixtures/nft-1.0.2/rl.tm_ratelimit.json" "$STATE/nftfix/-j_list_table_netdev_tm_ratelimit"
export NFT_FIXTURES="$STATE/nftfix"
assert_eq "has_limit: sees a live rate limit" "yes" "$(has_limit 192.168.1.50)"
assert_eq "has_limit: still says no for an unrelated address" "no" "$(has_limit 192.168.1.71)"
unset NFT_FIXTURES

# ════════════════════════════════════════════════════════════════════════════
# trafficctl newdevice
# ════════════════════════════════════════════════════════════════════════════

APPLIED="$STATE/applied.log"
LIBEXEC="$ROOT/usr/libexec/trafficctl"
mkdir -p "$LIBEXEC"
cat > "$LIBEXEC/trafficctl-ratelimit.sh" <<MOCK
#!/bin/sh
printf 'ratelimit via=%s src=%s args=%s\n' "\$TCTL_VIA" "\$TCTL_SRC" "\$*" >> "$APPLIED"
MOCK
cat > "$LIBEXEC/trafficctl-shape.sh" <<MOCK
#!/bin/sh
printf 'shape via=%s src=%s args=%s\n' "\$TCTL_VIA" "\$TCTL_SRC" "\$*" >> "$APPLIED"
MOCK
chmod +x "$LIBEXEC"/*

setnd() {   # setnd <enabled> <limit_kbit> <limit_mode>
    fw_cfg 0
    printf "\nconfig newdevice 'newdevice'\n\toption enabled '%s'\n\toption limit_kbit '%s'\n\toption limit_mode '%s'\n" \
        "$1" "$2" "$3" >> "$ROOT/etc/config/trafficctl"
}

run_newdevice() {   # run_newdevice <action> <mac> <ip>
    : > "$APPLIED"
    PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" ACTION="$1" MACADDR="$2" IPADDR="$3" \
        tctl newdevice >/dev/null 2>&1
    cat "$APPLIED" 2>/dev/null
}

setnd 1 4000 limiter

# A ledger that does not exist cannot answer "is this device new?", and the
# wrong answer limits the entire LAN. The first pass only takes the baseline.
# The MAC here appears in NEITHER seed source, which is the case that matters:
# with the guard removed, seeding alone would still call it new and limit it.
# Using a MAC that the leases already carry would let a broken version pass.
rm -f "$LEDGER"
: > "$LOGGER_LOG"
out=$(run_newdevice add aa:bb:cc:dd:ee:5a 192.168.1.50)
assert_empty "no ledger: applies nothing on the first pass, even to a MAC the seed never saw" "$out"
assert_eq "no ledger: the baseline is taken instead" "yes" \
    "$([ -f "$LEDGER" ] && echo yes || echo no)"
assert_eq "no ledger: the baseline carries the devices the seed did find" "yes" "$(known aa:bb:cc:dd:ee:01)"
assert_eq "no ledger: the triggering MAC is recorded too, so it is not limited later" "yes" "$(known aa:bb:cc:dd:ee:5a)"
assert_contains "no ledger: syslog says why nothing was applied" "seeded the seen-MAC ledger" "$(cat "$LOGGER_LOG")"

assert_empty "a MAC already in the ledger is left alone" \
    "$(run_newdevice add aa:bb:cc:dd:ee:01 192.168.1.5)"

assert_empty "a non-add DHCP event does nothing" \
    "$(run_newdevice old aa:bb:cc:dd:ee:aa 192.168.1.90)"

out=$(run_newdevice add aa:bb:cc:dd:ee:bb 192.168.1.91)
assert_eq "a genuinely new device gets the configured limit" \
    "ratelimit via=newdevice src=hotplug args=192.168.1.91 4000 rl_ratelimit_192_168_1_91" "$out"
assert_eq "the new device is recorded, so it is limited only once" "yes" "$(known aa:bb:cc:dd:ee:bb)"
assert_empty "the same device on a later lease renewal is left alone" \
    "$(run_newdevice add aa:bb:cc:dd:ee:bb 192.168.1.91)"

# A limit somebody set by hand outranks the default.
printf '[{"type":"ratelimit","ip":"192.168.1.92","param":"1000"}]\n' > "$RULES"
assert_empty "a device that already has a limit is not touched" \
    "$(run_newdevice add aa:bb:cc:dd:ee:cc 192.168.1.92)"
assert_eq "...but it is still recorded, so it is not reconsidered" "yes" "$(known aa:bb:cc:dd:ee:cc)"
printf '[]\n' > "$RULES"

# A new device with no address yet: nothing to apply a limit to.
assert_empty "a new MAC with no address applies nothing" \
    "$(run_newdevice add aa:bb:cc:dd:ee:dd "")"

# Shaper mode routes to the other backend.
setnd 1 4000 shaper
out=$(run_newdevice add aa:bb:cc:dd:ee:ee 192.168.1.93)
assert_eq "shaper mode calls the shaper with add, address, rate and label" \
    "shape via=newdevice src=hotplug args=add 192.168.1.93 4000 shape_192.168.1.93" "$out"

# Switched off, or with no rate set, the feature must be inert.
setnd 0 4000 limiter
assert_empty "disabled: applies nothing to a new device" \
    "$(run_newdevice add aa:bb:cc:dd:ee:f1 192.168.1.94)"

setnd 1 0 limiter
assert_empty "rate 0: enabled but with no rate is a no-op" \
    "$(run_newdevice add aa:bb:cc:dd:ee:f2 192.168.1.95)"
assert_eq "rate 0: and the device is NOT recorded, so it still counts as new later" "no" "$(known aa:bb:cc:dd:ee:f2)"
setnd 1 '4000;reboot' limiter
assert_empty "a rate that is not a number is a no-op" \
    "$(run_newdevice add aa:bb:cc:dd:ee:f3 192.168.1.96)"

# ── the Telegram notification queue ─────────────────────────────────────────
# Independent of the default limit: keyed on the bot's own known list.
NOTIFY="$ROOT/tmp/trafficctl_tg_newdev"
fw_cfg 0
printf "\nconfig telegram 'telegram'\n\toption enabled '1'\n" >> "$ROOT/etc/config/trafficctl"
printf '{"aa:bb:cc:dd:ee:01":1}\n' > "$ROOT/etc/trafficctl/telegram_known.json"
rm -f "$NOTIFY"
PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" ACTION=add MACADDR=aa:bb:cc:dd:ee:a1 IPADDR=192.168.1.97 HOSTNAME=laptop \
    tctl newdevice >/dev/null 2>&1
PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" ACTION=add MACADDR=aa:bb:cc:dd:ee:01 IPADDR=192.168.1.5 \
    tctl newdevice >/dev/null 2>&1
# bash exports its own HOSTNAME; the hook hands dnsmasq's on, empty here.
PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" ACTION=add MACADDR=aa:bb:cc:dd:ee:a2 HOSTNAME='' \
    tctl newdevice >/dev/null 2>&1
assert_eq "telegram: an unknown MAC is queued, a known one is not; ? and unknown fill the gaps" \
    "$(printf 'aa:bb:cc:dd:ee:a1\t192.168.1.97\tlaptop\naa:bb:cc:dd:ee:a2\t?\tunknown')" "$(cat "$NOTIFY" 2>/dev/null)"

# ── the hotplug hook ────────────────────────────────────────────────────────
# A wrapper now: what matters is that it filters as before and hands the
# DHCP environment on unchanged.
HP="$STATE/hotplug"
sed "s|/usr/sbin/trafficctl|$MOCKBIN/tctl-stub|" "$HOTPLUG" > "$HP"
cat > "$MOCKBIN/tctl-stub" <<MOCK
#!/bin/sh
printf '%s|%s|%s|%s|%s\n' "\$*" "\$ACTION" "\$MACADDR" "\$IPADDR" "\$HOSTNAME" >> "$STATE/stub.log"
MOCK
chmod +x "$MOCKBIN/tctl-stub"
: > "$STATE/stub.log"
ACTION=add MACADDR=aa:bb:cc:dd:ee:a3 IPADDR=192.168.1.98 HOSTNAME=tv sh "$HP"
ACTION=old MACADDR=aa:bb:cc:dd:ee:a4 IPADDR=192.168.1.99 sh "$HP"
ACTION=add MACADDR='' IPADDR=192.168.1.99 sh "$HP"
assert_eq "hotplug: passes an add event on with its environment, and nothing else" \
    "newdevice|add|aa:bb:cc:dd:ee:a3|192.168.1.98|tv" "$(cat "$STATE/stub.log")"

# ════════════════════════════════════════════════════════════════════════════

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
