#!/bin/bash
# Tests for the rpcd/ubus backend (luci.trafficctl), the entire authenticated
# write surface reachable from LuCI/ubus.
#
# Drives the real plugin the way rpcd-mod-ucode does, through
# tests/lib/rpcd.uc: the signature it returns, rpcd's strict argument policy,
# the reply or the deferred reply of each method, and rpcd's file.exec on a
# private ubusd for the commands. tools/ci/live-rpcd.sh does the same through
# a real rpcd on OpenWrt images. TCTL_ROOT
# points it at a scratch root holding the shipped config; /usr/sbin/trafficctl
# there is a mock that logs every command and its caller variables, and the
# init scripts are mocks that log their actions. uci is the real one from
# tools/ci/build-ucode.sh, so the assertions read what was committed.
# tests/equiv.sh compares every method with the v1.30.0 shell plugin.

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

PASS=0
FAIL=0

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

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  should NOT contain: '%s'\n" "$desc" "$needle"
    else
        PASS=$((PASS + 1))
    fi
}

PLUGIN="$UC_REPO/luci-app-trafficctl/root/usr/share/rpcd/ucode/luci.trafficctl.uc"
EXEC_LOG="$UC_TMP/exec.log"
export TCTL_RPCD_EXEC_LOG="$EXEC_LOG"
ACL="$UC_REPO/luci-app-trafficctl/root/usr/share/rpcd/acl.d/luci-app-trafficctl.json"
R="$UC_TMP/root"
CONF="$R/etc/config/trafficctl"
DISPATCH_LOG="$R/tmp/dispatch.log"
INIT_LOG="$R/tmp/init.log"

# A fresh root: the shipped config, a firewall defaults section, the mocks.
fresh() {
    rm -rf "$R"
    mkdir -p "$R/etc/config" "$R/etc/init.d" "$R/tmp/.uci" "$R/tmp/trafficctl" "$R/usr/sbin"
    cp "$UC_REPO/trafficctl/files/etc/config/trafficctl" "$CONF"
    chmod 600 "$CONF"
    printf "config defaults\n\toption flow_offloading '1'\n\toption flow_offloading_hw '0'\n" \
        > "$R/etc/config/firewall"
    cat > "$R/usr/sbin/trafficctl" <<EOF
#!/bin/sh
echo "trafficctl \$*" >> "$DISPATCH_LOG"
echo "env via=\$TCTL_VIA src=\$TCTL_SRC user=\$TCTL_USER token=\$TCTL_TG_TOKEN" >> "$DISPATCH_LOG"
echo '{"ok":true,"msg":"stub-'"\$1"'"}'
EOF
    chmod +x "$R/usr/sbin/trafficctl"
    for s in trafficctl-telegram trafficctl-history; do
        printf '#!/bin/sh\necho "%s $1" >> "%s"\n' "$s" "$INIT_LOG" > "$R/etc/init.d/$s"
        chmod +x "$R/etc/init.d/$s"
    done
    : > "$DISPATCH_LOG"
}

run_list() {
    TCTL_ROOT="$R" rpcd_uc "$PLUGIN" list 2>&1
}

run_call() {
    local method="$1" json="${2:-{\}}"
    printf '%s' "$json" | TCTL_ROOT="$R" rpcd_uc "$PLUGIN" call "$method" 2>&1
}

uget() { uci -c "$R/etc/config" -t "$R/tmp/.uci" -q get "$1"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
sum() { cksum < "$CONF"; }
staged() { cat "$R/tmp/.uci"/* 2>/dev/null; }
dispatched() { grep '^trafficctl ' "$DISPATCH_LOG"; }

fresh
ubusd_start

# ════════════════════════════════════════════════════════════════════════════
# list: every method and its argument schema
# ════════════════════════════════════════════════════════════════════════════

LIST_OUT=$(run_list)
assert_eq "list: is valid JSON" "0" "$(printf '%s' "$LIST_OUT" | jq -e . >/dev/null 2>&1; echo $?)"
for m in summary device bytes block unblock macfilter_add macfilter_remove \
         ratelimit ratelimit_stats subnets shape_add shape_remove shape_status shape_stats \
         rdns netify_status netify_list netify_collect names_list name_set name_clear \
         portfw_list portfw_ctl config_get config_set telegram_config_get \
         ifaces rules_list \
         telegram_config_set telegram_test logging_config_get logging_config_set \
         newdevice_config_get newdevice_config_set cut_status cut_set \
         history_status history_read history_read_ifaces history_periods \
         history_config_get history_config_set history_flush \
         activity_log version \
         notify_config_get notify_config_set notify_test; do
    assert_eq "list: declares method $m" "true" "$(printf '%s' "$LIST_OUT" | jq --arg m "$m" 'has($m)')"
done
assert_eq "list: no method beyond the known ones" "48" "$(printf '%s' "$LIST_OUT" | jq 'length')"
# settings.js has always sent persist_rules; undeclared, rpcd dropped it.
assert_eq "list: logging_config_set declares persist_rules" '"bool"' \
    "$(printf '%s' "$LIST_OUT" | jq -c '.logging_config_set.persist_rules')"
assert_eq "list: cut_set is declared with its parameters" \
    '{"active":"bool","duration":"int","persist":"bool"}' "$(printf '%s' "$LIST_OUT" | jq -c '.cut_set')"
assert_eq "list: ratelimit accepts an upload rate" '"int"' \
    "$(printf '%s' "$LIST_OUT" | jq -c '.ratelimit.rate_kbit_up')"
assert_eq "list: shape_add accepts an upload rate" '"int"' \
    "$(printf '%s' "$LIST_OUT" | jq -c '.shape_add.rate_kbit_up')"

# ════════════════════════════════════════════════════════════════════════════
# Delegated methods: what reaches /usr/sbin/trafficctl
# ════════════════════════════════════════════════════════════════════════════

OUT=$(run_call summary)
assert_contains "summary: wraps the command's output under result" '{"result":{"ok":true,"msg":"stub-summary"}}' "$OUT"

OUT=$(run_call ifaces)
assert_contains "ifaces: wraps the command's output under result" '{"result":{"ok":true,"msg":"stub-ifaces"}}' "$OUT"

# The dashboard builds its subnet-limit target picker from this.
OUT=$(run_call subnets)
assert_contains "subnets: wraps the command's output under result" '{"result":{"ok":true,"msg":"stub-subnets"}}' "$OUT"

# `bytes` goes through the accumulator, not the raw sampler: the lifetime
# totals the columns show are added there, and the LuCI poll keeps them
# advancing while somebody has the page open.
OUT=$(run_call bytes)
assert_contains "bytes: runs the accumulator, not the raw sampler" '"msg":"stub-totals"' "$OUT"

: > "$DISPATCH_LOG"
run_call device '{"ip":"192.168.1.5"}' >/dev/null
assert_eq "device: forwards the ip, with the reply capped under file.exec's 256 KiB" \
    "trafficctl device 192.168.1.5 --max-bytes 200000" "$(dispatched)"
assert_contains "device: the caller travels in the environment" "env via=luci src= user=root token=" "$(cat "$DISPATCH_LOG")"

: > "$DISPATCH_LOG"
OUT=$(run_call device '{}')
assert_contains "device: missing ip rejected" '"ok":false' "$OUT"
assert_eq "device: missing ip, nothing dispatched" "" "$(dispatched)"

: > "$DISPATCH_LOG"
run_call device '{"ip":"192.168.1.5","proto":"tcp"}' >/dev/null
assert_eq "device: proto tcp forwarded as --proto" "trafficctl device 192.168.1.5 --proto tcp --max-bytes 200000" "$(dispatched)"

: > "$DISPATCH_LOG"
run_call block '{"ip":"192.168.1.9","label":"my label"}' >/dev/null
assert_eq "block: ip and the sanitized label" "trafficctl block 192.168.1.9 mylabel" "$(dispatched)"

OUT=$(run_call block '{}')
assert_contains "block: missing ip rejected" '"ok":false' "$OUT"

: > "$DISPATCH_LOG"
run_call block '{"ip":"192.168.1.9","label":"x\"; reboot `id` $(id)"}' >/dev/null
assert_eq "block: label metacharacters stripped before dispatch" "trafficctl block 192.168.1.9 xrebootidid" "$(dispatched)"

# Every value reaches the command as one argument, never through a shell.
: > "$DISPATCH_LOG"
run_call device '{"ip":"1.2.3.4; touch '"$R"'/pwned"}' >/dev/null
assert_eq "device: a hostile ip is one argument, not a command" "no" "$([ -e "$R/pwned" ] && echo yes || echo no)"

: > "$DISPATCH_LOG"
run_call unblock '{"ip":"192.168.1.9"}' >/dev/null
assert_eq "unblock: dispatches with ip" "trafficctl unblock 192.168.1.9 " "$(dispatched)"

: > "$DISPATCH_LOG"
run_call macfilter_add '{"ip":"192.168.1.9"}' >/dev/null
assert_eq "macfilter_add: dispatches with ip" "trafficctl macfilter-add 192.168.1.9" "$(dispatched)"

: > "$DISPATCH_LOG"
run_call macfilter_remove '{"ip":"192.168.1.9"}' >/dev/null
assert_eq "macfilter_remove: dispatches with ip" "trafficctl macfilter-remove 192.168.1.9" "$(dispatched)"

# The Rules tab lifts a WiFi block by MAC: an offline device may have no lease
# left to find it by IP (#128). The MAC wins when both are sent, because it is
# what the deny list is keyed on.
: > "$DISPATCH_LOG"
run_call macfilter_remove '{"mac":"aa:bb:cc:dd:ee:ff"}' >/dev/null
assert_eq "macfilter_remove: a MAC alone" "trafficctl macfilter-remove aa:bb:cc:dd:ee:ff" "$(dispatched)"
: > "$DISPATCH_LOG"
run_call macfilter_remove '{"ip":"192.168.1.9","mac":"aa:bb:cc:dd:ee:ff"}' >/dev/null
assert_eq "macfilter_remove: prefers the MAC over the ip" "trafficctl macfilter-remove aa:bb:cc:dd:ee:ff" "$(dispatched)"
: > "$DISPATCH_LOG"
OUT=$(run_call macfilter_remove '{}')
assert_contains "macfilter_remove: neither ip nor mac is rejected" '"ok":false' "$OUT"
assert_eq "macfilter_remove: neither ip nor mac, nothing dispatched" "" "$(dispatched)"

# rules_list is the Rules tab's only read.
: > "$DISPATCH_LOG"
OUT=$(run_call rules_list)
assert_contains "rules_list: wraps the command's output under result" '{"result":' "$OUT"
assert_eq "rules_list: runs rules list" "trafficctl rules list" "$(dispatched)"
READ_ACL=$(sed -n '/"read"/,/"write"/p' "$ACL")
assert_contains "rules_list: granted by the read ACL" '"rules_list"' "$READ_ACL"

: > "$DISPATCH_LOG"
run_call ratelimit '{"ip":"192.168.1.9","rate_kbit":5000,"mode":"each"}' >/dev/null
assert_eq "ratelimit: forwards ip, rate, mode" "trafficctl ratelimit 192.168.1.9 5000  each " "$(dispatched)"

: > "$DISPATCH_LOG"
run_call ratelimit '{"ip":"192.168.1.9","rate_kbit":5000,"mode":"bogus"}' >/dev/null
assert_eq "ratelimit: an invalid mode is dropped, not passed through" "trafficctl ratelimit 192.168.1.9 5000   " "$(dispatched)"

# An absent or zero upload rate means "same as download", never a zero cap.
: > "$DISPATCH_LOG"
run_call ratelimit '{"ip":"192.168.1.9","rate_kbit":5000,"rate_kbit_up":0}' >/dev/null
assert_eq "ratelimit: a zero upload rate is normalised away" "trafficctl ratelimit 192.168.1.9 5000   " "$(dispatched)"
: > "$DISPATCH_LOG"
run_call ratelimit '{"ip":"192.168.1.9","rate_kbit":5000,"rate_kbit_up":2000}' >/dev/null
assert_eq "ratelimit: an upload rate is passed on" "trafficctl ratelimit 192.168.1.9 5000   2000" "$(dispatched)"

: > "$DISPATCH_LOG"
run_call shape_add '{"ip":"192.168.1.9","rate_kbit":5000}' >/dev/null
assert_eq "shape_add: add with ip and rate" "trafficctl shape add 192.168.1.9 5000  " "$(dispatched)"
: > "$DISPATCH_LOG"
run_call shape_add '{"ip":"192.168.1.9","rate_kbit":5000,"rate_kbit_up":0}' >/dev/null
assert_eq "shape_add: a zero upload rate is normalised away" "trafficctl shape add 192.168.1.9 5000  " "$(dispatched)"
: > "$DISPATCH_LOG"
run_call shape_add '{"ip":"192.168.1.9","rate_kbit":5000,"rate_kbit_up":1000}' >/dev/null
assert_eq "shape_add: an upload rate is passed on" "trafficctl shape add 192.168.1.9 5000  1000" "$(dispatched)"

OUT=$(run_call shape_add '{"ip":"192.168.1.9"}')
assert_contains "shape_add: missing rate_kbit rejected" '"ok":false' "$OUT"

: > "$DISPATCH_LOG"
run_call shape_remove '{"ip":"192.168.1.9"}' >/dev/null
assert_eq "shape_remove: remove with ip" "trafficctl shape remove 192.168.1.9" "$(dispatched)"

: > "$DISPATCH_LOG"
run_call shape_status '{"ip":"192.168.1.9"}' >/dev/null
assert_eq "shape_status: status with ip" "trafficctl shape status 192.168.1.9" "$(dispatched)"

# ── portfw_ctl: action must be pause/resume/limit ──────────────────────────

: > "$DISPATCH_LOG"
run_call portfw_ctl '{"action":"pause","scope":"forward","proto":"tcp","ip":"192.168.1.9","port":"8080"}' >/dev/null
assert_eq "portfw_ctl pause: scope/proto/ip/port" "trafficctl portfw pause forward tcp 192.168.1.9 8080" "$(dispatched)"

: > "$DISPATCH_LOG"
run_call portfw_ctl '{"action":"limit","scope":"forward","proto":"tcp","ip":"192.168.1.9","port":"8080","rate_kbit":5000}' >/dev/null
assert_eq "portfw_ctl limit: with the rate" "trafficctl portfw limit forward tcp 192.168.1.9 8080 5000" "$(dispatched)"

OUT=$(run_call portfw_ctl '{"action":"delete"}')
assert_contains "portfw_ctl: invalid action rejected" '"ok":false' "$OUT"

# ── the caller, for the activity log ───────────────────────────────────────

: > "$DISPATCH_LOG"
printf '{"ip":"192.168.1.9"}' | REMOTE_ADDR=10.1.2.3 USERNAME=alice TCTL_ROOT="$R" \
    rpcd_uc "$PLUGIN" call macfilter_add >/dev/null
assert_contains "caller: REMOTE_ADDR and USERNAME are passed on" "env via=luci src=10.1.2.3 user=alice" "$(cat "$DISPATCH_LOG")"

# LuCI's session (uhttpd adds ubus_rpc_session to every call) names the user.
SB="$UC_TMP/ubus-session"
mkdir -p "$SB"
printf '{"values":{"username":"operator","token":"x"}}' > "$SB/session@get.json"
ubus_start "$SB"
: > "$DISPATCH_LOG"
run_call macfilter_add '{"ip":"192.168.1.9","ubus_rpc_session":"0123456789abcdef0123456789abcdef"}' >/dev/null
assert_contains "caller: the session's username is passed on" "env via=luci src= user=operator" "$(cat "$DISPATCH_LOG")"
: > "$DISPATCH_LOG"
run_call macfilter_add '{"ip":"192.168.1.9","ubus_rpc_session":"not-a-session; id"}' >/dev/null
assert_contains "caller: a malformed session id is not looked up" "env via=luci src= user=root" "$(cat "$DISPATCH_LOG")"
ubus_stop
ubusd_start

# The session is asked for only by a method that logs or changes something:
# the read methods are the dashboard's polls, every 2 s. The ACL's read and
# write lists say which is which.
SLOG="$UC_TMP/ubus-calls.log"
: > "$SLOG"
ubus_start "$SB" "$SLOG"
SID='"ubus_rpc_session":"0123456789abcdef0123456789abcdef"'
for m in $(jq -r '."luci-app-trafficctl".read.ubus."luci.trafficctl"[]' "$ACL"); do
    : > "$SLOG"
    run_call "$m" "{$SID}" >/dev/null
    assert_eq "caller: read method $m does not ask for the session" "" "$(grep '^session get' "$SLOG")"
done
for m in $(jq -r '."luci-app-trafficctl".write.ubus."luci.trafficctl"[]' "$ACL"); do
    fresh
    : > "$SLOG"
    run_call "$m" "{$SID}" >/dev/null
    assert_contains "caller: write method $m asks for the session" "session get" "$(cat "$SLOG")"
done
ubus_stop
ubusd_start
fresh

# A login name is one word of one log line, whatever its source holds.
uci -c "$R/etc/config" -t "$R/tmp/.uci" set trafficctl.logging.enabled=1
uci -c "$R/etc/config" -t "$R/tmp/.uci" commit trafficctl
printf '{"enabled":true}' | USERNAME="$(printf 'eve\nsrc=6.6.6.6 forged')" TCTL_ROOT="$R" \
    rpcd_uc "$PLUGIN" call newdevice_config_set >/dev/null
assert_eq "caller: a newline in the user name stays on its log line" "1" \
    "$(grep -c . "$R/tmp/trafficctl/activity.log" 2>/dev/null)"
assert_contains "caller: ... as a blank" "user=eve src=6.6.6.6 forged via=luci" "$(cat "$R/tmp/trafficctl/activity.log" 2>/dev/null)"

# ── a delegated command that does not finish ───────────────────────────────
# The plugin gives up after TCTL_CLI_TIMEOUT_MS (60 s on a router) and says
# so; rpcd's file.exec kills the command at rpcd's exec timeout (120 s on a
# router, TCTL_RPCD_EXEC_TIMEOUT_MS here).
fresh
cat > "$R/usr/sbin/trafficctl" <<EOF
#!/bin/sh
echo \$\$ > "$R/tmp/cli.pid"
sleep 5
echo '{"ok":true}'
EOF
chmod +x "$R/usr/sbin/trafficctl"
t0=$(date +%s)
OUT=$(printf '{"ip":"192.168.1.9"}' | TCTL_CLI_TIMEOUT_MS=1000 TCTL_RPCD_EXEC_TIMEOUT_MS=2000 TCTL_ROOT="$R" \
    rpcd_uc "$PLUGIN" call block 2>&1)
assert_eq "timeout: an error reply" '{"ok":false,"msg":"trafficctl block did not finish within 1 s"}' "$OUT"
assert_eq "timeout: at rpcd's exec timeout, not after the command" "yes" "$([ $(( $(date +%s) - t0 )) -lt 4 ] && echo yes)"
assert_eq "timeout: file.exec kills the CLI" "gone" "$(kill -0 "$(cat "$R/tmp/cli.pid")" 2>/dev/null && echo alive || echo gone)"
OUT=$(TCTL_CLI_TIMEOUT_MS=1000 TCTL_RPCD_EXEC_TIMEOUT_MS=2000 TCTL_ROOT="$R" rpcd_uc "$PLUGIN" call summary 2>&1 </dev/null)
assert_eq "timeout: a result method keeps its result key" \
    '{"result":null,"ok":false,"msg":"trafficctl summary did not finish within 1 s"}' "$OUT"
# rpcd guards the plugin's own request with the same exec timeout, armed
# first: with that below the plugin's limit, the caller gets rpcd's TIMEOUT.
# That is why the plugin's limit (60 s, at most 110) stays under rpcd's 120.
OUT=$(printf '{"ip":"192.168.1.9"}' | TCTL_CLI_TIMEOUT_MS=60000 TCTL_RPCD_EXEC_TIMEOUT_MS=1000 TCTL_ROOT="$R" \
    rpcd_uc "$PLUGIN" call block 2>&1)
assert_eq "timeout: rpcd's own timeout first is rpcd's TIMEOUT" "Command failed: Request timed out" "$OUT"

# ── the command's output as rpcd took it from the exec plugin ──────────────
fresh
cli_prints() {   # the CLI stub becomes a script printing $1
    printf '#!/bin/sh\n%s\n' "$1" > "$R/usr/sbin/trafficctl"
    chmod +x "$R/usr/sbin/trafficctl"
}
cli_prints 'echo "not json"'
assert_eq "output: not JSON is INVALID_ARGUMENT" "Command failed: Invalid argument" "$(run_call block '{"ip":"192.168.1.9"}')"
assert_eq "output: not JSON under result too" "Command failed: Invalid argument" "$(run_call summary)"
cli_prints 'echo "[1,2]"'
assert_eq "output: an array is INVALID_ARGUMENT" "Command failed: Invalid argument" "$(run_call block '{"ip":"192.168.1.9"}')"
assert_eq "output: an array under result is the reply" '{"result":[1,2]}' "$(run_call summary)"
cli_prints 'exit 0'
assert_eq "output: nothing under result is null" '{"result":null}' "$(run_call summary)"
cli_prints 'echo null'
assert_eq "output: null is NO_DATA" "Command failed: No response" "$(run_call block '{"ip":"192.168.1.9"}')"
cli_prints "echo '{\"ok\":true}'; echo noise >&2; exit 3"
assert_eq "output: stderr and the exit status are dropped" '{"ok":true}' "$(run_call block '{"ip":"192.168.1.9"}')"
# file.exec refuses 256 KiB of output with NOT_SUPPORTED and nothing else.
cli_prints 'head -c 300000 /dev/zero | tr "\\000" a'
assert_eq "output: over 256 KiB is an error reply" \
    '{"ok":false,"msg":"trafficctl device printed more than rpcd takes (256 KiB)"}' "$(run_call device '{"ip":"192.168.1.9"}')"
rm -f "$R/usr/sbin/trafficctl"
assert_eq "output: a missing CLI is an error reply" \
    '{"ok":false,"msg":"trafficctl block could not be run (ubus status 4)"}' "$(run_call block '{"ip":"192.168.1.9"}')"

# The session never goes on to file.exec: without one, rpcd skips its exec
# ACL check, which LuCI's session (no exec grant) would fail.
fresh
: > "$EXEC_LOG"
run_call block '{"ip":"192.168.1.9","ubus_rpc_session":"0123456789abcdef0123456789abcdef"}' >/dev/null
assert_contains "file.exec: the command is called" '"command":"'"$R"'/usr/sbin/trafficctl"' "$(cat "$EXEC_LOG")"
assert_not_contains "file.exec: never with the caller's session" 'ubus_rpc_session' "$(cat "$EXEC_LOG")"

# ── netify_collect: a sample window the call can wait for ──────────────────
fresh
for s in 0 31 3600; do
    : > "$DISPATCH_LOG"
    OUT=$(run_call netify_collect "{\"secs\":$s}")
    assert_contains "netify_collect: secs $s rejected" '"ok":false' "$OUT"
    assert_eq "netify_collect: secs $s, nothing dispatched" "" "$(dispatched)"
done
: > "$DISPATCH_LOG"
run_call netify_collect '{"secs":30}' >/dev/null
assert_eq "netify_collect: 30 s is taken" "trafficctl netify collect 30" "$(dispatched)"
: > "$DISPATCH_LOG"
assert_eq "netify_collect: a string is refused by rpcd's policy" "Command failed: Invalid argument" \
    "$(run_call netify_collect '{"secs":"5s"}')"
assert_eq "netify_collect: a string, nothing dispatched" "" "$(dispatched)"

# ════════════════════════════════════════════════════════════════════════════
# Device names (handled in process)
# ════════════════════════════════════════════════════════════════════════════

fresh
OUT=$(run_call name_set '{"ip":"192.168.1.9","name":"MyPhone"}')
assert_contains "name_set: ok" '"ok":true' "$OUT"
assert_eq "name_set: written to the names file" "192.168.1.9 MyPhone" "$(cat "$R/etc/trafficctl/names" 2>/dev/null)"
assert_contains "names_list: reads it back" '{"ip":"192.168.1.9","name":"MyPhone"}' "$(run_call names_list)"
OUT=$(run_call name_set '{"ip":"192.168.1.9"}')
assert_eq "name_set: an empty name removes the alias" "" "$(cat "$R/etc/trafficctl/names" 2>/dev/null)"
run_call name_set '{"ip":"192.168.1.9","name":"MyPhone"}' >/dev/null
run_call name_clear '{"ip":"192.168.1.9"}' >/dev/null
assert_eq "name_clear: removes the alias" "" "$(cat "$R/etc/trafficctl/names" 2>/dev/null)"
OUT=$(run_call name_set '{"ip":"192.168.1.300","name":"x"}')
assert_contains "name_set: an invalid ip is rejected" '"ok":false' "$OUT"
assert_eq "names: nothing is dispatched" "" "$(dispatched)"

# ════════════════════════════════════════════════════════════════════════════
# config_get / config_set
# ════════════════════════════════════════════════════════════════════════════

fresh
OUT=$(run_call config_get)
assert_contains "config_get: reflects enabled=true" '"enabled":true' "$OUT"
assert_contains "config_get: reflects default_mode" '"default_mode":"limiter"' "$OUT"
assert_contains "config_get: reads the firewall's offload switches" '"sw":true,"hw":false' "$OUT"

OUT=$(run_call config_set '{"enabled":false,"default_mode":"shaper"}')
assert_contains "config_set: reports ok" '"ok":true' "$OUT"
assert_eq "config_set: commits enabled=0" "0" "$(uget trafficctl.main.enabled)"
assert_eq "config_set: commits default_mode" "shaper" "$(uget trafficctl.main.default_mode)"
assert_eq "config_set: nothing left staged" "" "$(staged)"
assert_eq "config_set: the config stays 0600" "600" "$(mode "$CONF")"

run_call config_set '{"sw":false,"hw":true}' >/dev/null
assert_eq "config_set: commits the firewall's sw offload" "0" "$(uget firewall.@defaults[0].flow_offloading)"
assert_eq "config_set: commits the firewall's hw offload" "1" "$(uget firewall.@defaults[0].flow_offloading_hw)"

# ── Router-wide Poll / Window defaults (#12) ──────────────────────────────
# Bounded rather than free-form: avg_window sizes the per-device sample
# history every open browser keeps, and poll_interval costs the router a
# conntrack read per tick.
fresh
assert_contains "config_get: reports the poll default" '"poll_interval":2' "$(run_call config_get)"
assert_contains "config_get: reports the window default" '"avg_window":15' "$(run_call config_get)"

OUT=$(run_call config_set '{"poll_interval":30,"avg_window":300}')
assert_contains "config_set: accepts a valid poll/window pair" '"ok":true' "$OUT"
assert_eq "config_set: commits poll_interval" "30" "$(uget trafficctl.main.poll_interval)"
assert_eq "config_set: commits avg_window" "300" "$(uget trafficctl.main.avg_window)"

# 0 is a real choice, "do not poll", and must not be rejected as out of range.
OUT=$(run_call config_set '{"poll_interval":0}')
assert_contains "config_set: 0 means polling off, not an invalid value" '"ok":true' "$OUT"
assert_eq "config_set: commits poll_interval=0" "0" "$(uget trafficctl.main.poll_interval)"

for bad in '{"poll_interval":301}' '{"avg_window":3601}' '{"avg_window":1}' \
           '{"enabled":false,"poll_interval":301}'; do
    fresh
    before=$(sum)
    OUT=$(run_call config_set "$bad")
    assert_contains "config_set $bad: rejected" '"ok":false' "$OUT"
    assert_eq "config_set $bad: the config is untouched" "$before" "$(sum)"
    assert_eq "config_set $bad: nothing left staged" "" "$(staged)"
done

# Wrong types never reach the method: rpcd's policy refuses them.
for bad in '{"poll_interval":"abc"}' '{"poll_interval":5.5}' '{"poll_interval":null}' '{"enabled":1}' \
           '{"enabled":"true"}' '{"poll_interval":4294967296}' '{"bogus":1}'; do
    fresh
    before=$(sum)
    assert_eq "config_set $bad: refused by rpcd's policy" "Command failed: Invalid argument" "$(run_call config_set "$bad")"
    assert_eq "config_set $bad: the config is untouched" "$before" "$(sum)"
done

# ── the offload mode: nft asked through file.exec only when offload is on ──
# By its absolute path, /usr/sbin/nft: never whatever PATH finds first.
fresh
mkdir -p "$R/bin"
printf '#!/bin/sh\necho "nft $*" >> "%s"\necho "flowtable ft { counter }"\n' "$DISPATCH_LOG" > "$R/usr/sbin/nft"
chmod +x "$R/usr/sbin/nft"
cp "$R/usr/sbin/nft" "$R/bin/nft"
sed -i 's/{ counter }/{ }/' "$R/bin/nft"
OUT=$(PATH="$R/bin:$PATH" run_call config_get)
assert_contains "config_get: a counter flowtable" '"offload_mode":"software-counter"' "$OUT"
assert_contains "config_get: asks nft list flowtables" "nft list flowtables" "$(cat "$DISPATCH_LOG")"
assert_contains "config_get: the reply keeps its key order" \
    '{"enabled":true,"default_mode":"limiter","offload_mode":"software-counter","nss":"absent","sw":true,"hw":false,' "$OUT"
printf "config defaults\n\toption flow_offloading '0'\n" > "$R/etc/config/firewall"
: > "$DISPATCH_LOG"
OUT=$(PATH="$R/bin:$PATH" run_call config_get)
assert_contains "config_get: no offload, none" '"offload_mode":"none"' "$OUT"
assert_eq "config_get: no offload, nft not asked" "" "$(cat "$DISPATCH_LOG")"
fresh
assert_contains "config_get: no nft, no counter" '"offload_mode":"software"' "$(run_call config_get)"

# ── NSS (Qualcomm ECM) offload: read from its debugfs knobs ────────────────
fresh
assert_contains "config_get: no ECM directory, no NSS" '"nss":"absent"' "$(run_call config_get)"
mkdir -p "$R/sys/kernel/debug/ecm"
echo 0 > "$R/sys/kernel/debug/ecm/front_end_ipv4_stop"; echo 1 > "$R/sys/kernel/debug/ecm/front_end_ipv6_stop"
assert_contains "config_get: ECM running for one family is active" '"nss":"active"' "$(run_call config_get)"
echo 1 > "$R/sys/kernel/debug/ecm/front_end_ipv4_stop"
assert_contains "config_get: both families stopped is stopped" '"nss":"stopped"' "$(run_call config_get)"

# ════════════════════════════════════════════════════════════════════════════
# telegram_config_get / set: the bot token never leaks
# ════════════════════════════════════════════════════════════════════════════

fresh
uci -c "$R/etc/config" -t "$R/tmp/.uci" set trafficctl.telegram.bot_token=999999:REALSECRETTOKEN
uci -c "$R/etc/config" -t "$R/tmp/.uci" set trafficctl.telegram.chat_id=12345
uci -c "$R/etc/config" -t "$R/tmp/.uci" commit trafficctl
OUT=$(run_call telegram_config_get)
assert_contains "telegram_config_get: bot_token_set is true when a token exists" '"bot_token_set":true' "$OUT"
assert_not_contains "telegram_config_get: the real token never appears in the response" "REALSECRETTOKEN" "$OUT"
assert_contains "telegram_config_get: token displayed as a mask" '"bot_token":"***"' "$OUT"

# procd's view, not pgrep: the bot is running when its instance is.
UB="$UC_TMP/ubus"
mkdir -p "$UB"
printf '{"trafficctl-telegram":{"instances":{"instance1":{"running":true,"pid":42}}}}' > "$UB/service@list.json"
ubus_start "$UB"
assert_contains "telegram_config_get: bot_running from procd" '"bot_running":true' "$(run_call telegram_config_get)"
ubus_stop
ubusd_start
printf '{"trafficctl-telegram":{"instances":{"instance1":{"running":false}}}}' > "$UB/service@list.json"
ubus_start "$UB"
assert_contains "telegram_config_get: a stopped instance is not running" '"bot_running":false' "$(run_call telegram_config_get)"
ubus_stop
ubusd_start
assert_contains "telegram_config_get: no ubus, not running" '"bot_running":false' "$(run_call telegram_config_get)"

OUT=$(run_call telegram_config_set '{"bot_token":"***","chat_id":"54321"}')
assert_contains "telegram_config_set: reports ok" '"ok":true' "$OUT"
assert_eq "telegram_config_set: the mask is never written back as the token" \
    "999999:REALSECRETTOKEN" "$(uget trafficctl.telegram.bot_token)"
assert_eq "telegram_config_set: commits chat_id" "54321" "$(uget trafficctl.telegram.chat_id)"
assert_eq "telegram_config_set: the config stays 0600" "600" "$(mode "$CONF")"

run_call telegram_config_set '{"bot_token":"999999:NEWTOKEN"}' >/dev/null
assert_eq "telegram_config_set: writes a new token" "999999:NEWTOKEN" "$(uget trafficctl.telegram.bot_token)"
assert_eq "telegram_config_set: still 0600 with the new token" "600" "$(mode "$CONF")"

# Without a telegram section it is created, not silently skipped.
fresh
uci -c "$R/etc/config" -t "$R/tmp/.uci" delete trafficctl.telegram
uci -c "$R/etc/config" -t "$R/tmp/.uci" commit trafficctl
run_call telegram_config_set '{"enabled":true,"chat_id":"1"}' >/dev/null
assert_eq "telegram_config_set: creates the section" "telegram" "$(uget trafficctl.telegram)"
assert_eq "telegram_config_set: and commits into it" "1" "$(uget trafficctl.telegram.chat_id)"

# The Settings toggle moves rc.d with the flag. It used to only reload the
# service, so a bot switched on in the UI ran until the next reboot, which
# starts only what rc.d enables, and was then gone.
for flag in true false; do
    : > "$INIT_LOG"
    OUT=$(run_call telegram_config_set "{\"enabled\":$flag,\"chat_id\":\"54321\"}")
    sleep 0.3
    assert_contains "telegram_config_set enabled=$flag: reports ok" '"ok":true' "$OUT"
    if [ "$flag" = true ]; then want=enable; other=disable; else want=disable; other=enable; fi
    assert_eq "telegram_config_set enabled=$flag: runs the init script's $want" "trafficctl-telegram $want" \
        "$(grep -x "trafficctl-telegram $want" "$INIT_LOG")"
    assert_eq "telegram_config_set enabled=$flag: never runs $other" "" \
        "$(grep -x "trafficctl-telegram $other" "$INIT_LOG")"
done

# ── telegram_test: the token reaches the command over stdin, never argv ────
fresh
: > "$DISPATCH_LOG"
OUT=$(run_call telegram_test '{"bot_token":"777:SECRETABC","chat_id":"4242","message":"hi"}')
assert_contains "telegram_test: returns the command's reply" '"msg":"stub-telegram-test"' "$OUT"
assert_eq "telegram_test: argv carries '-' for the token" "trafficctl telegram-test - 4242 hi" "$(dispatched)"
assert_contains "telegram_test: the token arrives in the environment" "token=777:SECRETABC" "$(cat "$DISPATCH_LOG")"
uci -c "$R/etc/config" -t "$R/tmp/.uci" set trafficctl.telegram.bot_token=999999:STORED
uci -c "$R/etc/config" -t "$R/tmp/.uci" commit trafficctl
: > "$DISPATCH_LOG"
run_call telegram_test '{"bot_token":"***","chat_id":"4242"}' >/dev/null
assert_contains "telegram_test: the mask means the stored token" "token=999999:STORED" "$(cat "$DISPATCH_LOG")"
OUT=$(run_call telegram_test '{"bot_token":"777:SECRETABC"}')
assert_contains "telegram_test: chat_id required" '"ok":false' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# logging_config_set: log_file and max_lines are bounded (see
# test_regressions.sh for why), persist_rules lands in main
# ════════════════════════════════════════════════════════════════════════════

fresh
OUT=$(run_call logging_config_set '{"enabled":true,"persist_rules":true}')
assert_contains "logging_config_set: reports ok" '"ok":true' "$OUT"
assert_eq "logging_config_set: commits persist_rules" "1" "$(uget trafficctl.main.persist_rules)"
assert_eq "logging_config_set: the config stays 0600" "600" "$(mode "$CONF")"
run_call logging_config_set '{"persist_rules":false}' >/dev/null
assert_eq "logging_config_set: clears persist_rules" "0" "$(uget trafficctl.main.persist_rules)"

for bad in '{"log_file":"/etc/shadow"}' '{"log_file":"/var/log/../shadow"}' \
           '{"max_lines":1}' '{"max_lines":100001}'; do
    fresh
    before=$(sum)
    OUT=$(run_call logging_config_set "$bad")
    assert_contains "logging_config_set $bad: rejected" '"ok":false' "$OUT"
    assert_eq "logging_config_set $bad: the config is untouched" "$before" "$(sum)"
    assert_eq "logging_config_set $bad: nothing left staged" "" "$(staged)"
done
OUT=$(run_call logging_config_set '{"log_file":"/tmp/trafficctl/x.log"}')
assert_contains "logging_config_set: accepts a legitimate path" '"ok":true' "$OUT"
assert_eq "logging_config_set: commits it" "/tmp/trafficctl/x.log" "$(uget trafficctl.logging.log_file)"
assert_eq "logging_config_set: a string max_lines is refused by rpcd's policy" "Command failed: Invalid argument" \
    "$(run_call logging_config_set '{"max_lines":"5k"}')"
OUT=$(run_call logging_config_set '{"max_lines":500}')
assert_contains "logging_config_set: accepts a legitimate max_lines" '"ok":true' "$OUT"

# ════════════════════════════════════════════════════════════════════════════
# newdevice_config_set, history_config_set, cut_set
# ════════════════════════════════════════════════════════════════════════════

fresh
OUT=$(run_call newdevice_config_set '{"enabled":true,"limit_kbit":2000,"limit_mode":"shaper"}')
assert_contains "newdevice_config_set: ok" '"ok":true' "$OUT"
assert_eq "newdevice_config_set: commits limit_kbit" "2000" "$(uget trafficctl.newdevice.limit_kbit)"
assert_eq "newdevice_config_set: the config stays 0600" "600" "$(mode "$CONF")"
before=$(sum)
OUT=$(run_call newdevice_config_set '{"limit_mode":"both"}')
assert_contains "newdevice_config_set: a bad mode is rejected" '"ok":false' "$OUT"
assert_eq "newdevice_config_set: rejected, untouched" "$before" "$(sum)"

fresh
OUT=$(run_call history_config_set '{"enabled":true,"dir":"/mnt/usb/history","period":"week","keep":24}')
sleep 0.3
assert_contains "history_config_set: ok" '"ok":true' "$OUT"
assert_eq "history_config_set: commits dir" "/mnt/usb/history" "$(uget trafficctl.history.dir)"
assert_eq "history_config_set: the config stays 0600" "600" "$(mode "$CONF")"
assert_contains "history_config_set: restarts the sampler" "trafficctl-history" "$(cat "$INIT_LOG" 2>/dev/null)"
for d in /etc /mnt/ /mnt/../etc '/tmp/a;b' /mnt/. /mnt/./ /mnt// /mnt/// /mnt/./x /mnt//x \
         /mnt/x/.. /etc/trafficctl/. /tmp/x/./y; do
    before=$(sum)
    OUT=$(run_call history_config_set "{\"dir\":\"$d\"}")
    assert_contains "history_config_set: dir $d rejected" '"ok":false' "$OUT"
    assert_eq "history_config_set: dir $d, untouched" "$before" "$(sum)"
done
assert_eq "history_config_set: validated in process" "" "$(dispatched)"
for d in /mnt/x/ /mnt/.x /mnt/x..y /etc/trafficctl/h; do
    fresh
    OUT=$(run_call history_config_set "{\"dir\":\"$d\"}")
    assert_contains "history_config_set: dir $d accepted" '"ok":true' "$OUT"
done

fresh
run_call cut_set '{"active":true,"duration":600,"persist":true}' >/dev/null
assert_eq "cut_set: engage with duration and persist" "trafficctl cut engage 600 1" "$(dispatched)"
: > "$DISPATCH_LOG"
run_call cut_set '{"active":false}' >/dev/null
assert_eq "cut_set: release" "trafficctl cut release" "$(dispatched)"
assert_eq "cut_set: a non-boolean is refused by rpcd's policy" "Command failed: Invalid argument" \
    "$(run_call cut_set '{"active":"maybe"}')"
assert_contains "cut_set: active absent is rejected" '"ok":false' "$(run_call cut_set '{}')"

# ════════════════════════════════════════════════════════════════════════════
# A commit that fails is an error, and leaves nothing behind
# ════════════════════════════════════════════════════════════════════════════

# The config directory and file read-only; root ignores modes, so it runs
# without the capability that lets it.
readonly_call() {
    local method="$1" json="$2"
    chmod 555 "$R/etc/config"
    chmod 400 "$CONF" "$R/etc/config/firewall"
    if [ "$(id -u)" = 0 ]; then
        printf '%s' "$json" | TCTL_ROOT="$R" setpriv --bounding-set -dac_override,-dac_read_search \
            "$UCODE" -S -L "$UC_LIB" "$UC_TESTLIB/rpcd.uc" "$PLUGIN" call "$method" 2>&1
    else
        printf '%s' "$json" | TCTL_ROOT="$R" rpcd_uc "$PLUGIN" call "$method" 2>&1
    fi
    chmod 755 "$R/etc/config"
    chmod 600 "$CONF" "$R/etc/config/firewall"
}

while IFS='|' read -r method json; do
    fresh
    uci -c "$R/etc/config" -t "$R/tmp/.uci" set trafficctl.logging.enabled=1
    uci -c "$R/etc/config" -t "$R/tmp/.uci" commit trafficctl
    chmod 600 "$CONF"
    before=$(sum)
    : > "$DISPATCH_LOG"
    OUT=$(readonly_call "$method" "$json")
    assert_eq "unwritable config, $method: an error reply" \
        '{"ok":false,"msg":"could not save the trafficctl settings"}' "$OUT"
    assert_eq "unwritable config, $method: the file is untouched" "$before" "$(sum)"
    assert_eq "unwritable config, $method: nothing left staged" "" "$(staged)"
    assert_eq "unwritable config, $method: nothing logged" "" "$(cat "$R/tmp/trafficctl/activity.log" 2>/dev/null)"
    assert_eq "unwritable config, $method: nothing dispatched" "" "$(dispatched)"
done <<'EOF'
config_set|{"enabled":false}
telegram_config_set|{"enabled":true,"chat_id":"1"}
logging_config_set|{"persist_rules":true}
newdevice_config_set|{"limit_kbit":100}
history_config_set|{"period":"week"}
cut_set|{"active":true,"duration":60}
EOF

# The firewall half of config_set has its own commit.
fresh
chmod 400 "$R/etc/config/firewall"
before=$(cksum < "$R/etc/config/firewall")
if [ "$(id -u)" = 0 ]; then
    OUT=$(printf '{"hw":true}' | TCTL_ROOT="$R" setpriv --bounding-set -dac_override,-dac_read_search \
        "$UCODE" -S -L "$UC_LIB" "$UC_TESTLIB/rpcd.uc" "$PLUGIN" call config_set 2>&1)
else
    OUT=$(run_call config_set '{"hw":true}')
fi
chmod 600 "$R/etc/config/firewall"
assert_eq "unwritable firewall config: an error reply" '{"ok":false,"msg":"could not save the firewall settings"}' "$OUT"
assert_eq "unwritable firewall config: untouched" "$before" "$(cksum < "$R/etc/config/firewall")"
assert_eq "unwritable firewall config: nothing left staged" "" "$(staged)"

# ════════════════════════════════════════════════════════════════════════════
# activity_log: lines clamped to [0,1000]
# ════════════════════════════════════════════════════════════════════════════

fresh
for i in 1 2 3 4 5; do echo "line $i"; done > "$R/tmp/trafficctl/activity.log"
OUT=$(run_call activity_log '{"lines":2}')
assert_eq "activity_log: the tail of the log" '["line 4","line 5"]' "$(printf '%s' "$OUT" | jq -c .lines)"
OUT=$(run_call activity_log '{"lines":99999}')
assert_eq "activity_log: an absurd lines value is clamped" "5" "$(printf '%s' "$OUT" | jq '.lines | length')"
printf 'line 6' >> "$R/tmp/trafficctl/activity.log"
OUT=$(run_call activity_log '{"lines":2}')
assert_eq "activity_log: a last line without its newline counts" '["line 5","line 6"]' "$(printf '%s' "$OUT" | jq -c .lines)"
printf '\n\nline 8\n' >> "$R/tmp/trafficctl/activity.log"
OUT=$(run_call activity_log '{"lines":3}')
assert_eq "activity_log: an empty line is a line" '["line 6","","line 8"]' "$(printf '%s' "$OUT" | jq -c .lines)"
# Only the tail is read, in 64 KiB chunks from the end: a log of several
# chunks gives the same lines as tail(1), at a chunk border too.
awk 'BEGIN { for (i = 1; i <= 9000; i++) printf "%06d %s\n", i, "an activity log line of some length" }' > "$R/tmp/trafficctl/activity.log"
for n in 1 2 999 1000; do
    assert_eq "activity_log: a 9000-line log, lines $n" "$(tail -n "$n" "$R/tmp/trafficctl/activity.log" | jq -Rsc 'split("\n") | if .[-1] == "" then .[:-1] else . end')" \
        "$(run_call activity_log "{\"lines\":$n}" | jq -c .lines)"
done
head -c 65536 "$R/tmp/trafficctl/activity.log" > "$R/tmp/a.log"; mv "$R/tmp/a.log" "$R/tmp/trafficctl/activity.log"
assert_eq "activity_log: a log of exactly one chunk" "$(tail -n 1000 "$R/tmp/trafficctl/activity.log" | jq -Rsc 'split("\n") | if .[-1] == "" then .[:-1] else . end')" \
    "$(run_call activity_log '{"lines":1000}' | jq -c .lines)"
# A configured path outside the allowed roots is never read.
mkdir -p "$R/etc"; echo "root:secret" > "$R/etc/shadow"
uci -c "$R/etc/config" -t "$R/tmp/.uci" set trafficctl.logging.log_file=/etc/shadow
uci -c "$R/etc/config" -t "$R/tmp/.uci" commit trafficctl
assert_not_contains "activity_log: a forbidden log_file is not read" "secret" "$(run_call activity_log)"

# ════════════════════════════════════════════════════════════════════════════
# version: from the package database, never by running opkg
# ════════════════════════════════════════════════════════════════════════════

fresh
assert_eq "version: no package database, dev" '{"version":"dev"}' "$(run_call version)"
mkdir -p "$R/usr/lib/opkg"
printf 'Package: luci-base\nVersion: 25.0\n\nPackage: luci-app-trafficctl\nVersion: 1.30.1-r1\nStatus: install user installed\n' \
    > "$R/usr/lib/opkg/status"
assert_eq "version: from the opkg status file" '{"version":"1.30.1-r1"}' "$(run_call version)"
rm -rf "$R/usr/lib/opkg"
mkdir -p "$R/lib/apk/db"
printf 'C:Q1abc=\nP:luci-base\nV:25.0\n\nC:Q1def=\nP:luci-app-trafficctl\nV:1.31.0-r1\nA:all\n' > "$R/lib/apk/db/installed"
assert_eq "version: from the apk database" '{"version":"1.31.0-r1"}' "$(run_call version)"

# ════════════════════════════════════════════════════════════════════════════
# Unknown method, malformed input
# ════════════════════════════════════════════════════════════════════════════

assert_eq "unknown method: METHOD_NOT_FOUND" "Command failed: Method not found" "$(run_call totally_bogus_method)"
assert_contains "ubus_rpc_session: always allowed" '"enabled":true' \
    "$(run_call config_get '{"ubus_rpc_session":"0123456789abcdef0123456789abcdef"}')"
assert_eq "an undeclared argument is refused" "Command failed: Invalid argument" "$(run_call config_get '{"x":1}')"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
