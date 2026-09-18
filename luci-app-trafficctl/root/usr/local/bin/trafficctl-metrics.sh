#!/bin/sh
# shellcheck shell=dash
# Prometheus / OpenMetrics exporter for trafficctl.
#
# Writes to stdout so one implementation serves both delivery paths:
#   scrape endpoint : /www/cgi-bin/trafficctl-metrics (uhttpd)
#   textfile        : cron > /var/lib/node_exporter/textfile_collector/trafficctl.prom
#
# Memory discipline (this runs on 128–512 MB routers):
#   * no large shell variables — the byte source is streamed straight into awk
#   * one awk process holds the only in-memory table, bounded by device count
#   * the state file is a few dozen bytes per device, kept in /tmp (tmpfs), so
#     scraping never writes to flash
#
# Counter semantics: the raw conntrack sums are NOT monotonic — a device's
# total drops when its flows expire. Exporting them directly would look like a
# counter reset on every expiry and produce nonsense rate(). So positive deltas
# are accumulated into a monotonic per-device counter here. A decrease means
# flows aged out (their bytes were already accumulated while they lived), so it
# resyncs the baseline and adds nothing.
#
# Usage: trafficctl-metrics.sh

. /usr/local/bin/trafficctl-fw.sh

STATE="/tmp/trafficctl_metrics.state"

metrics_enabled() {
    [ "$(uci -q get trafficctl.metrics.enabled 2>/dev/null)" = "1" ]
}

if ! metrics_enabled; then
    echo "# trafficctl metrics are disabled (set trafficctl.metrics.enabled=1)"
    exit 0
fi

opt_on() {
    # default-on toggles: anything but an explicit 0 counts as enabled
    [ "$(uci -q get "trafficctl.metrics.$1" 2>/dev/null)" != "0" ]
}

NOW=$(date +%s)

# ── device byte counters ────────────────────────────────────────────────────
# trafficctl-bytes.sh already resolves the right source (conntrack, or nft
# counters under uncountered offload) and handles routed/NATed clients, so it
# is reused rather than duplicating that logic here.
/usr/local/bin/trafficctl-bytes.sh 2>/dev/null \
    | sed 's/},{/}\n{/g' \
    | awk -v state="$STATE" -v now="$NOW" '
function num(line, key,   re, seg) {
    re = "\"" key "\"[ \t]*:[ \t]*"
    if (!match(line, re)) return -1
    seg = substr(line, RSTART + RLENGTH)
    if (!match(seg, /^[0-9]+/)) return -1
    return substr(seg, RSTART, RLENGTH) + 0
}
function str(line, key,   re, seg) {
    re = "\"" key "\"[ \t]*:[ \t]*\""
    if (!match(line, re)) return ""
    seg = substr(line, RSTART + RLENGTH)
    if (!match(seg, /"/)) return ""
    return substr(seg, 1, RSTART - 1)
}
BEGIN {
    # prior state: ip rx_acc tx_acc rx_last tx_last seen
    while ((getline l < state) > 0) {
        n = split(l, f, " ")
        if (n < 5) continue
        rxa[f[1]] = f[2] + 0; txa[f[1]] = f[3] + 0
        rxl[f[1]] = f[4] + 0; txl[f[1]] = f[5] + 0
    }
    close(state)
}
{
    ip = str($0, "ip")
    if (ip == "") next
    rx = num($0, "bytes_in"); tx = num($0, "bytes_out")
    if (rx < 0) rx = 0
    if (tx < 0) tx = 0

    # Only positive movement is real new traffic; a drop means flows expired.
    if (ip in rxl) {
        if (rx > rxl[ip]) rxa[ip] += rx - rxl[ip]
        if (tx > txl[ip]) txa[ip] += tx - txl[ip]
    } else {
        rxa[ip] += rx; txa[ip] += tx
    }
    rxl[ip] = rx; txl[ip] = tx
    live[ip] = 1
}
END {
    tmp = state ".tmp"
    for (ip in rxl) {
        # Drop devices that have gone quiet AND carry no total, so the state
        # file cannot grow without bound on a busy network.
        if (!(ip in live) && rxa[ip] + txa[ip] == 0) continue
        printf "%s %.0f %.0f %.0f %.0f %d\n", ip, rxa[ip], txa[ip], rxl[ip], txl[ip], now > tmp
    }
    close(tmp)
    system("mv " tmp " " state " 2>/dev/null")

    print "# HELP trafficctl_device_bytes_total Bytes transferred per device since the exporter started."
    print "# TYPE trafficctl_device_bytes_total counter"
    for (ip in rxa) {
        printf "trafficctl_device_bytes_total{ip=\"%s\",direction=\"rx\"} %.0f\n", ip, rxa[ip]
        printf "trafficctl_device_bytes_total{ip=\"%s\",direction=\"tx\"} %.0f\n", ip, txa[ip]
    }
}'

# ── per-device state gauges ─────────────────────────────────────────────────
# Off by default for the leanest possible scrape: this calls the full summary,
# which dumps nft/tc state and is markedly heavier than the byte pass.
if opt_on state; then
    /usr/local/bin/trafficctl-summary.sh 2>/dev/null \
        | sed 's/},{/}\n{/g' \
        | awk -v rdnsfile=/tmp/trafficctl_rdns_cache '
function num(line, key,   re, seg) {
    re = "\"" key "\"[ \t]*:[ \t]*"
    if (!match(line, re)) return 0
    seg = substr(line, RSTART + RLENGTH)
    if (!match(seg, /^[0-9]+/)) return 0
    return substr(seg, RSTART, RLENGTH) + 0
}
function str(line, key,   re, seg) {
    re = "\"" key "\"[ \t]*:[ \t]*\""
    if (!match(line, re)) return ""
    seg = substr(line, RSTART + RLENGTH)
    if (!match(seg, /"/)) return ""
    return substr(seg, 1, RSTART - 1)
}
function esc(v) { gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); return v }
BEGIN {
    # Reverse-DNS names resolved in the background; "-" is a cached miss.
    while ((getline l < rdnsfile) > 0) {
        n = split(l, f, " ")
        if (n >= 2 && f[2] != "-") rdns[f[1]] = f[2]
    }
    close(rdnsfile)
    print "# HELP trafficctl_device_connections Active tracked connections per device."
    print "# TYPE trafficctl_device_connections gauge"
    print "# HELP trafficctl_device_blocked Whether the device is blocked from the internet."
    print "# TYPE trafficctl_device_blocked gauge"
    print "# HELP trafficctl_device_limit_kbit Applied throttle in kbit/s (0 = none)."
    print "# TYPE trafficctl_device_limit_kbit gauge"
    print "# HELP trafficctl_device_wifi_blocked Whether the device is denied on WiFi."
    print "# TYPE trafficctl_device_wifi_blocked gauge"
    print "# HELP trafficctl_device_conntrack_bytes Bytes currently accounted in conntrack (falls as flows expire)."
    print "# TYPE trafficctl_device_conntrack_bytes gauge"
    print "# HELP trafficctl_device_blocked_bytes Bytes dropped by the block rule."
    print "# TYPE trafficctl_device_blocked_bytes gauge"
    print "# HELP trafficctl_device_info Device metadata; the value is always 1."
    print "# TYPE trafficctl_device_info gauge"
}
{
    ip = str($0, "ip")
    if (ip == "") next
    printf "trafficctl_device_connections{ip=\"%s\"} %d\n", ip, num($0, "conns")
    printf "trafficctl_device_blocked{ip=\"%s\"} %d\n", ip, (index($0, "\"blocked\":true") ? 1 : 0)
    printf "trafficctl_device_wifi_blocked{ip=\"%s\"} %d\n", ip, (index($0, "\"wifi_blocked\":true") ? 1 : 0)
    printf "trafficctl_device_limit_kbit{ip=\"%s\",mode=\"limiter\"} %d\n", ip, num($0, "rate_limit_kbit")
    printf "trafficctl_device_limit_kbit{ip=\"%s\",mode=\"shaper\"} %d\n", ip, num($0, "shape_kbit")
    # Conntrack view: current in-flight totals and the protocol split.
    printf "trafficctl_device_conntrack_bytes{ip=\"%s\",proto=\"all\"} %.0f\n", ip, num($0, "total")
    printf "trafficctl_device_conntrack_bytes{ip=\"%s\",proto=\"tcp\"} %.0f\n", ip, num($0, "tcp")
    printf "trafficctl_device_conntrack_bytes{ip=\"%s\",proto=\"udp\"} %.0f\n", ip, num($0, "udp")
    printf "trafficctl_device_blocked_bytes{ip=\"%s\"} %.0f\n", ip, num($0, "block_bytes")
    # Names/MACs live on an info metric rather than on the counters: churn in a
    # label would otherwise start a brand new time series for the same device.
    # Hoisted rather than inlined as esc(ip in rdns ? ...): BusyBox awk parses
    # an "in" test inside a call argument differently and silently drops the
    # whole statement.
    rd = ""
    if (ip in rdns) rd = rdns[ip]
    printf "trafficctl_device_info{ip=\"%s\",name=\"%s\",mac=\"%s\",link=\"%s\",app=\"%s\",rdns=\"%s\"} 1\n", \
        ip, esc(str($0, "name")), esc(str($0, "mac")), esc(str($0, "conn_type")), esc(str($0, "app")), esc(rd)
}'
fi

# ── port forwards ───────────────────────────────────────────────────────────
if opt_on portfw; then
    /usr/local/bin/trafficctl-portfw.sh list 2>/dev/null \
        | sed 's/},{/}\n{/g' \
        | awk '
function num(line, key,   re, seg) {
    re = "\"" key "\"[ \t]*:[ \t]*"
    if (!match(line, re)) return 0
    seg = substr(line, RSTART + RLENGTH)
    if (!match(seg, /^[0-9]+/)) return 0
    return substr(seg, RSTART, RLENGTH) + 0
}
function str(line, key,   re, seg) {
    re = "\"" key "\"[ \t]*:[ \t]*\""
    if (!match(line, re)) return ""
    seg = substr(line, RSTART + RLENGTH)
    if (!match(seg, /"/)) return ""
    return substr(seg, 1, RSTART - 1)
}
function esc(v) { gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); return v }
BEGIN {
    print "# HELP trafficctl_portfw_connections Active inbound connections per port forward."
    print "# TYPE trafficctl_portfw_connections gauge"
    print "# HELP trafficctl_portfw_clients Distinct remote clients per port forward."
    print "# TYPE trafficctl_portfw_clients gauge"
    print "# HELP trafficctl_portfw_paused Whether inbound traffic is paused."
    print "# TYPE trafficctl_portfw_paused gauge"
    print "# HELP trafficctl_portfw_enabled Whether the firewall rule itself is enabled."
    print "# TYPE trafficctl_portfw_enabled gauge"
    print "# HELP trafficctl_portfw_limit_kbit Inbound rate limit in kbit/s (0 = none)."
    print "# TYPE trafficctl_portfw_limit_kbit gauge"
    print "# HELP trafficctl_portfw_bytes Bytes currently accounted per port forward."
    print "# TYPE trafficctl_portfw_bytes gauge"
}
{
    id = str($0, "id")
    if (id == "") next
    lbl = sprintf("name=\"%s\",proto=\"%s\",port=\"%s\"", \
        esc(str($0, "name")), esc(str($0, "proto")), esc(str($0, "ext_port")))
    printf "trafficctl_portfw_connections{%s} %d\n", lbl, num($0, "conns")
    printf "trafficctl_portfw_clients{%s} %d\n", lbl, num($0, "clients")
    printf "trafficctl_portfw_paused{%s} %d\n", lbl, (index($0, "\"paused\":true") ? 1 : 0)
    printf "trafficctl_portfw_enabled{%s} %d\n", lbl, (index($0, "\"enabled\":true") ? 1 : 0)
    printf "trafficctl_portfw_limit_kbit{%s} %d\n", lbl, num($0, "limit_kbit")
    printf "trafficctl_portfw_bytes{%s,direction=\"rx\"} %.0f\n", lbl, num($0, "bytes_in")
    printf "trafficctl_portfw_bytes{%s,direction=\"tx\"} %.0f\n", lbl, num($0, "bytes_out")
}'
fi

# ── DPI application labels ──────────────────────────────────────────────────
# Off by default: device × application is a cardinality trap on a busy network.
if [ "$(uci -q get trafficctl.metrics.apps 2>/dev/null)" = "1" ]; then
    /usr/local/bin/trafficctl-netify.sh list 2>/dev/null \
        | sed -e 's/\]},{/]}\n{/g' \
        | awk '
BEGIN {
    print "# HELP trafficctl_app_bytes Bytes per device per application in the last DPI sample."
    print "# TYPE trafficctl_app_bytes gauge"
}
{
    if (!match($0, /"ip":"[^"]*"/)) next
    ip = substr($0, RSTART + 6, RLENGTH - 7)
    rest = $0
    # Match the whole app object, not just up to "bytes" — "flows" follows it.
    while (match(rest, /\{"name":"[^"]*","bytes":[0-9]+[^}]*\}/)) {
        rec = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        if (!match(rec, /"name":"[^"]*"/)) continue
        app = substr(rec, RSTART + 8, RLENGTH - 9)
        if (!match(rec, /"bytes":[0-9]+/)) continue
        b = substr(rec, RSTART + 8, RLENGTH - 8) + 0
        printf "trafficctl_app_bytes{ip=\"%s\",app=\"%s\"} %.0f\n", ip, app, b
        if (match(rec, /"flows":[0-9]+/))
            printf "trafficctl_app_flows{ip=\"%s\",app=\"%s\"} %d\n", ip, app, \
                substr(rec, RSTART + 8, RLENGTH - 8) + 0
    }
}'
fi

echo "# HELP trafficctl_up Always 1; presence indicates the exporter ran."
echo "# TYPE trafficctl_up gauge"
echo "trafficctl_up 1"
