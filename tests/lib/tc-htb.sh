#!/bin/sh
# A stateful stand-in for the tc and `ip link` calls of the shaper
# (trafficctl shape, its restore, and the v1.30.x trafficctl-shape.sh), so a
# test can read what the router would hold afterwards instead of matching
# command lines. Kernel behaviour it keeps, because the shaper depends on it:
#
#   - a u32 `filter del` with no handle removes every filter of that prio on
#     the device, whatever match it is given; with a handle, that one filter;
#   - an HTB class a filter still points at cannot be deleted (EBUSY), and
#     deleting a class deletes its leaf qdisc;
#   - `qdisc add ... root` fails while a root other than the default is there,
#     and deleting the root takes the classes, leaves and filters with it;
#   - tc on a device that does not exist fails, and so does `class add` for a
#     classid already there.
#
# Usage: tc-htb.sh tc <args>    tc-htb.sh ip <args>
#        tc-htb.sh init <dev>...   devices that exist (root qdisc noqueue)
#        tc-htb.sh dump            the state, normalised, for comparing
# Environment:
#   TC_STATE    the state directory (required)
#   TC_LOG      every write is appended here as "tc ..."/"ip ...", if set
#   TC_NO_IFB   1: `ip link add ... type ifb` fails as without kmod-ifb
#   TC_FAIL     a tc write whose arguments contain this text fails
#   TC_ROOT_<dev>  (init only) a root qdisc kind other than noqueue, e.g. cake

S="${TC_STATE:?TC_STATE is not set}"
mkdir -p "$S/links"
prog="$1"
shift

err() { echo "$*" >&2; exit 2; }
has_dev() { [ -f "$S/links/$1" ]; }
need_dev() { has_dev "$1" || { echo "Cannot find device \"$1\"" >&2; exit 1; }; }
root_of() { cat "$S/$1/root" 2>/dev/null || echo noqueue; }
logw() { [ -n "${TC_LOG:-}" ] && echo "$prog $*" >> "$TC_LOG"; return 0; }

# A tc rate as the kernel prints it: 5000kbit is 5Mbit, 1000mbit is 1Gbit.
fmt_rate() {
    awk -v r="$1" 'BEGIN {
        n = r + 0; u = tolower(substr(r, length(n "") + 1))
        m = (u == "gbit") ? 1e9 : (u == "mbit") ? 1e6 : (u == "kbit") ? 1e3 : 1
        b = n * m
        if (b % 1e9 == 0) printf "%dGbit", b / 1e9
        else if (b % 1e6 == 0) printf "%dMbit", b / 1e6
        else if (b % 1e3 == 0) printf "%dKbit", b / 1e3
        else printf "%dbit", b
    }'
}

hexip() { echo "$1" | awk -F'[./]' '{ printf "%02x%02x%02x%02x", $1, $2, $3, $4 }'; }

case "$prog" in
init)
    for d in "$@"; do
        : > "$S/links/$d"
        mkdir -p "$S/$d"
        k=$(printf '%s' "$d" | tr -c 'a-zA-Z0-9\n' '_')
        eval "kind=\${TC_ROOT_$k:-}"
        # shellcheck disable=SC2154
        [ -n "$kind" ] && echo "$kind" > "$S/$d/root"
    done
    exit 0 ;;
dump)
    for f in "$S"/links/*; do
        [ -e "$f" ] || continue
        d=${f##*/}
        echo "dev $d root $(root_of "$d")"
        [ -f "$S/$d/classes" ] && sort "$S/$d/classes" | sed 's/^/  class /'
        [ -f "$S/$d/leaves" ] && sort "$S/$d/leaves" | sed 's/^/  leaf fq_codel /'
        [ -f "$S/$d/filters" ] && awk '{ print "  filter prio " $2 " " $3 " " $4 " flowid " $5 }' "$S/$d/filters" | sort
        [ -f "$S/$d/ingress" ] && echo "  ingress"
        [ -f "$S/$d/mirred" ] && echo "  mirred to $(cat "$S/$d/mirred")"
    done
    exit 0 ;;
ip)
    [ "$1" = link ] || exit 1
    case "$2" in
    show)
        has_dev "$3" || { echo "Device \"$3\" does not exist." >&2; exit 1; }
        printf '7: %s: <BROADCAST,NOARP,UP,LOWER_UP> mtu 1500 qdisc noqueue state UNKNOWN mode DEFAULT group default qlen 32\n' "$3"
        exit 0 ;;
    add)
        logw "$@"
        [ "$3" = name ] || exit 1
        case " $* " in
            *" type ifb "*) [ "${TC_NO_IFB:-}" = 1 ] && err "Error: Unknown device type." ;;
        esac
        has_dev "$4" && err "RTNETLINK answers: File exists"
        : > "$S/links/$4"; mkdir -p "$S/$4"
        exit 0 ;;
    set)
        logw "$@"
        has_dev "$3" || { echo "Cannot find device \"$3\"" >&2; exit 1; }
        exit 0 ;;
    esac
    exit 1 ;;
tc) ;;
*) echo "tc-htb.sh: unknown program $prog" >&2; exit 2 ;;
esac

# ── tc ──────────────────────────────────────────────────────────────────────
stats=0
[ "$1" = -s ] && { stats=1; shift; }
obj="$1" op="$2"
[ "$3" = dev ] || err "tc-htb.sh: expected dev in: $*"
dev="$4"
shift 4
need_dev "$dev"
D="$S/$dev"
mkdir -p "$D"

case "$op" in
show) ;;
*)
    logw "$obj $op dev $dev $*"
    if [ -n "${TC_FAIL:-}" ]; then
        case "$obj $op dev $dev $*" in *"$TC_FAIL"*) err "RTNETLINK answers: Operation not supported" ;; esac
    fi ;;
esac

# Named arguments after the device: parent, classid, handle, prio, rate, ...
arg() {   # arg <name> <args...>
    n="$1"; shift
    while [ $# -gt 0 ]; do
        [ "$1" = "$n" ] && { echo "$2"; return 0; }
        shift
    done
    return 1
}

case "$obj $op" in
"qdisc show")
    if [ "$1" = ingress ]; then
        [ -f "$D/ingress" ] && echo "qdisc ingress ffff: parent ffff:fff1 ----------------"
        exit 0
    fi
    k=$(root_of "$dev")
    case "$k" in
        htb) echo "qdisc htb 1: root refcnt 2 r2q 10 default 0xfffe direct_packets_stat 0 direct_qlen 1000" ;;
        *) echo "qdisc $k 0: root refcnt 2" ;;
    esac
    i=1
    [ -f "$D/leaves" ] && while read -r c; do
        printf 'qdisc fq_codel 80%02x: parent %s limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 4Mb ecn drop_batch 64 \n' "$i" "$c"
        i=$((i + 1))
    done < "$D/leaves"
    [ -f "$D/ingress" ] && echo "qdisc ingress ffff: parent ffff:fff1 ----------------"
    exit 0 ;;
"qdisc del")
    if [ "$1" = root ]; then
        [ "$(root_of "$dev")" = noqueue ] && err "Error: Cannot delete qdisc with handle of zero."
        rm -f "$D/root" "$D/classes" "$D/leaves" "$D/filters" "$D/fh"
        exit 0
    fi
    p=$(arg parent "$@") || err "tc-htb.sh: qdisc del without parent"
    grep -qx "$p" "$D/leaves" 2>/dev/null || err "Error: Invalid handle."
    grep -vx "$p" "$D/leaves" > "$D/leaves.new"; mv "$D/leaves.new" "$D/leaves"
    exit 0 ;;
"qdisc add")
    if [ "$1" = root ]; then
        [ "$(root_of "$dev")" = noqueue ] || err "Error: Exclusivity flag on, cannot modify."
        case " $* " in *" htb "*) echo htb > "$D/root" ;; *) echo "$4" > "$D/root" ;; esac
        exit 0
    fi
    if [ "$1" = handle ] && [ "$3" = ingress ]; then
        [ -f "$D/ingress" ] && err "Error: Exclusivity flag on, cannot modify."
        : > "$D/ingress"
        exit 0
    fi
    p=$(arg parent "$@") || err "tc-htb.sh: qdisc add without parent"
    awk -v c="$p" '$1 == c { f = 1 } END { exit !f }' "$D/classes" 2>/dev/null || err "Error: Failed to find specified qdisc."
    grep -qx "$p" "$D/leaves" 2>/dev/null && err "Error: Exclusivity flag on, cannot modify."
    echo "$p" >> "$D/leaves"
    exit 0 ;;
"class add")
    [ "$(root_of "$dev")" = htb ] || err "Error: Failed to find qdisc with specified handle."
    p=$(arg parent "$@"); c=$(arg classid "$@")
    awk -v c="$c" '$1 == c { f = 1 } END { exit !f }' "$D/classes" 2>/dev/null && err "RTNETLINK answers: File exists"
    if [ "$p" != "1:" ]; then
        awk -v c="$p" '$1 == c { f = 1 } END { exit !f }' "$D/classes" 2>/dev/null || err "Error: Specified class not found."
    fi
    echo "$c $p $(arg rate "$@") $(arg ceil "$@") $(arg burst "$@") $(arg cburst "$@") $(arg prio "$@" || echo 0)" >> "$D/classes"
    exit 0 ;;
"class del")
    c=$(arg classid "$@")
    awk -v c="$c" '$1 == c { f = 1 } END { exit !f }' "$D/classes" 2>/dev/null || err "Error: Specified class not found."
    awk -v c="$c" '$5 == c { f = 1 } END { exit !f }' "$D/filters" 2>/dev/null && err "Error: Class is in use."
    awk -v c="$c" '$2 == c { f = 1 } END { exit !f }' "$D/classes" && err "Error: Class has children."
    awk -v c="$c" '$1 != c' "$D/classes" > "$D/classes.new"; mv "$D/classes.new" "$D/classes"
    if [ -f "$D/leaves" ]; then grep -vx "$c" "$D/leaves" > "$D/leaves.new"; mv "$D/leaves.new" "$D/leaves"; fi
    exit 0 ;;
"class show")
    c=$(arg classid "$@")
    [ -f "$D/classes" ] || exit 0
    while read -r id par rate ceil burst cburst prio; do
        [ -n "$c" ] && [ "$id" != "$c" ] && continue
        if [ "$par" = "1:" ]; then
            where="root"
        else
            where="parent $par"
            grep -qx "$id" "$D/leaves" 2>/dev/null && where="$where leaf 80$(echo "$id" | sed 's/^1://'):"
            where="$where prio $prio"
        fi
        echo "class htb $id $where rate $(fmt_rate "$rate") ceil $(fmt_rate "$ceil") burst $burst cburst $cburst "
        if [ "$stats" = 1 ]; then
            echo " Sent 0 bytes 0 pkt (dropped 0, overlimits 0 requeues 0) "
            echo " backlog 0b 0p requeues 0"
            echo " lended: 0 borrowed: 0 giants: 0"
            echo " tokens: 0 ctokens: 0"
            echo
        fi
    done < "$D/classes"
    exit 0 ;;
"filter show")
    p=$(arg parent "$@")
    case "$p" in
    ffff:)
        [ -f "$D/mirred" ] || exit 0
        echo "filter protocol ip pref 1 u32 chain 0 "
        echo "filter protocol ip pref 1 u32 chain 0 fh 800: ht divisor 1 "
        echo "filter protocol ip pref 1 u32 chain 0 fh 800::800 order 2048 key ht 800 bkt 0 terminal flowid ??? not_in_hw "
        echo "  match 00000000/00000000 at 0"
        printf '\taction order 1: mirred (Egress Redirect to device %s) stolen\n' "$(cat "$D/mirred")"
        printf '\tindex 1 ref 1 bind 1\n\n'
        exit 0 ;;
    esac
    [ -s "$D/filters" ] || exit 0
    for pr in $(awk '{ print $2 }' "$D/filters" | sort -un); do
        echo "filter protocol ip pref $pr u32 chain 0 "
        echo "filter protocol ip pref $pr u32 chain 0 fh 800: ht divisor 1 "
        awk -v pr="$pr" '$2 == pr' "$D/filters" | while read -r h _ dir ip flow; do
            o=$(printf '%d' "0x${h##*:}")
            echo "filter protocol ip pref $pr u32 chain 0 fh $h order $o key ht 800 bkt 0 *flowid $flow not_in_hw "
            [ "$dir" = dst ] && at=16 || at=12
            echo "  match $(hexip "$ip")/ffffffff at $at"
        done
    done
    exit 0 ;;
"filter add")
    p=$(arg parent "$@")
    if [ "$p" = ffff: ]; then
        [ -f "$D/ingress" ] || err "Error: Parent Qdisc doesn't exists."
        [ -f "$D/mirred" ] && err "RTNETLINK answers: File exists"
        arg dev "$@" > "$D/mirred"
        exit 0
    fi
    [ "$(root_of "$dev")" = htb ] || err "Error: Parent Qdisc doesn't exists."
    pr=$(arg prio "$@"); flow=$(arg flowid "$@")
    m=$(echo " $* " | sed -nE 's/.* match ip (dst|src) ([^ ]*) .*/\1 \2/p')
    [ -n "$m" ] || err "tc-htb.sh: not emulated: filter add dev $dev $*"
    dir=${m% *} ip=${m#* }
    n=$(cat "$D/fh" 2>/dev/null || echo 2048)
    echo "$((n + 1))" > "$D/fh"
    echo "800::$(printf '%x' "$n") $pr $dir $ip $flow" >> "$D/filters"
    exit 0 ;;
"filter del")
    pr=$(arg prio "$@")
    if h=$(arg handle "$@"); then
        awk -v h="$h" -v pr="$pr" '$1 == h && $2 == pr { f = 1 } END { exit !f }' "$D/filters" 2>/dev/null \
            || err "Error: Filter with specified handle not found."
        awk -v h="$h" '$1 != h' "$D/filters" > "$D/filters.new"
    else
        # The kernel's u32: no handle, the whole prio goes.
        awk -v pr="$pr" '$2 == pr { f = 1 } END { exit !f }' "$D/filters" 2>/dev/null \
            || err "Error: Filter with specified priority/protocol not found."
        awk -v pr="$pr" '$2 != pr' "$D/filters" > "$D/filters.new"
    fi
    mv "$D/filters.new" "$D/filters"
    exit 0 ;;
esac
err "tc-htb.sh: not emulated: tc $obj $op dev $dev $*"
