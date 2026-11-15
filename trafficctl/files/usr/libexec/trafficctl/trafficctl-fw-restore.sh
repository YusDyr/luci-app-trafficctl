#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=dash
# Restore persisted internet blocks after a firewall reload.
#
# tctl_block_add inserts drop rules into inet fw4 forward (and into iptables
# FORWARD on fw3). fw4 reload rebuilds that table from /etc/config/firewall,
# so every trafficctl block disappears while rules.json and the UI still say
# the device is blocked. The lan-ifup hotplug hook restores them after a
# reboot, but not after a mid-session reload (https-dns-proxy restart, a
# LuCI firewall edit, ...).
#
# This script is registered as a firewall include (type=script,
# fw4_compatible=1) so fw4 runs it after it has applied the new ruleset.
# It must write nothing to stdout: a script include's output is not nft
# syntax, and any stray text would only clutter the reload log.
#
# Rate limits and port-forward pauses live in their own tables
# (netdev tm_ratelimit, inet tctl_pfw) and survive a fw4 reload, so they
# are not replayed here. A future change that moved those rules into inet
# fw4 would need to restore them too.
#
# The restore is the same helper the ifup hook uses, not trafficctl-block.sh:
# that script would rewrite rules.json and flush conntrack on every reload.
# tctl_is_blocked keeps the insert idempotent if the include is ever run
# against a chain that still has the rules (or is invoked twice).

. /usr/libexec/trafficctl/trafficctl-fw.sh

tctl_persist_enabled || exit 0
[ -s "$TCTL_RULES_FILE" ] || exit 0

jsonfilter -i "$TCTL_RULES_FILE" -e '@[@.type="block"].ip' 2>/dev/null | while read -r ip; do
    [ -n "$ip" ] || continue
    tctl_validate_ip "$ip" || continue
    tctl_is_blocked "$ip" && continue
    tctl_block_add "$ip" "$(tctl_block_comment "$ip")" 2>/dev/null || \
        logger -t trafficctl "Failed to restore block for $ip after a firewall reload"
done
exit 0
