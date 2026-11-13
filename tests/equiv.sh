#!/bin/bash
# Equivalence harness: the released shell backend (v1.30.0, from git) and its
# ucode port run against the same fixture, and their outputs must match.
#
# A fixture is a directory under tests/fixtures/ (see tools/capture-fixtures.sh):
#   root/  becomes TCTL_ROOT; the legacy scripts get their paths rewritten to it
#   cmd/   replayed by PATH mocks for ip, nft, tc, iw, brctl, conntrack, nslookup,
#          hostapd_cli
#   ubus/  served by tests/lib/ubus-mock.uc on a private ubusd
# The writers (block, unblock, the WiFi deny, restore) meet a stateful
# `inet fw4 forward` instead (tests/lib/nft-fw4.uc) when the case's setup
# creates root/tmp/nft.state, the limiter a stateful `netdev tm_ratelimit`
# (tests/lib/nft-netdev.sh, its NFT_FAIL_* knobs included) when it creates
# the directory root/tmp/nft-netdev, and a command with no recording succeeds
# when cmd/<command>.default exists; every write lands in root/tmp/writes.log.
#
# The limiter is compared with v1.30.6 ($LEGACY5_TAG), not v1.30.0:
# v1.30.5 fixed it (#154: a meter per chain, partial success reported, the
# sets the rules name removed, the restore replacing a live limit), and #161
# stopped a removal from lifting other targets' limits that carry a caller's
# label from before v1.13.2. The port starts from there.
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
LEGACY5_TAG=v1.30.6
FIXTURES="$UC_REPO/tests/fixtures"
W="$UC_TMP/work"
L="$UC_TMP/legacy"
L5="$UC_TMP/legacy5"
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
    sed -i -E 's/ add @(tctl_(m|[du])_[0-9a-z_]+) \{/ meter \1 size 65535 {/' "$W/cmd/nft list table netdev tm_ratelimit"
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

# ── notifications ──
# telegram-test: the request curl got, and Telegram refusing it. Not
# {{wan_ip}}: v1.30.0's jsonfilter expression for it ('@.ipv4-address...') is
# a syntax error, so it always fell back to the route's source address; the
# port reads the WAN interface (tests/test_notify.sh). Not the clock tags.
CURLF='tmp/curl.log'
CURLERR='echo "{\\"ok\\":false,\\"error_code\\":400,\\"description\\":\\"Bad Request: chat not found\\"}" > "$W/root/tmp/curl.reply"'
# ── end notifications ──
# ── the writers ─────────────────────────────────────────────────────────────
# A stateful fw4 forward chain; conntrack flushes succeed unrecorded. Both
# sides log to the root (the later sed of log_file then finds nothing left).
LOGROOT='sed -i "s#'"'"'/tmp/trafficctl/#'"'"'$W/root/tmp/trafficctl/#" "$W/root/etc/config/trafficctl"'
FW4="$LOGROOT; printf '{\"next\":20,\"rules\":[]}' > \"\$W/root/tmp/nft.state\"; : > \"\$W/cmd/conntrack.default\""
# What the writers leave: the writes in order, the saved rules, both logs.
WR='tmp/writes.log,etc/trafficctl/rules.json,tmp/trafficctl/activity.log,tmp/logger.log'
CHAIN='nft -a list chain inet fw4 forward'
# Setup done: what it wrote is not part of either side's result.
FORGET='rm -f "$W/root/tmp/writes.log" "$W/root/tmp/logger.log" "$W/root/tmp/trafficctl/activity.log"'
RIP='printf "2: br-lan: <UP>\n    inet 192.168.0.1/24 brd 192.168.0.255 scope global br-lan\n" > "$W/cmd/ip -4 addr show dev br-lan"'
NSSON='mkdir -p "$W/root/sys/kernel/debug/ecm/ecm_db"; : > "$W/root/sys/kernel/debug/ecm/ecm_db/defunct_all"'
# Blocks placed by v1.30.0 itself, saved with persist on.
OLDBLK="$FW4; $PERSIST; sh \"\$LEXEC/trafficctl-block.sh\" 192.168.0.109 >/dev/null; sh \"\$LEXEC/trafficctl-block.sh\" 192.168.0.10 'kids tablet' >/dev/null; $FORGET"
# Comments from before v1.13.2: the caller's label, not the address. One
# label per device: with a shared one the shell's unblock also removed the
# other device's rule, which the port no longer does (tests/test_block.sh).
TGBLK="$FW4; nft insert rule inet fw4 forward ip saddr 192.168.0.109 counter drop comment '\"tctl_block_tg\"'; nft insert rule inet fw4 forward ip saddr 192.168.0.10 counter drop comment '\"tctl_block_kids\"'; $FORGET"
OLDLBL="$FW4; nft insert rule inet fw4 forward ip saddr 192.168.0.109 counter drop comment '\"tctl_block_block_192.168.0.109\"'; $FORGET"
# rules.json as v1.30.0 wrote it, the kernel empty again (a reboot).
REBOOT="$OLDBLK; printf '{\"next\":40,\"rules\":[]}' > \"\$W/root/tmp/nft.state\"; rm -f \"\$W/root/etc/trafficctl/shapes.json\""
LHOOK='ACTION=ifup INTERFACE=lan sh "$L/trafficctl/files/etc/hotplug.d/iface/99-trafficctl-shapes"'
# The WiFi deny: deny lists on both APs, hostapd_cli alive on both, its
# writes answered OK.
NEIGH="for a in 192.168.0.109 192.168.0.102 192.168.0.140; do grep \"^\$a \" \"\$W/cmd/ip neigh show\" > \"\$W/cmd/ip neigh show \$a\"; done"
MF="$FW4; $NEIGH; uci set wireless.default_radio0.macfilter=deny; uci set wireless.default_radio1.macfilter=deny; uci commit wireless; for i in phy0-ap0 phy1-ap0; do echo PONG > \"\$W/cmd/hostapd_cli -i \$i ping\"; : > \"\$W/cmd/hostapd_cli -i \$i deny_acl SHOW\"; done; echo OK > \"\$W/cmd/hostapd_cli.default\""
MFDEAD="$FW4; $NEIGH; uci set wireless.default_radio0.macfilter=deny; uci commit wireless"
MFW="$WR,etc/config/wireless"
# New devices: the default limit on, a ledger, and what the limit lands on: a
# stateful netdev table and tc (st_init, below). The legacy side is the
# v1.30.6 hook with the v1.30.6 limiter and shaper it runs; the port applies
# the limit in process (limit.uc, shape.uc), so the two are compared on the
# writes, the saved state and the logs, not on which script was called. Not
# the bot's flag file /tmp/trafficctl_tg_newdev: the port hands an unknown
# MAC to `trafficctl notify dhcp` instead (tests/test_newdevice.sh).
ND="$LOGROOT; uci set trafficctl.newdevice.enabled=1; uci set trafficctl.newdevice.limit_kbit=4000; uci commit trafficctl; mkdir -p \"\$W/root/etc/trafficctl\" \"\$W/root/tmp/nft-netdev\"; printf '02:00:00:00:00:12\n02:00:00:00:00:08\n' > \"\$W/root/etc/trafficctl/seen_macs\"; st_init; : > \"\$W/cmd/conntrack.default\""
NDF='tmp/writes.log,etc/trafficctl/seen_macs,tmp/trafficctl/activity.log,tmp/logger.log,etc/trafficctl/rules.json,etc/trafficctl/shapes.json'
LND='sh "$L5/trafficctl/files/etc/hotplug.d/dhcp/99-trafficctl-newdevice"; echo done'
NND='tctl newdevice; echo done'
NEWMAC='ACTION=add MACADDR=02:00:00:00:00:99 IPADDR=192.168.0.99 HOSTNAME=newbie'

# The limiter: an empty netdev table, conntrack flushes answered, both logs in
# the root. RLW adds the table as each side leaves it.
RL="$LOGROOT; mkdir -p \"\$W/root/tmp/nft-netdev\"; : > \"\$W/cmd/conntrack.default\"; rm -f \"\$W/root/etc/trafficctl/shapes.json\""
RLW="$WR"
RLT='nft -a list table netdev tm_ratelimit'
# A limit placed by the shell limiter itself.
RLOLD="$RL; $PERSIST; sh \"\$L5EXEC/trafficctl-ratelimit.sh\" 192.168.0.109 5000 >/dev/null; sh \"\$L5EXEC/trafficctl-ratelimit.sh\" 192.168.0.0/24 2000 '' each >/dev/null; $FORGET"
# The same, placed on nftables 1.1 (each meter a named set).
RLOLD11="$RL; $PERSIST; NFT_EMU=1.1 sh \"\$L5EXEC/trafficctl-ratelimit.sh\" 192.168.0.109 5000 >/dev/null; NFT_EMU=1.1 sh \"\$L5EXEC/trafficctl-ratelimit.sh\" 192.168.0.0/24 2000 '' each >/dev/null; $FORGET"
# Its rules.json after a reboot: the netdev table gone.
RLBOOT="$RLOLD; rm -rf \"\$W/root/tmp/nft-netdev\"; mkdir -p \"\$W/root/tmp/nft-netdev\"; rm -f \"\$W/root/etc/trafficctl/shapes.json\""
L5RL='sh "$L5EXEC/trafficctl-ratelimit.sh"'
# Limits from before v1.13.2, commented after the caller's label: two hosts
# and two subnets (each mode, a meter per target) from the bot, label tg, and
# a tg rule naming 192.168.0.109 in the other direction.
rlchain() { printf "nft add chain netdev tm_ratelimit %s '{ type filter hook %s device %s priority %s; }'" "$@"; }
rlrule() { printf "nft add rule netdev tm_ratelimit %s '%s counter drop comment \"%s\"'" "$@"; }
RATE='limit rate over 625000 bytes/second'
RLLEG="$RL; $(rlchain dl_br_lan egress br-lan 0); $(rlchain ul_lan2 ingress lan2 -200)"
for t in 192.168.0.109 192.168.0.110; do
    RLLEG="$RLLEG; $(rlrule dl_br_lan "ip daddr $t $RATE" rl_ratelimit_tg); $(rlrule ul_lan2 "ip saddr $t $RATE" rl_ratelimit_tg_ul)"
done
RLLEG="$RLLEG; $(rlrule ul_lan2 "ip daddr 192.168.0.109 $RATE" rl_ratelimit_tg_ul)"
for t in 10.0.20.0/24 10.0.30.0/24; do
    m=$(printf '%s' "$t" | tr './' '__')
    RLLEG="$RLLEG; $(rlrule dl_br_lan "ip daddr $t meter tctl_d_$m { ip daddr $RATE }" rl_ratelimit_tg)"
done
L5HOOK='ACTION=ifup INTERFACE=lan sh "$L5/trafficctl/files/etc/hotplug.d/iface/99-trafficctl-shapes"'
# Saved limits for targets that also have rules from before v1.13.2 live:
# those are not the restore's, and stay.
RLLEGREC="$RLLEG; $PERSIST; printf '[{\"type\":\"ratelimit\",\"ip\":\"192.168.0.109\",\"param\":\"4000\"},{\"type\":\"ratelimit\",\"ip\":\"10.0.20.0/24\",\"param\":\"3000\",\"mode\":\"each\"}]' > \"\$W/root/etc/trafficctl/rules.json\"; $FORGET"

# The shaper: a stateful tc and `ip link` (tests/lib/tc-htb.sh, st_init) on
# the fixture's devices, its shapes.json as captured (1:3, 1:4 and 1:5 taken).
# stt prints what tc holds afterwards. sttnf leaves the u32 filters out, for
# the cases with more than one shape: v1.30.x deleted filters by prio, so
# each shape it added removed the filters of the ones before it, and only the
# last stayed in force; the port deletes a filter by its handle.
STSET="$LOGROOT; st_init; : > \"\$W/cmd/conntrack.default\""
STW="$WR,etc/trafficctl/shapes.json"
L5SH='sh "$L5EXEC/trafficctl-shape.sh"'
# A shape v1.30.6 placed itself.
STON="$STSET; sh \"\$L5EXEC/trafficctl-shape.sh\" add 192.168.0.109 5000 >/dev/null; $FORGET"
STNOPERSIST='uci set trafficctl.main.persist_rules=0; uci commit trafficctl'
# OLDSHAPES less its negative rate: v1.30.6's restore handed that record to
# trafficctl-shape.sh, which refused it with exit 0, so no failure was logged;
# the port logs it as not restored, and its exit status says a record failed
# (tests/test_shape.sh).
OLDSHAPES5='printf "[{\"ip\":\"192.168.0.3\",\"rate_kbit\":2000},{\"ip\":\"192.168.0.109\",\"rate_kbit\":1000,\"classid\":\"1:4\"},{\"ip\":\"x\",\"rate_kbit\":5}]" > "$W/root/etc/trafficctl/shapes.json"'

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
tg-test-default | text+$CURLF | router-24.10 | trafficctl-telegram-test.sh 777:ABC 4242 | tctl telegram-test 777:ABC 4242
tg-test-env | text+$CURLF | router-24.10 | sh:TCTL_TG_TOKEN=777:ABC sh \"\$LEXEC/trafficctl-telegram-test.sh\" - -100123 | TCTL_TG_TOKEN=777:ABC tctl telegram-test - -100123
tg-test-template | text+$CURLF | router-24.10 | sh:sh \"\$LEXEC/trafficctl-telegram-test.sh\" 777:ABC 4242 '<b>{{name}}</b> {{ ip }}\\n{{mac}} {{link}} on {{router}} {{ssid}} {{signal}} {{freq}} {{iface}} {{clients}} {{conns}} {{nope}} \"q\"' | tctl telegram-test 777:ABC 4242 '<b>{{name}}</b> {{ ip }}\\n{{mac}} {{link}} on {{router}} {{ssid}} {{signal}} {{freq}} {{iface}} {{clients}} {{conns}} {{nope}} \"q\"'
tg-test-api-error | text+$CURLF | router-24.10 | trafficctl-telegram-test.sh 777:ABC 4242 | tctl telegram-test 777:ABC 4242 | $CURLERR
tg-test-garbage | text+$CURLF | router-24.10 | trafficctl-telegram-test.sh 777:ABC 4242 | tctl telegram-test 777:ABC 4242 | echo 'not json' > \"\$W/root/tmp/curl.reply\"
tg-test-no-chat | text+$CURLF | router-24.10 | trafficctl-telegram-test.sh 777:ABC | tctl telegram-test 777:ABC
tg-test-no-token | text+$CURLF | router-24.10 | trafficctl-telegram-test.sh '' 4242 | tctl telegram-test '' 4242
tg-test-chat-nan | text+$CURLF | router-24.10 | trafficctl-telegram-test.sh 777:ABC 42a | tctl telegram-test 777:ABC 42a
tg-test-bad-token | text+$CURLF | router-24.10 | trafficctl-telegram-test.sh 777-ABC 4242 | tctl telegram-test 777-ABC 4242
block | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.109; echo rc=\$?; $CHAIN | tctl block 192.168.0.109; echo rc=\$?; $CHAIN | $FW4
block-lease-mac | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.102; echo rc=\$?; $CHAIN | tctl block 192.168.0.102; echo rc=\$?; $CHAIN | $FW4
block-no-mac | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.9; echo rc=\$?; $CHAIN | tctl block 192.168.0.9; echo rc=\$?; $CHAIN | $FW4
block-nexthop | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.200; echo rc=\$?; $CHAIN | tctl block 192.168.0.200; echo rc=\$?; $CHAIN | $FW4; $ROUTED
block-persist | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.109 'my label'; echo rc=\$?; $CHAIN | tctl block 192.168.0.109 'my label'; echo rc=\$?; $CHAIN | $FW4; $PERSIST
block-already | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.109; echo rc=\$?; $CHAIN | tctl block 192.168.0.109; echo rc=\$?; $CHAIN | $OLDBLK
block-tg-label | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.109; echo rc=\$?; $CHAIN | tctl block 192.168.0.109; echo rc=\$?; $CHAIN | $TGBLK
block-self | text+$WR | router-24.10 | sh:TCTL_SRC=192.168.0.109 sh \"\$LEXEC/trafficctl-block.sh\" 192.168.0.109; echo rc=\$? | TCTL_SRC=192.168.0.109 tctl block 192.168.0.109; echo rc=\$? | $FW4
block-router | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.1; echo rc=\$?; $CHAIN | tctl block 192.168.0.1; echo rc=\$?; $CHAIN | $FW4; $RIP
block-bad | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.300; echo rc=\$? | tctl block 192.168.0.300; echo rc=\$? | $FW4
block-usage | text | router-24.10 | trafficctl-block.sh; echo rc=\$? | tctl block; echo rc=\$? | $FW4
block-nss | text+$WR,sys/kernel/debug/ecm/ecm_db/defunct_all | router-24.10 | sh:rmask sh \"\$LEXEC/trafficctl-block.sh\" 192.168.0.109 | rmask tctl block 192.168.0.109 | $FW4; $NSSON
block-nft-fails | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.109; echo rc=\$? | tctl block 192.168.0.109; echo rc=\$? | : > \"\$W/cmd/conntrack.default\"
unblock | text+$WR | router-24.10 | trafficctl-unblock.sh 192.168.0.109; echo rc=\$?; $CHAIN | tctl unblock 192.168.0.109; echo rc=\$?; $CHAIN | $OLDBLK
unblock-label | text+$WR | router-24.10 | trafficctl-unblock.sh 192.168.0.10 'kids tablet'; echo rc=\$?; $CHAIN | tctl unblock 192.168.0.10 'kids tablet'; echo rc=\$?; $CHAIN | $OLDBLK
unblock-tg-label | text+$WR | router-24.10 | trafficctl-unblock.sh 192.168.0.109 tg; echo rc=\$?; $CHAIN | tctl unblock 192.168.0.109 tg; echo rc=\$?; $CHAIN | $TGBLK
unblock-v1.13.1 | text+$WR | router-24.10 | trafficctl-unblock.sh 192.168.0.109; echo rc=\$?; $CHAIN | tctl unblock 192.168.0.109; echo rc=\$?; $CHAIN | $OLDLBL
unblock-none | text+$WR | router-24.10 | trafficctl-unblock.sh 192.168.0.109; echo rc=\$?; $CHAIN | tctl unblock 192.168.0.109; echo rc=\$?; $CHAIN | $FW4
unblock-bad | text | router-24.10 | trafficctl-unblock.sh 192.168.0.300; echo rc=\$? | tctl unblock 192.168.0.300; echo rc=\$? | $FW4
unblock-by-v1.30 | text+$WR | router-24.10 | trafficctl-block.sh 192.168.0.109 >/dev/null; sh \"\$LEXEC/trafficctl-unblock.sh\" 192.168.0.109; echo rc=\$?; $CHAIN | tctl block 192.168.0.109 >/dev/null; sh \"\$LEXEC/trafficctl-unblock.sh\" 192.168.0.109; echo rc=\$?; $CHAIN | $FW4; $PERSIST
restore | text+$WR | router-24.10 | sh:$LHOOK; echo rc=\$?; $CHAIN | tctl restore >/dev/null; echo rc=\$?; $CHAIN | $REBOOT
restore-persist-off | text+$WR | router-24.10 | sh:$LHOOK; echo rc=\$?; $CHAIN | tctl restore >/dev/null; echo rc=\$?; $CHAIN | $REBOOT; uci set trafficctl.main.persist_rules=0; uci commit trafficctl
macfilter-add | text+$MFW | router-24.10 | trafficctl-macfilter-add.sh 192.168.0.140; echo rc=\$? | tctl macfilter-add 192.168.0.140; echo rc=\$? | $MF
macfilter-add-acl | text+$MFW | router-24.10 | trafficctl-macfilter-add.sh 192.168.0.140; echo rc=\$? | tctl macfilter-add 192.168.0.140; echo rc=\$? | $MF; for i in phy0-ap0 phy1-ap0; do echo 02:00:00:00:00:12 > \"\$W/cmd/hostapd_cli -i \$i deny_acl SHOW\"; done
macfilter-add-lease | text+$MFW | router-24.10 | trafficctl-macfilter-add.sh 192.168.0.102; echo rc=\$? | tctl macfilter-add 192.168.0.102; echo rc=\$? | $MF
macfilter-add-unknown | text+$MFW | router-24.10 | trafficctl-macfilter-add.sh 192.168.0.9; echo rc=\$? | tctl macfilter-add 192.168.0.9; echo rc=\$? | $MF
macfilter-add-bad | text | router-24.10 | trafficctl-macfilter-add.sh 192.168.0.300; echo rc=\$? | tctl macfilter-add 192.168.0.300; echo rc=\$? | $MF
macfilter-add-no-cli | text+$MFW | router-24.10 | trafficctl-macfilter-add.sh 192.168.0.109; echo rc=\$? | tctl macfilter-add 192.168.0.109; echo rc=\$? | $MFDEAD
macfilter-remove | text+$MFW | router-24.10 | trafficctl-macfilter-remove.sh 192.168.0.109; echo rc=\$? | tctl macfilter-remove 192.168.0.109; echo rc=\$? | $MF; uci add_list wireless.default_radio0.maclist=02:00:00:00:00:08; uci commit wireless
macfilter-remove-mac | text+$MFW | router-24.10 | trafficctl-macfilter-remove.sh 02:00:00:00:00:08; echo rc=\$? | tctl macfilter-remove 02:00:00:00:00:08; echo rc=\$? | $MF; uci add_list wireless.default_radio1.maclist=02:00:00:00:00:08; uci commit wireless
macfilter-remove-bad | text | router-24.10 | trafficctl-macfilter-remove.sh nonsense; echo rc=\$? | tctl macfilter-remove nonsense; echo rc=\$? | $MF
newdevice | text+$NDF | router-24.10 | sh:$NEWMAC; export ACTION MACADDR IPADDR HOSTNAME; $LND | $NEWMAC; export ACTION MACADDR IPADDR HOSTNAME; $NND | $ND
newdevice-shaper | text+$NDF | router-24.10 | sh:$NEWMAC; export ACTION MACADDR IPADDR HOSTNAME; $LND | $NEWMAC; export ACTION MACADDR IPADDR HOSTNAME; $NND | $ND; uci set trafficctl.newdevice.limit_mode=shaper; uci commit trafficctl
newdevice-known | text+$NDF | router-24.10 | sh:ACTION=add MACADDR=02:00:00:00:00:08 IPADDR=192.168.0.109 HOSTNAME=x; export ACTION MACADDR IPADDR HOSTNAME; $LND | ACTION=add MACADDR=02:00:00:00:00:08 IPADDR=192.168.0.109 HOSTNAME=x; export ACTION MACADDR IPADDR HOSTNAME; $NND | $ND
newdevice-seed | text+$NDF | router-24.10 | sh:$NEWMAC; export ACTION MACADDR IPADDR HOSTNAME; $LND | $NEWMAC; export ACTION MACADDR IPADDR HOSTNAME; $NND | $ND; rm \"\$W/root/etc/trafficctl/seen_macs\"
newdevice-no-ip | text+$NDF | router-24.10 | sh:ACTION=add MACADDR=02:00:00:00:00:98 IPADDR= HOSTNAME=; export ACTION MACADDR IPADDR HOSTNAME; $LND | ACTION=add MACADDR=02:00:00:00:00:98 IPADDR= HOSTNAME=; export ACTION MACADDR IPADDR HOSTNAME; $NND | $ND
newdevice-limited | text+$NDF | router-24.10 | sh:ACTION=add MACADDR=02:00:00:00:00:98 IPADDR=192.168.0.109 HOSTNAME=x; export ACTION MACADDR IPADDR HOSTNAME; $LND | ACTION=add MACADDR=02:00:00:00:00:98 IPADDR=192.168.0.109 HOSTNAME=x; export ACTION MACADDR IPADDR HOSTNAME; $NND | $ND
newdevice-off | text+$NDF | router-24.10 | sh:$NEWMAC; export ACTION MACADDR IPADDR HOSTNAME; $LND | $NEWMAC; export ACTION MACADDR IPADDR HOSTNAME; $NND | $ND; uci set trafficctl.newdevice.enabled=0; uci set trafficctl.telegram.enabled=0; uci commit trafficctl
rl-host | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.109 5000; echo rc=\$?; $RLT | tctl ratelimit 192.168.0.109 5000; echo rc=\$?; $RLT | $RL
rl-host-1.1 | text+$RLW | router-24.10 | sh:NFT_EMU=1.1 $L5RL 192.168.0.109 5000 lbl each; echo rc=\$?; $RLT | NFT_EMU=1.1 tctl ratelimit 192.168.0.109 5000 lbl each; echo rc=\$?; $RLT | $RL
rl-asym | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.109 8000 '' '' 800; echo rc=\$?; $RLT | tctl ratelimit 192.168.0.109 8000 '' '' 800; echo rc=\$?; $RLT | $RL; $PERSIST
rl-no-mac | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.9 5000; echo rc=\$?; $RLT | tctl ratelimit 192.168.0.9 5000; echo rc=\$?; $RLT | $RL
rl-nexthop | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.200 5000; echo rc=\$?; $RLT | tctl ratelimit 192.168.0.200 5000; echo rc=\$?; $RLT | $RL; $ROUTED
rl-subnet | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.0/24 5000; echo rc=\$?; $RLT | tctl ratelimit 192.168.0.0/24 5000; echo rc=\$?; $RLT | $RL; $PERSIST
rl-subnet-1.1 | text+$RLW | router-24.10 | sh:NFT_EMU=1.1 $L5RL 192.168.0.0/24 5000; echo rc=\$?; $RLT | NFT_EMU=1.1 tctl ratelimit 192.168.0.0/24 5000; echo rc=\$?; $RLT | $RL
rl-shared | text+$RLW | router-24.10 | sh:$L5RL 10.0.20.0/24 5000 x shared; echo rc=\$?; $RLT | tctl ratelimit 10.0.20.0/24 5000 x shared; echo rc=\$?; $RLT | $RL; $PERSIST
rl-all | text+$RLW | router-24.10 | sh:$L5RL all 2000; echo rc=\$?; $RLT | tctl ratelimit all 2000; echo rc=\$?; $RLT | $RL
rl-replace | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.109 3000; echo rc=\$?; $RLT | tctl ratelimit 192.168.0.109 3000; echo rc=\$?; $RLT | $RLOLD
rl-remove | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.109 0; echo rc=\$?; $RLT | tctl ratelimit 192.168.0.109 0; echo rc=\$?; $RLT | $RLOLD
rl-remove-1.1 | text+$RLW | router-24.10 | sh:NFT_EMU=1.1 $L5RL 192.168.0.0/24 0; echo rc=\$?; $RLT | NFT_EMU=1.1 tctl ratelimit 192.168.0.0/24 0; echo rc=\$?; $RLT | $RL; $PERSIST; NFT_EMU=1.1 sh \"\$L5EXEC/trafficctl-ratelimit.sh\" 192.168.0.0/24 2000 >/dev/null; $FORGET
rl-remove-none | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.109 0; echo rc=\$? | tctl ratelimit 192.168.0.109 0; echo rc=\$? | $RL
rl-partial | text+$RLW | router-24.10 | sh:NFT_FAIL_CHAINS=ul_lan3 $L5RL 192.168.0.109 5000; echo rc=\$?; $RLT | NFT_FAIL_CHAINS=ul_lan3 tctl ratelimit 192.168.0.109 5000; echo rc=\$?; $RLT | $RL
rl-meter-busy | text+$RLW | router-24.10 | sh:NFT_FAIL_RULE='ul_lan2 saddr' $L5RL 192.168.0.0/24 5000; echo rc=\$?; $RLT | NFT_FAIL_RULE='ul_lan2 saddr' tctl ratelimit 192.168.0.0/24 5000; echo rc=\$?; $RLT | $RL
rl-upload-only | text+$RLW | router-24.10 | sh:NFT_FAIL_HOOKS='dl_br_lan dl' $L5RL 192.168.0.109 5000; echo rc=\$?; $RLT | NFT_FAIL_HOOKS='dl_br_lan dl' tctl ratelimit 192.168.0.109 5000; echo rc=\$?; $RLT | $RL
rl-wan-fallback | text+$RLW | router-24.10 | sh:NFT_FAIL_HOOKS=dl_br_lan $L5RL 192.168.0.109 5000; echo rc=\$?; $RLT | NFT_FAIL_HOOKS=dl_br_lan tctl ratelimit 192.168.0.109 5000; echo rc=\$?; $RLT | $RL
rl-no-set | text+$RLW | router-24.10 | sh:NFT_FAIL_SET=1 $L5RL 192.168.0.109 5000; echo rc=\$?; $RLT | NFT_FAIL_SET=1 tctl ratelimit 192.168.0.109 5000; echo rc=\$?; $RLT | $RL
rl-no-netdev | text+$RLW | router-24.10 | sh:NFT_FAIL_TABLE=1 $L5RL 192.168.0.109 5000; echo rc=\$? | NFT_FAIL_TABLE=1 tctl ratelimit 192.168.0.109 5000; echo rc=\$? | $RL
rl-nss | text+$RLW,sys/kernel/debug/ecm/ecm_db/defunct_all | router-24.10 | sh:wmask $L5RL 192.168.0.109 5000 | wmask tctl ratelimit 192.168.0.109 5000 | $RL; $NSSON
rl-bad-rate | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.109 010; echo rc=\$? | tctl ratelimit 192.168.0.109 010; echo rc=\$? | $RL
rl-bad-up | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.109 5000 x each 0; echo rc=\$? | tctl ratelimit 192.168.0.109 5000 x each 0; echo rc=\$? | $RL
rl-bad-target | text+$RLW | router-24.10 | sh:$L5RL '10.0.0.0/99' 5000; echo rc=\$? | tctl ratelimit '10.0.0.0/99' 5000; echo rc=\$? | $RL
rl-bad-mode | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.109 5000 x bogus; echo rc=\$? | tctl ratelimit 192.168.0.109 5000 x bogus; echo rc=\$? | $RL
rl-legacy-label | text+$RLW | router-24.10 | sh:$L5RL 192.168.0.109 0 tg; echo rc=\$?; $RLT | tctl ratelimit 192.168.0.109 0 tg; echo rc=\$?; $RLT | $RLLEG
rl-legacy-each | text+$RLW | router-24.10 | sh:$L5RL 10.0.20.0/24 0 tg; echo rc=\$?; $RLT | tctl ratelimit 10.0.20.0/24 0 tg; echo rc=\$?; $RLT | $RLLEG
rl-usage | text | router-24.10 | sh:$L5RL 192.168.0.109; echo rc=\$? | tctl ratelimit 192.168.0.109; echo rc=\$? | $RL
rl-restore | text+$RLW | router-24.10 | sh:$L5HOOK; echo rc=\$?; $RLT | tctl restore >/dev/null; echo rc=\$?; $RLT | $RLBOOT
rl-restore-live | text+$RLW | router-24.10 | sh:$L5HOOK; echo rc=\$?; $RLT | tctl restore >/dev/null; echo rc=\$?; $RLT | $RLOLD
rl-restore-off | text+$RLW | router-24.10 | sh:$L5HOOK; echo rc=\$?; $RLT | tctl restore >/dev/null; echo rc=\$?; $RLT | $RLBOOT; uci set trafficctl.main.persist_rules=0; uci commit trafficctl
rl-restore-bad | text+$RLW | router-24.10 | sh:$L5HOOK; echo rc=\$?; $RLT | tctl restore >/dev/null; echo rc=\$?; $RLT | $RL; $PERSIST; printf '[{\"type\":\"ratelimit\",\"ip\":\"192.168.0.9\",\"param\":\"abc\"},{\"type\":\"ratelimit\",\"ip\":\"192.168.0.10\",\"param\":\"0\"},{\"type\":\"ratelimit\",\"ip\":\"192.168.0.109\",\"param\":\"4000\",\"mode\":\"each\",\"param_up\":\"400\"}]' > \"\$W/root/etc/trafficctl/rules.json\"
rl-restore-live-1.1 | text+$RLW | router-24.10 | sh:NFT_EMU=1.1 $L5HOOK; echo rc=\$?; NFT_EMU=1.1 $RLT | NFT_EMU=1.1 tctl restore >/dev/null; echo rc=\$?; NFT_EMU=1.1 $RLT | $RLOLD11
rl-restore-legacy-live | text+$RLW | router-24.10 | sh:$L5HOOK; echo rc=\$?; $RLT | tctl restore >/dev/null; echo rc=\$?; $RLT | $RLLEGREC
rl-restore-fails | text+$RLW | router-24.10 | sh:NFT_FAIL_CHAINS=ul_lan3 $L5HOOK; echo rc=\$?; $RLT | NFT_FAIL_CHAINS=ul_lan3 tctl restore >/dev/null; echo rc=\$?; $RLT | $RLBOOT
newdevice-old | text+$NDF | router-24.10 | sh:ACTION=old MACADDR=02:00:00:00:00:99 IPADDR=192.168.0.99 HOSTNAME=x; export ACTION MACADDR IPADDR HOSTNAME; $LND | ACTION=old MACADDR=02:00:00:00:00:99 IPADDR=192.168.0.99 HOSTNAME=x; export ACTION MACADDR IPADDR HOSTNAME; $NND | $ND
shape-add-existing | text+$STW | router-24.10 | sh:$L5SH add 192.168.0.109 3000; echo rc=\$?; stt | tctl shape add 192.168.0.109 3000; echo rc=\$?; stt | $STSET
shape-add-new | text+$STW | router-24.10 | sh:$L5SH add 192.168.0.50 5000 lbl; echo rc=\$?; stt | tctl shape add 192.168.0.50 5000 lbl; echo rc=\$?; stt | $STSET
shape-add-asym | text+$STW | router-24.10 | sh:$L5SH add 192.168.0.50 8000 lbl 1000; echo rc=\$?; stt | tctl shape add 192.168.0.50 8000 lbl 1000; echo rc=\$?; stt | $STSET
shape-add-first | text+$STW | router-24.10 | sh:$L5SH add 192.168.0.50 8000; echo rc=\$?; stt | tctl shape add 192.168.0.50 8000; echo rc=\$?; stt | $STSET; $NOSHAPES
shape-readd | text+$STW | router-24.10 | sh:$L5SH add 192.168.0.109 7000 x 700; echo rc=\$?; stt | tctl shape add 192.168.0.109 7000 x 700; echo rc=\$?; stt | $STON
shape-remove | text+$STW | router-24.10 | sh:$L5SH remove 192.168.0.109; echo rc=\$?; stt | tctl shape remove 192.168.0.109; echo rc=\$?; stt | $STON
shape-remove-none | text | router-24.10 | sh:$L5SH remove 192.168.0.77 x; echo rc=\$?; stt | tctl shape remove 192.168.0.77 x; echo rc=\$?; stt | $STSET
shape-remove-legacy | text+$STW | router-24.10 | sh:$L5SH remove 192.168.0.3; echo rc=\$?; stt | tctl shape remove 192.168.0.3; echo rc=\$?; stt | $STSET; $OLDSHAPES
shape-status | text | router-24.10 | sh:$L5SH status 192.168.0.109; echo rc=\$?; $L5SH status 192.168.0.77; echo rc=\$? | tctl shape status 192.168.0.109; echo rc=\$?; tctl shape status 192.168.0.77; echo rc=\$? | $STON
shape-sqm | text+$STW | router-24.10 | sh:htbmsg $L5SH add 192.168.0.50 5000; echo rc=\$?; stt | tctl shape add 192.168.0.50 5000; echo rc=\$?; stt | $LOGROOT; TC_ROOT_br_lan=cake st_init
shape-no-ifb | text+$STW | router-24.10 | sh:TC_NO_IFB=1 $L5SH add 192.168.0.50 5000 lbl 1000; echo rc=\$?; stt | TC_NO_IFB=1 tctl shape add 192.168.0.50 5000 lbl 1000; echo rc=\$?; stt | $STSET
shape-usage | text+$STW | router-24.10 | sh:$L5SH; echo rc=\$?; $L5SH add; echo rc=\$?; $L5SH add 192.168.0.300 500; echo rc=\$?; $L5SH add 192.168.0.50 010; echo rc=\$?; $L5SH add 192.168.0.50 abc; echo rc=\$?; $L5SH add 192.168.0.50 0; echo rc=\$?; $L5SH remove; echo rc=\$?; $L5SH status; echo rc=\$?; $L5SH bogus 192.168.0.50; echo rc=\$? | tctl shape; echo rc=\$?; tctl shape add; echo rc=\$?; tctl shape add 192.168.0.300 500; echo rc=\$?; tctl shape add 192.168.0.50 010; echo rc=\$?; tctl shape add 192.168.0.50 abc; echo rc=\$?; tctl shape add 192.168.0.50 0; echo rc=\$?; tctl shape remove; echo rc=\$?; tctl shape status; echo rc=\$?; tctl shape bogus 192.168.0.50; echo rc=\$? | $STSET
shape-restore | text+$STW | router-24.10 | sh:$L5HOOK >/dev/null; echo rc=\$?; sttnf | tctl restore >/dev/null; echo rc=\$?; sttnf | $STSET; $STNOPERSIST
shape-restore-twice | text+$STW | router-24.10 | sh:$L5HOOK >/dev/null; $L5HOOK >/dev/null; echo rc=\$?; sttnf | tctl restore >/dev/null; tctl restore >/dev/null; echo rc=\$?; sttnf | $STSET; $STNOPERSIST
shape-restore-old | text+$STW | router-24.10 | sh:$L5HOOK >/dev/null; sttnf | tctl restore >/dev/null; sttnf | $STSET; $STNOPERSIST; $OLDSHAPES5
shape-restore-no-ifb | text+$STW | router-24.10 | sh:TC_NO_IFB=1 $L5HOOK >/dev/null; echo rc=\$?; sttnf | TC_NO_IFB=1 tctl restore >/dev/null; echo rc=\$?; sttnf | $STSET; $STNOPERSIST
"

# ── PR8 history (`trafficctl history`, history.uc) ──────────────────────────
# Both sides write the default store, /etc/trafficctl/history, which the
# rewrite and TCTL_ROOT both put in the case's root. The new side's `flush`
# runs `history flush-now` as a guarded child through the root's CLI, so hcli
# puts a real one there (cli_root links the spawn logger).
lh() { sh "$LEXEC/trafficctl-history.sh" "$@"; }
hcli() {
    rm -f "$W/root/usr/sbin/trafficctl"
    printf '#!/bin/sh\nPOSIXLY_CORRECT=1 exec "%s" -S -L "%s" "%s" "$@"\n' "$UCODE" "$UC_LIB" \
        "$UC_REPO/trafficctl/files/usr/sbin/trafficctl" > "$W/root/usr/sbin/trafficctl"
    chmod +x "$W/root/usr/sbin/trafficctl"
}
nh() { hcli; tctl history "$@"; }
hmask() {   # epochs and the root prefix, as with_files masks files
    sed -E -e "s|$W/root||g" \
        -e 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\1<epoch>\2/g' \
        -e 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\1<epoch>\2/g'
}
hm() { local rc; "$@" > "$W/hm.out"; rc=$?; hmask < "$W/hm.out"; echo "rc=$rc"; }
# Every store, cursor, accumulator, stamp and error file, one "<file>\t<line>"
# per line, so text-sorted compares each file's line set.
hd() {
    local f
    for f in "$W/root/etc/trafficctl/history/"* "$W/root/tmp/trafficctl_history."*; do
        [ -f "$f" ] || continue
        hmask < "$f" | sed "s|^|${f#"$W"/root/}	|"
    done
}
HISTON='uci set trafficctl.history=history; uci set trafficctl.history.enabled=1; uci commit trafficctl'
HSWOFF="$SWOFFLOAD"
# The interface counters move between two samples: wan's restart (#111), the
# rest grow.
IFGROW='sed -i -E -e "s/^( *wan:) *[0-9]+/\1 12345/" -e "s/^( *br-lan:) *([0-9]+)/\1 \29/" "$W/root/proc/net/dev"'
# Stores a 1.30.x keeper left: two months, an ISO week, a day, their
# interface files, a duplicate key (first position, last values), a "-" MAC
# after a real one, a 10-field row from before the degraded column, a row too
# short to read, comments, a dot file and a subdirectory that are not periods.
HFILES='d="$W/root/etc/trafficctl/history"; mkdir -p "$d/sub"; t=$(printf "\t"); printf "# trafficctl-history 1\nmac:02:00:00:00:00:06${t}02:00:00:00:00:06${t}192.168.0.102${t}host-26${t}100${t}200${t}50${t}60${t}1790000000${t}1790000100${t}false\nip:10.0.5.9${t}-${t}10.0.5.9${t}-${t}5${t}6${t}0${t}0${t}1790000000${t}1790000000\n# note\nshort${t}row\n" > "$d/2026-10.tsv"; printf "# trafficctl-history 1\nmac:02:00:00:00:00:06${t}-${t}192.168.0.150${t}-${t}1${t}2${t}3${t}4${t}1789999000${t}1791000000${t}true\nip:10.0.5.9${t}-${t}10.0.5.9${t}vpn peer${t}7${t}8${t}9${t}10${t}1791000000${t}1791000500${t}false\nip:10.0.5.9${t}-${t}10.0.5.10${t}-${t}70${t}80${t}0${t}0${t}1791000000${t}1791000600${t}false\n" > "$d/2026-11.tsv"; printf "# trafficctl-history 1\nip:172.30.0.5${t}-${t}172.30.0.5${t}-${t}4503599627370497${t}1${t}0${t}0${t}1791000000${t}1791000001${t}false\n" > "$d/2026-W46.tsv"; printf "# trafficctl-history 1\nip:172.30.0.5${t}-${t}172.30.0.5${t}-${t}1${t}1${t}0${t}0${t}1791000000${t}1791000001${t}false\n" > "$d/2026-11-11.tsv"; printf "# trafficctl-history-if 1\nwan${t}wan${t}-${t}1000${t}2000${t}1790000000${t}1790000100\nbr-lan${t}lan${t}lan${t}5${t}6${t}1790000000${t}1790000000\n" > "$d/2026-10.if.tsv"; printf "# trafficctl-history-if 1\nwan${t}wan${t}uplink${t}10${t}20${t}1789000000${t}1791000100\nawg3${t}vpn${t}Finland${t}1${t}2${t}1791000000${t}1791000000\n" > "$d/2026-11.if.tsv"; cp "$d/2026-10.tsv" "$d/.hidden.tsv"; cp "$d/2026-10.tsv" "$d/sub/2025-01.tsv"'
HODD='uci set trafficctl.history.keep=abc; uci set trafficctl.history.interval=10; uci set trafficctl.history.sample_interval=99999; uci set trafficctl.history.period=bogus; uci set trafficctl.history.interfaces=0; uci set trafficctl.history.dir=/etc; uci commit trafficctl'
HODD2='uci set trafficctl.history.keep=500; uci set trafficctl.history.interval=7200; uci set trafficctl.history.sample_interval=5; uci set trafficctl.history.period=day; uci set trafficctl.history.dir=/mnt/usb/hist/; uci commit trafficctl'
HERR='printf "1794000000\tcannot write /mnt/x.tsv \"q\" \\\\\n" > "$W/root/tmp/trafficctl_history.err"; printf "1794000001\n" > "$W/root/tmp/trafficctl_history.stamp"'
HERR2='printf "no tab here\n" > "$W/root/tmp/trafficctl_history.err"; printf "x\n" > "$W/root/tmp/trafficctl_history.stamp"'
HKEEP1='uci set trafficctl.history.keep=1; uci commit trafficctl'
# v1.30.0's prune recursed into subdirectories of the store and took any
# *.tsv for a period (.hidden.tsv included); history.uc deletes only files
# named like a period in the store itself (an intentional difference), so
# the prune cases leave both out.
HNOSUB='rm -r "$W/root/etc/trafficctl/history/sub"; rm "$W/root/etc/trafficctl/history/.hidden.tsv"'
# v1.30.0's flush leaks its lock directory (hist_if_flush replaces the EXIT
# trap that removed it), and the next flush steals it after 5 s; history.uc
# releases its lock and steals only one older than 20 s. Removed between two
# back-to-back flushes so both sides start unlocked.
HUNLOCK='rmdir "$W/root/tmp/trafficctl_history.lock.d"'
hz() { "$@" | sed -E 's/(^|[^0-9])1[0-9]{9}([^0-9]|$)/\10\2/g'; }   # epochs in JSON
VDIRS='/mnt/usb /mnt/usb/ /mnt/ /mnt /media/a /srv/b/c /tmp/x /tmp/ /etc /mnt/../etc /mnt/a/.. /mnt//x /mnt/./x /mnt/x/. /tmp/a;b /mnt/a$b /mnt/a`b /mnt/a"b /mnt/a<b relative/x ./mnt/x /mntx'
vdirs() { local d; for d in $VDIRS ""; do "$@" validate-dir "$d"; echo "[$d] rc=$?"; done; }
# Period ids over the 2026/2027 ISO year boundary (2026 has 53 weeks), in
# three zones: one west and one east of UTC with DST, so the local date and
# the UTC date differ, and the instant of a DST change.
PID_TIMES="$(seq 1798372800 21600 1799107200) 1774745999 1774746000 1792889999 1792890000 1775311199 1775311200 1790431199 1790431200 1788667199 1788667200 1775357999 1775358000"
PID_ZONES='UTC NZST-12NZDT,M9.5.0,M4.1.0/3 CET-1CEST,M3.5.0,M10.5.0/3 <-04>4<-03>,M9.1.6/24,M4.1.6/24'
pids() {   # pids legacy|new
    local z k t
    [ "$1" = legacy ] && sed '/^case "\$1" in$/,$d' "$LEXEC/trafficctl-history.sh" > "$W/hist-lib.sh"
    for k in day week month; do
        uci set trafficctl.history.period=$k; uci commit trafficctl
        for z in $PID_ZONES; do
            for t in $PID_TIMES; do
                if [ "$1" = legacy ]; then
                    printf '%s %s %s %s\n' "$k" "$z" "$t" "$(TZ=$z sh -c '. "$1"; hist_period_id "$2"' _ "$W/hist-lib.sh" "$t")"
                else
                    printf '%s %s %s %s\n' "$k" "$z" "$t" "$(TZ=$z tcall trafficctl.history period_id "$t")"
                fi
            done
        done
    done
}
HIST_CASES="
history-flush | text-sorted | router-24.10 | sh:hm lh flush; hd | hm nh flush; hd | $HISTON
history-flush-names | text-sorted | router-24.10 | sh:hm lh flush; hd | hm nh flush; hd | $HISTON; $NAMES
history-flush-grow | text-sorted | router-24.10 | sh:lh flush >/dev/null; $HUNLOCK; $GROW; $IFGROW; hm lh flush; hd | nh flush >/dev/null; $GROW; $IFGROW; hm nh flush; hd | $HISTON
history-flush-upgrade | text-sorted | router-24.10 | sh:lh flush >/dev/null; $HUNLOCK; $GROW; hm lh flush; hd | lh flush >/dev/null; $HUNLOCK; $GROW; hm nh flush; hd | $HISTON
history-flush-downgrade | text-sorted | router-24.10 | sh:lh flush >/dev/null; $GROW; hm lh flush; hd | nh flush >/dev/null; $GROW; hm lh flush; hd | $HISTON
history-flush-onto-legacy | text-sorted | router-24.10 | sh:hm lh flush; hd | hm nh flush; hd | $HISTON; $HFILES
history-flush-sw | text-sorted | router-24.10 | sh:hm lh flush; hd | hm nh flush; hd | $HISTON; $HSWOFF
history-flush-noifaces | text-sorted | router-24.10 | sh:hm lh flush; hd | hm nh flush; hd | $HISTON; uci set trafficctl.history.interfaces=0; uci commit trafficctl
history-flush-off | text-sorted | router-24.10 | sh:hm lh flush; hd | hm nh flush; hd
history-flush-locked | text-sorted+tmp/logger.log | router-24.10 | sh:hm lh flush; hd | hm nh flush; hd | $HISTON; mkdir \"\$W/root/tmp/trafficctl_history.lock.d\"; touch -d @1700000000 \"\$W/root/tmp/trafficctl_history.lock.d\"
history-sample | text-sorted | router-24.10 | sh:hm lh sample; hd | hm nh sample; hd | $HISTON
history-sample-flap | text-sorted | router-24.10 | sh:lh sample >/dev/null; $IFGROW; hm lh sample; hd | nh sample >/dev/null; $IFGROW; hm nh sample; hd | $HISTON
history-sample-onto-legacy | text-sorted | router-24.10 | sh:hm lh sample; hd | hm nh sample; hd | $HISTON; $HFILES
history-sample-off | text | router-24.10 | sh:hm lh sample; hd | hm nh sample; hd
history-read | json | router-24.10 | sh:lh read 2026-10 2026-11 | tctl history read 2026-10 2026-11 | $HISTON; $HFILES
history-read-one | json | router-24.10 | sh:lh read 2026-11 | tctl history read 2026-11 | $HISTON; $HFILES
history-read-weeks | json | router-24.10 | sh:lh read 2026-W01 2026-W99 | tctl history read 2026-W01 2026-W99 | $HISTON; $HFILES
history-read-all | json | router-24.10 | sh:lh read 0 9 | tctl history read 0 9 | $HISTON; $HFILES
history-read-none | json | router-24.10 | sh:lh read 2027-01 | tctl history read 2027-01 | $HISTON; $HFILES
history-read-current | json-set:key | router-24.10 | sh:lh flush >/dev/null; hz lh read | nh flush >/dev/null; hz tctl history read | $HISTON
history-read-empty | json | router-24.10 | sh:lh read | tctl history read | $HISTON
history-read-ifaces | json | router-24.10 | sh:lh read-ifaces 2026-10 2026-11 | tctl history read-ifaces 2026-10 2026-11 | $HISTON; $HFILES
history-read-ifaces-none | json | router-24.10 | sh:lh read-ifaces 2025-01 | tctl history read-ifaces 2025-01 | $HISTON; $HFILES
history-read-ifaces-current | json | router-24.10 | sh:lh flush >/dev/null; hz lh read-ifaces | nh flush >/dev/null; hz tctl history read-ifaces | $HISTON
history-periods | json | router-24.10 | sh:lh periods | tctl history periods | $HISTON; $HFILES
history-periods-none | json | router-24.10 | sh:lh periods | tctl history periods | $HISTON
history-prune | text-sorted | router-24.10 | sh:hm lh prune; hd | hm tctl history prune; hd | $HISTON; $HFILES; $HNOSUB; $HKEEP1
history-prune-keep | text-sorted | router-24.10 | sh:hm lh prune; hd | hm tctl history prune; hd | $HISTON; $HFILES
history-prune-current | text-sorted | router-24.10 | sh:lh flush >/dev/null; hm lh prune; hd | nh flush >/dev/null; hm tctl history prune; hd | $HISTON; $HFILES; $HNOSUB; $HKEEP1
history-status | json | router-24.10 | sh:hm lh status | hm tctl history status | $HISTON
history-status-flushed | json | router-24.10 | sh:lh flush >/dev/null; hm lh status | nh flush >/dev/null; hm tctl history status | $HISTON
history-status-off | json | router-24.10 | sh:hm lh status | hm tctl history status
history-status-sw | json | router-24.10 | sh:hm lh status | hm tctl history status | $HISTON; $HSWOFF
history-status-none | json | router-24.10 | sh:hm lh status | hm tctl history status | $HISTON; $NOOFFLOAD
history-status-odd | json | router-24.10 | sh:hm lh status | hm tctl history status | $HISTON; $HODD
history-status-odd2 | json | router-24.10 | sh:hm lh status | hm tctl history status | $HISTON; $HODD2
history-status-error | json | router-24.10 | sh:hm lh status | hm tctl history status | $HISTON; $HERR
history-status-error2 | json | router-24.10 | sh:hm lh status | hm tctl history status | $HISTON; $HERR2
history-validate-dir | text | router-24.10 | sh:vdirs lh | vdirs tctl history
history-usage | text | router-24.10 | sh:lh bogus; echo rc=\$?; lh; echo rc=\$? | tctl history bogus; echo rc=\$?; tctl history; echo rc=\$?
history-period-ids | text | router-24.10 | sh:pids legacy | pids new | $HISTON
"
CASES="$CASES$HIST_CASES"
# ── end PR8 history ──────────────────────────────────────────────────────────

command -v jq >/dev/null || { echo "FAIL: jq is required" >&2; exit 1; }

# ── legacy backend, and the current fw.sh ───────────────────────────────────
if ! git -C "$UC_REPO" rev-parse -q --verify "refs/tags/$LEGACY_TAG" >/dev/null; then
    git -C "$UC_REPO" fetch -q --depth=1 origin "refs/tags/$LEGACY_TAG:refs/tags/$LEGACY_TAG" ||
        { echo "FAIL: cannot get $LEGACY_TAG" >&2; exit 1; }
fi
mkdir -p "$L" "$C/trafficctl" "$W"
git -C "$UC_REPO" archive "$LEGACY_TAG" trafficctl/files luci-app-trafficctl/root | tar -x -C "$L"
if ! git -C "$UC_REPO" rev-parse -q --verify "refs/tags/$LEGACY5_TAG" >/dev/null; then
    git -C "$UC_REPO" fetch -q --depth=1 origin "refs/tags/$LEGACY5_TAG:refs/tags/$LEGACY5_TAG" ||
        { echo "FAIL: cannot get $LEGACY5_TAG" >&2; exit 1; }
fi
mkdir -p "$L5"
git -C "$UC_REPO" archive "$LEGACY5_TAG" trafficctl/files | tar -x -C "$L5"
L5EXEC="$L5/trafficctl/files/usr/libexec/trafficctl"
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
rewrite "$L5" "$L5EXEC"
rewrite "$C" "$CEXEC"

# ── mocks ───────────────────────────────────────────────────────────────────
mkdir -p "$W/bin"
cat > "$W/bin/replay" <<EOF
#!/bin/sh
# Prints the recorded output of this exact command line, or fails like the
# command would when the fixture has none.
c=\${0##*/}
if [ "\$c" = nft ] && [ -d "$W/root/tmp/nft-netdev" ]; then
    case " \$* " in
        *" netdev "*)
            case " \$* " in
                *" add "*|*" delete "*) echo "nft \$*" >> "$W/root/tmp/writes.log" ;;
            esac
            NFT_STATE="$W/root/tmp/nft-netdev" NFT_LOG= exec sh "$UC_TESTLIB/nft-netdev.sh" "\$@" ;;
    esac
fi
# The shaper's tc and ip link meet a stateful stand-in once a case has made
# one (st_init). The filter deletes are not logged: v1.30.x deleted by prio,
# the port by handle (see STSET), and the state each leaves is compared.
if [ -d "$W/root/tmp/tc-htb" ] && { [ "\$c" = tc ] || [ "\$c \$1" = "ip link" ]; }; then
    case " \$* " in
        *" show "*|*" filter del "*) ;;
        *) echo "\$c \$*" >> "$W/root/tmp/writes.log" ;;
    esac
    TC_STATE="$W/root/tmp/tc-htb" TC_LOG= exec sh "$UC_TESTLIB/tc-htb.sh" "\$c" "\$@"
fi
if [ "\$c" = nft ] && [ -f "$W/root/tmp/nft.state" ]; then
    case " \$* " in
        *" add "*|*" insert "*|*" delete "*|*" create "*|*" flush "*) echo "nft \$*" >> "$W/root/tmp/writes.log" ;;
    esac
    NFT_STATE="$W/root/tmp/nft.state" exec "$UCODE" -S "$UC_TESTLIB/nft-fw4.uc" -- "\$@"
fi
f="$W/cmd/\$c \$*"
if [ ! -f "\$f" ] && [ -f "$W/cmd/\$c.default" ]; then
    echo "\$c \$*" >> "$W/root/tmp/writes.log"
    cat "$W/cmd/\$c.default"
    exit 0
fi
[ -f "\$f" ] || { echo "replay: no fixture for: \$c \$*" >&2; exit 1; }
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
# ── notifications ──
# curl, for telegram-test: the request (URL and JSON body, from argv or from
# the --config on stdin, wherever each side puts them) goes to
# root/tmp/curl.log, the reply comes from root/tmp/curl.reply.
cat > "$W/bin/curl" <<EOF
#!/usr/bin/env python3
import json, re, sys
root = "$W/root"
url, body, argv = '', '', sys.argv[1:]
for i, a in enumerate(argv):
    if a in ('-d', '--data', '--data-raw') and i + 1 < len(argv):
        body = argv[i + 1]
if '-' in argv:
    for line in sys.stdin.read().splitlines():
        m = re.match(r'^(\\S+) = "(.*)"\$', line)
        if not m:
            continue
        v = json.loads('"' + m.group(2) + '"')
        if m.group(1) == 'url':
            url = v
        elif m.group(1) in ('data', 'data-raw'):
            body = v
try:
    body = json.dumps(json.loads(body), sort_keys=True, ensure_ascii=False)
except ValueError:
    pass
with open(root + '/tmp/curl.log', 'a') as f:
    f.write('url=%s body=%s\\n' % (url, body))
try:
    sys.stdout.write(open(root + '/tmp/curl.reply').read())
except OSError:
    sys.stdout.write('{"ok":true,"result":{}}')
EOF
# ── end notifications ──
chmod +x "$W/bin/"*

# ── PR7: cut, portfw ────────────────────────────────────────────────────────
# Both commands change nft state, which a replayed fixture cannot follow: a
# case that makes root/netfake gets tests/lib/netfake.sh for nft and
# conntrack instead, and its calls log is the record of what each side did to
# the kernel. Every other case still replays.
mkdir -p "$W/bin/replay.d"
for c in nft conntrack; do
    ln -sf ../replay "$W/bin/replay.d/$c"
    rm -f "$W/bin/$c"
    cat > "$W/bin/$c" <<EOF
#!/bin/sh
[ -d "$W/root/netfake" ] || exec "$W/bin/replay.d/$c" "\$@"
NETFAKE="$W/root/netfake" exec sh "$UC_TESTLIB/netfake.sh" $c "\$@"
EOF
    chmod +x "$W/bin/$c"
done
# The legacy cut reads its clock from date(1); the port from TCTL_NOW.
REAL_DATE=$(command -v date)
cat > "$W/bin/date" <<EOF
#!/bin/sh
[ "\$*" = +%s ] && [ -n "\$TCTL_NOW" ] && { echo "\$TCTL_NOW"; exit 0; }
exec "$REAL_DATE" "\$@"
EOF
chmod +x "$W/bin/date"
CUT_T0=1700000000
lcut() { TCTL_NOW="${CUT_NOW:-$CUT_T0}" sh "$LEXEC/trafficctl-cut.sh" "$@"; echo "rc=$?"; }
ncut() { TCTL_NOW="${CUT_NOW:-$CUT_T0}" tctl cut "$@"; echo "rc=$?"; }
# Not compared, because main changed them after v1.30.0 and the port keeps
# main's: nft is the only backend (v1.30 answered "running iptables" when nft
# listed nothing), and a rate goes through tctl_validate_rate (v1.30 took 08
# and 100000001). tests/test_cut.sh and tests/test_portfw.sh cover both.
lpfw() { sh "$LEXEC/trafficctl-portfw.sh" "$@"; echo "rc=$?"; }
npfw() { tctl portfw "$@"; echo "rc=$?"; }
# An init script that records what it was asked, and a kernel with our tables.
CUTENV='mkdir -p "$W/root/netfake" "$W/root/etc/init.d"; : > "$W/root/netfake/calls"; printf "#!/bin/sh\necho \"\$*\" >> \"$W/root/tmp/init.log\"\n" > "$W/root/etc/init.d/trafficctl-cut"; chmod +x "$W/root/etc/init.d/trafficctl-cut"'
CUTF='var/run/trafficctl/cut.state,etc/trafficctl/cut.state,tmp/init.log,tmp/logger.log,tmp/trafficctl/activity.log,netfake/calls'
CUTPSTATE='mkdir -p "$W/root/etc/trafficctl"; printf "expires_at=1700000600\npersist=1\nstarted_at=1699999000\n" > "$W/root/etc/trafficctl/cut.state"'
TPROXY='printf "table inet PodkopTable {\n\tchain proxy {\n\t\tmeta l4proto tcp tproxy ip to 127.0.0.1:1602\n\t}\n}\n" > "$W/root/netfake/ruleset"'
PFWENV='mkdir -p "$W/root/netfake"; : > "$W/root/netfake/calls"; uci add firewall redirect >/dev/null; uci set firewall.@redirect[-1].name="Web Server"; uci set firewall.@redirect[-1].src=wan; uci set firewall.@redirect[-1].src_dport=8080; uci set firewall.@redirect[-1].dest_ip=192.168.0.140; uci set firewall.@redirect[-1].dest_port=80; uci set firewall.@redirect[-1].proto=tcp; uci add firewall redirect >/dev/null; uci set firewall.@redirect[-1].name="Game"; uci set firewall.@redirect[-1].src=wan; uci set firewall.@redirect[-1].src_dport=27015-27030; uci set firewall.@redirect[-1].dest_ip=192.168.0.109; uci add firewall rule >/dev/null; uci set firewall.@rule[-1].name=WireGuard; uci set firewall.@rule[-1].src=wan; uci set firewall.@rule[-1].dest_port=51820; uci set firewall.@rule[-1].proto=udp; uci set firewall.@rule[-1].target=ACCEPT; uci commit firewall'
PFWF='etc/trafficctl/rules.json,tmp/trafficctl/activity.log,netfake/calls'
# rules.json as the other writers leave it, so a port-forward save or removal
# has to keep their records byte for byte.
cat > "$W/pfw-rules.json" <<'JSON'
[{"type":"block","ip":"192.168.0.5","param":""},{"type":"ratelimit","ip":"10.0.20.0/24","param":"5000","mode":"each","param_up":"1000"},{"type":"pfw_pause","ip":"forward/tcp/192.168.0.140/80","param":"1"},{"type":"pfw_limit","ip":"forward/udp/192.168.0.109/27015-27030","param":"8000"}]
JSON
PFWRULES='mkdir -p "$W/root/etc/trafficctl"; cp "$W/pfw-rules.json" "$W/root/etc/trafficctl/rules.json"'
PFWSEED='nft add table inet tctl_pfw; nft add chain inet tctl_pfw pfw_forward x; nft add rule inet tctl_pfw pfw_forward ip daddr 192.168.0.140 tcp dport 80 counter drop comment \"tctl_pfw_pause_tcp_192.168.0.140_80\"; nft add rule inet tctl_pfw pfw_forward ip daddr 192.168.0.109 udp dport 27015-27030 limit rate over 1000 kbytes/second counter drop comment \"tctl_pfw_limit_udp_192.168.0.109_27015-27030\"; : > "$W/root/netfake/calls"'
CASES+="
cut-status-off | json | router-24.10 | sh:lcut status | ncut status | $CUTENV
cut-usage | text | router-24.10 | sh:lcut; lcut bogus | ncut; ncut bogus | $CUTENV
cut-engage | text+$CUTF | router-24.10 | sh:lcut engage 900 0 | ncut engage 900 0 | $CUTENV
cut-engage-default | text+$CUTF | router-24.10 | sh:lcut engage | ncut engage | $CUTENV
cut-engage-indefinite | text+$CUTF | router-24.10 | sh:lcut engage 0 0 | ncut engage 0 0 | $CUTENV
cut-engage-persist | text+$CUTF | router-24.10 | sh:lcut engage 900 1 | ncut engage 900 1 | $CUTENV
cut-engage-bounds | text+$CUTF | router-24.10 | sh:lcut engage 59; lcut engage 604801; lcut engage 9x; lcut engage 900 2; lcut engage 60 0 | ncut engage 59; ncut engage 604801; ncut engage 9x; ncut engage 900 2; ncut engage 60 0 | $CUTENV
cut-engage-no-lan | text+$CUTF | router-24.10 | sh:lcut engage 900 0 | ncut engage 900 0 | $CUTENV; : > \"\$W/root/etc/config/firewall\"
cut-engage-no-fib | text+$CUTF | router-24.10 | sh:lcut engage 900 0 | ncut engage 900 0 | $CUTENV; : > \"\$W/root/netfake/no_fib\"
cut-engage-tproxy | text+$CUTF | router-24.10 | sh:lcut engage 900 0 | ncut engage 900 0 | $CUTENV; $TPROXY
cut-engage-tproxy-no-fib | text+$CUTF | router-24.10 | sh:lcut engage 900 0 | ncut engage 900 0 | $CUTENV; $TPROXY; : > \"\$W/root/netfake/no_fib\"
cut-engage-strip-local | text+$CUTF | router-24.10 | sh:lcut engage 900 0 | ncut engage 900 0 | $CUTENV; : > \"\$W/root/netfake/strip_local\"
cut-engage-no-conntrack | text+$CUTF | router-24.10 | sh:lcut engage 900 0 | ncut engage 900 0 | $CUTENV; : > \"\$W/root/netfake/no_conntrack\"
cut-status-on | text+$CUTF | router-24.10 | sh:lcut engage 900 0 >/dev/null; CUT_NOW=1700000300 lcut status | ncut engage 900 0 >/dev/null; CUT_NOW=1700000300 ncut status | $CUTENV
cut-status-expired | text+$CUTF | router-24.10 | sh:lcut engage 900 1 >/dev/null; CUT_NOW=1700000900 lcut status | ncut engage 900 1 >/dev/null; CUT_NOW=1700000900 ncut status | $CUTENV
cut-status-lapsed | text+$CUTF | router-24.10 | sh:lcut engage 0 0 >/dev/null; rm \"\$W/root/netfake/tctl_cut\"; lcut status | ncut engage 0 0 >/dev/null; rm \"\$W/root/netfake/tctl_cut\"; ncut status | $CUTENV
cut-release | text+$CUTF | router-24.10 | sh:lcut engage 900 1 >/dev/null; lcut release | ncut engage 900 1 >/dev/null; ncut release | $CUTENV
cut-release-idle | text+$CUTF | router-24.10 | sh:lcut release | ncut release | $CUTENV
cut-tick | text+$CUTF | router-24.10 | sh:lcut engage 900 0 >/dev/null; CUT_NOW=1700000005 lcut tick | ncut engage 900 0 >/dev/null; CUT_NOW=1700000005 ncut tick | $CUTENV
cut-tick-expired | text+$CUTF | router-24.10 | sh:lcut engage 900 0 >/dev/null; CUT_NOW=1700000901 lcut tick | ncut engage 900 0 >/dev/null; CUT_NOW=1700000901 ncut tick | $CUTENV
cut-tick-lapsed | text+$CUTF | router-24.10 | sh:lcut engage 0 0 >/dev/null; rm \"\$W/root/netfake/tctl_cut\"; lcut tick | ncut engage 0 0 >/dev/null; rm \"\$W/root/netfake/tctl_cut\"; ncut tick | $CUTENV
cut-tick-orphan | text+$CUTF | router-24.10 | sh:lcut tick | ncut tick | $CUTENV; echo 'counter drop comment \"tctl_cut\"' > \"\$W/root/netfake/tctl_cut\"
cut-tick-idle | text+$CUTF | router-24.10 | sh:lcut tick | ncut tick | $CUTENV
cut-restore | text+$CUTF | router-24.10 | sh:lcut restore; lcut status | ncut restore; ncut status | $CUTENV; $CUTPSTATE
cut-restore-expired | text+$CUTF | router-24.10 | sh:CUT_NOW=1700000600 lcut restore | CUT_NOW=1700000600 ncut restore | $CUTENV; $CUTPSTATE
cut-restore-no-consent | text+$CUTF | router-24.10 | sh:lcut restore | ncut restore | $CUTENV; $CUTPSTATE; sed -i s/persist=1/persist=0/ \"\$W/root/etc/trafficctl/cut.state\"
cut-restore-none | text+$CUTF | router-24.10 | sh:lcut restore | ncut restore | $CUTENV
cut-restore-no-lan | text+$CUTF | router-24.10 | sh:lcut restore | ncut restore | $CUTENV; $CUTPSTATE; : > \"\$W/root/etc/config/firewall\"
cut-v130-engage-new-release | text+$CUTF | router-24.10 | sh:lcut engage 900 1 >/dev/null; lcut release | lcut engage 900 1 >/dev/null; ncut release | $CUTENV
cut-new-engage-v130-release | text+$CUTF | router-24.10 | sh:lcut engage 900 1 >/dev/null; lcut release | ncut engage 900 1 >/dev/null; lcut release | $CUTENV
cut-v130-engage-new-status | text+$CUTF | router-24.10 | sh:lcut engage 900 1 >/dev/null; CUT_NOW=1700000100 lcut status | lcut engage 900 1 >/dev/null; CUT_NOW=1700000100 ncut status | $CUTENV
portfw-list | json | router-24.10 | trafficctl-portfw.sh list | tctl portfw list | $PFWENV
portfw-list-state | json | router-24.10 | trafficctl-portfw.sh list | tctl portfw list | $PFWENV; $PFWSEED
portfw-list-none | json | router-24.10 | trafficctl-portfw.sh list | tctl portfw list | mkdir -p \"\$W/root/netfake\"
portfw-pause | text+$PFWF | router-24.10 | sh:lpfw pause forward tcp 192.168.0.140 80; lpfw list | npfw pause forward tcp 192.168.0.140 80; npfw list | $PFWENV
portfw-pause-range | text+$PFWF | router-24.10 | sh:lpfw pause forward tcpudp 192.168.0.109 27015-27030 | npfw pause forward tcpudp 192.168.0.109 27015-27030 | $PFWENV
portfw-pause-input | text | router-24.10 | sh:lpfw pause input udp - 51820 | npfw pause input udp - 51820 | $PFWENV
portfw-resume | text+$PFWF | router-24.10 | sh:lpfw resume forward tcp 192.168.0.140 80; lpfw list | npfw resume forward tcp 192.168.0.140 80; npfw list | $PFWENV; $PFWSEED
portfw-limit | text+$PFWF | router-24.10 | sh:lpfw limit forward tcp 192.168.0.140 80 8000; lpfw list | npfw limit forward tcp 192.168.0.140 80 8000; npfw list | $PFWENV
portfw-limit-remove | text+$PFWF | router-24.10 | sh:lpfw limit forward udp 192.168.0.109 27015-27030 0; lpfw list | npfw limit forward udp 192.168.0.109 27015-27030 0; npfw list | $PFWENV; $PFWSEED
portfw-limit-input | text | router-24.10 | sh:lpfw limit input udp - 51820 800 | npfw limit input udp - 51820 800 | $PFWENV
portfw-persist | text+$PFWF | router-24.10 | sh:lpfw pause forward tcp 192.168.0.140 80; lpfw limit forward tcp 192.168.0.140 80 900; lpfw resume forward tcp 192.168.0.140 80 | npfw pause forward tcp 192.168.0.140 80; npfw limit forward tcp 192.168.0.140 80 900; npfw resume forward tcp 192.168.0.140 80 | $PFWENV; $PERSIST
portfw-persist-mixed | text+$PFWF | router-24.10 | sh:lpfw limit forward tcp 192.168.0.140 80 900; lpfw limit forward udp 192.168.0.109 27015-27030 0; lpfw resume forward tcp 192.168.0.140 80; lpfw pause forward tcpudp 192.168.0.109 27015-27030 | npfw limit forward tcp 192.168.0.140 80 900; npfw limit forward udp 192.168.0.109 27015-27030 0; npfw resume forward tcp 192.168.0.140 80; npfw pause forward tcpudp 192.168.0.109 27015-27030 | $PFWENV; $PERSIST; $PFWSEED; $PFWRULES
portfw-bad | text+$PFWF | router-24.10 | sh:lpfw; lpfw pause; lpfw pause forward icmp 192.168.0.140 80; lpfw pause forward tcp 1.2.3 80; lpfw pause forward tcp 192.168.0.140 0; lpfw pause forward tcp 192.168.0.140 9-8; lpfw pause x tcp - 80; lpfw limit forward tcp 192.168.0.140 80 | npfw; npfw pause; npfw pause forward icmp 192.168.0.140 80; npfw pause forward tcp 1.2.3 80; npfw pause forward tcp 192.168.0.140 0; npfw pause forward tcp 192.168.0.140 9-8; npfw pause x tcp - 80; npfw limit forward tcp 192.168.0.140 80 | $PFWENV
"
# ── end PR7 ─────────────────────────────────────────────────────────────────
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

# The shaper cases' tc (see STSET): the fixture's devices, then what tc holds.
st_init() {
    mkdir -p "$W/root/tmp/tc-htb"
    TC_STATE="$W/root/tmp/tc-htb" sh "$UC_TESTLIB/tc-htb.sh" init br-lan lan2 lan3 lan4 phy0-ap0 phy1-ap0 wan
}
stt() { echo "--- tc"; TC_STATE="$W/root/tmp/tc-htb" sh "$UC_TESTLIB/tc-htb.sh" dump; }
sttnf() { stt | grep -v '^  filter '; }
# v1.30.0 named "a custom HTB tree" among the root qdiscs it declines; an HTB
# root is in fact reused or replaced, so shape.uc no longer says so (an
# intentional difference). For the legacy side only, the new wording.
htbmsg() {
    local r
    "$@" > "$W/htbmsg.out"; r=$?
    sed 's#SQM/cake or a custom HTB tree#SQM/cake or another non-HTB qdisc#' "$W/htbmsg.out"
    return $r
}
# shape-remove-none compares the reply and the tc state, not the write log:
# v1.30.0 ran its deletes on the class derived from an address with no
# record, which can be another device's; shape.uc runs none (intentional).

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
# A command's text output with the root prefix masked: the shell names the
# rewritten debugfs path in its NSS hint.
wmask() { "$@" | sed "s#$W/root##g"; }
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
# ── notifications ──
# `notify` is new in the CLI, not a port: v1.30.0 has no script for it.
PORTED=$(printf '%s\n' $PORTED | grep -vx notify | tr '\n' ' ')
# ── end notifications ──
# The hotplug hooks' commands replace hook code, not a script the plugin
# runs: compared in the CLI cases above.
PORTED=$(printf '%s\n' $PORTED | grep -vxE 'newdevice|restore' | tr '\n' ' ')
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
    # ── notifications ── new in 1.31, no v1.30.0 method to compare with
    # (tests/test_notify.sh covers them)
    case "$m" in notify_*) continue ;; esac
    # ── end notifications ──
    printf '%s\n' "$covered" | grep -qx "$m" ||
        { FAIL=$((FAIL + 1)); echo "FAIL: rpcd method $m has no equivalence case"; }
done
echo "rpcd plugin: $RPASS cases equal, $RSKIP skipped (no busybox)"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
