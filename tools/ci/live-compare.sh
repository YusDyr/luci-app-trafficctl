#!/bin/bash
# Compares the output of tools/ci/live-readers.sh: the v1.30.0 shell readers
# against the ucode CLI on the same kernel state.
#
# Usage: live-compare.sh <out dir> <nft major.minor, e.g. 1.0 or 1.1>
#
# One difference is expected, on nftables 1.1 only: it lists a per-address
# meter as "add @set { ... }", which the shell readers did not recognise as
# a meter, so they reported the each-mode limits (192.168.0.70 and
# 10.0.20.0/24 in the writers' state) as shared. The port reads the JSON and
# reports each. On 1.1 the legacy output must show exactly that and nothing
# else; on 1.0 the two must be equal.
set -u
out="$1" nftv="$2"
fail=0
# shellcheck disable=SC2016
EACH='(.. | objects | select(has("mode") and (((.target // .ip) == "192.168.0.70") or ((.target // .ip) == "10.0.20.0/24")))) .mode'

for c in ratelimit-stats shape-stats rules; do
    l="$out/legacy/$c.json" n="$out/new/$c.json"
    if ! jq -e . "$n" >/dev/null 2>&1; then
        echo "FAIL: $c: the ucode CLI printed no JSON"; cat "$n" "$out/new/$c.err"; fail=1; continue
    fi
    if ! jq -e . "$l" >/dev/null 2>&1; then
        echo "FAIL: $c: the legacy reader printed no JSON"; cat "$l"; fail=1; continue
    fi
    want=$(jq -S . "$l")
    case "$c:$nftv" in
        ratelimit-stats:1.1|rules:1.1)
            fixed=$(jq -S "$EACH |= \"each\"" "$l")
            if [ "$fixed" = "$want" ]; then
                echo "FAIL: $c: nft 1.1, but the legacy side shows no shared/each difference"; fail=1
            fi
            if [ "$(jq "[$EACH] | unique" "$l" | jq -c .)" != '["shared"]' ]; then
                echo "FAIL: $c: the legacy each-mode limits are not all shared: $(jq -c "[$EACH]" "$l")"; fail=1
            fi
            want="$fixed" ;;
    esac
    if diff <(printf '%s\n' "$want") <(jq -S . "$n"); then
        echo "ok: $c ($(jq 'if type == "array" then length else (.rules | length) end' "$n") records)"
    else
        echo "FAIL: $c differs (< legacy, > ucode)"; fail=1
    fi
done

# Blocks written before v1.13.2 (the caller's label in the comment): listed,
# then removed by trafficctl-unblock.sh with the empty label the Rules tab
# sends, and only they.
blocks() { jq -c '[.rules[] | select(.type == "block") | .target] | sort' "$1"; }
if [ "$(blocks "$out/new/rules.json")" = '["192.168.0.5","192.168.0.50","192.168.0.51","192.168.0.52","192.168.0.90"]' ] &&
   [ "$(blocks "$out/new/rules-after-unblock.json")" = '["192.168.0.5","192.168.0.50","192.168.0.90"]' ] &&
   ! grep -qE 'tctl_block_(tg|block_)' "$out/new/fw4-after-unblock.nft"; then
    echo "ok: blocks from before v1.13.2 listed and unblocked from the Rules tab"
else
    echo "FAIL: blocks from before v1.13.2:"
    blocks "$out/new/rules.json"; blocks "$out/new/rules-after-unblock.json"
    cat "$out/new/fw4-after-unblock.nft"; fail=1
fi

expect=$(printf '192.168.0.60 limited\n192.168.0.80 limited\n192.168.0.8 free')
if [ "$(cat "$out/new/has_limit.txt")" = "$expect" ]; then
    echo "ok: tctl_has_limit through the shims"
else
    echo "FAIL: tctl_has_limit through the shims:"; cat "$out/new/has_limit.txt"; fail=1
fi
exit "$fail"
