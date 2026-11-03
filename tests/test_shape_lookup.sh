#!/bin/bash
# Readers of shapes.json must find a device's HTB class by LOOKUP.
#
# Minors are allocated (lowest free, see trafficctl-shape.sh), not derived from
# the address. Two readers had not caught up:
#
#   * trafficctl-summary.sh derived 1:<hex(o3*256+o4)> per device, so the first
#     shaped device's rate (class 1:2) was shown on 192.168.x.2, and the device
#     actually shaped read 0 — the Telegram bot builds its shape flag and its
#     "Shape — Remove" button from that field.
#   * trafficctl-shape-stats.sh only matched records that END at the classid,
#     so every shape with its own upload ceiling (rate_kbit_up) was missing
#     from its output, and with it from tctl_has_limit.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/local/bin"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"

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
        printf "FAIL: %s\n  expected to find: '%s'\n  in: '%s'\n" "$desc" "$needle" "$haystack"
    fi
}

SHAPES="$TMPDIR/shapes.json"
FW="$TMPDIR/fw.sh"
sed -e "s|TCTL_SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|TCTL_SHAPES_FILE=\"$SHAPES\"|" \
    "$BIN/trafficctl-fw.sh" > "$FW"
assert_contains "harness: the shapes path was redirected" "$SHAPES" "$(cat "$FW")"

# .100 symmetric, allocated 1:2 — the minor the old derivation gives 192.168.0.2.
# .101 with its own upload ceiling, allocated 1:3.
# .5   persisted before allocation: no classid, so its class is the derived 1:105.
cat > "$SHAPES" <<'JSON'
[{"ip":"192.168.1.100","rate_kbit":10000,"classid":"1:2"},{"ip":"192.168.1.101","rate_kbit":5000,"classid":"1:3","rate_kbit_up":1000},{"ip":"192.168.1.5","rate_kbit":2000}]
JSON

for c in uci ubus nft iptables; do printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/$c"; done
cat > "$MOCKBIN/tc" <<'MOCK'
#!/bin/sh
case "$*" in
    *qdisc\ show*) echo "qdisc htb 1: root refcnt 2 r2q 10 default 0xfffe" ;;
    *class\ show*)
        for c in "1:1 rate 1Gbit" "1:2 rate 10Mbit" "1:3 rate 5Mbit" "1:105 rate 2Mbit" "1:fffe rate 1Gbit"; do
            set -- $c
            echo "class htb $1 parent 1:1 prio 0 rate $3 ceil $3 burst 1600b cburst 1600b"
            echo " Sent 1000 bytes 10 pkt (dropped 0, overlimits 0 requeues 0)"
            echo " backlog 0b 0p requeues 0"
            echo " lended: 10 borrowed: 0 giants: 0"
        done ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN"/*

fw() { PATH="$MOCKBIN:$PATH" sh -c ". $FW >/dev/null 2>&1; $1" 2>&1; }

# ── tctl_shape_classmap ──────────────────────────────────────────────────────

MAP=$(fw 'tctl_shape_classmap')
assert_contains "classmap: symmetric record" "192.168.1.100 1:2" "$MAP"
assert_contains "classmap: record with rate_kbit_up" "192.168.1.101 1:3" "$MAP"
assert_contains "classmap: pre-allocation record maps to its derived class" "192.168.1.5 1:105" "$MAP"
assert_eq "classmap: one line per record" "3" "$(printf '%s\n' "$MAP" | grep -c .)"

# ── summary: shape_kbit per device ───────────────────────────────────────────

LOOKUP="$TMPDIR/lookup.sh"
sed -n '/^lookup_shape_kbit()/,/^}/p' "$BIN/trafficctl-summary.sh" > "$LOOKUP"
assert_contains "harness: lookup_shape_kbit extracted" "lookup_shape_kbit()" "$(cat "$LOOKUP")"
TC_MAP=$(printf '1:2 10000\n1:3 5000\n1:105 2000')

shape_of() {
    PATH="$MOCKBIN:$PATH" SHAPE_MAP="$MAP" TC_MAP="$TC_MAP" sh -c ". $LOOKUP; lookup_shape_kbit $1"
}
assert_eq "summary: the shaped device shows its own rate" "10000" "$(shape_of 192.168.1.100)"
assert_eq "summary: an asymmetric shape shows its download rate" "5000" "$(shape_of 192.168.1.101)"
assert_eq "summary: a pre-allocation shape still reads" "2000" "$(shape_of 192.168.1.5)"
# The derived minor of 192.168.0.2 is 1:2, which belongs to .100.
assert_eq "summary: an unshaped device does not borrow another's class" "0" "$(shape_of 192.168.0.2)"
assert_eq "summary: an unknown device reads 0" "0" "$(shape_of 10.0.0.9)"

# ── shape-stats: every record form is reported ───────────────────────────────

STATS_SH="$TMPDIR/shape-stats.sh"
sed "s|/usr/local/bin/trafficctl-fw.sh|$FW|" "$BIN/trafficctl-shape-stats.sh" > "$STATS_SH"
STATS=$(PATH="$MOCKBIN:$PATH" sh "$STATS_SH" 2>/dev/null)
assert_contains "stats: symmetric shape reported" '"ip":"192.168.1.100"' "$STATS"
assert_contains "stats: shape with its own upload ceiling reported" '"ip":"192.168.1.101"' "$STATS"
assert_contains "stats: pre-allocation shape reported" '"ip":"192.168.1.5"' "$STATS"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
