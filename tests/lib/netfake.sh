#!/bin/sh
# A stateful nft and conntrack for the global cut and port-forward tests, in
# a state directory ($NETFAKE): netfake.sh nft|conntrack <args>.
#
# Only our own tables are modelled: inet tctl_cut (the text `nft -f -`
# loaded, listed back as it was given) and inet tctl_pfw (chains of rules
# with handles). `list ruleset` adds <dir>/ruleset, the rest of the router.
# Every call that changes something is appended to <dir>/calls, a script fed
# to `nft -f -` with it, so two implementations can be compared on exactly
# what they did to the kernel; reads are not logged.
#
# Flags, as files in the directory:
#   no_nft         nft cannot list inet tables (no nf_tables)
#   no_fib         a script using fib is refused whole (no nft_fib), as the
#                  atomic transaction it is
#   strip_local    the load reports success but the router-local accept is
#                  missing from what lists back
#   fail_rule      adding or inserting a tctl_pfw rule fails
#   no_conntrack   conntrack -C fails (nf_conntrack not loaded)
D="${NETFAKE:?}"
tool="$1"
shift
log() { printf '%s\n' "$*" >> "$D/calls"; }

if [ "$tool" = conntrack ]; then
    log "conntrack $*"
    case "$1" in
        -C) [ -f "$D/no_conntrack" ] && exit 1; echo 42 ;;
    esac
    exit 0
fi

pfw_list() {   # pfw_list <chain> <with handles: 0|1>
    printf '\tchain %s {\n' "$1"
    case "$1" in
        pfw_forward) printf '\t\ttype filter hook forward priority filter - 190; policy accept;\n' ;;
        pfw_input) printf '\t\ttype filter hook input priority filter - 190; policy accept;\n' ;;
    esac
    if [ "$2" = 1 ]; then
        sed 's/^/\t\t/' "$D/pfw.$1"
    else
        sed -e 's/ # handle [0-9]*$//' -e 's/^/\t\t/' "$D/pfw.$1"
    fi
    printf '\t}\n'
}

next_handle() {
    n=$(cat "$D/handle" 2>/dev/null || echo 10)
    n=$((n + 1))
    echo "$n" > "$D/handle"
    echo "$n"
}

case "$*" in
    # v1.30's trafficctl-fw.sh probes `nft list tables` when it is sourced.
    "list tables inet" | "list tables")
        [ -f "$D/no_nft" ] && exit 1
        echo "table inet fw4"
        [ -f "$D/tctl_cut" ] && echo "table inet tctl_cut"
        [ -f "$D/tctl_pfw" ] && echo "table inet tctl_pfw"
        exit 0
        ;;
    "list table inet tctl_cut")
        [ -f "$D/tctl_cut" ] || { echo "Error: No such file or directory" >&2; exit 1; }
        cat "$D/tctl_cut"
        exit 0
        ;;
    "delete table inet tctl_cut")
        log "nft $*"
        [ -f "$D/tctl_cut" ] || exit 1
        rm -f "$D/tctl_cut"
        exit 0
        ;;
    "list ruleset")
        cat "$D/ruleset" 2>/dev/null
        cat "$D/tctl_cut" 2>/dev/null
        exit 0
        ;;
    "-f -")
        script=$(cat)
        log "nft -f -"
        printf '%s\n' "$script" | sed 's/^/  | /' >> "$D/calls"
        if [ -f "$D/no_fib" ] && printf '%s' "$script" | grep -q 'fib '; then
            echo "Error: Could not process rule: No such file or directory" >&2
            exit 1
        fi
        # The table block as loaded; the add/delete pair in front of it
        # replaces whatever was there.
        body=$(printf '%s\n' "$script" | sed -n '/^table inet tctl_cut {/,$p')
        if [ -f "$D/strip_local" ]; then
            printf '%s\n' "$body" | grep -v 'fib daddr type' > "$D/tctl_cut"
        else
            printf '%s\n' "$body" > "$D/tctl_cut"
        fi
        exit 0
        ;;
    "list table inet tctl_pfw")
        [ -f "$D/tctl_pfw" ] || { echo "Error: No such file or directory" >&2; exit 1; }
        echo "table inet tctl_pfw {"
        first=1
        for c in pfw_forward pfw_input; do
            [ -f "$D/pfw.$c" ] || continue
            [ "$first" = 1 ] || echo
            first=0
            pfw_list "$c" 0
        done
        echo "}"
        exit 0
        ;;
esac

case "$1 $2 $3 $4" in
    "add table inet tctl_pfw")
        log "nft $*"
        : > "$D/tctl_pfw"
        exit 0
        ;;
    "add chain inet tctl_pfw")
        log "nft $*"
        [ -f "$D/tctl_pfw" ] || exit 1
        [ -f "$D/pfw.$5" ] || : > "$D/pfw.$5"
        exit 0
        ;;
    "insert rule inet tctl_pfw" | "add rule inet tctl_pfw")
        log "nft $*"
        op=$1 chain=$5
        shift 5
        [ -f "$D/pfw.$chain" ] || exit 1
        [ -f "$D/fail_rule" ] && exit 1
        rule="$* # handle $(next_handle)"
        if [ "$op" = insert ]; then
            { printf '%s\n' "$rule"; cat "$D/pfw.$chain"; } > "$D/pfw.tmp"
        else
            { cat "$D/pfw.$chain"; printf '%s\n' "$rule"; } > "$D/pfw.tmp"
        fi
        mv "$D/pfw.tmp" "$D/pfw.$chain"
        exit 0
        ;;
    "delete rule inet tctl_pfw")
        log "nft $*"
        [ "$6" = handle ] && [ -f "$D/pfw.$5" ] || exit 1
        grep -q " # handle $7\$" "$D/pfw.$5" || exit 1
        grep -v " # handle $7\$" "$D/pfw.$5" > "$D/pfw.tmp"
        mv "$D/pfw.tmp" "$D/pfw.$5"
        exit 0
        ;;
    "-a list chain inet")
        [ "$5" = tctl_pfw ] && [ -f "$D/pfw.$6" ] || { echo "Error: No such file or directory" >&2; exit 1; }
        echo "table inet tctl_pfw {"
        pfw_list "$6" 1
        echo "}"
        exit 0
        ;;
esac
echo "netfake: nft $* is not modelled" >&2
log "nft $* (not modelled)"
exit 1
