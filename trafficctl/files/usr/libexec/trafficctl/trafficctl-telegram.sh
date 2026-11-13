#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# shellcheck shell=dash
# Telegram bot daemon for trafficctl.
# Runs under procd. Uses curl + jsonfilter to talk to Telegram Bot API.
# Only responds to the authorized chat_id configured in UCI.

. /lib/functions.sh

SCRIPTS="/usr/libexec/trafficctl"
OFFSET_FILE="/tmp/trafficctl_tg_offset"
CACHE_FILE="/tmp/trafficctl_tg_devices.json"
CACHE_TTL=5

TG_ENABLED=0
TG_TOKEN=""
TG_CHAT_ID=""
TG_POLL=3
TG_CONTROL=1
TG_BTN_INET=1
TG_BTN_WIFI=1
TG_BTN_LIMIT=1
TG_BTN_SHAPE=1

# ── config ──────────────────────────────────────────────────────────────────

load_config() {
	config_load trafficctl
	config_get TG_ENABLED telegram enabled 0
	config_get TG_TOKEN telegram bot_token ""
	config_get TG_CHAT_ID telegram chat_id ""
	config_get TG_POLL telegram poll_interval 3
	config_get TG_CONTROL telegram control_enabled 1
	config_get TG_BTN_INET telegram btn_block_inet 1
	config_get TG_BTN_WIFI telegram btn_block_wifi 1
	config_get TG_BTN_LIMIT telegram btn_limiter 1
	config_get TG_BTN_SHAPE telegram btn_shaper 1
	[ "$TG_POLL" -ge 2 ] 2>/dev/null || TG_POLL=3
}

validate_config() {
	if [ "$TG_ENABLED" != "1" ]; then
		logger -t trafficctl-tg "Telegram bot disabled"
		exit 0
	fi
	if [ -z "$TG_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
		logger -t trafficctl-tg "Missing bot_token or chat_id"
		exit 1
	fi
}

# ── telegram API ────────────────────────────────────────────────────────────

# The URL carries the bot token, so it is fed through a curl config file on stdin
# instead of argv — a command line is world-readable via ps and /proc.
tg_api() {
	local method="$1" body="$2"
	printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TG_TOKEN" "$method" | \
		curl -s -m 30 -X POST \
			-H "Content-Type: application/json" \
			-d "$body" \
			--config - 2>/dev/null
}

# Escape a string for embedding in a JSON body: backslashes, quotes, tabs,
# and real newlines (raw newlines are invalid inside JSON strings and make
# Telegram reject the whole request with a 400).
tg_json_escape() {
	printf '%s' "$1" | sed 's/\\/\\\\/g;s/"/\\"/g;s/	/\\t/g' | \
		awk 'NR==1{printf "%s",$0} NR>1{printf "\\n%s",$0}'
}

tg_send() {
	local text="$1" markup="$2"
	local body
	text=$(tg_json_escape "$text")
	if [ -n "$markup" ]; then
		body=$(printf '{"chat_id":"%s","text":"%s","parse_mode":"HTML","reply_markup":%s}' \
			"$TG_CHAT_ID" "$text" "$markup")
	else
		body=$(printf '{"chat_id":"%s","text":"%s","parse_mode":"HTML"}' \
			"$TG_CHAT_ID" "$text")
	fi
	tg_api "sendMessage" "$body" >/dev/null
}

tg_answer_cb() {
	local cb_id="$1" text="$2"
	# The Bot API caps a callback toast at 200 characters and rejects the whole
	# call when it is longer — so an over-long message does not get trimmed, it
	# vanishes. Backend results carrying remediation advice can reach that
	# length, and a silently missing answer is exactly the failure mode this
	# plugin is being fixed for.
	if [ "${#text}" -gt 200 ]; then
		text="$(printf '%.196s' "$text")..."
	fi
	text=$(tg_json_escape "$text")
	tg_api "answerCallbackQuery" \
		"$(printf '{"callback_query_id":"%s","text":"%s"}' "$cb_id" "$text")" >/dev/null
}

tg_edit_msg() {
	local msg_id="$1" text="$2" markup="$3"
	text=$(tg_json_escape "$text")
	local body
	if [ -n "$markup" ]; then
		body=$(printf '{"chat_id":"%s","message_id":%s,"text":"%s","parse_mode":"HTML","reply_markup":%s}' \
			"$TG_CHAT_ID" "$msg_id" "$text" "$markup")
	else
		body=$(printf '{"chat_id":"%s","message_id":%s,"text":"%s","parse_mode":"HTML"}' \
			"$TG_CHAT_ID" "$msg_id" "$text")
	fi
	tg_api "editMessageText" "$body" >/dev/null
}

# ── device helpers ──────────────────────────────────────────────────────────

get_devices() {
	local now mtime age
	now=$(date +%s)
	if [ -f "$CACHE_FILE" ]; then
		mtime=$(date -r "$CACHE_FILE" +%s 2>/dev/null || echo 0)
		age=$((now - mtime))
		if [ "$age" -lt "$CACHE_TTL" ]; then
			cat "$CACHE_FILE"
			return
		fi
	fi
	"$SCRIPTS/trafficctl-summary.sh" > "$CACHE_FILE" 2>/dev/null
	cat "$CACHE_FILE"
}

invalidate_cache() { rm -f "$CACHE_FILE"; }

get_device_field() {
	local json="$1" ip="$2" field="$3"
	echo "$json" | jsonfilter -e "@[@.ip='$ip'].$field" 2>/dev/null
}

# New-device and online notifications are not the bot's job any more: the
# device scan and the senders live in trafficctl.notify (trafficctl-notify
# service), which writes telegram_known.json and /tmp/trafficctl_tg_online in
# the formats this script used.

# ── keyboard builders ───────────────────────────────────────────────────────

build_device_keyboard() {
	local devices="$1"
	local tmpkb="/tmp/trafficctl_tg_kb.tmp"
	local ip name btn col=0 first=1

	printf '{"inline_keyboard":[' > "$tmpkb"

	for ip in $(echo "$devices" | jsonfilter -e '@[*].ip' 2>/dev/null); do
		name=$(echo "$devices" | jsonfilter -e "@[@.ip='$ip'].name" 2>/dev/null)
		# Keep button labels JSON-safe: drop quotes/backslashes and anything
		# non-ASCII, then truncate. A %.12s cut through a multi-byte character
		# would produce invalid UTF-8 and Telegram would reject the keyboard.
		name=$(printf '%s' "$name" | tr -cd 'a-zA-Z0-9 _.()-')
		btn=$(printf '{"text":"%.12s %s","callback_data":"act:menu:%s"}' \
			"${name:-$ip}" "$ip" "$ip")
		if [ "$col" -eq 0 ]; then
			if [ "$first" -eq 1 ]; then
				first=0
			else
				printf '],' >> "$tmpkb"
			fi
			printf '[%s' "$btn" >> "$tmpkb"
			col=1
		else
			printf ',%s' "$btn" >> "$tmpkb"
			col=0
		fi
	done

	printf ']]}' >> "$tmpkb"
	cat "$tmpkb"
	rm -f "$tmpkb"
}

# A ceiling as "8000 kbit/s", or "8000↓ / 2000↑ kbit/s" when upload has its
# own (#66). An upload figure of 0 or equal to download is not a split.
tg_ceiling() {
	if [ "${2:-0}" -gt 0 ] 2>/dev/null && [ "$2" != "$1" ]; then
		printf '%s↓ / %s↑ kbit/s' "$1" "$2"
	else
		printf '%s kbit/s' "$1"
	fi
}

# The same, compact, for the /status flags: "8000k" or "8000/2000k".
tg_ceiling_short() {
	if [ "${2:-0}" -gt 0 ] 2>/dev/null && [ "$2" != "$1" ]; then
		printf '%s/%sk' "$1" "$2"
	else
		printf '%sk' "$1"
	fi
}

build_action_keyboard() {
	local ip="$1" devices="$2"
	local blocked wifi_blocked rl_kbit shape_kbit rl_up shape_up
	blocked=$(get_device_field "$devices" "$ip" "blocked")
	wifi_blocked=$(get_device_field "$devices" "$ip" "wifi_blocked")
	rl_kbit=$(get_device_field "$devices" "$ip" "rate_limit_kbit")
	shape_kbit=$(get_device_field "$devices" "$ip" "shape_kbit")
	rl_up=$(get_device_field "$devices" "$ip" "rate_limit_kbit_up")
	shape_up=$(get_device_field "$devices" "$ip" "shape_kbit_up")
	conn_type=$(get_device_field "$devices" "$ip" "conn_type")

	local kb='{"inline_keyboard":['
	local rows=""

	# internet block/unblock
	if [ "$TG_BTN_INET" = "1" ]; then
		if [ "$blocked" = "true" ] || [ "$blocked" = "1" ]; then
			rows="${rows}[{\"text\":\"▶️ Unblock Internet\",\"callback_data\":\"act:unblock:${ip}\"}],"
		else
			rows="${rows}[{\"text\":\"⏸ Block Internet\",\"callback_data\":\"act:block:${ip}\"}],"
		fi
	fi

	# wifi block/unblock (only for wifi devices)
	if [ "$TG_BTN_WIFI" = "1" ]; then
		case "$conn_type" in
			*wifi*|*2.4G*|*5G*|*6G*|*WiFi*)
				if [ "$wifi_blocked" = "true" ] || [ "$wifi_blocked" = "1" ]; then
					rows="${rows}[{\"text\":\"📶 Unblock WiFi\",\"callback_data\":\"act:wunblock:${ip}\"}],"
				else
					rows="${rows}[{\"text\":\"📵 Block WiFi\",\"callback_data\":\"act:wblock:${ip}\"}],"
				fi
				;;
		esac
	fi

	# limiter
	if [ "$TG_BTN_LIMIT" = "1" ]; then
		if [ "${rl_kbit:-0}" -gt 0 ] 2>/dev/null; then
			rows="${rows}[{\"text\":\"⚡ Limit: $(tg_ceiling "$rl_kbit" "$rl_up") — Remove\",\"callback_data\":\"act:unlimit:${ip}\"}],"
		else
			rows="${rows}[{\"text\":\"⚡ 1M\",\"callback_data\":\"act:limit:${ip}:1000\"},{\"text\":\"⚡ 2M\",\"callback_data\":\"act:limit:${ip}:2000\"},{\"text\":\"⚡ 5M\",\"callback_data\":\"act:limit:${ip}:5000\"}],"
			rows="${rows}[{\"text\":\"⚡ 10M\",\"callback_data\":\"act:limit:${ip}:10000\"},{\"text\":\"⚡ 25M\",\"callback_data\":\"act:limit:${ip}:25000\"},{\"text\":\"⚡ 50M\",\"callback_data\":\"act:limit:${ip}:50000\"},{\"text\":\"⚡ 100M\",\"callback_data\":\"act:limit:${ip}:100000\"}],"
		fi
	fi

	# shaper
	if [ "$TG_BTN_SHAPE" = "1" ]; then
		if [ "${shape_kbit:-0}" -gt 0 ] 2>/dev/null; then
			rows="${rows}[{\"text\":\"🔧 Shape: $(tg_ceiling "$shape_kbit" "$shape_up") — Remove\",\"callback_data\":\"act:unshape:${ip}\"}],"
		else
			rows="${rows}[{\"text\":\"🔧 1M\",\"callback_data\":\"act:shape:${ip}:1000\"},{\"text\":\"🔧 2M\",\"callback_data\":\"act:shape:${ip}:2000\"},{\"text\":\"🔧 5M\",\"callback_data\":\"act:shape:${ip}:5000\"}],"
			rows="${rows}[{\"text\":\"🔧 10M\",\"callback_data\":\"act:shape:${ip}:10000\"},{\"text\":\"🔧 25M\",\"callback_data\":\"act:shape:${ip}:25000\"},{\"text\":\"🔧 50M\",\"callback_data\":\"act:shape:${ip}:50000\"},{\"text\":\"🔧 100M\",\"callback_data\":\"act:shape:${ip}:100000\"}],"
		fi
	fi

	# back button
	rows="${rows}[{\"text\":\"⬅️ Back\",\"callback_data\":\"act:back\"}]"

	printf '%s%s]}' "$kb" "$rows"
}

# ── command handlers ────────────────────────────────────────────────────────

handle_help() {
	if [ "$TG_CONTROL" = "1" ]; then
		tg_send "$(printf '<b>TrafficCtl Bot</b>\n\n/devices — active devices with action buttons\n/status — blocked/limited summary\n/help — this message')"
	else
		tg_send "$(printf '<b>TrafficCtl Bot</b> (notifications only)\n\n/devices — active devices list\n/status — blocked/limited summary\n/help — this message\n\n<i>Control disabled — enable in LuCI settings</i>')"
	fi
}

handle_devices() {
	local devices
	devices=$(get_devices)
	if [ -z "$devices" ] || [ "$devices" = "[]" ]; then
		tg_send "No active devices"
		return
	fi
	local count
	count=$(echo "$devices" | jsonfilter -e '@[*].ip' 2>/dev/null | wc -l)
	if [ "$TG_CONTROL" = "1" ]; then
		local kb
		kb=$(build_device_keyboard "$devices")
		tg_send "$(printf '<b>Active devices: %d</b>\nSelect a device:' "$count")" "$kb"
	else
		local list="" ip name
		for ip in $(echo "$devices" | jsonfilter -e '@[*].ip' 2>/dev/null); do
			name=$(get_device_field "$devices" "$ip" "name")
			list="${list}• ${name:-?} (${ip})\n"
		done
		tg_send "$(printf '<b>Active devices: %d</b>\n%b' "$count" "$list")"
	fi
}

handle_devices_edit() {
	local msg_id="$1"
	invalidate_cache
	local devices
	devices=$(get_devices)
	local count
	count=$(echo "$devices" | jsonfilter -e '@[*].ip' 2>/dev/null | wc -l)
	local kb
	kb=$(build_device_keyboard "$devices")
	tg_edit_msg "$msg_id" "$(printf '<b>Active devices: %d</b>\nSelect a device:' "$count")" "$kb"
}

handle_status() {
	local devices ip name rl_kbit shape_kbit rl_up shape_up blocked wifi_blocked
	local result=""
	devices=$(get_devices)
	[ -z "$devices" ] || [ "$devices" = "[]" ] && { tg_send "No active devices"; return; }

	for ip in $(echo "$devices" | jsonfilter -e '@[*].ip' 2>/dev/null); do
		blocked=$(get_device_field "$devices" "$ip" "blocked")
		wifi_blocked=$(get_device_field "$devices" "$ip" "wifi_blocked")
		rl_kbit=$(get_device_field "$devices" "$ip" "rate_limit_kbit")
		shape_kbit=$(get_device_field "$devices" "$ip" "shape_kbit")
		rl_up=$(get_device_field "$devices" "$ip" "rate_limit_kbit_up")
		shape_up=$(get_device_field "$devices" "$ip" "shape_kbit_up")
		name=$(get_device_field "$devices" "$ip" "name")

		local flags=""
		[ "$blocked" = "true" ] || [ "$blocked" = "1" ] && flags="${flags} 🚫inet"
		[ "$wifi_blocked" = "true" ] || [ "$wifi_blocked" = "1" ] && flags="${flags} 📵wifi"
		[ "${rl_kbit:-0}" -gt 0 ] 2>/dev/null && flags="${flags} ⚡$(tg_ceiling_short "$rl_kbit" "$rl_up")"
		[ "${shape_kbit:-0}" -gt 0 ] 2>/dev/null && flags="${flags} 🔧$(tg_ceiling_short "$shape_kbit" "$shape_up")"

		[ -n "$flags" ] && result="${result}${name:-?} (${ip}):${flags}\n"
	done

	if [ -z "$result" ]; then
		tg_send "All devices are clean — no blocks or limits"
	else
		tg_send "$(printf '<b>Active restrictions:</b>\n%b' "$result")"
	fi
}

# ── callback handler ────────────────────────────────────────────────────────

handle_callback() {
	local cb_id="$1" data="$2" msg_id="$3"
	local verb ip param result msg devices name

	if [ "$TG_CONTROL" != "1" ]; then
		tg_answer_cb "$cb_id" "Control disabled"
		return
	fi

	verb=$(echo "$data" | cut -d: -f2)
	ip=$(echo "$data" | cut -d: -f3)
	param=$(echo "$data" | cut -d: -f4)

	# Validate IP from callback data
	if [ -n "$ip" ] && [ "$verb" != "back" ]; then
		if ! echo "$ip" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
			tg_answer_cb "$cb_id" "invalid IP"
			return
		fi
	fi
	# Validate rate param is numeric
	if [ -n "$param" ]; then
		case "$param" in *[!0-9]*) tg_answer_cb "$cb_id" "invalid param"; return ;; esac
	fi

	case "$verb" in
	menu)
		invalidate_cache
		devices=$(get_devices)
		name=$(get_device_field "$devices" "$ip" "name")
		local blocked wifi_blocked rl_kbit shape_kbit rl_up shape_up
		blocked=$(get_device_field "$devices" "$ip" "blocked")
		wifi_blocked=$(get_device_field "$devices" "$ip" "wifi_blocked")
		rl_kbit=$(get_device_field "$devices" "$ip" "rate_limit_kbit")
		shape_kbit=$(get_device_field "$devices" "$ip" "shape_kbit")
		rl_up=$(get_device_field "$devices" "$ip" "rate_limit_kbit_up")
		shape_up=$(get_device_field "$devices" "$ip" "shape_kbit_up")

		local status_line=""
		[ "$blocked" = "true" ] || [ "$blocked" = "1" ] && status_line="${status_line}🚫 Internet blocked\n"
		[ "$wifi_blocked" = "true" ] || [ "$wifi_blocked" = "1" ] && status_line="${status_line}📵 WiFi blocked\n"
		[ "${rl_kbit:-0}" -gt 0 ] 2>/dev/null && status_line="${status_line}⚡ Limiter: $(tg_ceiling "$rl_kbit" "$rl_up")\n"
		[ "${shape_kbit:-0}" -gt 0 ] 2>/dev/null && status_line="${status_line}🔧 Shaper: $(tg_ceiling "$shape_kbit" "$shape_up")\n"
		[ -z "$status_line" ] && status_line="✅ No restrictions\n"

		local text
		text=$(printf '<b>%s</b> (%s)\n%b' "${name:-?}" "$ip" "$status_line")
		local kb
		kb=$(build_action_keyboard "$ip" "$devices")
		tg_edit_msg "$msg_id" "$text" "$kb"
		tg_answer_cb "$cb_id" ""
		;;
	block)
		result=$("$SCRIPTS/trafficctl-block.sh" "$ip" "tg")
		msg=$(echo "$result" | jsonfilter -e '@.msg' 2>/dev/null)
		tg_answer_cb "$cb_id" "${msg:-done}"
		invalidate_cache
		handle_callback "$cb_id" "act:menu:$ip" "$msg_id"
		;;
	unblock)
		result=$("$SCRIPTS/trafficctl-unblock.sh" "$ip" "tg")
		msg=$(echo "$result" | jsonfilter -e '@.msg' 2>/dev/null)
		tg_answer_cb "$cb_id" "${msg:-done}"
		invalidate_cache
		handle_callback "$cb_id" "act:menu:$ip" "$msg_id"
		;;
	wblock)
		result=$("$SCRIPTS/trafficctl-macfilter-add.sh" "$ip")
		msg=$(echo "$result" | jsonfilter -e '@.msg' 2>/dev/null)
		tg_answer_cb "$cb_id" "${msg:-done}"
		invalidate_cache
		handle_callback "$cb_id" "act:menu:$ip" "$msg_id"
		;;
	wunblock)
		result=$("$SCRIPTS/trafficctl-macfilter-remove.sh" "$ip")
		msg=$(echo "$result" | jsonfilter -e '@.msg' 2>/dev/null)
		tg_answer_cb "$cb_id" "${msg:-done}"
		invalidate_cache
		handle_callback "$cb_id" "act:menu:$ip" "$msg_id"
		;;
	limit)
		result=$("$SCRIPTS/trafficctl-ratelimit.sh" "$ip" "$param" "tg")
		msg=$(echo "$result" | jsonfilter -e '@.msg' 2>/dev/null)
		tg_answer_cb "$cb_id" "${msg:-done}"
		invalidate_cache
		handle_callback "$cb_id" "act:menu:$ip" "$msg_id"
		;;
	unlimit)
		result=$("$SCRIPTS/trafficctl-ratelimit.sh" "$ip" "0" "tg")
		msg=$(echo "$result" | jsonfilter -e '@.msg' 2>/dev/null)
		tg_answer_cb "$cb_id" "${msg:-done}"
		invalidate_cache
		handle_callback "$cb_id" "act:menu:$ip" "$msg_id"
		;;
	shape)
		result=$("$SCRIPTS/trafficctl-shape.sh" add "$ip" "$param" "tg")
		msg=$(echo "$result" | jsonfilter -e '@.msg' 2>/dev/null)
		tg_answer_cb "$cb_id" "${msg:-done}"
		invalidate_cache
		handle_callback "$cb_id" "act:menu:$ip" "$msg_id"
		;;
	unshape)
		result=$("$SCRIPTS/trafficctl-shape.sh" remove "$ip")
		msg=$(echo "$result" | jsonfilter -e '@.msg' 2>/dev/null)
		tg_answer_cb "$cb_id" "${msg:-done}"
		invalidate_cache
		handle_callback "$cb_id" "act:menu:$ip" "$msg_id"
		;;
	back)
		handle_devices_edit "$msg_id"
		tg_answer_cb "$cb_id" ""
		;;
	*)
		tg_answer_cb "$cb_id" "Unknown action"
		;;
	esac
}

# ── main loop ───────────────────────────────────────────────────────────────

main() {
	load_config
	validate_config

	export TCTL_VIA="telegram"
	export TCTL_SRC="telegram:${TG_CHAT_ID}"
	export TCTL_USER="telegram-bot"

	logger -t trafficctl-tg "Bot started, chat_id=$TG_CHAT_ID"

	local offset response ok i
	local update update_id msg_chat_id msg_text cb_id cb_data cb_msg_id
	local config_reload_at
	config_reload_at=$(($(date +%s) + 60))

	offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")

	while true; do
		response=$(tg_api "getUpdates" \
			"$(printf '{"offset":%s,"timeout":%d,"allowed_updates":["message","callback_query"]}' \
				"$offset" "$TG_POLL")")

		ok=$(echo "$response" | jsonfilter -e '@.ok' 2>/dev/null)
		[ "$ok" = "true" ] || { sleep 5; continue; }

		# Iterate results by index until one comes back empty. Do NOT use
		# `jsonfilter -l '@.result'` to get a count: on newer jsonfilter
		# (OpenWrt 25.12 / APK and snapshot) it returns an empty string, which
		# left update_count empty and turned `[ "$i" -lt "$update_count" ]` into
		# a BusyBox "sh: out of range" loop that never processed commands (#22).
		i=0
		while update=$(echo "$response" | jsonfilter -e "@.result[$i]" 2>/dev/null); [ -n "$update" ]; do
			update_id=$(echo "$update" | jsonfilter -e '@.update_id' 2>/dev/null)
			[ -n "$update_id" ] && offset=$((update_id + 1))
			echo "$offset" > "$OFFSET_FILE"

			# try message first
			msg_chat_id=$(echo "$update" | jsonfilter -e '@.message.chat.id' 2>/dev/null)
			if [ -n "$msg_chat_id" ]; then
				if [ "$msg_chat_id" = "$TG_CHAT_ID" ]; then
					msg_text=$(echo "$update" | jsonfilter -e '@.message.text' 2>/dev/null)
					case "$msg_text" in
						/start*|/help*) handle_help ;;
						/devices*)      handle_devices ;;
						/status*)       handle_status ;;
					esac
				fi
				i=$((i + 1))
				continue
			fi

			# try callback_query
			cb_id=$(echo "$update" | jsonfilter -e '@.callback_query.id' 2>/dev/null)
			if [ -n "$cb_id" ]; then
				msg_chat_id=$(echo "$update" | jsonfilter -e '@.callback_query.message.chat.id' 2>/dev/null)
				if [ "$msg_chat_id" = "$TG_CHAT_ID" ]; then
					cb_data=$(echo "$update" | jsonfilter -e '@.callback_query.data' 2>/dev/null)
					cb_msg_id=$(echo "$update" | jsonfilter -e '@.callback_query.message.message_id' 2>/dev/null)
					handle_callback "$cb_id" "$cb_data" "$cb_msg_id"
				fi
			fi

			i=$((i + 1))
		done

		# reload config periodically
		if [ "$(date +%s)" -ge "$config_reload_at" ]; then
			load_config
			config_reload_at=$(($(date +%s) + 60))
		fi
	done
}

main
