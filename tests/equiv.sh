#!/bin/bash
# Equivalence harness: the released shell backend (v1.30.0, from git) and its
# ucode port run against the same fixture, and their outputs must match.
#
# A fixture is a directory under tests/fixtures/ (see tools/capture-fixtures.sh):
#   root/  becomes TCTL_ROOT; the legacy scripts get their paths rewritten to it
#   cmd/   replayed by PATH mocks for ip, nft, tc, iw, brctl, conntrack
#   ubus/  served by tests/lib/ubus-mock.uc on a private ubusd
# Both sides see the real uci, ubus and jsonfilter binaries from build-ucode.sh.
#
# Compare modes:
#   json            semantic JSON equality (jq -S)
#   json-set:<key>  arrays whose legacy order is awk hash order, sorted by <key>
#   text            byte-exact
#   text-sorted     line sets, for files the legacy code writes in hash order

# shellcheck source=tests/lib/ucode.sh
. "$(dirname "$0")/lib/ucode.sh"

LEGACY_TAG=v1.30.0
FIXTURES="$UC_REPO/tests/fixtures"
W="$UC_TMP/work"
L="$UC_TMP/legacy"
PASS=0
FAIL=0

# name | mode | fixture | legacy script and args | new command
CASES='
smoke-subnets | json | router-24.10 | trafficctl-subnets.sh | tcall smoke subnets
'

command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }

# ── legacy backend ──────────────────────────────────────────────────────────
if ! git -C "$UC_REPO" rev-parse -q --verify "refs/tags/$LEGACY_TAG" >/dev/null; then
    git -C "$UC_REPO" fetch -q --depth=1 origin "refs/tags/$LEGACY_TAG:refs/tags/$LEGACY_TAG" ||
        { echo "FAIL: cannot get $LEGACY_TAG" >&2; exit 1; }
fi
mkdir -p "$L" "$W"
git -C "$UC_REPO" archive "$LEGACY_TAG" trafficctl/files luci-app-trafficctl/root | tar -x -C "$L"
LEXEC="$L/trafficctl/files/usr/libexec/trafficctl"
# The same rewrites the unit tests apply, pointed at the case's root.
find "$L" -type f -exec sed -i \
    -e "s|/usr/libexec/trafficctl/|$LEXEC/|g" \
    -e "s|/tmp/dhcp\.leases|$W/root/tmp/dhcp.leases|g" \
    -e "s|/proc/net/|$W/root/proc/net/|g" \
    -e "s|/sys/class/net|$W/root/sys/class/net|g" \
    -e "s|/etc/trafficctl/|$W/root/etc/trafficctl/|g" \
    -e "s|/tmp/trafficctl_|$W/root/tmp/trafficctl_|g" \
    -e "s|/tmp/\.trafficctl_|$W/root/tmp/.trafficctl_|g" \
    -e "s|/var/run/trafficctl|$W/root/var/run/trafficctl|g" {} +

# ── mocks ───────────────────────────────────────────────────────────────────
mkdir -p "$W/bin"
cat > "$W/bin/replay" <<'EOF'
#!/bin/sh
# Prints the recorded output of this exact command line, or fails like the
# command would when the fixture has none.
f="$TCTL_FIXTURE/cmd/${0##*/} $*"
[ -f "$f" ] || { echo "replay: no fixture for: ${0##*/} $*" >&2; exit 1; }
cat "$f"
EOF
for c in ip nft tc iw brctl conntrack; do ln -sf replay "$W/bin/$c"; done
cat > "$W/bin/uci" <<EOF
#!/bin/sh
exec "$UCODE_PREFIX/bin/uci" -c "$W/root/etc/config" -P "$W/root/tmp/.uci" "\$@"
EOF
cat > "$W/bin/ubus" <<EOF
#!/bin/sh
exec "$UCODE_PREFIX/bin/ubus" -s "\$TCTL_UBUS_SOCKET" "\$@"
EOF
chmod +x "$W/bin/"*

compare() {   # compare <mode> <legacy file> <new file>; 0 = equal
    case "$1" in
        json) diff <(jq -S . "$2") <(jq -S . "$3") ;;
        json-set:*) diff <(jq -S --arg k "${1#json-set:}" 'sort_by(.[$k])' "$2") \
                         <(jq -S --arg k "${1#json-set:}" 'sort_by(.[$k])' "$3") ;;
        text) diff "$2" "$3" ;;
        text-sorted) diff <(LC_ALL=C sort "$2") <(LC_ALL=C sort "$3") ;;
        *) echo "unknown compare mode: $1" >&2; return 2 ;;
    esac
}

fresh_root() {   # a writable copy, so one side's writes cannot reach the other
    rm -rf "$W/root"
    cp -R "$FIXTURES/$1/root" "$W/root"
    mkdir -p "$W/root/tmp/.uci" "$W/root/var/run"
}

# The comparison itself has to be able to fail, or every case passes.
printf '[1,2]' > "$W/a"; printf '[2,1]' > "$W/b"
if compare json "$W/a" "$W/b" >/dev/null || ! compare json-set:x <(echo '[{"x":1},{"x":2}]') <(echo '[{"x":2},{"x":1}]') >/dev/null; then
    echo "FAIL: compare modes are broken"; exit 1
fi

# ── cases ───────────────────────────────────────────────────────────────────
while IFS='|' read -r name mode fixture legacy new; do
    name=$(echo "$name" | xargs)
    [ -n "$name" ] || continue
    mode=$(echo "$mode" | xargs); fixture=$(echo "$fixture" | xargs)
    legacy=$(echo "$legacy" | xargs); new=$(echo "$new" | xargs)
    export TCTL_FIXTURE="$FIXTURES/$fixture"
    ubus_start "$TCTL_FIXTURE/ubus"

    fresh_root "$fixture"
    # shellcheck disable=SC2086 # the case line holds script and arguments
    PATH="$W/bin:$PATH" sh "$LEXEC"/$legacy > "$W/legacy.out" 2> "$W/legacy.err"
    fresh_root "$fixture"
    (export TCTL_ROOT="$W/root" PATH="$W/bin:$PATH"; eval "$new") > "$W/new.out" 2> "$W/new.err"
    ubus_stop

    if [ ! -s "$W/legacy.out" ]; then
        FAIL=$((FAIL + 1)); echo "FAIL: $name: legacy side printed nothing"; cat "$W/legacy.err"
    elif compare "$mode" "$W/legacy.out" "$W/new.out" > "$W/diff" 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $name ($mode)"; cat "$W/diff" "$W/new.err"
    fi
done <<< "$CASES"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
