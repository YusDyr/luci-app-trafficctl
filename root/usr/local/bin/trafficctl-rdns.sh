#!/bin/sh
# shellcheck shell=dash
# Reverse DNS lookup for an IP address.
# Usage: trafficctl-rdns.sh <ip>
# Output: {"ip":"...","host":"..."}

. /usr/local/bin/trafficctl-fw.sh

IP="$1"

if [ -z "$IP" ]; then
    echo '{"ip":"","host":""}'
    exit 1
fi

if ! tctl_validate_ip "$IP"; then
    echo "{\"ip\":\"$IP\",\"host\":\"\"}"
    exit 1
fi

HOST=""
if command -v dig >/dev/null 2>&1; then
    HOST=$(dig -4 +short +time=1 +tries=1 -x "$IP" 2>/dev/null | grep -v '^;;' | head -1 | sed 's/\.$//')
elif command -v nslookup >/dev/null 2>&1; then
    HOST=$(nslookup "$IP" 2>/dev/null | grep 'name =' | awk '{print $NF}' | sed 's/\.$//')
fi

# Validate hostname (only allow safe chars)
case "$HOST" in
    *[!a-zA-Z0-9._-]*|"") HOST="" ;;
esac

if [ -z "$HOST" ]; then
    echo "{\"ip\":\"$IP\",\"host\":\"\"}"
else
    echo "{\"ip\":\"$IP\",\"host\":\"$HOST\"}"
fi
