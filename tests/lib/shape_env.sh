#!/bin/bash
# shellcheck shell=bash
# A scratch router for the tests of the shaper (trafficctl shape, the shapes
# half of trafficctl restore). Source it after tests/lib/ucode.sh; it builds
# on tests/lib/limit_env.sh (ROOT, MOCKBIN, STATE, lt_cfg, lt_net, lt_run)
# and puts tests/lib/tc-htb.sh behind tc and `ip link`:
#
#   SHAPES            /etc/trafficctl/shapes.json under ROOT
#   TC_STATE TC_LOG   the tc state and its write log
#   st_net <lan> [port...]   lt_net, and the same devices for tc (plus eth1)
#   st_run <args>            `trafficctl shape <args>` with the fakes
#   st_dump                  the tc state, normalised (tc-htb.sh dump)
#   st_reset                 no tc state, no shapes.json, empty logs
#
# TC_NO_IFB, TC_FAIL and TC_ROOT_<dev> (see tc-htb.sh) are read from the
# environment of each call; TC_ROOT_<dev> at st_net.

# shellcheck source=tests/lib/limit_env.sh
. "$UC_TESTLIB/limit_env.sh"

SHAPES="$ROOT/etc/trafficctl/shapes.json"
export TC_STATE="$STATE/tc" TC_LOG="$STATE/tc.log"
ST_DEVS=""

cat > "$MOCKBIN/tc" <<MOCK
#!/bin/sh
exec sh "$UC_TESTLIB/tc-htb.sh" tc "\$@"
MOCK
# `ip link` to tc-htb.sh; neighbours and routes as limit_env.sh answers them.
mv "$MOCKBIN/ip" "$MOCKBIN/ip-lt"
cat > "$MOCKBIN/ip" <<MOCK
#!/bin/sh
[ "\$1" = link ] && exec sh "$UC_TESTLIB/tc-htb.sh" ip "\$@"
exec "$MOCKBIN/ip-lt" "\$@"
MOCK
chmod +x "$MOCKBIN/tc" "$MOCKBIN/ip"

st_net() {
    lt_net "$@"
    ST_DEVS="$*"
    st_reset
}

st_reset() {
    rm -rf "${TC_STATE:?}"
    mkdir -p "$TC_STATE"
    # shellcheck disable=SC2086
    sh "$UC_TESTLIB/tc-htb.sh" init $ST_DEVS eth1
    : > "$TC_LOG"; : > "$LOGGER_LOG"
    rm -f "$SHAPES"
    rm -rf "$ROOT/tmp/trafficctl_shapes.lock.d"
}

st_run() {
    PATH="$MOCKBIN:$PATH" TCTL_ROOT="$ROOT" tctl shape "$@" 2>&1
}

st_dump() {
    sh "$UC_TESTLIB/tc-htb.sh" dump
}
