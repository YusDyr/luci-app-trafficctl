#!/bin/sh
# shellcheck shell=dash
# Test Telegram bot connection by sending a test message.
# Usage: trafficctl-telegram-test.sh <token> <chat_id> [message]

TOKEN="$1"
CHAT_ID="$2"
CUSTOM_MSG="$3"

if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
	echo '{"ok":false,"msg":"token and chat_id required"}'
	exit 0
fi

echo "$CHAT_ID" | grep -qE '^-?[0-9]+$' || {
	echo '{"ok":false,"msg":"chat_id must be numeric"}'
	exit 0
}

echo "$TOKEN" | grep -qE '^[0-9]+:[A-Za-z0-9_-]+$' || {
	echo '{"ok":false,"msg":"invalid token format"}'
	exit 0
}

_fill_template() {
	ROUTER=$(uci -q get system.@system[0].hostname 2>/dev/null || echo "OpenWrt")
	DATE_NOW=$(date '+%Y-%m-%d')
	TIME_NOW=$(date '+%H:%M')
	_SEC=$(cut -d. -f1 /proc/uptime 2>/dev/null || echo "0")
	UPTIME_STR="$((_SEC / 86400))d $(((_SEC % 86400) / 3600))h"
	LOAD=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "0.00")
	WAN_IP=$(ubus call network.interface.wan status 2>/dev/null | jsonfilter -e '@.ipv4-address[0].address' 2>/dev/null)
	[ -z "$WAN_IP" ] && WAN_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -o 'src [0-9.]*' | cut -d' ' -f2)
	[ -z "$WAN_IP" ] && WAN_IP="unknown"
	SSID=$(uci -q get wireless.@wifi-iface[0].ssid 2>/dev/null || echo "WiFi")

	sed \
		-e "s|{{ *name *}}|TestDevice|g" \
		-e "s|{{ *ip *}}|192.168.0.100|g" \
		-e "s|{{ *mac *}}|aa:bb:cc:dd:ee:ff|g" \
		-e "s|{{ *link *}}|5G|g" \
		-e "s|{{ *router *}}|$ROUTER|g" \
		-e "s|{{ *date *}}|$DATE_NOW|g" \
		-e "s|{{ *time *}}|$TIME_NOW|g" \
		-e "s|{{ *datetime *}}|$DATE_NOW $TIME_NOW|g" \
		-e "s|{{ *ssid *}}|$SSID|g" \
		-e "s|{{ *signal *}}|-52|g" \
		-e "s|{{ *freq *}}|5GHz|g" \
		-e "s|{{ *iface *}}|wlan1|g" \
		-e "s|{{ *clients *}}|12|g" \
		-e "s|{{ *uptime *}}|$UPTIME_STR|g" \
		-e "s|{{ *wan_ip *}}|$WAN_IP|g" \
		-e "s|{{ *load *}}|$LOAD|g" \
		-e "s|{{ *conns *}}|5|g"
}

_json_encode() {
	# Escape backslashes, quotes, then fold real newlines back to \n for JSON
	printf '%s' "$1" \
		| sed 's/\\/\\\\/g; s/"/\\"/g' \
		| awk 'NR==1{printf "%s",$0} NR>1{printf "\\n%s",$0} END{printf ""}'
}

if [ -n "$CUSTOM_MSG" ]; then
	# Convert literal \n escape sequences, then fill template variables
	MSG=$(printf '%s' "$CUSTOM_MSG" | sed 's/\\n/\n/g' | _fill_template)
else
	ROUTER=$(uci -q get system.@system[0].hostname 2>/dev/null || echo "OpenWrt")
	MSG=$(printf '✅ TrafficCtl bot connected from %s' "$ROUTER")
fi

MSG_JSON=$(_json_encode "$MSG")

RESULT=$(curl -s -m 10 -X POST \
	"https://api.telegram.org/bot${TOKEN}/sendMessage" \
	-H "Content-Type: application/json" \
	-d "{\"chat_id\":\"${CHAT_ID}\",\"text\":\"${MSG_JSON}\",\"parse_mode\":\"HTML\"}" 2>/dev/null)

if echo "$RESULT" | jsonfilter -e '@.ok' 2>/dev/null | grep -q "true"; then
	echo '{"ok":true,"msg":"test message sent"}'
else
	ERR=$(echo "$RESULT" | jsonfilter -e '@.description' 2>/dev/null)
	printf '{"ok":false,"msg":"API error: %s"}\n' "${ERR:-unknown}"
fi
