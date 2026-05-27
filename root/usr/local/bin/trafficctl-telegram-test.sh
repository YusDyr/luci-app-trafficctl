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

if [ -n "$CUSTOM_MSG" ]; then
	MSG="$CUSTOM_MSG"
else
	HOSTNAME=$(uci -q get system.@system[0].hostname 2>/dev/null || echo "OpenWrt")
	MSG=$(printf '✅ TrafficCtl bot connected from %s' "$HOSTNAME")
fi

RESULT=$(curl -s -m 10 -X POST \
	"https://api.telegram.org/bot${TOKEN}/sendMessage" \
	-H "Content-Type: application/json" \
	-d "{\"chat_id\":\"${CHAT_ID}\",\"text\":\"${MSG}\",\"parse_mode\":\"HTML\"}" 2>/dev/null)

if echo "$RESULT" | jsonfilter -e '@.ok' 2>/dev/null | grep -q "true"; then
	echo '{"ok":true,"msg":"test message sent"}'
else
	ERR=$(echo "$RESULT" | jsonfilter -e '@.description' 2>/dev/null)
	printf '{"ok":false,"msg":"API error: %s"}\n' "${ERR:-unknown}"
fi
