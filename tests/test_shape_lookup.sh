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

BIN="$(cd "$(dirname "$0")/.." && pwd)/trafficctl/files/usr/libexec/trafficctl"

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
TMPDIR="$UC_TMP/t"
mkdir -p "$TMPDIR/root/etc/trafficctl"
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

# The ucode readers find it under TCTL_ROOT, the shell ones at the path below.
SHAPES="$TMPDIR/root/etc/trafficctl/shapes.json"
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

for c in uci ubus nft; do printf '#!/bin/sh\nexit 1\n' > "$MOCKBIN/$c"; done
cat > "$MOCKBIN/tc" <<'MOCK'
#!/bin/sh
case "$*" in
    *qdisc\ show*) echo "qdisc htb 1: root refcnt 2 r2q 10 default 0xfffe" ;;
    *class\ show\ dev\ tctl-ifb0*)
        # Upload classes: .101 has its own ceiling, .100 is symmetric.
        for c in "1:1 rate 1Gbit" "1:2 rate 10Mbit" "1:3 rate 1Mbit"; do
            set -- $c
            echo "class htb $1 parent 1:1 prio 0 rate $3 ceil $3 burst 1600b cburst 1600b"
        done ;;
    *class\ show*)
        # TC_FIRST: a known class listed ahead of the root class.
        [ -n "$TC_FIRST" ] && { echo "class htb 1:2 parent 1:1 prio 0 rate 10Mbit ceil 10Mbit burst 1600b cburst 1600b"; echo " Sent 7 bytes 1 pkt (dropped 0, overlimits 0 requeues 0)"; }
        for c in "1:1 rate 1Gbit" "1:2 rate 10Mbit" "1:3 rate 5Mbit" "1:105 rate 2Mbit" "1:fffe rate 1Gbit"; do
            set -- $c
            [ -n "$TC_FIRST" ] && [ "$1" = 1:2 ] && continue
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

TC_MAP_UP=$(printf '1:2 10000\n1:3 1000')

shape_of() {
    PATH="$MOCKBIN:$PATH" SHAPE_MAP="$MAP" TC_MAP="$TC_MAP" TC_MAP_UP="$TC_MAP_UP" sh -c ". $LOOKUP; lookup_shape_kbit $1"
}
assert_eq "summary: the shaped device shows its own rate" "10000" "$(shape_of 192.168.1.100)"
assert_eq "summary: an asymmetric shape shows its download rate" "5000" "$(shape_of 192.168.1.101)"
assert_eq "summary: a pre-allocation shape still reads" "2000" "$(shape_of 192.168.1.5)"
# The derived minor of 192.168.0.2 is 1:2, which belongs to .100.
assert_eq "summary: an unshaped device does not borrow another's class" "0" "$(shape_of 192.168.0.2)"
assert_eq "summary: an unknown device reads 0" "0" "$(shape_of 10.0.0.9)"
assert_eq "summary up: an asymmetric shape shows its upload rate" "1000" "$(shape_of '192.168.1.101 up')"
assert_eq "summary up: a symmetric shape reads the same both ways" "10000" "$(shape_of '192.168.1.100 up')"
assert_eq "summary up: no IFB class (no kmod-ifb) reads 0" "0" "$(shape_of '192.168.1.5 up')"

# ── tctl_tc_class_rates: the maps both readers are built from ────────────────

DL=$(fw 'tctl_tc_class_rates br-lan')
UL=$(fw 'tctl_tc_class_rates tctl-ifb0')
assert_contains "class rates: LAN download class" "1:3 5000" "$DL"
assert_contains "class rates: IFB upload class" "1:3 1000" "$UL"
assert_eq "class rates: root and default classes left out" "" "$(printf '%s\n' "$DL" | grep -E '^1:(1|fffe) ')"
assert_eq "class rates: default IFB name" "tctl-ifb0" "$(fw 'tctl_shape_ifb_dev')"

# ── device view: looked up, not derived, both directions ─────────────────────

DEV_SRC=$(cat "$BIN/trafficctl-device.sh")
assert_eq "device: no classid derived from the address" "" "$(printf '%s\n' "$DEV_SRC" | grep -E 'o3 \* 256')"
assert_contains "device: classid from shapes.json" "tctl_shape_classmap" "$DEV_SRC"
assert_contains "device: upload shape from the IFB" 'tctl_tc_class_rates "$(tctl_shape_ifb_dev)"' "$DEV_SRC"
assert_contains "device: shape_kbit_up in the JSON" '"shape_kbit_up":%d' "$DEV_SRC"

# ── ucode: the same lookups ─────────────────────────────────────────────────

uc() { PATH="$MOCKBIN:$PATH" TCTL_ROOT="$TMPDIR/root" "$@" 2>&1; }
assert_eq "ucode classmap: every record form, as the shell map" \
    '{"192.168.1.100":"1:2","192.168.1.101":"1:3","192.168.1.5":"1:105"}' "$(uc tcall trafficctl.ctl shape_classmap | jq -c .)"
assert_eq "ucode class rates: LAN, root and default left out" \
    '{"1:2":10000,"1:3":5000,"1:105":2000}' "$(uc tcall trafficctl.ctl tc_class_rates '"br-lan"' | jq -c .)"
assert_eq "ucode class rates: IFB" '{"1:2":10000,"1:3":1000}' "$(uc tcall trafficctl.ctl tc_class_rates '"tctl-ifb0"' | jq -c .)"
assert_eq "ucode: default IFB name" "tctl-ifb0" "$(uc tcall trafficctl.ctl ifb_dev)"

# ── shape-stats: every record form is reported ───────────────────────────────

STATS=$(uc tctl shape-stats)
assert_contains "stats: symmetric shape reported" '"ip":"192.168.1.100"' "$STATS"
assert_contains "stats: shape with its own upload ceiling reported" '"ip":"192.168.1.101"' "$STATS"
assert_contains "stats: pre-allocation shape reported" '"ip":"192.168.1.5"' "$STATS"
assert_contains "stats: counters of the class" '"ip":"192.168.1.101","rate_kbit":5000,"bytes":1000,"packets":10,"backlog":0,"drops":0,"overlimits":0,"requeues":0,"lended":10,"borrowed":0' "$STATS"
assert_eq "stats: one record per shape" "3" "$(printf '%s' "$STATS" | jq length)"
# v1.30.0 did not close a record at the root class, so a class listed before
# 1:1 came out twice.
STATS=$(TC_FIRST=1 uc tctl shape-stats)
assert_eq "stats: a class before the root class is reported once" "1" "$(printf '%s' "$STATS" | jq '[.[] | select(.ip == "192.168.1.100")] | length')"
assert_contains "stats: with its own counters" '"ip":"192.168.1.100","rate_kbit":10000,"bytes":7,"packets":1' "$STATS"
mv "$SHAPES" "$SHAPES.off"
assert_eq "stats: no shapes.json, nothing known" "[]" "$(uc tctl shape-stats)"
mv "$SHAPES.off" "$SHAPES"
mkdir -p "$TMPDIR/nohtb"
printf '#!/bin/sh\necho "qdisc fq_codel 0: root refcnt 2"\n' > "$TMPDIR/nohtb/tc"
chmod +x "$TMPDIR/nohtb/tc"
assert_eq "stats: no HTB root, no shapes" "[]" "$(PATH="$TMPDIR/nohtb:$MOCKBIN:$PATH" TCTL_ROOT="$TMPDIR/root" tctl shape-stats 2>&1)"
assert_eq "shim: the script is the CLI command" 'exec /usr/sbin/trafficctl shape-stats "$@"' "$(tail -n 1 "$BIN/trafficctl-shape-stats.sh")"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
