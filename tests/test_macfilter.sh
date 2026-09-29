#!/bin/bash
# Tests for trafficctl-macfilter-add.sh / trafficctl-macfilter-remove.sh —
# previously had NO test coverage at all. Fakes uci/hostapd_cli/ubus/ip on
# PATH and runs the real scripts, asserting on the uci list mutations and the
# runtime hostapd ACL calls made.
#
# Two behaviours are under test.
#
# 1. The scripts must respect whichever ACL policy ("allow"/whitelist vs
#    "deny"/blacklist) the admin already configured on a wifi interface,
#    rather than forcing "deny" — forcing deny would invert a curated
#    whitelist (letting in everything it meant to keep out).
#
# 2. The scripts must never claim success for a runtime block that did not
#    happen. A router without hostapd-utils wrote the uci maclist, got
#    "command not found" from every hostapd_cli call, discarded the status and
#    answered ok:true while the device kept browsing. So the hostapd_cli fake
#    below is STATEFUL — ADD_MAC/DEL_MAC mutate ACL files that SHOW reads back
#    — and its knobs let each failure mode be mocked apart from the others:
#    the tool missing entirely, the tool present but not landing the entry, the
#    control socket dead, ubus unavailable. A fake that merely logs the call
#    would pass whether or not the ACL was ever touched, which is the very
#    assumption that let this ship.

PASS=0
FAIL=0

BIN="$(cd "$(dirname "$0")/.." && pwd)/luci-app-trafficctl/root/usr/local/bin"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
MOCKBIN="$TMPDIR/bin"
mkdir -p "$MOCKBIN"

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
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

ADD_SH="$TMPDIR/macfilter-add.sh"
REMOVE_SH="$TMPDIR/macfilter-remove.sh"
sed "s|/usr/local/bin/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" "$BIN/trafficctl-macfilter-add.sh" > "$ADD_SH"
sed "s|/usr/local/bin/trafficctl-fw.sh|$BIN/trafficctl-fw.sh|" "$BIN/trafficctl-macfilter-remove.sh" > "$REMOVE_SH"

UCI_LOG="$TMPDIR/uci.log"
HOSTAPD_LOG="$TMPDIR/hostapd.log"
UBUS_LOG="$TMPDIR/ubus.log"
LEASES_FILE="$TMPDIR/dhcp.leases"

# Runtime state the fakes read and write. deny_acl/accept_acl are hostapd's
# running ACLs, bans is what `ubus call hostapd.X list_bans` would report.
STATE="$TMPDIR/state"
mkdir -p "$STATE"

# Stateful hostapd_cli. ADD_MAC/DEL_MAC really mutate the ACL file that SHOW
# prints, so "did the entry land" is a question the tests can ask instead of
# assume. $STATE/cli_mode selects the failure being mocked:
#   ok      - works
#   silent  - every command still exits 0, but the ACL never changes. That is
#             the shape of a hostapd_cli talking to the wrong socket, or a
#             hostapd that drops the entry: nothing in the exit status says so,
#             which is exactly why the code reads the ACL back.
#   dead    - the binary exists but the control socket does not answer ping.
cat > "$MOCKBIN/hostapd_cli" <<MOCK
#!/bin/sh
echo "\$*" >> "$HOSTAPD_LOG"
STATE="$STATE"
MOCK
cat >> "$MOCKBIN/hostapd_cli" <<'MOCK'
mode=$(cat "$STATE/cli_mode" 2>/dev/null)
# argv is always: -i <iface> <cmd> [sub] [mac]
shift 2
cmd="$1"; sub="$2"; mac="$3"
case "$cmd" in
    ping)
        [ "$mode" = "dead" ] && exit 1
        echo "PONG"
        ;;
    deny_acl|accept_acl)
        f="$STATE/$cmd"
        [ -f "$f" ] || : > "$f"
        case "$sub" in
            SHOW) cat "$f" ;;
            ADD_MAC)
                [ "$mode" = "silent" ] || grep -qixF "$mac" "$f" || echo "$mac" >> "$f"
                ;;
            DEL_MAC)
                if [ "$mode" != "silent" ]; then
                    grep -vixF "$mac" "$f" > "$f.new"
                    mv "$f.new" "$f"
                fi
                ;;
        esac
        ;;
esac
exit 0
MOCK
chmod +x "$MOCKBIN/hostapd_cli"

# tctl_get_hostapd_ifaces enumerates RUNNING APs via `ubus list`, and the
# fallback path calls del_client / list_bans on them. $STATE/ubus_mode:
#   ok          - everything works
#   ban_nonzero - del_client exits non-zero but the ban still lands, which is
#                 what hostapd does for a client that is not associated. The
#                 code must believe list_bans, not the exit status.
#   noban       - del_client fails and no ban lands
#   noradio     - ubus answers and no hostapd object exists (radios down)
#   broken      - ubus itself fails, which is NOT the same as "no AP running"
cat > "$MOCKBIN/ubus" <<MOCK
#!/bin/sh
STATE="$STATE"
UBUS_LOG="$UBUS_LOG"
MOCK
cat >> "$MOCKBIN/ubus" <<'MOCK'
mode=$(cat "$STATE/ubus_mode" 2>/dev/null)
[ "$mode" = "broken" ] && exit 1
[ -f "$STATE/bans" ] || : > "$STATE/bans"
case "$1" in
    list)
        echo "network.interface"
        [ "$mode" = "noradio" ] || echo "hostapd.wifi0"
        exit 0
        ;;
    call)
        case "$3" in
            del_client)
                echo "del_client $2 $4" >> "$UBUS_LOG"
                [ "$mode" = "noban" ] && exit 1
                echo "$4" | grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' >> "$STATE/bans"
                [ "$mode" = "ban_nonzero" ] && exit 1
                exit 0
                ;;
            list_bans)
                printf '{"clients":['
                sep=""
                while read -r m; do
                    [ -z "$m" ] && continue
                    printf '%s"%s"' "$sep" "$m"
                    sep=","
                done < "$STATE/bans"
                printf ']}\n'
                exit 0
                ;;
        esac
        exit 1
        ;;
esac
exit 1
MOCK
chmod +x "$MOCKBIN/ubus"
cp "$MOCKBIN/hostapd_cli" "$TMPDIR/hostapd_cli.real"

cat > "$MOCKBIN/ip" <<'MOCK'
#!/bin/sh
exit 1
MOCK
chmod +x "$MOCKBIN/ip"

# dnsmasq lease format: <expiry> <mac> <ip> <hostname> <clientid>
echo "1787600000 aa:bb:cc:dd:ee:ff 192.168.1.50 device-name *" > "$LEASES_FILE"
sed -i.bak "s|/tmp/dhcp.leases|$LEASES_FILE|g" "$ADD_SH" "$REMOVE_SH"

# $1 = cli_mode, or "missing" to delete the binary entirely — the router this
# bug was found on had no hostapd-utils at all, and "not installed" has to be
# mocked apart from "installed but not working".
# $2 = ubus_mode. $3.. = MACs already in the running deny ACL.
set_runtime() {
    local cli="$1" ubus_mode="$2" m
    shift 2
    : > "$STATE/deny_acl"
    : > "$STATE/accept_acl"
    : > "$STATE/bans"
    for m in "$@"; do echo "$m" >> "$STATE/deny_acl"; done
    echo "$ubus_mode" > "$STATE/ubus_mode"
    if [ "$cli" = "missing" ]; then
        rm -f "$MOCKBIN/hostapd_cli"
        echo ok > "$STATE/cli_mode"
    else
        cp "$TMPDIR/hostapd_cli.real" "$MOCKBIN/hostapd_cli"
        chmod +x "$MOCKBIN/hostapd_cli"
        echo "$cli" > "$STATE/cli_mode"
    fi
}
set_runtime ok ok

acl_state() { cat "$STATE/deny_acl" "$STATE/accept_acl" 2>/dev/null; }

run_add() { : > "$UCI_LOG"; : > "$HOSTAPD_LOG"; : > "$UBUS_LOG"; PATH="$MOCKBIN:$PATH" sh "$ADD_SH" "$@" 2>&1; }
run_remove() { : > "$UCI_LOG"; : > "$HOSTAPD_LOG"; : > "$UBUS_LOG"; PATH="$MOCKBIN:$PATH" sh "$REMOVE_SH" "$@" 2>&1; }

set_uci_single_iface() {
    # $1 = macfilter mode ("deny"/"allow"/""), $2 = existing maclist content
    local mode="$1" maclist="$2"
    cat > "$MOCKBIN/uci" <<MOCK
#!/bin/sh
echo "\$*" >> "$UCI_LOG"
case "\$*" in
    "show wireless") echo "wireless.wifi0=wifi-iface" ;;
    -q\ get\ wireless.wifi0.macfilter) echo "$mode" ;;
    -q\ get\ wireless.wifi0.maclist) echo "$maclist" ;;
    *) exit 1 ;;
esac
exit 0
MOCK
    chmod +x "$MOCKBIN/uci"
}

# ── validation ───────────────────────────────────────────────────────────────

OUT=$(run_add)
assert_contains "add: missing ip rejected" '"ok":false' "$OUT"

OUT=$(run_add 'bad;ip')
assert_contains "add: invalid ip rejected" '"ok":false' "$OUT"

# ── add on a deny/blacklist radio: MAC gets ADDED to the deny list ──────────

set_uci_single_iface "deny" "11:22:33:44:55:66"
OUT=$(run_add 192.168.1.50)
assert_contains "add (deny radio): reports ok" '"ok":true' "$OUT"
assert_contains "add (deny radio): MAC resolved from leases in the response" "aa:bb:cc:dd:ee:ff" "$OUT"
UCI=$(cat "$UCI_LOG")
assert_contains "add (deny radio): MAC added to the blacklist" \
    "add_list wireless.wifi0.maclist=aa:bb:cc:dd:ee:ff" "$UCI"
assert_not_contains "add (deny radio): macfilter mode left untouched (already deny)" \
    "wireless.wifi0.macfilter=" "$UCI"
HOSTAPD=$(cat "$HOSTAPD_LOG")
assert_contains "add (deny radio): deny_acl ADD_MAC issued" "deny_acl ADD_MAC aa:bb:cc:dd:ee:ff" "$HOSTAPD"
assert_contains "add (deny radio): client deauthenticated" "deauthenticate aa:bb:cc:dd:ee:ff" "$HOSTAPD"
assert_not_contains "add (deny radio): never touches accept_acl" "accept_acl" "$HOSTAPD"

# ── add on an unconfigured radio (no macfilter set yet): creates deny mode ──

set_uci_single_iface "" ""
OUT=$(run_add 192.168.1.50)
UCI=$(cat "$UCI_LOG")
assert_contains "add (unconfigured radio): creates deny mode on demand" \
    "wireless.wifi0.macfilter=deny" "$UCI"
assert_contains "add (unconfigured radio): MAC added to the new blacklist" \
    "add_list wireless.wifi0.maclist=aa:bb:cc:dd:ee:ff" "$UCI"

# ── add on an allow/whitelist radio where the target IS listed (i.e. an ──────
# ── allowed device): blocking means DROPPING it from the allow-list, never ──
# ── forcing deny mode (that would invert the whole whitelist). ─────────────

set_uci_single_iface "allow" "aa:bb:cc:dd:ee:ff"
OUT=$(run_add 192.168.1.50)
assert_contains "add (allow radio): reports ok" '"ok":true' "$OUT"
UCI=$(cat "$UCI_LOG")
assert_contains "add (allow radio): MAC dropped from the whitelist" \
    "del_list wireless.wifi0.maclist=aa:bb:cc:dd:ee:ff" "$UCI"
assert_not_contains "add (allow radio): never forces deny mode onto a whitelist radio" \
    "wireless.wifi0.macfilter=deny" "$UCI"
assert_not_contains "add (allow radio): never adds to maclist (that would be wrong on a whitelist)" \
    "add_list wireless.wifi0.maclist" "$UCI"
HOSTAPD=$(cat "$HOSTAPD_LOG")
assert_contains "add (allow radio): accept_acl DEL_MAC issued (not deny_acl)" \
    "accept_acl DEL_MAC aa:bb:cc:dd:ee:ff" "$HOSTAPD"
assert_not_contains "add (allow radio): never issues deny_acl on a whitelist radio" "deny_acl" "$HOSTAPD"

# ── remove: inverse of add on each radio type ───────────────────────────────

set_uci_single_iface "deny" "aa:bb:cc:dd:ee:ff"
OUT=$(run_remove 192.168.1.50)
assert_contains "remove (deny radio): reports ok" '"ok":true' "$OUT"
UCI=$(cat "$UCI_LOG")
assert_contains "remove (deny radio): MAC dropped from the blacklist" \
    "del_list wireless.wifi0.maclist=aa:bb:cc:dd:ee:ff" "$UCI"
HOSTAPD=$(cat "$HOSTAPD_LOG")
assert_contains "remove (deny radio): deny_acl DEL_MAC issued" "deny_acl DEL_MAC aa:bb:cc:dd:ee:ff" "$HOSTAPD"

set_uci_single_iface "allow" "11:22:33:44:55:66"
OUT=$(run_remove 192.168.1.50)
assert_contains "remove (allow radio): reports ok" '"ok":true' "$OUT"
UCI=$(cat "$UCI_LOG")
assert_contains "remove (allow radio): MAC added back to the whitelist" \
    "add_list wireless.wifi0.maclist=aa:bb:cc:dd:ee:ff" "$UCI"
HOSTAPD=$(cat "$HOSTAPD_LOG")
assert_contains "remove (allow radio): accept_acl ADD_MAC issued" "accept_acl ADD_MAC aa:bb:cc:dd:ee:ff" "$HOSTAPD"

OUT=$(run_remove 'bad;ip')
assert_contains "remove: invalid ip rejected" '"ok":false' "$OUT"


# ── enforcement reporting ───────────────────────────────────────────────────
# The bug these cover: on a router with no hostapd-utils the uci maclist was
# written and committed, every hostapd_cli call died with "not found", the
# status was discarded, and the script answered ok:true while the device stayed
# associated and online. Nothing distinguished "blocked" from "written down".

# Working hostapd_cli: the entry lands in the running ACL and is read back.
set_uci_single_iface "deny" ""
set_runtime ok ok
OUT=$(run_add 192.168.1.50)
assert_contains "enforce (cli ok): ok:true" '"ok":true' "$OUT"
assert_contains "enforce (cli ok): enforcement=acl" '"enforcement":"acl"' "$OUT"
assert_contains "enforce (cli ok): MAC really is in the running deny ACL" \
    "aa:bb:cc:dd:ee:ff" "$(cat "$STATE/deny_acl")"

# hostapd-utils not installed — the exact router this was found on. The uci
# maclist must still be written (it is the durable half and it applies at the
# next wifi restart), but the answer must not be ok:true.
set_uci_single_iface "deny" ""
set_runtime missing ok
OUT=$(run_add 192.168.1.50)
assert_contains "enforce (cli missing): NOT ok" '"ok":false' "$OUT"
assert_contains "enforce (cli missing): falls back to a ubus ban" '"enforcement":"ban"' "$OUT"
assert_contains "enforce (cli missing): says the block is temporary" "temporary" "$OUT"
assert_contains "enforce (cli missing): names the remedy" "hostapd-utils" "$OUT"
assert_contains "enforce (cli missing): uci maclist still written (intent is kept)" \
    "add_list wireless.wifi0.maclist=aa:bb:cc:dd:ee:ff" "$(cat "$UCI_LOG")"
assert_contains "enforce (cli missing): ubus del_client carries a ban_time" \
    "ban_time" "$(cat "$UBUS_LOG")"
assert_contains "enforce (cli missing): ubus del_client deauths the client" \
    '"deauth":true' "$(cat "$UBUS_LOG")"

# hostapd_cli present and exiting 0, but the ACL never gains the entry. Only
# reading the ACL back catches this; the exit status says everything is fine.
set_uci_single_iface "deny" ""
set_runtime silent noban
OUT=$(run_add 192.168.1.50)
assert_contains "enforce (cli lies, no ubus ban): NOT ok" '"ok":false' "$OUT"
assert_contains "enforce (cli lies, no ubus ban): enforcement=none" '"enforcement":"none"' "$OUT"
assert_contains "enforce (cli lies): the ADD_MAC really was issued" \
    "deny_acl ADD_MAC aa:bb:cc:dd:ee:ff" "$(cat "$HOSTAPD_LOG")"
assert_not_contains "enforce (cli lies): but nothing landed in the ACL" \
    "aa:bb:cc:dd:ee:ff" "$(cat "$STATE/deny_acl")"

# Same silent hostapd_cli, but ubus can still ban: the fallback has to engage
# off the readback, not off an error code that never came.
set_uci_single_iface "deny" ""
set_runtime silent ok
OUT=$(run_add 192.168.1.50)
assert_contains "enforce (cli lies, ubus ok): falls back to ban" '"enforcement":"ban"' "$OUT"
assert_contains "enforce (cli lies, ubus ok): still NOT ok" '"ok":false' "$OUT"

# Control socket dead, and del_client returns non-zero while the ban lands —
# which is what hostapd does for a client that is not currently associated.
# list_bans is the authority, not the exit status.
set_uci_single_iface "deny" ""
set_runtime dead ban_nonzero
OUT=$(run_add 192.168.1.50)
assert_contains "enforce (dead socket, del_client exits non-zero): ban still reported" \
    '"enforcement":"ban"' "$OUT"

# No AP running at all: ubus answered, there is simply nothing to program, and
# the maclist takes effect when wifi starts. That is a real success.
set_uci_single_iface "deny" ""
set_runtime ok noradio
OUT=$(run_add 192.168.1.50)
assert_contains "enforce (no radio up): ok:true" '"ok":true' "$OUT"
assert_contains "enforce (no radio up): enforcement=no-radio" '"enforcement":"no-radio"' "$OUT"

# ubus itself unusable. An empty interface list here means "cannot tell", not
# "no AP running" — treating the two alike would reopen the same hole through
# a different door.
set_uci_single_iface "deny" ""
set_runtime ok broken
OUT=$(run_add 192.168.1.50)
assert_contains "enforce (ubus broken): NOT ok" '"ok":false' "$OUT"
assert_contains "enforce (ubus broken): enforcement=none, not no-radio" '"enforcement":"none"' "$OUT"
assert_not_contains "enforce (ubus broken): never claims no-radio" '"enforcement":"no-radio"' "$OUT"

# Re-blocking a MAC uci already lists. This used to be a total no-op that still
# answered ok:true, so pressing Block again — the obvious reaction to "it did
# not work" — could never repair a config-only block.
set_uci_single_iface "deny" "aa:bb:cc:dd:ee:ff"
set_runtime ok ok
OUT=$(run_add 192.168.1.50)
assert_contains "re-block (already in uci): still programs the running ACL" \
    "deny_acl ADD_MAC aa:bb:cc:dd:ee:ff" "$(cat "$HOSTAPD_LOG")"
assert_contains "re-block (already in uci): MAC now in the running deny ACL" \
    "aa:bb:cc:dd:ee:ff" "$(cat "$STATE/deny_acl")"
assert_contains "re-block (already in uci): reports ok once enforced" '"ok":true' "$OUT"
assert_not_contains "re-block (already in uci): no duplicate uci entry" \
    "add_list wireless.wifi0.maclist" "$(cat "$UCI_LOG")"

# ── unblock enforcement ─────────────────────────────────────────────────────
# An unblock that silently fails leaves a real person off the network while the
# UI says they are not blocked, so it gets the same readback treatment.

set_uci_single_iface "deny" "aa:bb:cc:dd:ee:ff"
set_runtime ok ok aa:bb:cc:dd:ee:ff
OUT=$(run_remove 192.168.1.50)
assert_contains "unblock (cli ok): ok:true" '"ok":true' "$OUT"
assert_contains "unblock (cli ok): enforcement=acl" '"enforcement":"acl"' "$OUT"
assert_not_contains "unblock (cli ok): MAC gone from the running deny ACL" \
    "aa:bb:cc:dd:ee:ff" "$(cat "$STATE/deny_acl")"

# Runtime ACL still denies the MAC even though uci no longer lists it: the
# unblock must not report success just because the uci edit went through.
set_uci_single_iface "deny" ""
set_runtime silent noban aa:bb:cc:dd:ee:ff
OUT=$(run_remove 192.168.1.50)
assert_contains "unblock (cli lies): NOT ok" '"ok":false' "$OUT"
assert_contains "unblock (cli lies): enforcement=none" '"enforcement":"none"' "$OUT"
assert_contains "unblock (cli lies): warns the device may still be blocked" \
    "may still be blocked" "$OUT"

# No hostapd_cli: the runtime ACL cannot be inspected at all, so the honest
# answer is "cannot confirm", never ok:true.
set_uci_single_iface "deny" ""
set_runtime missing ok
OUT=$(run_remove 192.168.1.50)
assert_contains "unblock (cli missing): NOT ok" '"ok":false' "$OUT"
assert_contains "unblock (cli missing): enforcement=none" '"enforcement":"none"' "$OUT"

# A ban left over from an earlier hostapd_cli-less block keeps the client off
# the air, and no ubus method can lift one early. Removing it from uci does not
# make the person reachable again, so say so.
set_uci_single_iface "deny" ""
set_runtime missing ok
run_add 192.168.1.50 >/dev/null
OUT=$(run_remove 192.168.1.50)
assert_contains "unblock (leftover ubus ban): NOT ok" '"ok":false' "$OUT"
assert_contains "unblock (leftover ubus ban): enforcement=ban" '"enforcement":"ban"' "$OUT"

# Whitelist radio: unblocking means the accept ACL must really carry the MAC
# again, checked by reading it back rather than by the ADD_MAC exiting 0.
set_uci_single_iface "allow" ""
set_runtime silent noban
OUT=$(run_remove 192.168.1.50)
assert_contains "unblock (allow radio, cli lies): NOT ok" '"ok":false' "$OUT"
set_uci_single_iface "allow" ""
set_runtime ok ok
OUT=$(run_remove 192.168.1.50)
assert_contains "unblock (allow radio, cli ok): ok:true" '"ok":true' "$OUT"
assert_contains "unblock (allow radio, cli ok): MAC back in the accept ACL" \
    "aa:bb:cc:dd:ee:ff" "$(cat "$STATE/accept_acl")"


# ── the row indicator (defect 2) ─────────────────────────────────────────────
# The backend reported wifi_blocked correctly all along; the dashboard row did
# not show it, because the only marking was a line-through applied inside the
# `else if (isWifi)` branch of the Link cell. That branch is reachable only
# while the device is associated on WiFi — so the marking disappeared from the
# row in precisely the case where the block WORKED (device stops associating,
# the cell falls through to "?" or eth) and whenever a blocked device was on
# cable. Source-level guards, in the same spirit as tests/test_byte_overflow.sh:
# there is no JS test harness in this repo, and the failure mode is structural.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATUS_JS="$ROOT/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"

# The marking must hang off the finished cell, not off one branch inside it.
CONN_CELL=$(grep -A 10 "cellMap.conn_type = E(" "$STATUS_JS")
assert_contains "row: Link cell is marked from wifi_blocked outside the isWifi branch" \
    "r.wifi_blocked" "$CONN_CELL"
assert_contains "row: marking uses the shared badge helper" \
    "mkWifiBlockBadge" "$CONN_CELL"

assert_contains "row: frontend consumes wifi_block_pending" \
    "wifi_block_pending" "$(cat "$STATUS_JS")"

# A device on the deny list that is still associated is not blocked, and the
# backend has to say so for the row to be able to.
assert_contains "summary.sh emits wifi_block_pending" \
    '"wifi_block_pending":%s' "$(cat "$ROOT/luci-app-trafficctl/root/usr/local/bin/trafficctl-summary.sh")"
assert_contains "device.sh emits wifi_block_pending" \
    '"wifi_block_pending":%s' "$(cat "$ROOT/luci-app-trafficctl/root/usr/local/bin/trafficctl-device.sh")"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
