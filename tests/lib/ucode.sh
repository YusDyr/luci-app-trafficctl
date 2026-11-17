#!/bin/bash
# shellcheck shell=bash
# Shared setup for tests that run the ucode backend. Source it, then:
#   tctl <cmd> [args]          the CLI, /usr/sbin/trafficctl
#   tcall <module> <fn> [json] one module function, through tests/lib/call.uc
#   ubus_start <dir> [log]     private ubusd + ubus-mock.uc serving <dir>
#   ubus_stop                  both gone, so the next case starts clean
#   ubusd_start                only the private ubusd (TCTL_UBUS_SOCKET)
#   rpcd_uc <plugin> list|call <method>
#                              a plugin as rpcd-mod-ucode runs it, through
#                              tests/lib/rpcd.uc (args JSON on stdin). A call
#                              needs ubusd_start first, outside any $(...)
#
# UCODE_PREFIX is the install root of tools/ci/build-ucode.sh. A missing
# interpreter is a failure, never a skip: a skipped suite reads as green.

UC_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UC_LIB="$UC_REPO/trafficctl/files/usr/share/ucode"
UC_TESTLIB="$UC_REPO/tests/lib"
UCODE="${UCODE:-${UCODE_PREFIX:+$UCODE_PREFIX/bin/ucode}}"
UCODE="${UCODE:-$(command -v ucode)}"

if [ -z "$UCODE" ] || ! [ -x "$UCODE" ]; then
    echo "FAIL: no ucode interpreter (set UCODE_PREFIX; build with tools/ci/build-ucode.sh)" >&2
    exit 1
fi
UCODE_PREFIX="${UCODE_PREFIX:-$(cd "$(dirname "$UCODE")/.." && pwd)}"
export PATH="$UCODE_PREFIX/bin:$UCODE_PREFIX/sbin:$PATH"

UC_TMP=$(mktemp -d)
UC_PIDS=""
ubus_stop() {
    local p
    for p in $UC_PIDS; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    UC_PIDS=""
    rm -f "$UC_TMP/ubus.sock"
    unset TCTL_UBUS_SOCKET
}
trap 'ubus_stop; rm -rf "$UC_TMP"' EXIT

tctl() {
    # "--": glibc's getopt would take a command's own --all for ucode's.
    "$UCODE" -S -L "$UC_LIB" -- "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" "$@"
}

tcall() {
    "$UCODE" -S -L "$UC_LIB" -L "$UC_TESTLIB" "$UC_TESTLIB/call.uc" "$@"
}

ubusd_start() {
    local sock="$UC_TMP/ubus.sock" _
    [ -n "${TCTL_UBUS_SOCKET:-}" ] && return 0
    ubusd -s "$sock" 2>"$UC_TMP/ubusd.err" &
    UC_PIDS="$UC_PIDS $!"
    for _ in $(seq 50); do [ -S "$sock" ] && break; sleep 0.1; done
    [ -S "$sock" ] || { echo "FAIL: ubusd did not start" >&2; cat "$UC_TMP/ubusd.err" >&2; exit 1; }
    export TCTL_UBUS_SOCKET="$sock"
}

rpcd_uc() {
    "$UCODE" -S -L "$UC_LIB" "$UC_TESTLIB/rpcd.uc" "$@"
}

ubus_start() {   # ubus_start <fixture dir> [call log]
    local ready="$UC_TMP/ubus-mock.out" _
    ubusd_start
    "$UCODE" -S "$UC_TESTLIB/ubus-mock.uc" "$TCTL_UBUS_SOCKET" "$1" "${2:-}" >"$ready" 2>&1 &
    UC_PIDS="$UC_PIDS $!"
    for _ in $(seq 50); do grep -q '^ready$' "$ready" && return 0; sleep 0.1; done
    echo "FAIL: ubus-mock did not start" >&2
    cat "$ready" >&2
    exit 1
}
