#!/bin/sh
# Live check of the rpcd plugin inside this release's own rpcd, run INSIDE an
# OpenWrt rootfs container (.github/workflows/compat.yml, job live-rpcd).
#
# The plugin is a ucode script that rpcd-mod-ucode loads into rpcd
# (/usr/share/rpcd/ucode/luci.trafficctl.uc). It answers cheap reads in
# process and runs the CLI through rpcd's own file.exec as a deferred reply,
# so what the unit tests (tests/lib/rpcd.uc) model has to hold for the real
# rpcd too, on the oldest ucode we support (22.03) and the newest:
#
#   - rpcd registers the object with every method and its typed arguments
#   - every method answers with an object, through rpcd, and rpcd survives
#     every one of them (a script error must not take rpcd down)
#   - a call with a session (ubus_rpc_session) works, a write through the CLI
#     included: the plugin looks the session up with a deferred call to rpcd's
#     own session object, and the CLI logs the session's user
#   - rpcd's policy refuses a value of the wrong type, a null and an unknown
#     method before the plugin runs
#   - a CLI call that outlives the plugin's limit is answered, not dropped
#   - through uhttpd's /ubus with a real login, when uhttpd-mod-ubus installs
#
# Usage: live-rpcd.sh [repository root, default /src]

set -u
SRC="${1:-/src}"
FAILS=0
say() { echo "== $*"; }
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
die() { echo "live-rpcd: $*" >&2; exit 2; }

add() {
    if command -v opkg >/dev/null 2>&1; then
        [ -f /tmp/.updated ] || { opkg update >/dev/null 2>&1; touch /tmp/.updated; }
        opkg install "$@" >/dev/null 2>&1
    else
        [ -f /tmp/.updated ] || { apk update >/dev/null 2>&1; touch /tmp/.updated; }
        apk add "$@" >/dev/null 2>&1
    fi
}

mkdir -p /var/lock /var/run /tmp/trafficctl /etc/trafficctl
[ -e /usr/lib/rpcd/ucode.so ] || add rpcd-mod-ucode
[ -e /usr/lib/rpcd/ucode.so ] || die "no rpcd-mod-ucode for this image"
[ -e /usr/lib/rpcd/file.so ] || add rpcd-mod-file
[ -e /usr/lib/rpcd/file.so ] || die "no rpcd-mod-file (file.exec) for this image"
for m in fs uci ubus; do
    [ -e "/usr/lib/ucode/$m.so" ] || add "ucode-mod-$m"
done

cp -R "$SRC/trafficctl/files/." / || die "cannot install the backend"
cp -R "$SRC/luci-app-trafficctl/root/." / || die "cannot install the plugin"
chmod 0755 /usr/sbin/trafficctl /usr/libexec/trafficctl/* /etc/init.d/trafficctl-*
chmod 0600 /etc/config/trafficctl
[ ! -e /usr/libexec/rpcd/luci.trafficctl ] || die "an exec plugin is installed too"

/sbin/ubusd & UBUSD_PID=$!
sleep 1
/sbin/rpcd & RPCD_PID=$!
i=0
until ubus list luci.trafficctl >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 20 ] || die "rpcd never registered luci.trafficctl"
    sleep 1
done
say "rpcd $(opkg list-installed rpcd 2>/dev/null || apk list -I rpcd 2>/dev/null | head -n 1)"

alive() { kill -0 "$RPCD_PID" 2>/dev/null; }

# ── the object and its signature ────────────────────────────────────────────
SIG=$(ubus -v list luci.trafficctl 2>&1)
N=$(printf '%s\n' "$SIG" | grep -c '^	"')
[ "$N" -ge 48 ] && ok "luci.trafficctl lists $N methods" || bad "luci.trafficctl lists $N methods: $SIG"
case "$SIG" in *'"config_set":{'*'"poll_interval":"Integer"'*) ok "typed arguments" ;;
    *) bad "config_set does not declare poll_interval as an Integer: $SIG" ;; esac
case "$SIG" in *'"cut_set":{"active":"Boolean"'*) ok "boolean arguments" ;;
    *) bad "cut_set does not declare active as a Boolean" ;; esac

# ── every method, through rpcd ──────────────────────────────────────────────
# Arguments that keep each call inside the container: a device that is not
# there, sender settings that change nothing, a cut that is switched off.
args_of() {
    case "$1" in
        device|block|unblock|macfilter_add|macfilter_remove|rdns|shape_remove)
            echo '{"ip":"192.168.77.5"}' ;;
        ratelimit) echo '{"ip":"192.168.77.5","rate_kbit":0}' ;;
        shape_add) echo '{"ip":"192.168.77.5","rate_kbit":1000}' ;;
        name_set) echo '{"ip":"192.168.77.5","name":"ci-probe"}' ;;
        name_clear) echo '{"ip":"192.168.77.5"}' ;;
        portfw_ctl) echo '{"action":"status","proto":"tcp","ip":"192.168.77.5","port":"8080"}' ;;
        config_set) echo '{"poll_interval":3}' ;;
        telegram_test) echo '{"chat_id":"1"}' ;;
        notify_test) echo '{"sender":"nobody"}' ;;
        notify_config_set) echo '{"scan_interval":30}' ;;
        cut_set) echo '{"active":false}' ;;
        history_read) echo '{"period":"day"}' ;;
        *) echo '{}' ;;
    esac
}
METHODS=$(printf '%s\n' "$SIG" | sed -n 's/^	"\([a-z_0-9]*\)":.*/\1/p')
T0=$(date +%s)
for m in $METHODS; do
    a=$(args_of "$m")
    out=$(ubus -t 120 call luci.trafficctl "$m" "$a" 2>&1); rc=$?
    if [ "$rc" = 0 ] && printf '%s' "$out" | head -c 1 | grep -q '{'; then
        ok "$m"
    else
        bad "$m $a: ubus exit $rc: $(printf '%s' "$out" | head -c 300)"
    fi
    alive || { bad "rpcd died at $m"; break; }
done
say "every method in $(( $(date +%s) - T0 )) s"

# ── a session: the plugin looks it up in rpcd's own session object ─────────
SID=$(ubus call session create '{"timeout":300}' 2>/dev/null | sed -n 's/.*"ubus_rpc_session": "\([0-9a-f]*\)".*/\1/p')
if [ -n "$SID" ]; then
    ubus call session set "{\"ubus_rpc_session\":\"$SID\",\"values\":{\"username\":\"ci-user\"}}" >/dev/null 2>&1
    uci -q set trafficctl.logging=logging
    uci -q set trafficctl.logging.enabled=1
    uci -q set trafficctl.logging.log_file=/tmp/trafficctl/activity.log
    uci -q commit trafficctl
    out=$(ubus -t 30 call luci.trafficctl name_set "{\"ip\":\"192.168.77.6\",\"name\":\"ci-sid\",\"ubus_rpc_session\":\"$SID\"}" 2>&1)
    case "$out" in *'"ok": true'*) ok "name_set with a session" ;; *) bad "name_set with a session: $out" ;; esac
    if grep 'target=192.168.77.6' /tmp/trafficctl/activity.log 2>/dev/null | grep -q 'user=ci-user'; then
        ok "the activity log names the session's user"
    else
        bad "the activity log does not name the session's user: $(tail -n 3 /tmp/trafficctl/activity.log 2>&1)"
    fi
    # A write as LuCI sends it, delegated to the CLI: the session lookup
    # first, then file.exec, which must reach the CLI with the session's user
    # in its environment (the session itself is never passed on).
    out=$(ubus -t 60 call luci.trafficctl cut_set "{\"active\":false,\"ubus_rpc_session\":\"$SID\"}" 2>&1)
    case "$out" in *'internet restored for all devices'*) ok "cut_set with a session, through file.exec" ;; *) bad "cut_set with a session: $out" ;; esac
    if grep 'action=uncut' /tmp/trafficctl/activity.log 2>/dev/null | grep 'via=luci' | grep -q 'user=ci-user'; then
        ok "the CLI's activity log line names the session's user"
    else
        bad "the CLI's activity log line does not name the session's user: $(tail -n 3 /tmp/trafficctl/activity.log 2>&1)"
    fi
    out=$(ubus -t 30 call luci.trafficctl config_get "{\"ubus_rpc_session\":\"$SID\"}" 2>&1)
    case "$out" in *'"enabled":'*) ok "a read with a session" ;; *) bad "config_get with a session: $out" ;; esac
    out=$(ubus -t 30 call luci.trafficctl name_clear "{\"ip\":\"192.168.77.6\",\"ubus_rpc_session\":\"0123456789abcdef0123456789abcdef\"}" 2>&1)
    case "$out" in *'"ok": true'*) ok "an unknown session still gets an answer" ;; *) bad "name_clear with an unknown session: $out" ;; esac
else
    bad "rpcd gave no session"
fi

# ── rpcd's policy ───────────────────────────────────────────────────────────
refused() {
    out=$(ubus -t 30 call luci.trafficctl "$2" "$3" 2>&1); rc=$?
    case "$rc:$out" in 0:*) bad "$1: rpcd took it: $out" ;;
        *"$4"*) ok "$1: $4" ;;
        *) bad "$1: exit $rc: $out" ;; esac
}
refused "a string for an int" config_set '{"poll_interval":"3"}' 'Invalid argument'
refused "a string for a bool" cut_set '{"active":"true"}' 'Invalid argument'
refused "an undeclared argument" config_get '{"bogus":1}' 'Invalid argument'
refused "an unknown method" bogus_method '{}' 'Method not found'
alive && ok "rpcd survived the refusals" || bad "rpcd died on a refusal"

# ── a CLI call that runs past the plugin's limit ───────────────────────────
# A stand-in CLI that sleeps: the plugin's file.exec call is killed by rpcd
# at the exec timeout and the caller gets the plugin's message, not a hang.
mv /usr/sbin/trafficctl /usr/sbin/trafficctl.real
printf '#!/bin/sh\nexec sleep 300\n' > /usr/sbin/trafficctl
chmod 0755 /usr/sbin/trafficctl
kill "$RPCD_PID"; wait "$RPCD_PID" 2>/dev/null
/sbin/rpcd -t 3 & RPCD_PID=$!
i=0
until ubus list luci.trafficctl >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 20 ] || die "rpcd -t 3 never registered luci.trafficctl"; sleep 1
done
t0=$(date +%s)
out=$(ubus -t 30 call luci.trafficctl summary 2>&1); rc=$?
dt=$(( $(date +%s) - t0 ))
case "$rc:$out" in
    *'Request timed out'*|*'did not finish'*) ok "a hung CLI is answered in $dt s ($out)" ;;
    *) bad "a hung CLI: exit $rc after $dt s: $out" ;;
esac
[ "$dt" -lt 20 ] || bad "a hung CLI took $dt s"
alive && ok "rpcd survived the timeout" || bad "rpcd died on the timeout"
sleep 1
pgrep -f 'sleep 300' >/dev/null && bad "the hung CLI is still running" || ok "the hung CLI was killed"
mv /usr/sbin/trafficctl.real /usr/sbin/trafficctl
kill "$RPCD_PID"; wait "$RPCD_PID" 2>/dev/null
/sbin/rpcd & RPCD_PID=$!
i=0
until ubus list luci.trafficctl >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 20 ] || die "rpcd never came back"; sleep 1
done

# ── through uhttpd with a login, as LuCI calls it ──────────────────────────
command -v uhttpd >/dev/null 2>&1 || add uhttpd uhttpd-mod-ubus
if command -v uhttpd >/dev/null 2>&1 && [ -e /usr/lib/uhttpd_ubus.so ]; then
    mkdir -p /www
    uhttpd -f -p 127.0.0.1:8080 -h /www -u /ubus -a & UHTTPD_PID=$!
    sleep 1
    rpc() {
        uclient-fetch -q -O - --post-data="$1" http://127.0.0.1:8080/ubus 2>&1
    }
    # The rootfs has an empty root password; rpcd lets it log in.
    L=$(rpc '{"jsonrpc":"2.0","id":1,"method":"call","params":["00000000000000000000000000000000","session","login",{"username":"root","password":""}]}')
    SID=$(printf '%s' "$L" | sed -n 's/.*"ubus_rpc_session":"\([0-9a-f]*\)".*/\1/p')
    if [ -n "$SID" ]; then
        out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"call\",\"params\":[\"$SID\",\"luci.trafficctl\",\"config_get\",{}]}")
        case "$out" in *'"result":[0,{'*) ok "config_get through /ubus" ;; *) bad "config_get through /ubus: $out" ;; esac
        out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"call\",\"params\":[\"$SID\",\"luci.trafficctl\",\"name_set\",{\"ip\":\"192.168.77.7\",\"name\":\"ci-http\"}]}")
        case "$out" in *'"result":[0,{'*'"ok":true'*) ok "name_set through /ubus" ;; *) bad "name_set through /ubus: $out" ;; esac
        out=$(rpc "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"call\",\"params\":[\"$SID\",\"luci.trafficctl\",\"summary\",{}]}")
        case "$out" in *'"result":[0,{'*) ok "summary (a deferred file.exec) through /ubus" ;; *) bad "summary through /ubus: $out" ;; esac
        if grep 'target=192.168.77.7' /tmp/trafficctl/activity.log 2>/dev/null | grep -q 'user=root'; then
            ok "the activity log names the logged-in user"
        else
            bad "the activity log does not name the logged-in user"
        fi
    else
        echo "warning: no login through /ubus ($L), skipped"
    fi
    kill "$UHTTPD_PID" 2>/dev/null
else
    echo "warning: no uhttpd-mod-ubus for this image, skipped the /ubus calls"
fi

kill "$RPCD_PID" "$UBUSD_PID" 2>/dev/null
say "$FAILS failed"
[ "$FAILS" = 0 ]
