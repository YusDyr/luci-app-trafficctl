#!/bin/sh
# Creates a 2-hour LuCI session for root on the router over ssh (no password) and
# writes its id to .sid. Every rpcd ACL group is granted by name: a "*" in
# the access-group scope does not match LuCI's per-view checks.
ssh -o BatchMode=yes "root@${ROUTER:-192.168.0.1}" sh -s > "$(dirname "$0")/.sid" <<'EOF'
S=$(ubus call session create '{"timeout":7200}' | jsonfilter -e '@.ubus_rpc_session')
T=$(head -c16 /dev/urandom | hexdump -e '16/1 "%02x"')
ubus call session set "{\"ubus_rpc_session\":\"$S\",\"values\":{\"username\":\"root\",\"token\":\"$T\"}}"
for g in '"ubus",[["*","*"]]' '"uci",[["*","read"],["*","write"]]' '"file",[["*","*"]]' '"cgi-io",[["*","*"]]'; do
	ubus call session grant "{\"ubus_rpc_session\":\"$S\",\"scope\":${g%%,*},\"objects\":${g#*,}}"
done
G=$(cat /usr/share/rpcd/acl.d/*.json | ucode -l fs -e 'let t=fs.readfile("/dev/stdin"), o=[]; for (let m in match(t, /"([a-zA-Z0-9_.-]+)"[ \t\r\n]*:[ \t\r\n]*\{[ \t\r\n]*"description"/g)) push(o, m[1]); print(join(" ", o));')
objs=""; for g in $G; do objs="$objs[\"$g\",\"read\"],[\"$g\",\"write\"],"; done
ubus call session grant "{\"ubus_rpc_session\":\"$S\",\"scope\":\"access-group\",\"objects\":[${objs%,}]}"
echo "$S"
EOF
chmod 600 "$(dirname "$0")/.sid"
