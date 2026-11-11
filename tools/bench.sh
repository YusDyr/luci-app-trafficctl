#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Benchmark gate for the ucode port: wall time and peak RSS of the legacy
# summary/totals/bytes scripts against `trafficctl summary|totals|bytes`, over
# synthetic conntrack tables. Runs ON the router:
#
#   ssh root@192.168.0.1 sh -s -- 2000 8000 16000 < tools/bench.sh
#
# BENCH_RUNS (default 5) timed runs per cell. BENCH_LEGACY (default
# /usr/libexec/trafficctl) is where the shell scripts are read from: once a
# script is a wrapper for /usr/sbin/trafficctl it is no legacy baseline, so
# point this at an unpacked older release (v1.30.0's usr/libexec/trafficctl).
# A cell is skipped when its side does not have the command: a wrapper on the
# legacy side, a command `trafficctl` does not know yet on the ucode side.
#
# Everything either side writes goes under /tmp/tctl-bench: the legacy copy has
# its paths rewritten, the ucode side gets TCTL_ROOT. Live rules, /etc and the
# real state files are only read.
set -u

B=/tmp/tctl-bench
RUNS="${BENCH_RUNS:-5}"
LEGACY="${BENCH_LEGACY:-/usr/libexec/trafficctl}"
NEW=/usr/sbin/trafficctl
[ $# -gt 0 ] || set -- 2000 8000 16000

rm -rf "$B"
mkdir -p "$B/legacy" "$B/root/proc/net" "$B/root/tmp" "$B/root/etc/trafficctl" "$B/root/var/run"
trap 'rm -rf "$B"' EXIT INT TERM

for f in "$LEGACY"/*.sh; do
    sed -e "s|/usr/libexec/trafficctl/|$B/legacy/|g" \
        -e "s|/proc/net/nf_conntrack|$B/root/proc/net/nf_conntrack|g" \
        -e "s|/etc/trafficctl/|$B/root/etc/trafficctl/|g" \
        -e "s|/tmp/trafficctl_|$B/root/tmp/trafficctl_|g" \
        -e "s|/tmp/\.trafficctl_|$B/root/tmp/.trafficctl_|g" \
        -e "s|/var/run/trafficctl|$B/root/var/run/trafficctl|g" "$f" > "$B/legacy/${f##*/}"
    chmod +x "$B/legacy/${f##*/}"
done
cp -p /etc/trafficctl/* "$B/root/etc/trafficctl/" 2>/dev/null
ln -s /etc/config "$B/root/etc/config"
ln -s /sys "$B/root/sys"
ln -s /tmp/dhcp.leases "$B/root/tmp/dhcp.leases"
for f in dev arp; do ln -s "/proc/net/$f" "$B/root/proc/net/$f"; done
for f in uptime loadavg sys; do ln -s "/proc/$f" "$B/root/proc/$f"; done

# Synthetic table: real LAN clients when there are leases, so lookups hit.
gen() {   # gen <entries>
    leases=/tmp/dhcp.leases
    [ -f "$leases" ] || leases=/dev/null
    awk -v n="$1" 'BEGIN { srand(1) }
    FILENAME != "" { ip[k++] = $3; next }
    END {
        if (!k) for (i = 0; i < 50; i++) ip[k++] = "192.168.0." (100 + i)
        for (i = 0; i < n; i++) {
            s = ip[i % k]; d = sprintf("%d.%d.%d.%d", 20 + i % 200, i % 251, int(i / 251) % 251, 1 + i % 250)
            sp = 1024 + i % 60000; dp = (i % 3) ? 443 : 53; pr = (i % 3) ? "tcp      6" : "udp      17"
            printf "ipv4     2 %s 3600 %s src=%s dst=%s sport=%d dport=%d packets=%d bytes=%d src=%s dst=%s sport=%d dport=%d packets=%d bytes=%d [ASSURED] mark=0 zone=0 use=2\n",
                pr, (i % 3) ? "ESTABLISHED" : "", s, d, sp, dp, 1 + i % 900, 64 + (i * 7919) % 4000000,
                d, s, dp, sp, 1 + i % 1200, 64 + (i * 104729) % 90000000
        }
    }' "$leases" > "$B/root/proc/net/nf_conntrack"
}

now_cs() { cut -d' ' -f1 /proc/uptime | tr -d .; }

# Peak resident memory of a command and all its children, sampled: busybox
# has no `time -v`, and a pipeline of awks peaks in more than one process.
peak_rss() {   # peak_rss <cmd...>  -> kB
    "$@" >/dev/null 2>&1 &
    pid=$! peak=0
    while kill -0 "$pid" 2>/dev/null; do
        cur=$(cat /proc/[0-9]*/stat 2>/dev/null | awk -v root="$pid" '
            { p = $1; sub(/^.*\) /, ""); pp[p] = $2; rss[p] = $22 }
            END {
                in_tree[root] = 1
                do { more = 0
                     for (p in pp) if (!(p in in_tree) && (pp[p] in in_tree)) { in_tree[p] = 1; more = 1 }
                } while (more)
                for (p in in_tree) t += rss[p]
                print t * 4
            }')
        [ "${cur:-0}" -gt "$peak" ] && peak=$cur
    done
    wait "$pid" 2>/dev/null
    echo "$peak"
}

cell() {   # cell <label> <cmd...>
    label=$1; shift
    "$@" >/dev/null 2>&1   # warm the page cache and the state files
    t0=$(now_cs); i=0
    while [ "$i" -lt "$RUNS" ]; do "$@" >/dev/null 2>&1; i=$((i + 1)); done
    t1=$(now_cs)
    printf '%-8s %7s %-7s %8d %9d\n' "$case" "$n" "$label" $(( (t1 - t0) * 10 / RUNS )) "$(peak_rss "$@")"
}

new() { TCTL_ROOT="$B/root" "$NEW" "$@"; }

# The usage line lists every command: "usage: trafficctl <a|b|c> [args]".
new_has() { [ -x "$NEW" ] && "$NEW" 2>/dev/null | grep -q "[<|]$1[|>]"; }
legacy_has() { [ -f "$B/legacy/trafficctl-$1.sh" ] && ! grep -q '^exec /usr/sbin/trafficctl' "$B/legacy/trafficctl-$1.sh"; }

printf '%-8s %7s %-7s %8s %9s\n' case entries impl wall_ms peak_kB
for n in "$@"; do
    gen "$n"
    for case in summary totals bytes; do
        legacy_has "$case" && cell legacy sh "$B/legacy/trafficctl-$case.sh"
        new_has "$case" && cell ucode new "$case"
    done
done
