#!/bin/bash
# `trafficctl macfilter-add` / `macfilter-remove` (the WiFi deny;
# trafficctl-macfilter-add.sh and -remove.sh are wrappers since the ucode
# port). Runs the CLI with the real uci on a scratch wireless config, a fake
# hostapd_cli on PATH and hostapd's ubus objects on a private ubusd
# (tests/lib/fw4_env.sh), asserting on the maclist edits and the runtime
# hostapd ACL calls made.
#
# Two behaviours are under test.
#
# 1. The CLI must respect whichever ACL policy ("allow"/whitelist vs
#    "deny"/blacklist) the admin already configured on a wifi interface,
#    rather than forcing "deny" — forcing deny would invert a curated
#    whitelist (letting in everything it meant to keep out).
#
# 2. It must never claim success for a runtime block that did not happen. A
#    router without hostapd-utils wrote the uci maclist, got "command not
#    found" from every hostapd_cli call, discarded the status and answered
#    ok:true while the device kept browsing. So the hostapd_cli fake is
#    STATEFUL — ADD_MAC/DEL_MAC mutate ACL files that SHOW reads back — and so
#    is the ubus ban list, and fw_hostapd mocks each failure mode apart from
#    the others: the tool missing entirely, the tool present but not landing
#    the entry, the control socket dead, ubus unavailable. A fake that merely
#    logs the call would pass whether or not the ACL was ever touched, which is
#    the very assumption that let this ship.

PASS=0
FAIL=0

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"
# shellcheck source=tests/lib/fw4_env.sh
. "$UC_TESTLIB/fw4_env.sh"

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected to find: '%s'\n  in:\n%s\n" "$desc" "$needle" "$haystack"
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
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

fw_cfg 0
# dnsmasq lease format: <expiry> <mac> <ip> <hostname> <clientid>
echo "1787600000 aa:bb:cc:dd:ee:ff 192.168.1.50 device-name *" > "$LEASES"

# set_runtime <cli> <ubus> [mac...]: cli ok|silent|dead|missing ("missing"
# deletes the binary: the router this bug was found on had no hostapd-utils
# at all, and "not installed" has to be mocked apart from "installed but not
# working"); ubus ok|ban_nonzero|noban|noradio|broken; the MACs already in
# the running deny ACL. See fw_hostapd.
set_runtime() { fw_hostapd "$@"; }
set_runtime ok ok

run_add() { fw_clear; fw_run macfilter-add "$@"; }
run_remove() { fw_clear; fw_run macfilter-remove "$@"; }

# $1 = macfilter mode ("deny"/"allow"/""), $2 = existing maclist content
# shellcheck disable=SC2086
set_uci_single_iface() { fw_wifi "$1" $2; }

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
    '"deauth": true' "$(cat "$UBUS_LOG")"

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


# ── hostapd-utils is optional ────────────────────────────────────────────────
# trafficctl no longer depends on hostapd-utils, so it can be selected on
# wired-only builds (hostapd-utils needs a hostapd/wpad variant). Two routers
# have to keep working: one with no radios at all, and one with radios but no
# hostapd_cli. The second is covered above ("cli missing": a temporary ubus ban
# that says so). The first must refuse cleanly without touching hostapd.

set_uci_wired() { : > "$ROOT/etc/config/wireless"; }

set_uci_wired
set_runtime missing noradio
OUT=$(run_add 192.168.1.50)
assert_contains "wired-only add: NOT ok" '"ok":false' "$OUT"
assert_contains "wired-only add: says there is no wifi" "no wifi interfaces found" "$OUT"
assert_not_contains "wired-only add: no shell error from a missing hostapd_cli" "not found" "$OUT"
assert_eq "wired-only add: hostapd untouched" "" "$(cat "$HOSTAPD_LOG" "$UBUS_LOG")"
assert_not_contains "wired-only add: no uci commit" "commit" "$(cat "$UCI_LOG")"
OUT=$(run_remove 192.168.1.50)
assert_contains "wired-only remove: NOT ok" '"ok":false' "$OUT"
assert_contains "wired-only remove: says there is no wifi" "no wifi interfaces found" "$OUT"
assert_eq "wired-only remove: hostapd untouched" "" "$(cat "$HOSTAPD_LOG" "$UBUS_LOG")"

# What the view keys the WiFi button on (none/temporary/full) is reported by
# `trafficctl device` as wifi_filter: tests/test_report.sh.

REPO="$UC_REPO"
STATUS_JS="$REPO/luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js"
assert_contains "view passes wifi_filter to the WiFi button" \
    "updateWifiBtn(data.wifi_blocked, !!data.mac, data.wifi_filter)" "$(cat "$STATUS_JS")"
assert_contains "view hides the WiFi button where there is no wifi" \
    "filter === 'none' && !wifiBlocked" "$(cat "$STATUS_JS")"
assert_contains "view explains a temporary block with a translatable note" \
    "_('hostapd-utils is not installed:" "$(cat "$STATUS_JS")"
# Makefile and builders: optional for the backend, kept on the web interface.
assert_not_contains "trafficctl does not depend on hostapd-utils" "hostapd-utils" \
    "$(grep -E '^[[:space:]]*DEPENDS:=' "$REPO/trafficctl/Makefile")"
assert_not_contains "build-ipk backend deps lack hostapd-utils" "hostapd-utils" \
    "$(grep '^BE_DEPENDS=' "$REPO/build-ipk.sh")"
assert_not_contains "build-apk backend deps lack hostapd-utils" "hostapd-utils" \
    "$(grep '^BE_DEPENDS=' "$REPO/build-apk.sh")"
assert_contains "the backend description names hostapd-utils for WiFi filtering" \
    "WiFi MAC filtering needs hostapd-utils" "$(cat "$REPO/trafficctl/Makefile")"


# ── the row indicator (defect 2) ─────────────────────────────────────────────
# The backend reported wifi_blocked correctly all along; the dashboard row did
# not show it, because the only marking was a line-through applied inside the
# `else if (isWifi)` branch of the Link cell. That branch is reachable only
# while the device is associated on WiFi — so the marking disappeared from the
# row in precisely the case where the block WORKED (device stops associating,
# the cell falls through to "?" or eth) and whenever a blocked device was on
# cable. Source-level guards, in the same spirit as tests/test_byte_overflow.sh:
# there is no JS test harness in this repo, and the failure mode is structural.
# (REPO and STATUS_JS are set in the hostapd-utils section above.)

# The marking must hang off the finished cell, not off one branch inside it.
CONN_CELL=$(grep -A 10 "cellMap.conn_type = E(" "$STATUS_JS")
assert_contains "row: Link cell is marked from wifi_blocked outside the isWifi branch" \
    "r.wifi_blocked" "$CONN_CELL"
assert_contains "row: marking uses the shared badge helper" \
    "mkWifiBlockBadge" "$CONN_CELL"

assert_contains "row: frontend consumes wifi_block_pending" \
    "wifi_block_pending" "$(cat "$STATUS_JS")"

# A device on the deny list that is still associated is not blocked, and the
# backend has to say so for the row to be able to: wifi_block_pending, from
# the summary and the device report (tests/test_report.sh).

# ── a hung control socket ───────────────────────────────────────────────────
# hostapd_cli blocks for as long as hostapd does not answer, and the caller
# (rpcd, the bot) has its own deadline: every call is timed, and a socket that
# never answers is a dead one.
set_uci_single_iface "deny" ""
set_runtime hang ok
t0=$(date +%s)
OUT=$(run_add 192.168.1.50)
t1=$(date +%s)
assert_eq "hung hostapd_cli: the call returns within its timeout" "yes" "$([ $((t1 - t0)) -lt 15 ] && echo yes || echo no)"
assert_contains "hung hostapd_cli: falls back to the ubus ban" '"enforcement":"ban"' "$OUT"

# ── the MAC is validated ────────────────────────────────────────────────────
# A lease line with junk in the MAC field was used as it stood; refused now
# rather than written into the wireless config.
set_runtime ok ok
echo "1787600000 not-a-mac 192.168.1.51 junk *" >> "$LEASES"
OUT=$(run_add 192.168.1.51)
assert_contains "junk lease MAC: refused" "cannot find MAC for 192.168.1.51" "$OUT"
assert_eq "junk lease MAC: nothing written" "" "$(cat "$UCI_LOG")"
# The neighbour table is the second source, case-folded.
echo "192.168.1.52 dev br-lan lladdr AA:BB:CC:00:00:52 REACHABLE" > "$STATE/neigh"
OUT=$(run_add 192.168.1.52)
assert_contains "no lease: the MAC comes from ip neigh, lowercased" "MAC aa:bb:cc:00:00:52 blocked" "$OUT"
: > "$STATE/neigh"

# ── the weakest AP decides ──────────────────────────────────────────────────
# A block applied on one radio and missed on another must report the miss:
# the device simply joins the other radio.
FW_RADIOS="wifi0 wifi1" set_runtime ok ok
echo silent > "$STATE/cli_mode.wifi1"
OUT=$(run_add 192.168.1.50)
assert_contains "two APs, one ACL lands, the other bans: reports ban" '"enforcement":"ban"' "$OUT"
assert_contains "two APs: the good one did get the ACL" "aa:bb:cc:dd:ee:ff" "$(cat "$STATE/deny_acl")"
FW_RADIOS="wifi0 wifi1" set_runtime ok noban
echo silent > "$STATE/cli_mode.wifi1"
OUT=$(run_add 192.168.1.50)
assert_contains "two APs, one enforced, one not at all: reports none" '"enforcement":"none"' "$OUT"
assert_contains "two APs, one not at all: NOT ok" '"ok":false' "$OUT"
FW_RADIOS="wifi0 wifi1" set_runtime ok ok
OUT=$(run_add 192.168.1.50)
assert_contains "two APs, both ACLs: acl" '"enforcement":"acl"' "$OUT"
set_runtime ok ok

# ── the block_applied notification ──────────────────────────────────────────
# As v1.30.0's macfilter-add.sh: kind wifi, only when the deny took (ok:true),
# never for a removal.
unset FW_RADIOS
set_runtime ok ok
set_uci_single_iface "deny" ""
fw_events_on
OUT=$(TCTL_VIA=telegram TCTL_SRC=tg run_add 192.168.1.50)
assert_contains "event: the WiFi deny went in" '"ok":true' "$OUT"
assert_eq "event: a WiFi deny fires block_applied, kind wifi, with via/src" \
    "ACTION=block_applied IP=192.168.1.50 KIND=wifi MAC=aa:bb:cc:dd:ee:ff SRC=tg VIA=telegram" \
    "$(cat "$EVENTS_LOG")"
OUT=$(run_remove 192.168.1.50)
assert_eq "event: a WiFi allow fires nothing" "" "$(cat "$EVENTS_LOG")"
set_runtime silent noban
set_uci_single_iface "deny" ""
OUT=$(run_add 192.168.1.50)
assert_contains "event: the radio refused the deny" '"ok":false' "$OUT"
assert_eq "event: a deny that did not take fires nothing" "" "$(cat "$EVENTS_LOG")"
fw_events_off
set_runtime ok ok

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
