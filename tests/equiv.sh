#!/bin/bash
# Equivalence harness: the released shell backend (v1.30.0, from git) and its
# ucode port run against the same fixture, and their outputs must match.
#
# A fixture is a directory under tests/fixtures/ (see tools/capture-fixtures.sh):
#   root/  becomes TCTL_ROOT; the legacy scripts get their paths rewritten to it
#   cmd/   replayed by PATH mocks for ip, nft, tc, iw, brctl, conntrack, nslookup,
#          hostapd_cli
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
# flowtable; these switch it to the other offload modes.
NOOFFLOAD='uci set firewall.@defaults[0].flow_offloading=0; uci set firewall.@defaults[0].flow_offloading_hw=0; uci commit firewall'
# Software offload without a flowtable counter: conntrack flagged degraded.
# The legacy side still tries its nft counter maps first; with no fixture for
# them it meets what every kernel answered ("Not supported") and falls back to
# the same conntrack sample, which is the only path the port keeps.
SWOFFLOAD='uci set firewall.@defaults[0].flow_offloading_hw=0; uci commit firewall; printf "table inet fw4 {\n\tflowtable ft {\n\t\thook ingress priority filter\n\t\tdevices = { lan2, wan }\n\t}\n}\n" > "$W/cmd/nft list flowtables"'
# Every state line form the legacy reader takes: 13 fields, 12, 10, 6, 5, a
# duplicate (the later line wins field by field), one too short to read, a
# degraded and an nft-sourced device, a total past 2^53, a zero total.
TOTSTATE='printf "192.168.0.119 1503032 819121 97829 103518 1794298352 2142119 176192 201347 0 ct 1794257886 false\n192.168.0.223 6368 7086 224 432 1794298352 4592 9404 656 0 ct 1794257886\n192.168.0.224 1009 880 76 76 1794298352 0 1889 0 152\n192.168.0.240 1474356 379065 157926 48918 1794298352\n192.168.0.251 323186755 18433361 17174710 613781\n192.168.0.251 5 6 7 8 1794298000 9 10 11 12 ct 1794257000 true\n192.168.0.99 77\n10.0.5.9 9007199254740992 3 1 1 1794298352 -1 -1 -1 -1 nft 1794257886 true\n10.0.5.10 0 0 0 0 1794298352 0 0 0 0 ct 1794257886 false\n" > "$W/root/tmp/trafficctl_totals.state"'
# Traffic between two samples: the first 40 entries expire, the rest grow.
GROW='sed -i -e "1,40d" -e "s/ bytes=\([0-9]*\)/ bytes=\11/g" "$W/root/proc/net/nf_conntrack"'
TOTFILE='tmp/trafficctl_totals.state'

# The reports. A detached refresh the summary starts lands in tmp/spawn.log on
# both sides (see spawn below), so what it would have started is compared too.
SPAWNF='tmp/spawn.log,tmp/trafficctl_conn_cache'
# Blocks (both halves, a v6 half alone) and limits in each unit form, from
# tests/fixtures/nft-src/summary.nft as each nftables release lists it, and
# shapes on both directions.
TCIFB='printf "class htb 1:1 root rate 1Gbit ceil 1Gbit burst 125000b cburst 125000b\nclass htb 1:4 parent 1:1 leaf 8004: prio 0 rate 500Kbit ceil 500Kbit burst 1600b cburst 1600b\n" > "$W/cmd/tc class show dev tctl-ifb0"'
LIMITS10="nftfix 1.0.2 summary; $TCIFB"
LIMITS11="nftfix 1.1.6 summary; $TCIFB"
# Sources the fixture lacks: a client of a routed subnet, one this router
# NATs, an inbound flow whose LAN end is the reply source, policy-routed
# (marked) flows, and a dozen unnamed devices for the reverse-DNS cap.
CTADD='ct() { printf "ipv4     2 tcp      6 300 ESTABLISHED src=%s dst=%s sport=40000 dport=%s packets=1 bytes=%s src=%s dst=%s sport=%s dport=40000 packets=1 bytes=%s [ASSURED] mark=%s zone=0 use=2\n" "$@" >> "$W/root/proc/net/nf_conntrack"; }; ct 10.0.5.9 198.18.0.3 443 1000 198.18.0.3 10.0.5.9 443 2000 0; ct 172.30.0.5 8.8.8.8 53 300 8.8.8.8 203.0.113.2 53 400 0; ct 198.51.100.7 203.0.113.2 8443 50 192.168.0.140 198.51.100.7 8443 70 0; ct 192.168.0.140 1.1.1.1 443 5 1.1.1.1 192.168.0.140 443 6 256; ct 192.168.0.140 9.9.9.9 853 7 9.9.9.9 192.168.0.140 853 8 512; ct 192.168.0.140 1.0.0.1 443 9 1.0.0.1 192.168.0.140 443 10 768; for i in 60 61 62 63 64 65 66 67 68 69 70 71; do ct 192.168.0.$i 198.18.0.3 443 1 198.18.0.3 192.168.0.$i 443 1 0; done; printf "1.1.1.1 dev awg3 table 100 src 10.8.0.2 uid 0\n    cache\n" > "$W/cmd/ip route get 1.1.1.1 mark 256"; printf "local 9.9.9.9 dev lo table local src 127.0.0.1\n" > "$W/cmd/ip route get 9.9.9.9 mark 512"; printf "1.0.0.1 via 10.128.28.1 dev wan src 10.128.28.73\n" > "$W/cmd/ip route get 1.0.0.1 mark 768"'
IFROLES='printf "# 9999999999\nawg3 vpn 0 0 0 0 Finland\nwan wan 0 0 0 0 -\n" > "$W/root/tmp/trafficctl_ifroles"'
DSTRESOLV='printf "3.0.18.198.in-addr.arpa\tname = cdn.example.\n" > "$W/cmd/nslookup 198.18.0.3"; printf "1.0.168.192.in-addr.arpa\tname = router.lan.\n" > "$W/cmd/nslookup 192.168.0.1"; printf "x\tname = bad host;rm.\n" > "$W/cmd/nslookup 198.18.0.36"'
WIFI_ALLOW='uci set wireless.default_radio1.macfilter=allow; uci add_list wireless.default_radio1.maclist=02:00:00:00:00:12; uci commit wireless'
NORESOLVE='uci set trafficctl.main.resolve_names=0; uci commit trafficctl'
RDNSC='printf "192.168.0.210 tv.lan 1794229581\n192.168.0.110 - 9999999999\n10.32.55.195 vpn-peer.lan 9999999999\n" >> "$W/root/tmp/trafficctl_rdns_cache"; uci set trafficctl.main.rdns_ttl=x; uci commit trafficctl'
CONNC='printf "192.168.0.104 5G 1794229581\n192.168.0.104 lan3 1794229582\n192.168.0.113 2.4G 1794229583\n" > "$W/root/tmp/trafficctl_conn_cache"'
# netifyd up: the default socket path on both sides (the fixture's explicit
# one is a router path the legacy side would look up as it is).
NETIFY_ON='uci delete trafficctl.main.netify_socket; uci commit trafficctl; mkdir -p "$W/root/var/run/netifyd"; python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "$W/root/var/run/netifyd/netifyd.sock"; printf "[{\"ip\":\"192.168.0.140\",\"top\":\"youtube\",\"apps\":[{\"name\":\"youtube\",\"bytes\":900,\"flows\":2},{\"name\":\"dns\",\"bytes\":80,\"flows\":1}]},{\"ip\":\"192.168.0.109\",\"top\":\"netflix\",\"apps\":[{\"name\":\"netflix\",\"bytes\":12,\"flows\":1}]}]\n" > "$W/root/tmp/trafficctl_netify.json"'
NETIFY_STALE="$NETIFY_ON; touch -d 2020-01-01 \"\$W/root/tmp/trafficctl_netify.json\""
METRICS='uci set trafficctl.metrics.enabled=1; uci commit trafficctl'
MAPPS="$METRICS; $NETIFY_ON; uci set trafficctl.metrics.apps=1; uci commit trafficctl"
MBARE="$METRICS; uci set trafficctl.metrics.state=0; uci set trafficctl.metrics.portfw=0; uci commit trafficctl"
# Recorded agent output: v5 aggregator records, v4 flow records re-emitted
# with growing counters under one digest, junk.
FEED='printf "{\"stats\":[{\"local_ip\":\"192.168.0.140\",\"application_id\":\"10.netify.youtube\",\"download\":700,\"upload\":200},{\"local_ip\":\"192.168.0.140\",\"application_id\":\"5.netify.dns\",\"download\":50,\"upload\":30}]}\n{\"local_ip\":\"192.168.0.109\",\"detected_application_name\":\"netify.netflix\",\"digest\":\"ab\",\"local_bytes\":5,\"other_bytes\":1}\n{\"local_ip\":\"192.168.0.109\",\"detected_application_name\":\"netify.netflix\",\"digest\":\"ab\",\"local_bytes\":10,\"other_bytes\":2}\n{\"local_ip\":\"192.168.0.109\",\"detected_application_name\":\"unknown\",\"detected_protocol_name\":\"Unknown\",\"host_server_name\":\"cdn.ex\$ample.com\",\"total_bytes\":44}\n{\"local_ip\":\"fe80::1\",\"detected_application_name\":\"x\"}\nnot json\n" > "$W/root/tmp/feed"'
NETIFY_LOCKED='mkdir "$W/root/tmp/trafficctl_netify.lock"'
NETIFY_OFF='uci set trafficctl.main.netify_enabled=0; uci commit trafficctl'
SINK='mkdir -p "$W/root/etc/netifyd"; printf "{\n  \"sink_socket\": { \"channels\": { \"x\": { \"bind_address\" : \"tcp://127.0.0.1:1780\" } } }\n}\n" > "$W/root/etc/netifyd/netify-sink-socket.json"'
NETF='tmp/trafficctl_netify.json'
# Limiter, block and shaper readers. live: a router state built by the real
# writers in an OpenWrt rootfs (tools/ci/live-readers.sh capture) with the
# nft and tc of that release; nftfix: one listing of tests/fixtures/nft-src
# as that nft version prints it, text for the legacy side, JSON for the port.
live() {   # live <nft version>
    cp -R "$FIXTURES/nft-$1/live/cmd/." "$W/cmd/"
    cp -R "$FIXTURES/nft-$1/live/root/." "$W/root/"
}
nftfix() {   # nftfix <nft version> <name>
    local d="$FIXTURES/nft-$1"
    if [ -f "$d/$2.tm_ratelimit.json" ]; then
        cp "$d/$2.tm_ratelimit.nft" "$W/cmd/nft list table netdev tm_ratelimit"
        cp "$d/$2.tm_ratelimit.json" "$W/cmd/nft -j list table netdev tm_ratelimit"
    fi
    if [ -f "$d/$2.fw4.json" ]; then
        cp "$d/$2.fw4.nft" "$W/cmd/nft list chain inet fw4 forward"
        cp "$d/$2.fw4.json" "$W/cmd/nft -j list chain inet fw4 forward"
    fi
}
# nft 1.1 lists a per-address meter as "add @set { ... }", which the legacy
# readers took for a shared limit (an intentional fix in the port). For the
# legacy side only, put the listing back into the 1.0 form it recognises.
meterize() {
    sed -i -E 's/ add @(tctl_[du]_[0-9a-z_]+) \{/ meter \1 size 65535 {/' "$W/cmd/nft list table netdev tm_ratelimit"
}
PERSIST='uci set trafficctl.main.persist_rules=1; uci commit trafficctl'
NORDNS='uci set trafficctl.main.resolve_names=0; uci commit trafficctl'
EMPTYRL='printf "table netdev tm_ratelimit {\n}\n" > "$W/cmd/nft list table netdev tm_ratelimit"; printf "{\"nftables\": [{\"metainfo\": {\"version\": \"1.0.2\", \"release_name\": \"Lester Gooch\", \"json_schema_version\": 1}}, {\"table\": {\"family\": \"netdev\", \"name\": \"tm_ratelimit\", \"handle\": 9}}]}\n" > "$W/cmd/nft -j list table netdev tm_ratelimit"'
NOSHAPES='rm -f "$W/root/etc/trafficctl/shapes.json"'
# Records from before the classid was allocated: the minor comes from the
# address (1:3 is 0*256+3), the odd ones are skipped.
OLDSHAPES='printf "[{\"ip\":\"192.168.0.3\",\"rate_kbit\":2000},{\"ip\":\"192.168.0.109\",\"rate_kbit\":1000,\"classid\":\"1:4\"},{\"ip\":\"x\",\"rate_kbit\":5},{\"ip\":\"192.168.0.9\",\"rate_kbit\":-1}]" > "$W/root/etc/trafficctl/shapes.json"'
# A deny list in hostapd's running ACL on one AP, none on the other.
WIFIDENY='uci set wireless.default_radio0.macfilter=deny; uci set wireless.default_radio1.macfilter=deny; uci commit wireless; echo PONG > "$W/cmd/hostapd_cli -i phy0-ap0 ping"; printf "02:00:00:00:00:05\n02:00:00:00:00:06\n" > "$W/cmd/hostapd_cli -i phy0-ap0 deny_acl SHOW"'
WIFIACL='uci set wireless.default_radio0.macfilter=deny; uci set wireless.default_radio1.macfilter=deny; uci commit wireless; for i in phy0-ap0 phy1-ap0; do echo PONG > "$W/cmd/hostapd_cli -i $i ping"; printf "02:00:00:00:00:05\n02:00:00:00:00:06\n02:00:00:00:00:07\n" > "$W/cmd/hostapd_cli -i $i deny_acl SHOW"; done'
WIFIALLOW='uci set wireless.default_radio0.macfilter=allow; uci set wireless.default_radio1.macfilter=deny; uci commit wireless'

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
totals | json-set:ip | router-24.10 | sh:masked legacy_tot | masked tctl totals
totals-all | json-set:ip | router-24.10 | sh:masked legacy_tot --all | masked tctl totals --all
totals-state | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; echo ran | tctl totals >/dev/null; echo ran
totals-fresh | json-set:ip | router-24.10 | sh:masked legacy_tot --all | masked tctl totals --all | rm -f \"\$W/root/$TOTFILE\"
totals-degraded | json-set:ip | router-24.10 | sh:masked legacy_tot --all | masked tctl totals --all | $SWOFFLOAD
totals-forms | json-set:ip | router-24.10 | sh:masked legacy_tot --all | masked tctl totals --all | $TOTSTATE
totals-forms-state | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; echo ran | tctl totals >/dev/null; echo ran | $TOTSTATE
totals-grow | json-set:ip | router-24.10 | sh:legacy_tot >/dev/null; $GROW; masked legacy_tot --all | tctl totals >/dev/null; $GROW; masked tctl totals --all
totals-upgrade | json-set:ip | router-24.10 | sh:legacy_tot >/dev/null; $GROW; masked legacy_tot --all | legacy_tot >/dev/null; $GROW; masked tctl totals --all
totals-upgrade-state | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; $GROW; legacy_tot >/dev/null; echo ran | legacy_tot >/dev/null; $GROW; tctl totals >/dev/null; echo ran
totals-downgrade | json-set:ip | router-24.10 | sh:legacy_tot >/dev/null; $GROW; masked legacy_tot --all | tctl totals >/dev/null; $GROW; masked legacy_tot --all
totals-downgrade-state | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; $GROW; legacy_tot >/dev/null; echo ran | tctl totals >/dev/null; $GROW; legacy_tot >/dev/null; echo ran
totals-stale-lock | text-sorted+$TOTFILE | router-24.10 | sh:legacy_tot >/dev/null; [ -d \"\$W/root/tmp/trafficctl_totals.lock.d\" ] && echo held; echo ran | tctl totals >/dev/null; [ -d \"\$W/root/tmp/trafficctl_totals.lock.d\" ] && echo held; echo ran | mkdir \"\$W/root/tmp/trafficctl_totals.lock.d\"
summary | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3
summary-routed | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3 | $ROUTED
summary-names | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3 | $NAMES; $RDNSC; $CONNC
summary-noresolve | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3 | $NAMES; $RDNSC; $NORESOLVE
summary-limits-1.0 | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3 | $LIMITS10; $WIFI_ALLOW
summary-limits-1.1 | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3 | $LIMITS11; $WIFI_ALLOW
summary-sources | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3 | $ROUTED; $CTADD
summary-no-offload | text | router-24.10 | trafficctl-summary.sh | tctl summary | $NOOFFLOAD
summary-degraded | text | router-24.10 | trafficctl-summary.sh | tctl summary | $SWOFFLOAD
summary-netify | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3 | $NETIFY_ON
summary-netify-stale | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3 | $NETIFY_STALE
summary-netify-off | text+$SPAWNF | router-24.10 | trafficctl-summary.sh; sleep 0.3 | tctl summary; sleep 0.3 | $NETIFY_STALE; $NETIFY_OFF
summary-empty | text+$SPAWNF | router-24.10 | trafficctl-summary.sh | tctl summary | : > \"\$W/root/proc/net/nf_conntrack\"
device | text+tmp/trafficctl_conn_cache | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.140 | rmask tctl device 192.168.0.140
device-tcp | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" --proto tcp 192.168.0.109 | rmask tctl device --proto tcp 192.168.0.109
device-udp | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.210 --proto udp | rmask tctl device 192.168.0.210 --proto udp
device-rdns | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.101 --rdns | rmask tctl device 192.168.0.101 --rdns | $RESOLV; $NAMES
device-limits-1.0 | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.140 | rmask tctl device 192.168.0.140 | $LIMITS10; $WIFI_ALLOW
device-limits-1.1 | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.140 | rmask tctl device 192.168.0.140 | $LIMITS11; $WIFI_ALLOW
device-v6-block-1.0 | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.109 | rmask tctl device 192.168.0.109 | $LIMITS10
device-v6-block-1.1 | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.109 | rmask tctl device 192.168.0.109 | $LIMITS11
device-routed | text+tmp/trafficctl_conn_cache | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 10.32.55.195 | rmask tctl device 10.32.55.195 | $ROUTED; $RDNSC
device-offline | text+tmp/trafficctl_conn_cache | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.104 | rmask tctl device 192.168.0.104 | $CONNC
device-wifi | text+tmp/trafficctl_conn_cache | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.102 | rmask tctl device 192.168.0.102
device-oif | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.140 | rmask tctl device 192.168.0.140 | $CTADD; $IFROLES
device-oif-noroles | text+tmp/trafficctl_ifroles | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.140 | rmask tctl device 192.168.0.140 | $CTADD
device-rdns-dst | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.140 --rdns | rmask tctl device 192.168.0.140 --rdns | $DSTRESOLV
device-routed-sub | text+tmp/trafficctl_conn_cache | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 10.0.5.9 | rmask tctl device 10.0.5.9 | $ROUTED; $CTADD
device-bad | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" 192.168.0.300 | rmask tctl device 192.168.0.300
device-none | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-device.sh\" --rdns | rmask tctl device --rdns
metrics-off | text | router-24.10 | trafficctl-metrics.sh | tctl metrics
metrics | text-sorted+$SPAWNF,$TOTFILE | router-24.10 | trafficctl-metrics.sh; sleep 0.3 | tctl metrics; sleep 0.3 | $METRICS
metrics-limits-1.0 | text-sorted | router-24.10 | trafficctl-metrics.sh | tctl metrics | $METRICS; $LIMITS10; $NAMES; $RDNSC
metrics-limits-1.1 | text-sorted | router-24.10 | trafficctl-metrics.sh | tctl metrics | $METRICS; $LIMITS11; $NAMES; $RDNSC
metrics-sources-1.0 | text-sorted+$TOTFILE | router-24.10 | trafficctl-metrics.sh | tctl metrics | $METRICS; $ROUTED; $CTADD; $LIMITS10
metrics-sources-1.1 | text-sorted+$TOTFILE | router-24.10 | trafficctl-metrics.sh | tctl metrics | $METRICS; $ROUTED; $CTADD; $LIMITS11
metrics-apps | text-sorted | router-24.10 | trafficctl-metrics.sh | tctl metrics | $MAPPS
metrics-bare | text-sorted | router-24.10 | trafficctl-metrics.sh | tctl metrics | $MBARE
netify-status | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-netify.sh\" status | rmask tctl netify status
netify-status-on | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-netify.sh\" status | rmask tctl netify status | $NETIFY_ON
netify-status-sink | text | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-netify.sh\" status | rmask tctl netify status | $SINK
netify-list | text | router-24.10 | trafficctl-netify.sh list | tctl netify list | $NETIFY_ON
netify-list-none | text | router-24.10 | trafficctl-netify.sh list | tctl netify list
netify-collect | text+$NETF | router-24.10 | trafficctl-netify.sh collect | tctl netify collect | $FEED
netify-collect-0 | text+$NETF | router-24.10 | trafficctl-netify.sh collect 0 | tctl netify collect 0 | $FEED
netify-collect-007 | text+$NETF | router-24.10 | trafficctl-netify.sh collect 007 | tctl netify collect 007 | $FEED
netify-collect-99 | text+$NETF | router-24.10 | trafficctl-netify.sh collect 99 | tctl netify collect 99 | $FEED
netify-collect-off | text+$NETF | router-24.10 | trafficctl-netify.sh collect | tctl netify collect | $FEED; $NETIFY_OFF
netify-collect-locked | text+$NETF | router-24.10 | trafficctl-netify.sh collect | tctl netify collect | $FEED; $NETIFY_LOCKED
netify-collect-nodata | text+$NETF | router-24.10 | trafficctl-netify.sh collect 1 | tctl netify collect 1
netify-raw | text | router-24.10 | trafficctl-netify.sh raw 5 | tctl netify raw 5 | $FEED
netify-usage | text | router-24.10 | sh:sh \"\$LEXEC/trafficctl-netify.sh\" bogus; echo rc=\$? | tctl netify bogus; echo rc=\$?
ratelimit-stats-none | json | router-24.10 | trafficctl-ratelimit-stats.sh | tctl ratelimit-stats
ratelimit-stats-empty | json | router-24.10 | trafficctl-ratelimit-stats.sh | tctl ratelimit-stats | $EMPTYRL
ratelimit-stats-live-1.0 | json | router-24.10 | trafficctl-ratelimit-stats.sh | tctl ratelimit-stats | live 1.0.2
ratelimit-stats-live-1.1 | json | router-24.10 | sh:meterize; sh \"\$LEXEC/trafficctl-ratelimit-stats.sh\" | tctl ratelimit-stats | live 1.1.6
ratelimit-stats-rl-1.0 | json | router-24.10 | trafficctl-ratelimit-stats.sh | tctl ratelimit-stats | nftfix 1.0.2 rl
ratelimit-stats-rl-1.1 | json | router-24.10 | sh:meterize; sh \"\$LEXEC/trafficctl-ratelimit-stats.sh\" | tctl ratelimit-stats | nftfix 1.1.6 rl
ratelimit-stats-subnet-1.0 | json | router-24.10 | trafficctl-ratelimit-stats.sh | tctl ratelimit-stats | nftfix 1.0.2 subnet
ratelimit-stats-subnet-1.1 | json | router-24.10 | sh:meterize; sh \"\$LEXEC/trafficctl-ratelimit-stats.sh\" | tctl ratelimit-stats | nftfix 1.1.6 subnet
ratelimit-stats-args | json | router-24.10 | trafficctl-ratelimit-stats.sh x y | tctl ratelimit-stats x y | live 1.0.2
shape-stats | json | router-24.10 | trafficctl-shape-stats.sh | tctl shape-stats
shape-stats-none | json | router-24.10 | trafficctl-shape-stats.sh | tctl shape-stats | $NOSHAPES
shape-stats-old-records | json | router-24.10 | trafficctl-shape-stats.sh | tctl shape-stats | $OLDSHAPES
shape-stats-live-1.0 | json | router-24.10 | trafficctl-shape-stats.sh | tctl shape-stats | live 1.0.2
shape-stats-live-1.1 | json | router-24.10 | trafficctl-shape-stats.sh | tctl shape-stats | live 1.1.6
rules | json | router-24.10 | trafficctl-rules.sh | tctl rules
rules-list | json | router-24.10 | trafficctl-rules.sh list | tctl rules list
rules-bad-arg | text | router-24.10 | trafficctl-rules.sh bogus; echo \"rc=\$?\" | tctl rules bogus; echo \"rc=\$?\"
rules-persist | json | router-24.10 | trafficctl-rules.sh | tctl rules | $PERSIST
rules-no-rdns | json | router-24.10 | trafficctl-rules.sh | tctl rules | $NORDNS
rules-old-shapes | json | router-24.10 | trafficctl-rules.sh | tctl rules | $OLDSHAPES
rules-wifi-deny | json | router-24.10 | trafficctl-rules.sh | tctl rules | $WIFIDENY
rules-wifi-acl | json | router-24.10 | trafficctl-rules.sh | tctl rules | $WIFIACL
rules-wifi-allow | json | router-24.10 | trafficctl-rules.sh | tctl rules | $WIFIALLOW
rules-live-1.0 | json | router-24.10 | trafficctl-rules.sh | tctl rules | live 1.0.2; $PERSIST
rules-live-1.0-transient | json | router-24.10 | trafficctl-rules.sh | tctl rules | live 1.0.2
rules-live-1.1 | json | router-24.10 | sh:meterize; sh \"\$LEXEC/trafficctl-rules.sh\" | tctl rules | live 1.1.6; $PERSIST
rules-nft-1.0 | json | router-24.10 | trafficctl-rules.sh | tctl rules | nftfix 1.0.2 rules; $PERSIST
rules-nft-1.1 | json | router-24.10 | sh:meterize; sh \"\$LEXEC/trafficctl-rules.sh\" | tctl rules | nftfix 1.1.6 rules; $PERSIST
rules-subnet-1.0 | json | router-24.10 | trafficctl-rules.sh | tctl rules | nftfix 1.0.2 subnet
rules-subnet-1.1 | json | router-24.10 | sh:meterize; sh \"\$LEXEC/trafficctl-rules.sh\" | tctl rules | nftfix 1.1.6 subnet
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
        -e "s|\"/usr/libexec/trafficctl\"|\"$2\"|g" \
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
        -e "s|/sys/kernel/debug/ecm|$W/root/sys/kernel/debug/ecm|g" \
        -e "s|/var/run/netifyd/|$W/root/var/run/netifyd/|g" \
        -e "s|/etc/netifyd/|$W/root/etc/netifyd/|g" {} +
}
# The summary's detached refreshes, as the spawn log records the port's.
sed -i -e "s|/usr/libexec/trafficctl/trafficctl-rdns-refresh\.sh|$W/bin/spawn rdns-refresh|" \
    -e "s|/usr/libexec/trafficctl/trafficctl-netify\.sh collect|$W/bin/spawn netify collect|" \
    "$LEXEC/trafficctl-summary.sh"
grep -q "$W/bin/spawn netify collect" "$LEXEC/trafficctl-summary.sh" ||
    { echo "FAIL: the legacy summary's spawns were not redirected"; exit 1; }
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
for c in ip nft tc iw brctl conntrack nslookup hostapd_cli; do ln -sf replay "$W/bin/$c"; done
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
cat > "$W/bin/spawn" <<EOF
#!/bin/sh
echo "\$*" >> "$W/root/tmp/spawn.log"
EOF
chmod +x "$W/bin/"*
# A recorded agent feed, read by both netify sides when a case writes it.
export TCTL_NETIFY_FEED="$W/root/tmp/feed"

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
# The new side's root: the CLI the reports spawn (the spawn log), and the
# current scripts the ported code still runs, rewritten like the legacy ones.
cli_root() {
    mkdir -p "$W/root/usr/sbin" "$W/root/usr/libexec"
    ln -sfn "$CEXEC" "$W/root/usr/libexec/trafficctl"
    ln -sf "$W/bin/spawn" "$W/root/usr/sbin/trafficctl"
}
# A report as compact JSON in its own key order, then its exit status: the
# clock (device timestamp, netify cache_age) and the root prefix masked.
rmask() {
    local rc
    "$@" > "$W/masked.json"; rc=$?
    jq -c --arg r "$W/root" 'walk(if type == "string" then (split($r) | join("")) else . end)
        | if type == "object" then
            (if has("timestamp") then .timestamp = 0 else . end)
            | (if has("cache_age") then .cache_age = (.cache_age >= 0) else . end)
          else . end' "$W/masked.json" 2>/dev/null || cat "$W/masked.json"
    echo "rc=$rc"
}
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
    # EQUIV_ONLY=<ERE> runs the matching cases only, for a look by hand.
    [ -z "${EQUIV_ONLY:-}" ] || [[ "$name" =~ $EQUIV_ONLY ]] || continue
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
    cli_root
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
#            compared on what it hands on. The ucode side reaches the stubs
#            through the real CLI for the commands it still passes to a
#            script; a command the CLI has ported goes to the stub of the
#            script it replaced, with the plugin's arguments and environment
#            (the port itself is compared in the CLI cases above).
#            real: the legacy scripts themselves
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

# The CLI's ported commands: the keys of its `commands` table.
PORTED=$(awk '/^const commands = \{/ { f = 1; next } f && /^\};/ { f = 0 }
    f && match($0, /^\t'"'"'?[a-z-]+'"'"'?: /) { c = substr($0, 2, RLENGTH - 3); gsub(/'"'"'/, "", c); print c }' \
    "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" | tr '\n' ' ')
case " $PORTED " in *" totals "*) ;; *) echo "FAIL: no ported commands found in the CLI ($PORTED)"; exit 1 ;; esac
for c in $PORTED; do
    [ -e "$STUBS/trafficctl-$c.sh" ] || { echo "FAIL: ported command $c has no legacy script to stub"; exit 1; }
done

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
ifaces-stub | json+$LOGF | stub | ifaces | {}
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
subnets-stub | json+$LOGF | stub | subnets | {}
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
rdns-stub | json+$LOGF | stub | rdns | {\"ip\":\"192.168.0.101; reboot\"}
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
        {
            echo '#!/bin/sh'
            if [ "$2" = stub ]; then
                printf 'case "$1" in\n'
                for c in $PORTED; do
                    printf '%s) c=$1; shift; exec "%s/trafficctl-$c.sh" "$@" ;;\n' "$c" "$STUBS"
                done
                printf 'esac\n'
            fi
            printf 'POSIXLY_CORRECT=1 exec "%s" -S -L "%s" "%s" "$@"\n' "$UCODE" "$UC_LIB" \
                "$UC_REPO/trafficctl/files/usr/sbin/trafficctl"
        } > "$W/root/usr/sbin/trafficctl"
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
    [ -z "${EQUIV_ONLY:-}" ] || [[ "rpcd-$name" =~ $EQUIV_ONLY ]] || continue
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
