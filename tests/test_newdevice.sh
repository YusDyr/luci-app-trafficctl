#!/bin/bash
# Default limits for devices seen for the first time (#28, part 2).
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

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/luci-app-trafficctl/root/usr/local/bin"
HOTPLUG="$REPO_ROOT/luci-app-trafficctl/root/etc/hotplug.d/dhcp/99-trafficctl-newdevice"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

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

LEDGER="$TMP/seen_macs"
LEASES="$TMP/dhcp.leases"
MOCKBIN="$TMP/bin"
mkdir -p "$MOCKBIN"

cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
[ "$1" = "neigh" ] || exit 1
echo "192.168.1.9 dev br-lan lladdr AA:BB:CC:DD:EE:03 REACHABLE"
echo "192.168.1.8 dev br-lan  FAILED"
MOCK
cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
exit 1
MOCK
cat > "$MOCKBIN/nft" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN"/*

printf '1700000000 aa:bb:cc:dd:ee:01 192.168.1.5 host-a *\n' > "$LEASES"
printf '1700000001 AA:BB:CC:DD:EE:02 192.168.1.6 host-b *\n' >> "$LEASES"

RULES="$TMP/rules.json"
SHAPES="$TMP/shapes.json"
: > "$SHAPES"
printf '[]\n' > "$RULES"

# fw.sh names its state files by absolute path, as it must on the router. The
# tests rewrite those paths into the scratch directory rather than adding
# override variables to the production script — the same approach the metrics
# tests take, and it keeps test-only seams out of the shipped code.
FW="$TMP/fw.sh"
sed -e "s|TCTL_SEEN_FILE=\"/etc/trafficctl/seen_macs\"|TCTL_SEEN_FILE=\"$LEDGER\"|" \
    -e "s|TCTL_LEASES_FILE=\"/tmp/dhcp.leases\"|TCTL_LEASES_FILE=\"$LEASES\"|" \
    -e "s|TCTL_SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|TCTL_SHAPES_FILE=\"$SHAPES\"|" \
    -e "s|TCTL_RULES_FILE=\"/etc/trafficctl/rules.json\"|TCTL_RULES_FILE=\"$RULES\"|" \
    -e "s|/usr/local/bin/trafficctl-ratelimit-stats.sh|$MOCKBIN/ratelimit-stats|" \
    -e "s|/usr/local/bin/trafficctl-shape-stats.sh|$MOCKBIN/shape-stats|" \
    "$BIN/trafficctl-fw.sh" > "$FW"

# Confirm the rewrite actually landed: a silently unpatched copy would write to
# the real /etc and every assertion below would be meaningless.
assert_contains "test harness: the ledger path was redirected" "$LEDGER" "$(cat "$FW")"
assert_empty "test harness: no production state path survived the rewrite" \
    "$(grep -n '/etc/trafficctl/seen_macs\|/etc/trafficctl/rules.json\|/tmp/dhcp.leases' "$FW")"

# Default stats mocks: nothing is limited unless a case says otherwise.
printf '#!/bin/sh\nprintf "[]\\n"\n' > "$MOCKBIN/ratelimit-stats"
printf '#!/bin/sh\nprintf "[]\\n"\n' > "$MOCKBIN/shape-stats"
chmod +x "$MOCKBIN/ratelimit-stats" "$MOCKBIN/shape-stats"

# Sourcing fw.sh runs its firewall probe, which is noise here.
ledger_env() {
    PATH="$MOCKBIN:$PATH" bash -c ". '$FW' >/dev/null 2>&1; $1"
}

rm -f "$LEDGER"
assert_eq "no ledger: seen_ready is false" "no" \
    "$(ledger_env 'tctl_seen_ready && echo yes || echo no')"

# The safe answer, so a caller that ignores seen_ready still cannot mass-limit.
assert_eq "no ledger: an unknown MAC still answers 'known'" "yes" \
    "$(ledger_env 'tctl_seen_known aa:bb:cc:dd:ee:99 && echo yes || echo no')"

ledger_env 'tctl_seen_seed'
assert_eq "seed: picks up both leases and the neighbour table" "3" \
    "$(wc -l < "$LEDGER" | tr -d ' ')"
assert_contains "seed: lowercases a MAC from the leases" "aa:bb:cc:dd:ee:02" "$(cat "$LEDGER")"
assert_contains "seed: lowercases a MAC from ip neigh" "aa:bb:cc:dd:ee:03" "$(cat "$LEDGER")"
assert_empty "seed: drops the neighbour entry with no lladdr" \
    "$(grep -i 'FAILED\|192.168' "$LEDGER")"

assert_eq "seeded ledger: a listed MAC is known" "yes" \
    "$(ledger_env 'tctl_seen_known AA:BB:CC:DD:EE:01 && echo yes || echo no')"
assert_eq "seeded ledger: an unlisted MAC is not known" "no" \
    "$(ledger_env 'tctl_seen_known aa:bb:cc:dd:ee:99 && echo yes || echo no')"

# Re-seeding must not wipe a ledger that already carries history.
printf 'aa:bb:cc:dd:ee:77\n' >> "$LEDGER"
ledger_env 'tctl_seen_seed'
assert_contains "seed: leaves an existing ledger alone" "aa:bb:cc:dd:ee:77" "$(cat "$LEDGER")"

ledger_env 'tctl_seen_mark aa:bb:cc:dd:ee:99'
assert_eq "mark: appends an unseen MAC" "yes" \
    "$(ledger_env 'tctl_seen_known aa:bb:cc:dd:ee:99 && echo yes || echo no')"
before=$(wc -l < "$LEDGER" | tr -d ' ')
ledger_env 'tctl_seen_mark AA:BB:CC:DD:EE:99'
assert_eq "mark: is idempotent, and case-insensitively so" "$before" \
    "$(wc -l < "$LEDGER" | tr -d ' ')"

# The cap keeps the file from growing without bound on a guest network.
rm -f "$LEDGER"
i=0
while [ "$i" -lt 1005 ]; do
    printf 'aa:bb:cc:%02x:%02x:%02x\n' $((i / 65536)) $(((i / 256) % 256)) $((i % 256)) >> "$LEDGER"
    i=$((i + 1))
done
ledger_env 'tctl_seen_mark ff:ff:ff:ff:ff:ff'
count=$(wc -l < "$LEDGER" | tr -d ' ')
assert_eq "cap: the ledger is trimmed once it passes TCTL_SEEN_MAX" "800" "$count"
assert_eq "cap: the most recent MAC survives the trim" "yes" \
    "$(ledger_env 'tctl_seen_known ff:ff:ff:ff:ff:ff && echo yes || echo no')"

# ════════════════════════════════════════════════════════════════════════════
# tctl_has_limit — "is this address already under somebody's control?"
#
# Live nft/tc state is not enough. After a reboot the restore hook runs on
# `ifup lan` and only when persist_rules is on, so a device carrying a manual
# limit reads as unlimited until then; a default limit applied in that window
# would overwrite a deliberate choice. The persisted files are checked too.
# ════════════════════════════════════════════════════════════════════════════

has_limit_env() {
    PATH="$MOCKBIN:$PATH" bash -c ". '$FW' >/dev/null 2>&1; tctl_has_limit '$1' && echo yes || echo no"
}

printf '[{"type":"ratelimit","ip":"192.168.1.50","param":"2000"}]\n' > "$RULES"
assert_eq "has_limit: sees a persisted rate limit while nft is empty" "yes" \
    "$(has_limit_env 192.168.1.50)"
assert_eq "has_limit: says no for an address nothing mentions" "no" \
    "$(has_limit_env 192.168.1.51)"

printf '[]\n' > "$RULES"
printf '[{"ip":"192.168.1.60","rate_kbit":5000}]\n' > "$SHAPES"
assert_eq "has_limit: sees a persisted shape" "yes" "$(has_limit_env 192.168.1.60)"

# Live state is consulted first; a stats script that reports the address wins
# even with both files empty.
printf '[]\n' > "$RULES"
: > "$SHAPES"
cat > "$MOCKBIN/ratelimit-stats" <<'MOCK'
#!/bin/sh
printf '[{"ip":"192.168.1.70","rate_kbit":1000,"packets":0,"bytes":0}]\n'
MOCK
chmod +x "$MOCKBIN/ratelimit-stats"
assert_eq "has_limit: sees a live rate limit" "yes" "$(has_limit_env 192.168.1.70)"
assert_eq "has_limit: still says no for an unrelated address" "no" "$(has_limit_env 192.168.1.71)"
# Back to "nothing is limited" for the hotplug cases below.
printf '#!/bin/sh\nprintf "[]\\n"\n' > "$MOCKBIN/ratelimit-stats"
chmod +x "$MOCKBIN/ratelimit-stats"

# ════════════════════════════════════════════════════════════════════════════
# The hotplug script
# ════════════════════════════════════════════════════════════════════════════

APPLIED="$TMP/applied.log"
HP="$TMP/hotplug"

sed -e "s|\\. /usr/local/bin/trafficctl-fw.sh|. $FW|" \
    -e "s|/usr/local/bin/trafficctl-ratelimit.sh|$MOCKBIN/ratelimit|" \
    -e "s|/usr/local/bin/trafficctl-shape.sh|$MOCKBIN/shape|" \
    "$HOTPLUG" > "$HP"

cat > "$MOCKBIN/ratelimit" <<MOCK
#!/bin/sh
printf 'ratelimit via=%s src=%s args=%s\n' "\$TCTL_VIA" "\$TCTL_SRC" "\$*" >> "$APPLIED"
MOCK
cat > "$MOCKBIN/shape" <<MOCK
#!/bin/sh
printf 'shape via=%s src=%s args=%s\n' "\$TCTL_VIA" "\$TCTL_SRC" "\$*" >> "$APPLIED"
MOCK
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/logger"
chmod +x "$MOCKBIN/ratelimit" "$MOCKBIN/shape" "$MOCKBIN/logger"

# uci mock driven by a file, so each case can restate the configuration.
UCIVALS="$TMP/uci.vals"
cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
key=""
for a in "\$@"; do case "\$a" in trafficctl.*) key="\$a" ;; esac; done
v=\$(grep "^\$key=" "$UCIVALS" 2>/dev/null | head -1 | cut -d= -f2-)
[ -n "\$v" ] || exit 1
printf '%s\n' "\$v"
MOCK
chmod +x "$MOCKBIN/uci"

run_hotplug() {   # run_hotplug <action> <mac> <ip>
    : > "$APPLIED"
    PATH="$MOCKBIN:$PATH" ACTION="$1" MACADDR="$2" IPADDR="$3" \
        sh "$HP" >/dev/null 2>&1
    cat "$APPLIED" 2>/dev/null
}

cat > "$UCIVALS" <<'VALS'
trafficctl.newdevice.enabled=1
trafficctl.newdevice.limit_kbit=4000
trafficctl.newdevice.limit_mode=limiter
trafficctl.logging.enabled=0
VALS

# A ledger that does not exist cannot answer "is this device new?", and the
# wrong answer limits the entire LAN. The first pass only takes the baseline.
# The MAC here appears in NEITHER seed source, which is the case that matters:
# with the guard removed, seeding alone would still call it new and limit it.
# Using a MAC that the leases already carry would let a broken version pass.
rm -f "$LEDGER"
out=$(run_hotplug add aa:bb:cc:dd:ee:5a 192.168.1.50)
assert_empty "no ledger: applies nothing on the first pass, even to a MAC the seed never saw" "$out"
assert_eq "no ledger: the baseline is taken instead" "yes" \
    "$([ -f "$LEDGER" ] && echo yes || echo no)"
assert_eq "no ledger: the baseline carries the devices the seed did find" "yes" \
    "$(ledger_env 'tctl_seen_known aa:bb:cc:dd:ee:01 && echo yes || echo no')"
assert_eq "no ledger: the triggering MAC is recorded too, so it is not limited later" "yes" \
    "$(ledger_env 'tctl_seen_known aa:bb:cc:dd:ee:5a && echo yes || echo no')"

assert_empty "a MAC already in the ledger is left alone" \
    "$(run_hotplug add aa:bb:cc:dd:ee:01 192.168.1.5)"

assert_empty "a non-add DHCP event does nothing" \
    "$(run_hotplug old aa:bb:cc:dd:ee:aa 192.168.1.90)"

out=$(run_hotplug add aa:bb:cc:dd:ee:bb 192.168.1.91)
assert_contains "a genuinely new device gets the configured limit" \
    "args=192.168.1.91 4000" "$out"
assert_contains "the limit is attributed to the feature, not to the CLI" \
    "via=newdevice src=hotplug" "$out"
assert_eq "the new device is recorded, so it is limited only once" "yes" \
    "$(ledger_env 'tctl_seen_known aa:bb:cc:dd:ee:bb && echo yes || echo no')"
assert_empty "the same device on a later lease renewal is left alone" \
    "$(run_hotplug add aa:bb:cc:dd:ee:bb 192.168.1.91)"

# A limit somebody set by hand outranks the default.
printf '[{"type":"ratelimit","ip":"192.168.1.92","param":"1000"}]\n' > "$RULES"
assert_empty "a device that already has a limit is not touched" \
    "$(run_hotplug add aa:bb:cc:dd:ee:cc 192.168.1.92)"
assert_eq "...but it is still recorded, so it is not reconsidered" "yes" \
    "$(ledger_env 'tctl_seen_known aa:bb:cc:dd:ee:cc && echo yes || echo no')"
printf '[]\n' > "$RULES"

# A new device with no address yet: nothing to apply a limit to.
assert_empty "a new MAC with no address applies nothing" \
    "$(run_hotplug add aa:bb:cc:dd:ee:dd "")"

# Shaper mode routes to the other backend.
sed -i.bak 's/^trafficctl.newdevice.limit_mode=.*/trafficctl.newdevice.limit_mode=shaper/' "$UCIVALS"
out=$(run_hotplug add aa:bb:cc:dd:ee:ee 192.168.1.93)
assert_contains "shaper mode calls the shaper" "shape via=newdevice" "$out"
assert_contains "shaper mode passes add, address and rate" "args=add 192.168.1.93 4000" "$out"

# Switched off, or with no rate set, the feature must be inert.
sed -i.bak 's/^trafficctl.newdevice.enabled=.*/trafficctl.newdevice.enabled=0/' "$UCIVALS"
assert_empty "disabled: applies nothing to a new device" \
    "$(run_hotplug add aa:bb:cc:dd:ee:f1 192.168.1.94)"

sed -i.bak 's/^trafficctl.newdevice.enabled=.*/trafficctl.newdevice.enabled=1/' "$UCIVALS"
sed -i.bak 's/^trafficctl.newdevice.limit_kbit=.*/trafficctl.newdevice.limit_kbit=0/' "$UCIVALS"
assert_empty "rate 0: enabled but with no rate is a no-op" \
    "$(run_hotplug add aa:bb:cc:dd:ee:f2 192.168.1.95)"
assert_eq "rate 0: and the device is NOT recorded, so it still counts as new later" "no" \
    "$(ledger_env 'tctl_seen_known aa:bb:cc:dd:ee:f2 && echo yes || echo no')"

# ════════════════════════════════════════════════════════════════════════════

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
