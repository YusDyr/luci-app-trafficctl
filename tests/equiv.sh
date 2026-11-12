#!/bin/bash
# Equivalence harness: the released shell backend (v1.30.0, from git) and its
# ucode port run against the same fixture, and their outputs must match.
#
# A fixture is a directory under tests/fixtures/ (see tools/capture-fixtures.sh):
#   root/  becomes TCTL_ROOT; the legacy scripts get their paths rewritten to it
#   cmd/   replayed by PATH mocks for ip, nft, tc, iw, brctl, conntrack, nslookup
#   ubus/  served by tests/lib/ubus-mock.uc on a private ubusd
# Both sides see the real uci, ubus and jsonfilter binaries from build-ucode.sh;
# logger is recorded to root/tmp/logger.log.
#
# Case lines: name | mode | fixture | legacy | new [| setup]
#   legacy  a script under usr/libexec/trafficctl and its arguments, or
#           fw:<shell> to run <shell> after sourcing the CURRENT trafficctl-fw.sh
#           (whose shell helpers must stay equal to the ucode ones), or
#           sh:<shell> to run <shell> as it is (legacy_tot is the legacy
#           totals script, masked prints a command's JSON with fresh epochs
#           masked)
#   new     a shell command; tctl and tcall come from tests/lib/ucode.sh
#   setup   run in the fresh root before each side; $W/cmd is that side's
#           writable copy of cmd/, uci writes to the root
# Compare modes, optionally followed by +<path>[,<path>...]: those root files
# are appended to the output, with times and epochs masked:
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
C="$UC_TMP/current"
PASS=0
FAIL=0

# Subnet records as the shell prints them: "dev base block router".
monitored() { tcall trafficctl.net monitored_subnets | jq -r '.[] | "\(.dev) \(.base) \(.block) \(.router)"'; }
ROUTED='printf "10.0.5.0/24 via 192.168.0.200 dev br-lan proto static\n10.0.6.0/23 via 192.168.0.201 dev br-lan\n10.0.7.9 via 192.168.0.201 dev br-lan\n172.16.0.0/16 via 10.128.28.1 dev wan\n" >> "$W/cmd/ip route show"; uci set trafficctl.main.extra_subnets="10.9.0.0/16 bogus 192.168.0.0/24 10.20.30.40 10.0.5.0/24"; uci commit trafficctl'
NAMES='mkdir -p "$W/root/etc/trafficctl"; printf "192.168.0.101 Kitchen tablet\n192.168.0.50  Old  TV\n192.168.0.102\n" > "$W/root/etc/trafficctl/names"'
# Synthetic answers in the BusyBox forms: "name = host." and the old
# "Name:" form, which names the address itself.
RESOLV='printf "Server:\t127.0.0.1\n\n101.0.168.192.in-addr.arpa\tname = host-12.lan.\n" > "$W/cmd/nslookup 192.168.0.101"; printf "Name:      192.168.0.220\nAddress 1: 192.168.0.220 host-35.lan\n" > "$W/cmd/nslookup 192.168.0.220"; printf "102.0.168.192.in-addr.arpa\tname = printer.lan.\n" > "$W/cmd/nslookup 192.168.0.102 192.168.0.253"'
RDNS='uci set trafficctl.main.rdns_server="192.168.0.254 192.168.0.253"; uci commit trafficctl'
LOGS='etc/trafficctl/names,tmp/trafficctl/activity.log,tmp/logger.log'

# Byte counters. The fixture router runs hardware offload with a counter
# flowtable, so it samples conntrack; these switch it to the other paths.
NOOFFLOAD='uci set firewall.@defaults[0].flow_offloading=0; uci set firewall.@defaults[0].flow_offloading_hw=0; uci commit firewall'
# Software offload without counter sync: the nft maps, or conntrack flagged
# degraded when there are none (no fixture for them = "Not supported").
SWOFFLOAD='uci set firewall.@defaults[0].flow_offloading_hw=0; uci commit firewall; printf "table inet fw4 {\n\tflowtable ft {\n\t\thook ingress priority filter\n\t\tdevices = { lan2, wan }\n\t}\n}\n" > "$W/cmd/nft list flowtables"'
# The maps as the legacy text parser reads them (one element a line), and in
# the nft -j form; .119 and .5 are past 2^32 and 2^53.
MONCHAIN='printf "table inet trafficctl_mon {\n\tchain mon_forward {\n\t\ttype filter hook forward priority -200; policy accept;\n\t\tupdate @bytes_in { ip daddr counter }\n\t\tupdate @bytes_out { ip saddr counter }\n\t}\n}\n" > "$W/cmd/nft list chain inet trafficctl_mon mon_forward"'
MONTEXT='printf "table inet trafficctl_mon {\n\tmap bytes_in {\n\t\ttype ipv4_addr : counter\n\t\tflags dynamic\n\t\telements = { 192.168.0.119 : counter packets 5 bytes 5368709120,\n\t\t\t     192.168.0.223 : counter packets 3 bytes 900,\n\t\t\t     10.0.5.7 : counter packets 1 bytes 64 }\n\t}\n}\n" > "$W/cmd/nft list map inet trafficctl_mon bytes_in"; printf "table inet trafficctl_mon {\n\tmap bytes_out {\n\t\ttype ipv4_addr : counter\n\t\tflags dynamic\n\t\telements = { 192.168.0.119 : counter packets 2 bytes 9007199254740992,\n\t\t\t     192.168.0.5 : counter packets 2 bytes 128 }\n\t}\n}\n" > "$W/cmd/nft list map inet trafficctl_mon bytes_out"'
MONJSON='printf "%s\n" "{\"nftables\": [{\"metainfo\": {\"version\": \"1.1.6\", \"json_schema_version\": 1}}, {\"map\": {\"family\": \"inet\", \"name\": \"bytes_in\", \"table\": \"trafficctl_mon\", \"type\": \"ipv4_addr\", \"handle\": 2, \"map\": \"counter\", \"flags\": [\"dynamic\"], \"elem\": [{\"elem\": {\"val\": \"192.168.0.119\", \"counter\": {\"packets\": 5, \"bytes\": 5368709120}}}, {\"elem\": {\"val\": \"192.168.0.223\", \"counter\": {\"packets\": 3, \"bytes\": 900}}}, {\"elem\": {\"val\": \"10.0.5.7\", \"counter\": {\"packets\": 1, \"bytes\": 64}}}]}}]}" > "$W/cmd/nft -j list map inet trafficctl_mon bytes_in"; printf "%s\n" "{\"nftables\": [{\"metainfo\": {\"version\": \"1.0.2\", \"json_schema_version\": 1}}, {\"map\": {\"family\": \"inet\", \"name\": \"bytes_out\", \"table\": \"trafficctl_mon\", \"type\": \"ipv4_addr\", \"handle\": 3, \"map\": \"counter\", \"elem\": [[\"192.168.0.119\", {\"counter\": {\"packets\": 2, \"bytes\": 9007199254740992}}], [\"192.168.0.5\", {\"counter\": {\"packets\": 2, \"bytes\": 128}}]]}}]}" > "$W/cmd/nft -j list map inet trafficctl_mon bytes_out"'
# Every state line form the legacy reader takes: 13 fields, 12, 10, 6, 5, a
# duplicate (the later line wins field by field), one too short to read, a
# degraded and an nft-sourced device, a total past 2^53, a zero total.
TOTSTATE='printf "192.168.0.119 1503032 819121 97829 103518 1794298352 2142119 176192 201347 0 ct 1794257886 false\n192.168.0.223 6368 7086 224 432 1794298352 4592 9404 656 0 ct 1794257886\n192.168.0.224 1009 880 76 76 1794298352 0 1889 0 152\n192.168.0.240 1474356 379065 157926 48918 1794298352\n192.168.0.251 323186755 18433361 17174710 613781\n192.168.0.251 5 6 7 8 1794298000 9 10 11 12 ct 1794257000 true\n192.168.0.99 77\n10.0.5.9 9007199254740992 3 1 1 1794298352 -1 -1 -1 -1 nft 1794257886 true\n10.0.5.10 0 0 0 0 1794298352 0 0 0 0 ct 1794257886 false\n" > "$W/root/tmp/trafficctl_totals.state"'
# Traffic between two samples: the first 40 entries expire, the rest grow.
GROW='sed -i -e "1,40d" -e "s/ bytes=\([0-9]*\)/ bytes=\11/g" "$W/root/proc/net/nf_conntrack"'
TOTFILE='tmp/trafficctl_totals.state'

CASES="
subnets | json | router-24.10 | trafficctl-subnets.sh | tctl subnets
subnets-routed | json | router-24.10 | trafficctl-subnets.sh | tctl subnets | $ROUTED
monitored-subnets | text | router-24.10 | fw:tctl_monitored_subnets | monitored
monitored-routed | text | router-24.10 | fw:tctl_monitored_subnets | monitored | $ROUTED
lan-device | text | router-24.10 | fw:tctl_get_lan_device | tcall trafficctl.net lan_device; echo
ifaces | text+tmp/trafficctl_ifroles | router-24.10 | trafficctl-ifaces.sh | tctl ifaces
ifaces-cached | text | router-24.10 | trafficctl-ifaces.sh | tctl ifaces | printf '# 9999999999\nwan other 0 0 0 0 cached\n' > \"\$W/root/tmp/trafficctl_ifroles\"
names-list | text | router-24.10 | trafficctl-names.sh list | tctl names list | $NAMES
names-list-empty | text | router-24.10 | trafficctl-names.sh list | tctl names list
names-set | text+$LOGS | router-24.10 | trafficctl-names.sh set 192.168.0.50 'Living room TV;\"x' | tctl names set 192.168.0.50 'Living room TV;\"x' | $NAMES
names-set-new | text+$LOGS | router-24.10 | trafficctl-names.sh set 192.168.0.9 Printer | tctl names set 192.168.0.9 Printer
names-set-bad | text+$LOGS | router-24.10 | trafficctl-names.sh set 192.168.0.300 x | tctl names set 192.168.0.300 x
names-remove | text+$LOGS | router-24.10 | trafficctl-names.sh remove 192.168.0.101 | tctl names remove 192.168.0.101 | $NAMES
names-remove-none | text | router-24.10 | trafficctl-names.sh remove 192.168.0.101 | tctl names remove 192.168.0.101
rdns | json | router-24.10 | trafficctl-rdns.sh 192.168.0.101 | tctl rdns 192.168.0.101 | $RESOLV
rdns-none | json | router-24.10 | trafficctl-rdns.sh 192.168.0.102 | tctl rdns 192.168.0.102 | $RESOLV
rdns-refresh | text+tmp/trafficctl_rdns_cache | router-24.10 | trafficctl-rdns-refresh.sh 192.168.0.101 192.168.0.102 192.168.0.220 198.18.0.7 bad | tctl rdns-refresh 192.168.0.101 192.168.0.102 192.168.0.220 198.18.0.7 bad | $RESOLV
rdns-refresh-servers | text+tmp/trafficctl_rdns_cache | router-24.10 | trafficctl-rdns-refresh.sh 192.168.0.101 192.168.0.102 192.168.0.220 | tctl rdns-refresh 192.168.0.101 192.168.0.102 192.168.0.220 | $RESOLV; $RDNS
bytes | json-set:ip | router-24.10 | trafficctl-bytes.sh | tctl bytes
bytes-routed | json-set:ip | router-24.10 | trafficctl-bytes.sh | tctl bytes | $ROUTED
bytes-no-offload | json-set:ip | router-24.10 | trafficctl-bytes.sh | tctl bytes | $NOOFFLOAD
bytes-degraded | json-set:ip | router-24.10 | trafficctl-bytes.sh | tctl bytes | $SWOFFLOAD
bytes-forced | json-set:ip | router-24.10 | sh:TCTL_FORCE_CONNTRACK=1 sh \"\$LEXEC\"/trafficctl-bytes.sh | TCTL_FORCE_CONNTRACK=1 tctl bytes | $SWOFFLOAD
bytes-nft | json-set:ip | router-24.10 | trafficctl-bytes.sh | tctl bytes | $SWOFFLOAD; $MONCHAIN; $MONTEXT; $MONJSON
bytes-nft-text | json-set:ip | router-24.10 | trafficctl-bytes.sh | tctl bytes | $SWOFFLOAD; $MONCHAIN; $MONTEXT
bytes-nft-direct | json-set:ip | router-24.10 | trafficctl-bytes-nft.sh | tctl bytes-nft | $MONCHAIN; $MONTEXT; $MONJSON
bytes-nft-unsupported | json-set:ip | router-24.10 | trafficctl-bytes-nft.sh | tctl bytes-nft | $MONCHAIN
totals | json-set:ip | router-24.10 | sh:masked legacy_tot | masked tctl totals
totals-all | json-set:ip | router-24.10 | sh:masked legacy_tot --all | masked tctl totals --all
totals-state | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; echo ran | tctl totals >/dev/null; echo ran
totals-fresh | json-set:ip | router-24.10 | sh:masked legacy_tot --all | masked tctl totals --all | rm -f \"\$W/root/$TOTFILE\"
totals-forms | json-set:ip | router-24.10 | sh:masked legacy_tot --all | masked tctl totals --all | $TOTSTATE
totals-forms-state | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; echo ran | tctl totals >/dev/null; echo ran | $TOTSTATE
totals-nft-switch | json-set:ip | router-24.10 | sh:legacy_tot >/dev/null; $SWOFFLOAD; $MONCHAIN; $MONTEXT; $MONJSON; masked legacy_tot --all | tctl totals >/dev/null; $SWOFFLOAD; $MONCHAIN; $MONTEXT; $MONJSON; masked tctl totals --all
totals-grow | json-set:ip | router-24.10 | sh:legacy_tot >/dev/null; $GROW; masked legacy_tot --all | tctl totals >/dev/null; $GROW; masked tctl totals --all
totals-upgrade | json-set:ip | router-24.10 | sh:legacy_tot >/dev/null; $GROW; masked legacy_tot --all | legacy_tot >/dev/null; $GROW; masked tctl totals --all
totals-upgrade-state | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; $GROW; legacy_tot >/dev/null; echo ran | legacy_tot >/dev/null; $GROW; tctl totals >/dev/null; echo ran
totals-downgrade | json-set:ip | router-24.10 | sh:legacy_tot >/dev/null; $GROW; masked legacy_tot --all | tctl totals >/dev/null; $GROW; masked legacy_tot --all
totals-downgrade-state | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; $GROW; legacy_tot >/dev/null; echo ran | tctl totals >/dev/null; $GROW; legacy_tot >/dev/null; echo ran
totals-stale-lock | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; [ -d \"\$W/root/tmp/trafficctl_totals.lock.d\" ] && echo held; echo ran | tctl totals >/dev/null; [ -d \"\$W/root/tmp/trafficctl_totals.lock.d\" ] && echo held; echo ran | mkdir \"\$W/root/tmp/trafficctl_totals.lock.d\"
"

command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }

# ── legacy backend, and the current fw.sh ───────────────────────────────────
if ! git -C "$UC_REPO" rev-parse -q --verify "refs/tags/$LEGACY_TAG" >/dev/null; then
    git -C "$UC_REPO" fetch -q --depth=1 origin "refs/tags/$LEGACY_TAG:refs/tags/$LEGACY_TAG" ||
        { echo "FAIL: cannot get $LEGACY_TAG" >&2; exit 1; }
fi
mkdir -p "$L" "$C/trafficctl" "$W"
git -C "$UC_REPO" archive "$LEGACY_TAG" trafficctl/files luci-app-trafficctl/root | tar -x -C "$L"
cp -R "$UC_REPO/trafficctl/files" "$C/trafficctl/"
LEXEC="$L/trafficctl/files/usr/libexec/trafficctl"
CEXEC="$C/trafficctl/files/usr/libexec/trafficctl"
# The same rewrites the unit tests apply, pointed at the case's root.
rewrite() {   # rewrite <tree> <its libexec dir>
    find "$1" -type f -exec sed -i \
        -e "s|/usr/libexec/trafficctl/|$2/|g" \
        -e "s|/tmp/dhcp\.leases|$W/root/tmp/dhcp.leases|g" \
        -e "s|/proc/net/|$W/root/proc/net/|g" \
        -e "s|/sys/class/net|$W/root/sys/class/net|g" \
        -e "s|/etc/trafficctl/|$W/root/etc/trafficctl/|g" \
        -e "s|/tmp/trafficctl_|$W/root/tmp/trafficctl_|g" \
        -e "s|/tmp/trafficctl/|$W/root/tmp/trafficctl/|g" \
        -e "s|/tmp/\.trafficctl_|$W/root/tmp/.trafficctl_|g" \
        -e "s|/var/run/trafficctl|$W/root/var/run/trafficctl|g" \
        -e "s|/etc/init\.d/|$W/root/etc/init.d/|g" \
        -e "s|/etc/config/trafficctl|$W/root/etc/config/trafficctl|g" \
        -e "s|/sys/kernel/debug/ecm|$W/root/sys/kernel/debug/ecm|g" {} +
}
rewrite "$L" "$LEXEC"
rewrite "$C" "$CEXEC"

# ── mocks ───────────────────────────────────────────────────────────────────
mkdir -p "$W/bin"
cat > "$W/bin/replay" <<EOF
#!/bin/sh
# Prints the recorded output of this exact command line, or fails like the
# command would when the fixture has none.
f="$W/cmd/\${0##*/} \$*"
[ -f "\$f" ] || { echo "replay: no fixture for: \${0##*/} \$*" >&2; exit 1; }
cat "\$f"
EOF
for c in ip nft tc iw brctl conntrack nslookup; do ln -sf replay "$W/bin/$c"; done
# -t, not -P: since 2023 uci treats -P as a search path only, and commit
# would read its deltas from /tmp/.uci and change nothing.
cat > "$W/bin/uci" <<EOF
#!/bin/sh
exec "$UCODE_PREFIX/bin/uci" -c "$W/root/etc/config" -t "$W/root/tmp/.uci" "\$@"
EOF
cat > "$W/bin/ubus" <<EOF
#!/bin/sh
exec "$UCODE_PREFIX/bin/ubus" -s "\$TCTL_UBUS_SOCKET" "\$@"
EOF
# The shell plugin's version and bot checks, answered from the case's root and
# the same procd fixture the ucode plugin asks over ubus.
cat > "$W/bin/opkg" <<EOF
#!/bin/sh
[ "\$1" = info ] || exit 1
awk -v p="\$2" '/^Package: /{ on = (\$2 == p) } on' "$W/root/usr/lib/opkg/status" 2>/dev/null
EOF
cat > "$W/bin/pgrep" <<EOF
#!/bin/sh
[ "\$*" = "-f trafficctl-telegram.sh" ] || exit 1
jq -e '."trafficctl-telegram".instances[] | select(.running)' "\$TCTL_FIXTURE/ubus/service@list.json" >/dev/null
EOF
cat > "$W/bin/logger" <<EOF
#!/bin/sh
echo "\$*" >> "$W/root/tmp/logger.log"
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
    rm -rf "$W/root" "$W/cmd"
    cp -R "$FIXTURES/$1/root" "$W/root"
    cp -R "$FIXTURES/$1/cmd" "$W/cmd"
    mkdir -p "$W/root/tmp/.uci" "$W/root/var/run"
    if [ -n "$2" ]; then
        (export PATH="$W/bin:$PATH"; eval "$2") || echo "setup failed: $2" >&2
    fi
}

with_files() {   # with_files <out> <comma list>: append root files, masked
    local f
    for f in ${2//,/ }; do
        echo "--- $f" >> "$1"
        [ -f "$W/root/$f" ] || { echo "(missing)" >> "$1"; continue; }
        # Epochs twice: two of them in a row share the space between them.
        sed -E -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/<time>/g' \
               -e 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\1<epoch>\2/g' \
               -e 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\1<epoch>\2/g' "$W/root/$f" >> "$1"
    done
}

trim() { printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

# For sh: cases. total_since is "now" for a device first seen in this run,
# and the two sides do not run in the same second.
legacy_tot() { sh "$LEXEC/trafficctl-totals.sh" "$@"; }
masked() {
    "$@" > "$W/masked.json"
    jq -c 'map(if (.total_since | type) == "number" and .total_since > now - 3600 then .total_since = "<now>" else . end)' "$W/masked.json"
}

# The comparison itself has to be able to fail, or every case passes.
printf '[1,2]' > "$W/a"; printf '[2,1]' > "$W/b"
if compare json "$W/a" "$W/b" >/dev/null || ! compare json-set:x <(echo '[{"x":1},{"x":2}]') <(echo '[{"x":2},{"x":1}]') >/dev/null; then
    echo "FAIL: compare modes are broken"; exit 1
fi

# ── cases ───────────────────────────────────────────────────────────────────
while IFS='|' read -r name mode fixture legacy new setup; do
    name=$(trim "$name")
    [ -n "$name" ] || continue
    mode=$(trim "$mode"); fixture=$(trim "$fixture")
    legacy=$(trim "$legacy"); new=$(trim "$new"); setup=$(trim "$setup")
    files=""
    case "$mode" in *+*) files="${mode#*+}"; mode="${mode%%+*}" ;; esac
    export TCTL_FIXTURE="$FIXTURES/$fixture"
    ubus_start "$TCTL_FIXTURE/ubus"

    fresh_root "$fixture" "$setup"
    # The configured log file is a router path; point it into the root, as the
    # rewrite does for the scripts' own default.
    sed -i "s|'/tmp/trafficctl/|'$W/root/tmp/trafficctl/|" "$W/root/etc/config/trafficctl"
    case "$legacy" in
        fw:*) PATH="$W/bin:$PATH" sh -c ". '$CEXEC/trafficctl-fw.sh'; ${legacy#fw:}" ;;
        sh:*) (export PATH="$W/bin:$PATH"; eval "${legacy#sh:}") ;;
        *) (export PATH="$W/bin:$PATH"; eval "sh \"\$LEXEC\"/$legacy") ;;
    esac > "$W/legacy.out" 2> "$W/legacy.err"
    [ -z "$files" ] || with_files "$W/legacy.out" "$files"

    fresh_root "$fixture" "$setup"
    (export TCTL_ROOT="$W/root" PATH="$W/bin:$PATH"; eval "$new") > "$W/new.out" 2> "$W/new.err"
    [ -z "$files" ] || with_files "$W/new.out" "$files"
    ubus_stop
    # EQUIV_KEEP=<dir> keeps both sides' output for a look by hand.
    if [ -n "${EQUIV_KEEP:-}" ]; then
        mkdir -p "$EQUIV_KEEP"
        cp "$W/legacy.out" "$EQUIV_KEEP/$name.legacy"; cp "$W/new.out" "$EQUIV_KEEP/$name.new"
    fi

    if [ ! -s "$W/legacy.out" ]; then
        FAIL=$((FAIL + 1)); echo "FAIL: $name: legacy side printed nothing"; cat "$W/legacy.err"
    elif compare "$mode" "$W/legacy.out" "$W/new.out" > "$W/diff" 2>&1; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: $name ($mode)"; cat "$W/diff" "$W/new.err"
    fi
done <<< "$CASES"

# ── the rpcd plugin ─────────────────────────────────────────────────────────
# The v1.30.0 shell plugin and the ucode one, method by method, with the same
# JSON on stdin. Case lines: name | mode | scripts | method | json [| setup]
#   scripts  stub: every backend script is a stub that logs its arguments and
#            the caller variables to tmp/dispatch.log, so a delegated method is
#            compared on what it hands on (the ucode side reaches the stubs
#            through the real CLI); real: the legacy scripts themselves
#   mode     json[+files]: the reply semantically (jq -S, or as text when it
#            is not JSON), then the files; the root prefix is masked
LPLUGIN="$L/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
NPLUGIN="$UC_REPO/luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl"
STUBS="$UC_TMP/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/stub" <<EOF
#!/bin/sh
n=\${0##*/}
{ printf '%s' "\$n"; for a in "\$@"; do printf ' [%s]' "\$a"; done
  printf ' via=%s src=%s user=%s token=%s\n' "\$TCTL_VIA" "\$TCTL_SRC" "\$TCTL_USER" "\$TCTL_TG_TOKEN"; } >> "$W/root/tmp/dispatch.log"
printf '{"stub":"%s","argc":%d}\n' "\$n" "\$#"
EOF
chmod +x "$STUBS/stub"
for f in "$LEXEC"/trafficctl-*.sh; do
    [ "${f##*/}" = trafficctl-fw.sh ] || ln -sf stub "$STUBS/${f##*/}"
done
# The stubbed plugin still sources the real library.
ln -sf "$LEXEC/trafficctl-fw.sh" "$STUBS/trafficctl-fw.sh"

# Mock init scripts for the services the plugin restarts; reload runs in the
# background, hence the pause after each call.
INITS='mkdir -p "$W/root/etc/init.d"; for s in trafficctl-telegram trafficctl-history; do printf "#!/bin/sh\necho \"$s \$*\" >> \"$W/root/tmp/init.log\"\n" > "$W/root/etc/init.d/$s"; chmod +x "$W/root/etc/init.d/$s"; done'
LOGF='tmp/dispatch.log,tmp/init.log,etc/config/trafficctl,tmp/trafficctl/activity.log,tmp/logger.log'
TOKEN='uci set trafficctl.telegram.bot_token=123456:SECRETTOKEN; uci set trafficctl.telegram.chat_id=4242; uci set trafficctl.telegram.notify_template="say hi to {{name}}"; uci commit trafficctl'
NOTG='uci delete trafficctl.telegram; uci commit trafficctl'
ACTLOG='mkdir -p "$W/root/tmp/trafficctl"; for i in 1 2 3 4 5; do echo "[trafficctl] line $i \"q\""; done > "$W/root/tmp/trafficctl/activity.log"'
OPKG='mkdir -p "$W/root/usr/lib/opkg"; printf "Package: luci-base\nVersion: 25.0\n\nPackage: luci-app-trafficctl\nVersion: 1.30.1-r1\nStatus: install user installed\n" > "$W/root/usr/lib/opkg/status"'
ECM_ON='mkdir -p "$W/root/sys/kernel/debug/ecm"; echo 1 > "$W/root/sys/kernel/debug/ecm/front_end_ipv4_stop"; echo 0 > "$W/root/sys/kernel/debug/ecm/front_end_ipv6_stop"'
ECM_OFF='mkdir -p "$W/root/sys/kernel/debug/ecm"; echo 1 > "$W/root/sys/kernel/debug/ecm/front_end_ipv4_stop"; echo 1 > "$W/root/sys/kernel/debug/ecm/front_end_ipv6_stop"'
NOFLOW='uci set firewall.@defaults[0].flow_offloading=0; uci set firewall.@defaults[0].flow_offloading_hw=0; uci commit firewall'
SWFLOW='uci set firewall.@defaults[0].flow_offloading=1; uci set firewall.@defaults[0].flow_offloading_hw=0; uci commit firewall'
SEEN='mkdir -p "$W/root/etc/trafficctl"; printf "aa:bb:cc:00:00:01\naa:bb:cc:00:00:02\n" > "$W/root/etc/trafficctl/seen_macs"'
HIST='uci set trafficctl.history=history; uci set trafficctl.history.enabled=1; uci commit trafficctl'
ODD='uci set trafficctl.main.poll_interval=0x1f; uci set trafficctl.main.avg_window=12x; uci commit trafficctl'
ODD2='uci set trafficctl.main.poll_interval=" 010"; uci set trafficctl.main.avg_window=99999999999999999999; uci set trafficctl.newdevice.limit_kbit=-5; uci commit trafficctl'
NOLOG='uci delete trafficctl.logging; uci commit trafficctl'

RPCD_CASES="
unknown | json | stub | bogus_method | {}
summary | json+$LOGF | stub | summary | {}
device | json+$LOGF | stub | device | {\"ip\":\"192.168.0.101\"}
device-tcp | json+$LOGF | stub | device | {\"ip\":\"192.168.0.101\",\"proto\":\"tcp\"}
device-proto-bad | json+$LOGF | stub | device | {\"ip\":\"192.168.0.101\",\"proto\":\"icmp\"}
device-no-ip | json+$LOGF | stub | device | {}
bytes | json+$LOGF | stub | bytes | {}
ifaces | json | real | ifaces | {}
block | json+$LOGF | stub | block | {\"ip\":\"192.168.0.9\",\"label\":\"my label; reboot\"}
block-no-ip | json+$LOGF | stub | block | {\"label\":\"x\"}
unblock | json+$LOGF | stub | unblock | {\"ip\":\"192.168.0.9\",\"label\":\"block_192.168.0.9\"}
unblock-no-ip | json+$LOGF | stub | unblock | {}
macfilter-add | json+$LOGF | stub | macfilter_add | {\"ip\":\"192.168.0.9\"}
macfilter-add-no-ip | json+$LOGF | stub | macfilter_add | {}
macfilter-remove-ip | json+$LOGF | stub | macfilter_remove | {\"ip\":\"192.168.0.9\"}
macfilter-remove-mac | json+$LOGF | stub | macfilter_remove | {\"mac\":\"AA:bb:cc:dd:ee:ff\"}
macfilter-remove-both | json+$LOGF | stub | macfilter_remove | {\"ip\":\"192.168.0.9\",\"mac\":\"aa:bb:cc:dd:ee:ff\"}
macfilter-remove-none | json+$LOGF | stub | macfilter_remove | {}
ratelimit | json+$LOGF | stub | ratelimit | {\"ip\":\"192.168.0.9\",\"rate_kbit\":5000,\"label\":\"rl\",\"mode\":\"each\",\"rate_kbit_up\":0}
ratelimit-up | json+$LOGF | stub | ratelimit | {\"ip\":\"10.0.20.0/24\",\"rate_kbit\":5000,\"mode\":\"shared\",\"rate_kbit_up\":2000}
ratelimit-bad-mode | json+$LOGF | stub | ratelimit | {\"ip\":\"192.168.0.9\",\"rate_kbit\":5000,\"mode\":\"bogus\"}
ratelimit-no-rate | json+$LOGF | stub | ratelimit | {\"ip\":\"192.168.0.9\"}
ratelimit-no-ip | json+$LOGF | stub | ratelimit | {\"rate_kbit\":5000}
ratelimit-stats | json+$LOGF | stub | ratelimit_stats | {}
subnets | json | real | subnets | {}
shape-add | json+$LOGF | stub | shape_add | {\"ip\":\"192.168.0.9\",\"rate_kbit\":8000,\"label\":\"x y\",\"rate_kbit_up\":1000}
shape-add-up0 | json+$LOGF | stub | shape_add | {\"ip\":\"192.168.0.9\",\"rate_kbit\":8000,\"rate_kbit_up\":0}
shape-add-no-rate | json+$LOGF | stub | shape_add | {\"ip\":\"192.168.0.9\"}
shape-remove | json+$LOGF | stub | shape_remove | {\"ip\":\"192.168.0.9\",\"label\":\"x\"}
shape-remove-no-ip | json+$LOGF | stub | shape_remove | {}
shape-status | json+$LOGF | stub | shape_status | {\"ip\":\"192.168.0.9\"}
shape-status-no-ip | json+$LOGF | stub | shape_status | {}
shape-stats | json+$LOGF | stub | shape_stats | {}
rules-list | json+$LOGF | stub | rules_list | {}
rdns | json | real | rdns | {\"ip\":\"192.168.0.101\"} | $RESOLV
rdns-no-ip | json | real | rdns | {}
netify-status | json+$LOGF | stub | netify_status | {}
netify-list | json+$LOGF | stub | netify_list | {}
netify-collect | json+$LOGF | stub | netify_collect | {\"secs\":5}
netify-collect-default | json+$LOGF | stub | netify_collect | {}
names-list | json | real | names_list | {} | $NAMES
names-list-empty | json | real | names_list | {}
name-set | json+$LOGF,etc/trafficctl/names | real | name_set | {\"ip\":\"192.168.0.50\",\"name\":\"Living room;TV\"} | $NAMES
name-set-bad-ip | json+$LOGF,etc/trafficctl/names | real | name_set | {\"ip\":\"192.168.0.500\",\"name\":\"x\"} | $NAMES
name-set-empty | json+$LOGF,etc/trafficctl/names | real | name_set | {\"ip\":\"192.168.0.101\",\"name\":\"\"} | $NAMES
name-set-no-ip | json+$LOGF | real | name_set | {\"name\":\"x\"}
name-clear | json+$LOGF,etc/trafficctl/names | real | name_clear | {\"ip\":\"192.168.0.101\"} | $NAMES
name-clear-none | json+$LOGF | real | name_clear | {\"ip\":\"192.168.0.101\"}
name-clear-no-ip | json+$LOGF | real | name_clear | {}
portfw-list | json+$LOGF | stub | portfw_list | {}
portfw-pause | json+$LOGF | stub | portfw_ctl | {\"action\":\"pause\",\"scope\":\"forward\",\"proto\":\"tcp\",\"ip\":\"192.168.0.9\",\"port\":\"8080\"}
portfw-resume-local | json+$LOGF | stub | portfw_ctl | {\"action\":\"resume\",\"scope\":\"input\",\"proto\":\"udp\",\"port\":\"51820\"}
portfw-limit | json+$LOGF | stub | portfw_ctl | {\"action\":\"limit\",\"scope\":\"forward\",\"proto\":\"tcp\",\"ip\":\"192.168.0.9\",\"port\":\"8080\",\"rate_kbit\":5000}
portfw-limit-no-rate | json+$LOGF | stub | portfw_ctl | {\"action\":\"limit\",\"scope\":\"forward\",\"proto\":\"tcp\",\"port\":\"8080\"}
portfw-bad-action | json+$LOGF | stub | portfw_ctl | {\"action\":\"delete\"}
config-get | json | stub | config_get | {}
config-get-sw | json | stub | config_get | {} | $SWFLOW
config-get-none | json | stub | config_get | {} | $NOFLOW
config-get-ecm-active | json | stub | config_get | {} | $ECM_ON
config-get-ecm-stopped | json | stub | config_get | {} | $ECM_OFF
config-get-odd | json | stub-ash | config_get | {} | $ODD
config-get-odd2 | json | stub-ash | config_get | {} | $ODD2
config-get-ash | json | stub-ash | config_get | {}
logging-get-ash | json | stub-ash | logging_config_get | {}
newdevice-get-odd | json | stub-ash | newdevice_config_get | {} | $ODD2
config-set | json+$LOGF,etc/config/firewall | stub | config_set | {\"enabled\":false,\"default_mode\":\"shaper\",\"poll_interval\":30,\"avg_window\":300}
config-set-poll-off | json+$LOGF | stub | config_set | {\"poll_interval\":0}
config-set-poll-high | json+$LOGF | stub | config_set | {\"poll_interval\":301}
config-set-poll-nan | json+$LOGF | stub | config_set | {\"poll_interval\":\"abc\"}
config-set-poll-double | json+$LOGF | stub | config_set | {\"poll_interval\":5.5}
config-set-window-low | json+$LOGF | stub | config_set | {\"avg_window\":1}
config-set-window-high | json+$LOGF | stub | config_set | {\"avg_window\":3601}
config-set-window-nan | json+$LOGF | stub | config_set | {\"avg_window\":\"1e3\"}
config-set-offload | json+$LOGF,etc/config/firewall | stub | config_set | {\"sw\":false,\"hw\":false}
config-set-offload-sw | json+$LOGF,etc/config/firewall | stub | config_set | {\"sw\":true} | $NOFLOW
telegram-get | json | stub | telegram_config_get | {}
telegram-get-token | json | stub | telegram_config_get | {} | $TOKEN
telegram-get-none | json | stub | telegram_config_get | {} | $NOTG
telegram-set | json+$LOGF | stub | telegram_config_set | {\"enabled\":true,\"bot_token\":\"999:NEWTOKEN\",\"chat_id\":\"54321\",\"poll_interval\":5,\"notify_new_device\":false,\"notify_known_device\":true,\"control_enabled\":false,\"notify_template\":\"{{name}} joined\",\"btn_block_inet\":false,\"btn_block_wifi\":true,\"btn_limiter\":false,\"btn_shaper\":true} | $INITS
telegram-set-mask | json+$LOGF | stub | telegram_config_set | {\"enabled\":false,\"bot_token\":\"***\",\"chat_id\":\"54321\"} | $TOKEN; $INITS
telegram-set-clear | json+$LOGF | stub | telegram_config_set | {\"bot_token\":\"\",\"notify_template\":\"\"} | $TOKEN; $INITS
telegram-set-new-section | json+$LOGF | stub | telegram_config_set | {\"enabled\":true,\"chat_id\":\"1\"} | $NOTG; $INITS
telegram-test | json+$LOGF | stub | telegram_test | {\"bot_token\":\"777:ABC\",\"chat_id\":\"4242\",\"message\":\"it's {{name}}\"}
telegram-test-mask | json+$LOGF | stub | telegram_test | {\"bot_token\":\"***\",\"chat_id\":\"4242\"} | $TOKEN
telegram-test-no-chat | json+$LOGF | stub | telegram_test | {\"bot_token\":\"777:ABC\"}
telegram-test-no-token | json+$LOGF | stub | telegram_test | {\"chat_id\":\"4242\"}
logging-get | json | stub | logging_config_get | {}
logging-get-unset | json | stub | logging_config_get | {} | $NOLOG
logging-set | json+$LOGF | stub | logging_config_set | {\"enabled\":true,\"log_file\":\"/tmp/trafficctl/other.log\",\"max_lines\":800,\"syslog\":false,\"log_blocks\":false,\"log_ratelimits\":true,\"log_shapes\":false,\"log_telegram\":true,\"log_config\":true,\"persist_rules\":true}
logging-set-persist-off | json+$LOGF | stub | logging_config_set | {\"persist_rules\":false}
logging-set-shadow | json+$LOGF | stub | logging_config_set | {\"log_file\":\"/etc/shadow\"}
logging-set-dotdot | json+$LOGF | stub | logging_config_set | {\"log_file\":\"/var/log/../shadow\"}
logging-set-varlog | json+$LOGF | stub | logging_config_set | {\"log_file\":\"/var/log/trafficctl.log\"}
logging-set-max-low | json+$LOGF | stub | logging_config_set | {\"max_lines\":\"1\"}
logging-set-max-high | json+$LOGF | stub | logging_config_set | {\"max_lines\":100001}
logging-set-max-nan | json+$LOGF | stub | logging_config_set | {\"max_lines\":\"5k\"}
logging-set-max-str | json+$LOGF | stub | logging_config_set | {\"max_lines\":\"500\"}
newdevice-get | json | stub | newdevice_config_get | {}
newdevice-get-seen | json | stub | newdevice_config_get | {} | $SEEN
newdevice-set | json+$LOGF,etc/trafficctl/seen_macs | stub | newdevice_config_set | {\"enabled\":true,\"limit_kbit\":2000,\"limit_mode\":\"shaper\"}
newdevice-set-seeded | json+$LOGF,etc/trafficctl/seen_macs | stub | newdevice_config_set | {\"enabled\":true} | $SEEN
newdevice-set-off | json+$LOGF,etc/trafficctl/seen_macs | stub | newdevice_config_set | {\"enabled\":false}
newdevice-set-kbit-nan | json+$LOGF | stub | newdevice_config_set | {\"limit_kbit\":\"fast\"}
newdevice-set-mode-bad | json+$LOGF | stub | newdevice_config_set | {\"limit_mode\":\"both\"}
cut-status | json+$LOGF | stub | cut_status | {}
cut-engage | json+$LOGF | stub | cut_set | {\"active\":true,\"duration\":600,\"persist\":true}
cut-engage-forever | json+$LOGF | stub | cut_set | {\"active\":\"true\",\"duration\":0}
cut-engage-no-duration | json+$LOGF | stub | cut_set | {\"active\":true}
cut-release | json+$LOGF | stub | cut_set | {\"active\":false}
cut-bad | json+$LOGF | stub | cut_set | {\"active\":\"maybe\"}
activity-log | json | stub | activity_log | {\"lines\":2} | $ACTLOG
activity-log-default | json | stub | activity_log | {} | $ACTLOG
activity-log-zero | json | stub | activity_log | {\"lines\":0} | $ACTLOG
activity-log-huge | json | stub | activity_log | {\"lines\":99999} | $ACTLOG
activity-log-nan | json | stub | activity_log | {\"lines\":\"x\"} | $ACTLOG
activity-log-missing | json | stub | activity_log | {}
history-status | json+$LOGF | stub | history_status | {}
history-periods | json+$LOGF | stub | history_periods | {}
history-read | json+$LOGF | stub | history_read | {\"period\":\"2026-11\",\"to\":\"2026-W46\"}
history-read-day | json+$LOGF | stub | history_read | {\"period\":\"2026-11-11\"}
history-read-all | json+$LOGF | stub | history_read | {}
history-read-bad | json+$LOGF | stub | history_read | {\"period\":\"../../etc\"}
history-read-bad-to | json+$LOGF | stub | history_read | {\"period\":\"2026-11\",\"to\":\"2026-11-1\"}
history-read-ifaces | json+$LOGF | stub | history_read_ifaces | {\"period\":\"2026-W01\",\"to\":\"2026-W02\"}
history-read-ifaces-bad | json+$LOGF | stub | history_read_ifaces | {\"to\":\"x\"}
history-config-get | json+$LOGF | stub | history_config_get | {}
history-config-set | json+$LOGF | real | history_config_set | {\"enabled\":true,\"dir\":\"/mnt/usb/history/\",\"period\":\"week\",\"interval\":900,\"sample_interval\":30,\"keep\":24,\"interfaces\":true} | $INITS
history-config-set-off | json+$LOGF | real | history_config_set | {\"enabled\":false} | $HIST; $INITS
history-config-set-own | json+$LOGF | real | history_config_set | {\"dir\":\"/etc/trafficctl/hist\"} | $INITS
history-config-set-noinit | json+$LOGF | real | history_config_set | {\"enabled\":true}
history-config-set-dir-bad | json+$LOGF | real | history_config_set | {\"dir\":\"/etc\"} | $INITS
history-config-set-dir-root | json+$LOGF | real | history_config_set | {\"dir\":\"/mnt/\"} | $INITS
history-config-set-dir-dotdot | json+$LOGF | real | history_config_set | {\"dir\":\"/mnt/../etc\"} | $INITS
history-config-set-dir-meta | json+$LOGF | real | history_config_set | {\"dir\":\"/tmp/a;b\"} | $INITS
history-config-set-period-bad | json+$LOGF | real | history_config_set | {\"period\":\"year\"} | $INITS
history-config-set-keep-nan | json+$LOGF | real | history_config_set | {\"keep\":\"-1\"} | $INITS
history-flush | json+$LOGF | stub | history_flush | {}
version | json | stub | version | {} | $OPKG
version-none | json | stub | version | {}
"

normalise() {   # normalise <out> <files>: the reply as jq -S, the files, prefix masked
    if jq -S . "$1" > "$1.n" 2>/dev/null && [ -s "$1.n" ]; then mv "$1.n" "$1"; fi
    [ -z "$2" ] || with_files "$1" "$2"
    sed -i "s|$W/root||g" "$1"
}
rpcd_side() {   # rpcd_side <legacy|new> <stub|real> <method> <json>
    local dir="$STUBS"
    [ "$2" = real ] && dir="$LEXEC"
    if [ "$1" = legacy ]; then
        sed "s|^SCRIPTS=.*|SCRIPTS=\"$dir\"|" "$LPLUGIN" > "$W/legacy-plugin"
        printf '%s\n' "$4" | sed -e "s|/tmp/trafficctl/|$W/root/tmp/trafficctl/|g" \
            -e "s|/etc/trafficctl/|$W/root/etc/trafficctl/|g" |
            (export PATH="$W/bin:$PATH"; $LSH "$W/legacy-plugin" call "$3")
    else
        mkdir -p "$W/root/usr/sbin" "$W/root/usr/libexec"
        ln -sfn "$dir" "$W/root/usr/libexec/trafficctl"
        # glibc's getopt would take the CLI's own --proto for a ucode option;
        # musl's, on the router, stops at the script name.
        printf '#!/bin/sh\nPOSIXLY_CORRECT=1 exec "%s" -S -L "%s" "%s" "$@"\n' "$UCODE" "$UC_LIB" \
            "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" > "$W/root/usr/sbin/trafficctl"
        chmod +x "$W/root/usr/sbin/trafficctl"
        printf '%s\n' "$4" |
            (export TCTL_ROOT="$W/root" PATH="$W/bin:$PATH"; "$UCODE" -S -L "$UC_LIB" "$NPLUGIN" call "$3")
    fi
    sleep 0.3
}

# scripts "stub-ash": the shell plugin runs under busybox ash, as on the
# router, for the cases where its printf %d differs from dash's ('12x' is 0,
# not 12). Not by default: a busybox built to prefer its applets bypasses the
# logger mock. Skipped without busybox; CI installs it.
BUSYBOX_SH=""
busybox sh -c 'printf %d 12x' 2>/dev/null | grep -qx 0 && BUSYBOX_SH="busybox sh"
RSKIP=0
RPASS=0
while IFS='|' read -r name mode scripts method input setup; do
    name=$(trim "$name")
    [ -n "$name" ] || continue
    mode=$(trim "$mode"); scripts=$(trim "$scripts"); method=$(trim "$method")
    input=$(trim "$input"); setup=$(trim "$setup")
    files=""
    case "$mode" in *+*) files="${mode#*+}"; mode="${mode%%+*}" ;; esac
    LSH="sh"
    if [ "$scripts" = stub-ash ]; then
        scripts=stub
        [ -n "$BUSYBOX_SH" ] || { RSKIP=$((RSKIP + 1)); continue; }
        LSH=$BUSYBOX_SH
    fi
    export TCTL_FIXTURE="$FIXTURES/router-24.10"
    ubus_start "$TCTL_FIXTURE/ubus"

    fresh_root router-24.10 "$setup"
    sed -i "s|'/tmp/trafficctl/|'$W/root/tmp/trafficctl/|" "$W/root/etc/config/trafficctl"
    rpcd_side legacy "$scripts" "$method" "$input" > "$W/legacy.out" 2> "$W/legacy.err"
    normalise "$W/legacy.out" "$files"

    fresh_root router-24.10 "$setup"
    rpcd_side new "$scripts" "$method" "$input" > "$W/new.out" 2> "$W/new.err"
    normalise "$W/new.out" "$files"
    ubus_stop
    if [ -n "${EQUIV_KEEP:-}" ]; then
        mkdir -p "$EQUIV_KEEP"
        cp "$W/legacy.out" "$EQUIV_KEEP/rpcd-$name.legacy"; cp "$W/new.out" "$EQUIV_KEEP/rpcd-$name.new"
    fi

    if [ ! -s "$W/legacy.out" ]; then
        FAIL=$((FAIL + 1)); echo "FAIL: rpcd $name: legacy side printed nothing"; cat "$W/legacy.err"
    elif diff "$W/legacy.out" "$W/new.out" > "$W/diff" 2>&1; then
        PASS=$((PASS + 1)); RPASS=$((RPASS + 1))
    else
        FAIL=$((FAIL + 1)); echo "FAIL: rpcd $name"; cat "$W/diff"
        sed 's/^/legacy stderr: /' "$W/legacy.err"; sed 's/^/new stderr: /' "$W/new.err"
    fi
done <<< "$RPCD_CASES"
# Every method the plugin lists has a case.
covered=$(printf '%s\n' "$RPCD_CASES" | awk -F'|' 'NF > 3 { gsub(/[[:space:]]/, "", $4); print $4 }')
for m in $("$UCODE" -S -L "$UC_LIB" "$NPLUGIN" list | jq -r 'keys[]'); do
    printf '%s\n' "$covered" | grep -qx "$m" ||
        { FAIL=$((FAIL + 1)); echo "FAIL: rpcd method $m has no equivalence case"; }
done
echo "rpcd plugin: $RPASS cases equal, $RSKIP skipped (no busybox)"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
