#!/bin/bash
# Several shapes at once: each one's u32 filters survive the others' changes.
#
# Every shape is one HTB class plus one prio-10 u32 filter on the LAN device
# (match ip dst) and one on the IFB (match ip src). The shaper deleted a
# shape's filter with "tc filter del ... prio 10 ... match ip dst <ip>/32"
# and no handle, and the kernel's u32 then deletes EVERY filter of that prio
# on the device, whatever match is given. Adding a shape (attach detaches
# first) or removing one took all other shapes' filters with it: only the
# last shape applied was in force, while the classes stayed and the UI showed
# every device as shaped. After a reboot the restore left one working shape.
#
# tests/lib/tc-htb.sh is a stateful tc that keeps that kernel behaviour, so
# the test reads what the router holds afterwards.

PASS=0
FAIL=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/trafficctl/files/usr/libexec/trafficctl"
TCHTB="$ROOT/tests/lib/tc-htb.sh"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"
export TC_STATE="$TMPDIR/tc"

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

cat > "$MOCKBIN/uci" <<'MOCK'
#!/bin/sh
case "$3" in
    network.wan.device) echo "eth1" ;;
    network.lan.device) echo "br-lan" ;;
    "firewall.@zone[0].name") echo "lan" ;;
    "firewall.@zone[0].network") echo "lan" ;;
    *) exit 1 ;;
esac
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
printf '#!/bin/sh\nexec sh "%s" tc "$@"\n' "$TCHTB" > "$MOCKBIN/tc"
printf '#!/bin/sh\nexec sh "%s" ip "$@"\n' "$TCHTB" > "$MOCKBIN/ip"
printf '#!/bin/sh\nexit 0\n' > "$MOCKBIN/logger"
chmod +x "$MOCKBIN"/*

mkdir -p "$TMPDIR/sys/class/net/eth1" \
         "$TMPDIR/sys/class/net/br-lan/brif/lan1" \
         "$TMPDIR/sys/class/net/br-lan/brif/lan2"
export TCTL_SYSFS_NET="$TMPDIR/sys/class/net"

SHAPE="$TMPDIR/shape.sh"
sed -e "s|/usr/libexec/trafficctl/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" \
    -e "s|SHAPES_FILE=\"/etc/trafficctl/shapes.json\"|SHAPES_FILE=\"$TMPDIR/shapes.json\"|" \
    -e "s|/sys/class/net/|$TMPDIR/sys/class/net/|g" \
    "$BIN/trafficctl-shape.sh" > "$SHAPE"

shape() { PATH="$MOCKBIN:$PATH" sh "$SHAPE" "$@" 2>&1; }
# "<dir> <ip> flowid <class>" for every prio-10 filter on a device.
filters() {
    PATH="$MOCKBIN:$PATH" sh "$TCHTB" dump | awk -v d="$1" '
        $1 == "dev" { cur = $2; next }
        cur == d && $1 == "filter" && $3 == "10" { print $4, $5, $6, $7 }' | sort
}
classes() {
    PATH="$MOCKBIN:$PATH" sh "$TCHTB" dump | awk -v d="$1" '
        $1 == "dev" { cur = $2; next }
        cur == d && $1 == "class" && $2 != "1:1" && $2 != "1:fffe" { print $2 }' | sort | tr '\n' ' '
}

PATH="$MOCKBIN:$PATH" sh "$TCHTB" init br-lan lan1 lan2 eth1

# ── three shapes: every one keeps its filters ───────────────────────────────
OUT=$(shape add 192.168.1.50 5000)
assert_contains "add .50: ok" '"ok":true' "$OUT"
shape add 192.168.1.51 6000 >/dev/null
shape add 192.168.1.52 7000 >/dev/null

assert_eq "three shapes: one download filter each on br-lan" \
"dst 192.168.1.50/32 flowid 1:2
dst 192.168.1.51/32 flowid 1:3
dst 192.168.1.52/32 flowid 1:4" "$(filters br-lan)"
assert_eq "three shapes: one upload filter each on the IFB" \
"src 192.168.1.50/32 flowid 1:2
src 192.168.1.51/32 flowid 1:3
src 192.168.1.52/32 flowid 1:4" "$(filters tctl-ifb0)"

# ── re-shaping one leaves the others in force ──────────────────────────────
shape add 192.168.1.51 8000 >/dev/null
assert_eq "reshape .51: the other shapes keep their download filters" \
"dst 192.168.1.50/32 flowid 1:2
dst 192.168.1.51/32 flowid 1:3
dst 192.168.1.52/32 flowid 1:4" "$(filters br-lan)"
assert_eq "reshape .51: and their upload filters" \
"src 192.168.1.50/32 flowid 1:2
src 192.168.1.51/32 flowid 1:3
src 192.168.1.52/32 flowid 1:4" "$(filters tctl-ifb0)"

# ── removing one leaves the others in force ────────────────────────────────
OUT=$(shape remove 192.168.1.50)
assert_contains "remove .50: ok" '"ok":true' "$OUT"
assert_eq "remove .50: the other shapes keep their download filters" \
"dst 192.168.1.51/32 flowid 1:3
dst 192.168.1.52/32 flowid 1:4" "$(filters br-lan)"
assert_eq "remove .50: and their upload filters" \
"src 192.168.1.51/32 flowid 1:3
src 192.168.1.52/32 flowid 1:4" "$(filters tctl-ifb0)"
assert_eq "remove .50: its class is gone, the others stay" "1:3 1:4 " "$(classes br-lan)"

# An address that is a prefix of another's (.5 of .50) touches nothing else.
shape add 192.168.1.50 5000 >/dev/null
shape add 192.168.1.5 4000 >/dev/null
shape remove 192.168.1.5 >/dev/null
assert_eq "remove .5: .50, .51 and .52 keep their filters" \
"dst 192.168.1.50/32 flowid 1:2
dst 192.168.1.51/32 flowid 1:3
dst 192.168.1.52/32 flowid 1:4" "$(filters br-lan)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
