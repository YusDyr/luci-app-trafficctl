#!/bin/sh
# A stateful nft for the limiter's table, netdev tm_ratelimit, as verified on
# the OpenWrt 22.03.7 (nftables 1.0.2) and 25.12.4 (nftables 1.1.6) rootfs
# images. Installed as `nft` by tests/lib/limit_env.sh.
#
# nftables 1.0 binds a meter to the one rule that declares it, so a second
# rule naming it fails with "Resource busy"; 1.1 turns it into a named set
# shared by every chain, which outlives its rules and lists as `add @<name>`.
#
#   NFT_STATE        a directory: chains (a name a line), rules ("<handle>
#                    <chain> <text>"), sets, bound (1.0 meters, each bound to
#                    the handle of its rule), handle
#   NFT_LOG          every call appended, arguments joined by spaces
#   NFT_EMU          1.0 (default) or 1.1
#   NFT_FAIL_TABLE   `add table netdev` fails (no kmod-nft-netdev)
#   NFT_FAIL_SET     `add set netdev` fails
#   NFT_FAIL_HOOKS   chains that cannot be created (the device is gone): the
#                    chain, and so every rule in it, fails
#   NFT_FAIL_CHAINS  chains that refuse every rule
#   NFT_FAIL_RULE    "<chain> <text fragment>": that one rule only
# `list tables` names inet fw4; anything else exits 0 and prints nothing.
S="$NFT_STATE"
mkdir -p "$S"
touch "$S/chains" "$S/rules" "$S/sets" "$S/bound"
[ -n "$NFT_LOG" ] && echo "$*" >> "$NFT_LOG"
fail() { echo "Error: Could not process rule: $1" >&2; echo "$2" >&2; exit 1; }
list=0
[ "$1" = "-a" ] && { list=1; shift; }
case "$1 $2 $3" in
    "list tables "*) echo "table inet fw4"; exit 0 ;;
    "add table netdev")
        [ -n "$NFT_FAIL_TABLE" ] && { echo "Error: Could not process rule: Operation not supported" >&2; echo "add table netdev tm_ratelimit" >&2; exit 1; }
        exit 0 ;;
    "add set netdev")
        [ -n "$NFT_FAIL_SET" ] && fail "Operation not supported" "add set $5"
        grep -qx "$5" "$S/sets" || echo "$5" >> "$S/sets"; exit 0 ;;
    "add chain netdev")
        case " $NFT_FAIL_HOOKS " in *" $5 "*) fail "No such file or directory" "add chain $5" ;; esac
        grep -qx "$5" "$S/chains" || echo "$5" >> "$S/chains"; exit 0 ;;
    "add rule netdev")
        chain="$5"; text="$6"
        grep -qx "$chain" "$S/chains" || fail "No such file or directory" "add rule $chain $text"
        case " $NFT_FAIL_CHAINS " in *" $chain "*) fail "Operation not supported" "add rule $chain $text" ;; esac
        if [ -n "$NFT_FAIL_RULE" ] && [ "$chain" = "${NFT_FAIL_RULE%% *}" ]; then
            case "$text" in *"${NFT_FAIL_RULE#* }"*) fail "Operation not supported" "add rule $chain $text" ;; esac
        fi
        h=$(( $(cat "$S/handle" 2>/dev/null || echo 3) + 1 )); echo "$h" > "$S/handle"
        m=$(printf '%s\n' "$text" | sed -n 's/.* meter \([A-Za-z0-9_]*\) .*/\1/p')
        if [ -n "$m" ]; then
            if [ "$NFT_EMU" = "1.1" ]; then
                grep -qx "$m" "$S/sets" || echo "$m" >> "$S/sets"
                text=$(printf '%s\n' "$text" | sed "s/ meter $m / add @$m /")
            else
                grep -q " $m\$" "$S/bound" && fail "Resource busy" "add rule $chain $text"
                echo "$h $m" >> "$S/bound"
                text=$(printf '%s\n' "$text" | sed "s/ meter $m / meter $m size 65535 /")
            fi
        fi
        echo "$h $chain $text" >> "$S/rules"
        exit 0 ;;
    "delete rule netdev")
        h="$7"
        grep -q "^$h " "$S/rules" || exit 1
        grep -v "^$h " "$S/rules" > "$S/r.tmp"; mv "$S/r.tmp" "$S/rules"
        grep -v "^$h " "$S/bound" > "$S/b.tmp"; mv "$S/b.tmp" "$S/bound"
        exit 0 ;;
    "delete set netdev")
        grep -qx "$5" "$S/sets" || exit 1
        grep -qF "@$5 " "$S/rules" && exit 1
        grep -vx "$5" "$S/sets" > "$S/s.tmp"; mv "$S/s.tmp" "$S/sets"
        exit 0 ;;
    "list table netdev")
        [ -s "$S/chains" ] || [ -s "$S/sets" ] || exit 1
        echo "table netdev tm_ratelimit {"
        while read -r s; do
            [ -n "$s" ] && printf '\tset %s {\n\t\ttype ipv4_addr\n\t\tflags dynamic\n\t}\n' "$s"
        done < "$S/sets"
        while read -r c; do
            printf '\tchain %s {\n' "$c"
            awk -v c="$c" -v a="$list" '$2 == c {
                h = $1; $1 = ""; $2 = ""; sub(/^  /, "")
                printf "\t\t%s%s\n", $0, (a ? " # handle " h : "")
            }' "$S/rules"
            printf '\t}\n'
        done < "$S/chains"
        echo "}"
        exit 0 ;;
esac
exit 0
