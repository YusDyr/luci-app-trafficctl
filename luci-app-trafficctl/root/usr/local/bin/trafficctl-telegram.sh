#!/bin/sh
# shellcheck shell=dash
# Telegram bot daemon for trafficctl.
# Runs under procd. Uses curl + jsonfilter to talk to Telegram Bot API.
# Only responds to the authorized chat_id configured in UCI.

SCRIPTS="/usr/local/bin"
KNOWN_FILE="/etc/trafficctl/telegram_known.json"
OFFSET_FILE="/tmp/trafficctl_tg_offset"
CACHE_FILE="/tmp/trafficctl_tg_devices.json"
CACHE_TTL=5

TG_ENABLED=0
TG_TOKEN=""
TG_CHAT_ID=""
TG_POLL=3
TG_NOTIFY_NEW=1
TG_NOTIFY_KNOWN=0
TG_CONTROL=1
TG_NOTIFY_TEMPLATE=""
TG_BTN_INET=1
TG_BTN_WIFI=1
TG_BTN_LIMIT=1
TG_BTN_SHAPE=1

# ── config ──────────────────────────────────────────────────────────────────

load_config() {
	TG_ENABLED=$(uci -q get trafficctl.telegram.enabled || echo 0)
	TG_TOKEN=$(uci -q get trafficctl.telegram.bot_token)
	TG_CHAT_ID=$(uci -q get trafficctl.telegram.chat_id)
	TG_POLL=$(uci -q get trafficctl.telegram.poll_interval || echo 3)
	TG_NOTIFY_NEW=$(uci -q get trafficctl.telegram.notify_new_device || echo 1)
	TG_NOTIFY_KNOWN=$(uci -q get trafficctl.telegram.notify_known_device || echo 0)
	TG_CONTROL=$(uci -q get trafficctl.telegram.control_enabled || echo 1)
	TG_NOTIFY_TEMPLATE=$(uci -q get trafficctl.telegram.notify_template)
	TG_BTN_INET=$(uci -q get trafficctl.telegram.btn_block_inet || echo 1)
	TG_BTN_WIFI=$(uci -q get trafficctl.telegram.btn_block_wifi || echo 1)
	TG_BTN_LIMIT=$(uci -q get trafficctl.telegram.btn_limiter || echo 1)
	TG_BTN_SHAPE=$(uci -q get trafficctl.telegram.btn_shaper || echo 1)
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

tg_api() {
	local method="$1" body="$2"
	curl -s -m 30 -X POST \
		"https://api.telegram.org/bot${TG_TOKEN}/${method}" \
		-H "Content-Type: application/json" \
		-d "$body" 2>/dev/null
}

tg_send() {
	local text="$1" markup="$2"
	local body
	text=$(printf '%s' "$text" | sed 's/\\/\\\\/g;s/"/\\"/g')
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
	text=$(printf '%s' "$text" | sed 's/\\/\\\\/g;s/"/\\"/g')
	tg_api "answerCallbackQuery" \
		"$(printf '{"callback_query_id":"%s","text":"%s"}' "$cb_id" "$text")" >/dev/null
}

tg_edit_msg() {
	local msg_id="$1" text="$2" markup="$3"
	text=$(printf '%s' "$text" | sed 's/\\/\\\\/g;s/"/\\"/g')
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

# ── known devices ───────────────────────────────────────────────────────────

seed_known() {
	local mac info name ip
	for mac in $(discover_macs); do
		[ -z "$mac" ] && continue
		info=$(resolve_mac_info "$mac")
		name=$(printf '%s' "$info" | cut -f1)
		ip=$(printf '%s' "$info" | cut -f2)
		add_known_mac "$mac" "${name:-unknown}" "${ip:-?}"
	done
	logger -t trafficctl-tg "Seeded known devices from current state"
}

load_known() {
	if [ ! -f "$KNOWN_FILE" ] || [ "$(cat "$KNOWN_FILE" 2>/dev/null)" = "[]" ]; then
		mkdir -p "$(dirname "$KNOWN_FILE")"
		[ -f "$KNOWN_FILE" ] || echo '[]' > "$KNOWN_FILE"
		seed_known
	fi
}

lock_known() { while ! mkdir /tmp/.trafficctl_known.lock 2>/dev/null; do sleep 0.1; done; }
unlock_known() { rmdir /tmp/.trafficctl_known.lock 2>/dev/null; }

is_known_mac() {
	grep -q "\"$1\"" "$KNOWN_FILE" 2>/dev/null
}

add_known_mac() {
	local mac="$1" name="$2" ip="$3"
	local now
	now=$(date +%s)
	# Sanitize inputs: strip anything that could break JSON or sed
	mac=$(printf '%s' "$mac" | tr -cd 'a-fA-F0-9:')
	name=$(printf '%s' "$name" | tr -cd 'a-zA-Z0-9 _.-')
	ip=$(printf '%s' "$ip" | tr -cd '0-9.')
	local tmp="${KNOWN_FILE}.tmp"
	local entry
	entry=$(printf '{"mac":"%s","name":"%s","ip":"%s","first_seen":%d}' \
		"$mac" "$name" "$ip" "$now")
	lock_known
	if [ "$(cat "$KNOWN_FILE" 2>/dev/null)" = "[]" ]; then
		printf '[%s]' "$entry" > "$tmp"
	else
		awk -v e="$entry" '{sub(/\]$/,","e"]")}1' "$KNOWN_FILE" > "$tmp"
	fi
	mv "$tmp" "$KNOWN_FILE"
	unlock_known
}

discover_macs() {
	local seen_file="/tmp/trafficctl_tg_seen.tmp"
	: > "$seen_file"

	# Source 1: ARP table (covers any device that communicated at L2)
	ip neigh show 2>/dev/null | awk '/lladdr/ {print tolower($5)}' >> "$seen_file"

	# Source 2: DHCP leases (covers any device that requested an IP)
	if [ -f /tmp/dhcp.leases ]; then
		awk '{print tolower($2)}' /tmp/dhcp.leases >> "$seen_file"
	fi

	# Source 3: Wi-Fi associated stations (covers connected Wi-Fi clients even without traffic)
	for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
		iw dev "$iface" station dump 2>/dev/null | awk '/Station/{print tolower($2)}'
	done >> "$seen_file"

	# Deduplicate, filter valid MACs
	sort -u "$seen_file" | grep -E '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
	rm -f "$seen_file"
}

resolve_mac_info() {
	local mac="$1" name="" ip="" conn_type="?"

	# Try DHCP leases first
	if [ -f /tmp/dhcp.leases ]; then
		ip=$(awk -v m="$mac" 'tolower($2)==m {print $3; exit}' /tmp/dhcp.leases)
		name=$(awk -v m="$mac" 'tolower($2)==m {print $4; exit}' /tmp/dhcp.leases)
	fi

	# Fallback: ARP for IP
	if [ -z "$ip" ]; then
		ip=$(ip neigh show 2>/dev/null | awk -v m="$mac" 'tolower($5)==m {print $1; exit}')
	fi

	# Determine connection type
	for iface in $(iw dev 2>/dev/null | awk '/Interface/{print $2}'); do
		if iw dev "$iface" station get "$mac" >/dev/null 2>&1; then
			conn_type="wifi"
			break
		fi
	done
	if [ "$conn_type" = "?" ] && [ -n "$ip" ]; then
		conn_type="ethernet"
	fi

	[ -z "$name" ] || [ "$name" = "*" ] && name="unknown"
	printf '%s\t%s\t%s' "${name}" "${ip:-?}" "${conn_type}"
}

ONLINE_STATE_FILE="/tmp/trafficctl_tg_online"
DHCP_TRIGGER_FILE="/tmp/trafficctl_tg_newdev"

get_wifi_info() {
	local mac="$1" iw_out="" iface="" ssid="" signal="" freq=""
	for iface in /sys/class/net/wlan*/phy80211; do
		[ -d "$iface" ] || continue
		iface=$(basename "$(dirname "$iface")")
		iw_out=$(iw dev "$iface" station get "$mac" 2>/dev/null) && break
	done
	if [ -n "$iw_out" ]; then
		signal=$(echo "$iw_out" | awk '/signal:/{print $2}')
		freq=$(iw dev "$iface" info 2>/dev/null | awk '/channel/{if($4>5000)print "5GHz";else print "2.4GHz"}')
		ssid=$(iw dev "$iface" info 2>/dev/null | awk '/ssid/{print $2}')
	fi
	printf '%s\t%s\t%s\t%s' "$iface" "$ssid" "$signal" "$freq"
}

get_device_conns() {
	local ip="$1"
	cat /proc/net/nf_conntrack 2>/dev/null | grep -c "src=$ip " 2>/dev/null || echo 0
}

get_router_vars() {
	local uptime_s up_d up_h up_m __ip
	uptime_s=$(awk '{print int($1)}' /proc/uptime)
	up_d=$((uptime_s / 86400))
	up_h=$(( (uptime_s % 86400) / 3600 ))
	up_m=$(( (uptime_s % 3600) / 60 ))
	if [ "$up_d" -gt 0 ]; then
		TVAR_UPTIME="${up_d}d ${up_h}h"
	elif [ "$up_h" -gt 0 ]; then
		TVAR_UPTIME="${up_h}h ${up_m}m"
	else
		TVAR_UPTIME="${up_m}m"
	fi
	TVAR_DATE=$(date '+%Y-%m-%d')
	TVAR_TIME=$(date '+%H:%M')
	TVAR_DATETIME=$(date '+%Y-%m-%d %H:%M')
	TVAR_ROUTER=$(uci -q get system.@system[0].hostname || cat /proc/sys/kernel/hostname)
	. /lib/functions/network.sh
	network_get_ipaddr __ip wan
	TVAR_WAN_IP="$__ip"
	TVAR_LOAD=$(awk '{print $1}' /proc/loadavg)
	TVAR_CLIENTS=$(wc -l < /tmp/dhcp.leases 2>/dev/null || echo 0)
}

format_new_device_msg() {
	local name="$1" ip="$2" mac="$3" link="$4"
	if [ -n "$TG_NOTIFY_TEMPLATE" ]; then
		get_router_vars
		local wifi_info iface ssid signal freq conns
		wifi_info=$(get_wifi_info "$mac")
		iface=$(printf '%s' "$wifi_info" | cut -f1)
		ssid=$(printf '%s' "$wifi_info" | cut -f2)
		signal=$(printf '%s' "$wifi_info" | cut -f3)
		freq=$(printf '%s' "$wifi_info" | cut -f4)
		conns=$(get_device_conns "$ip")

		printf '%s' "$TG_NOTIFY_TEMPLATE" | \
			awk -v n="$name" -v i="$ip" -v m="$mac" -v l="$link" \
			    -v dt="$TVAR_DATE" -v tm="$TVAR_TIME" -v dtm="$TVAR_DATETIME" \
			    -v rtr="$TVAR_ROUTER" -v ssid="$ssid" -v sig="$signal" \
			    -v freq="$freq" -v iface="$iface" -v clients="$TVAR_CLIENTS" \
			    -v up="$TVAR_UPTIME" -v wan="$TVAR_WAN_IP" -v ld="$TVAR_LOAD" \
			    -v conns="$conns" '{
				gsub(/\{\{\s*name\s*\}\}/, n)
				gsub(/\{\{\s*ip\s*\}\}/, i)
				gsub(/\{\{\s*mac\s*\}\}/, m)
				gsub(/\{\{\s*link\s*\}\}/, l)
				gsub(/\{\{\s*date\s*\}\}/, dt)
				gsub(/\{\{\s*time\s*\}\}/, tm)
				gsub(/\{\{\s*datetime\s*\}\}/, dtm)
				gsub(/\{\{\s*router\s*\}\}/, rtr)
				gsub(/\{\{\s*ssid\s*\}\}/, ssid)
				gsub(/\{\{\s*signal\s*\}\}/, sig)
				gsub(/\{\{\s*freq\s*\}\}/, freq)
				gsub(/\{\{\s*iface\s*\}\}/, iface)
				gsub(/\{\{\s*clients\s*\}\}/, clients)
				gsub(/\{\{\s*uptime\s*\}\}/, up)
				gsub(/\{\{\s*wan_ip\s*\}\}/, wan)
				gsub(/\{\{\s*load\s*\}\}/, ld)
				gsub(/\{\{\s*conns\s*\}\}/, conns)
				gsub(/\\n/, "\n")
				print
			}'
	else
		printf '🆕 <b>New device</b>\n%s (%s)\nMAC: <code>%s</code>\nLink: %s' \
			"$name" "$ip" "$mac" "$link"
	fi
}

process_dhcp_triggers() {
	[ -f "$DHCP_TRIGGER_FILE" ] || return 0
	local tmpf="${DHCP_TRIGGER_FILE}.proc"
	mv "$DHCP_TRIGGER_FILE" "$tmpf" 2>/dev/null || return 0

	local mac ip name
	while IFS='	' read -r mac ip name; do
		[ -z "$mac" ] && continue
		mac=$(printf '%s' "$mac" | tr 'A-F' 'a-f')
		if ! is_known_mac "$mac"; then
			add_known_mac "$mac" "${name:-unknown}" "${ip:-?}"
			if [ "$TG_NOTIFY_NEW" = "1" ]; then
				tg_send "$(format_new_device_msg "${name:-unknown}" "${ip:-?}" "$mac" "dhcp")"
			fi
		fi
	done < "$tmpf"
	rm -f "$tmpf"
}

check_new_devices() {
	local mac info name ip conn_type
	local current_macs="/tmp/trafficctl_tg_cur.tmp"

	discover_macs > "$current_macs"

	while read -r mac; do
		[ -z "$mac" ] && continue
		if ! is_known_mac "$mac"; then
			info=$(resolve_mac_info "$mac")
			name=$(printf '%s' "$info" | cut -f1)
			ip=$(printf '%s' "$info" | cut -f2)
			conn_type=$(printf '%s' "$info" | cut -f3)
			add_known_mac "$mac" "${name:-unknown}" "${ip:-?}"
			if [ "$TG_NOTIFY_NEW" = "1" ]; then
				tg_send "$(format_new_device_msg "${name:-unknown}" "${ip:-?}" "$mac" "${conn_type:-?}")"
			fi
		elif [ "$TG_NOTIFY_KNOWN" = "1" ]; then
			if [ -f "$ONLINE_STATE_FILE" ] && ! grep -q "$mac" "$ONLINE_STATE_FILE" 2>/dev/null; then
				info=$(resolve_mac_info "$mac")
				name=$(printf '%s' "$info" | cut -f1)
				ip=$(printf '%s' "$info" | cut -f2)
				conn_type=$(printf '%s' "$info" | cut -f3)
				tg_send "$(printf '📱 <b>Device online</b>\n%s (%s)\nLink: %s' \
					"${name:-unknown}" "${ip:-?}" "${conn_type:-?}")"
			fi
		fi
	done < "$current_macs"

	mv "$current_macs" "$ONLINE_STATE_FILE"
}

# ── keyboard builders ───────────────────────────────────────────────────────

build_device_keyboard() {
	local devices="$1"
	local tmpkb="/tmp/trafficctl_tg_kb.tmp"
	local ip name btn col=0 first=1

	printf '{"inline_keyboard":[' > "$tmpkb"

	for ip in $(echo "$devices" | jsonfilter -e '@[*].ip' 2>/dev/null); do
		name=$(echo "$devices" | jsonfilter -e "@[@.ip='$ip'].name" 2>/dev/null)
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

build_action_keyboard() {
	local ip="$1" devices="$2"
	local blocked wifi_blocked rl_kbit shape_kbit
	blocked=$(get_device_field "$devices" "$ip" "blocked")
	wifi_blocked=$(get_device_field "$devices" "$ip" "wifi_blocked")
	rl_kbit=$(get_device_field "$devices" "$ip" "rate_limit_kbit")
	shape_kbit=$(get_device_field "$devices" "$ip" "shape_kbit")
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
			rows="${rows}[{\"text\":\"⚡ Limit: ${rl_kbit} kbit/s — Remove\",\"callback_data\":\"act:unlimit:${ip}\"}],"
		else
			rows="${rows}[{\"text\":\"⚡ 1M\",\"callback_data\":\"act:limit:${ip}:1000\"},{\"text\":\"⚡ 2M\",\"callback_data\":\"act:limit:${ip}:2000\"},{\"text\":\"⚡ 5M\",\"callback_data\":\"act:limit:${ip}:5000\"}],"
			rows="${rows}[{\"text\":\"⚡ 10M\",\"callback_data\":\"act:limit:${ip}:10000\"},{\"text\":\"⚡ 25M\",\"callback_data\":\"act:limit:${ip}:25000\"},{\"text\":\"⚡ 50M\",\"callback_data\":\"act:limit:${ip}:50000\"},{\"text\":\"⚡ 100M\",\"callback_data\":\"act:limit:${ip}:100000\"}],"
		fi
	fi

	# shaper
	if [ "$TG_BTN_SHAPE" = "1" ]; then
		if [ "${shape_kbit:-0}" -gt 0 ] 2>/dev/null; then
			rows="${rows}[{\"text\":\"🔧 Shape: ${shape_kbit} kbit/s — Remove\",\"callback_data\":\"act:unshape:${ip}\"}],"
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
	local devices ip name rl_kbit shape_kbit blocked wifi_blocked
	local result=""
	devices=$(get_devices)
	[ -z "$devices" ] || [ "$devices" = "[]" ] && { tg_send "No active devices"; return; }

	for ip in $(echo "$devices" | jsonfilter -e '@[*].ip' 2>/dev/null); do
		blocked=$(get_device_field "$devices" "$ip" "blocked")
		wifi_blocked=$(get_device_field "$devices" "$ip" "wifi_blocked")
		rl_kbit=$(get_device_field "$devices" "$ip" "rate_limit_kbit")
		shape_kbit=$(get_device_field "$devices" "$ip" "shape_kbit")
		name=$(get_device_field "$devices" "$ip" "name")

		local flags=""
		[ "$blocked" = "true" ] || [ "$blocked" = "1" ] && flags="${flags} 🚫inet"
		[ "$wifi_blocked" = "true" ] || [ "$wifi_blocked" = "1" ] && flags="${flags} 📵wifi"
		[ "${rl_kbit:-0}" -gt 0 ] 2>/dev/null && flags="${flags} ⚡${rl_kbit}k"
		[ "${shape_kbit:-0}" -gt 0 ] 2>/dev/null && flags="${flags} 🔧${shape_kbit}k"

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
		local blocked wifi_blocked rl_kbit shape_kbit
		blocked=$(get_device_field "$devices" "$ip" "blocked")
		wifi_blocked=$(get_device_field "$devices" "$ip" "wifi_blocked")
		rl_kbit=$(get_device_field "$devices" "$ip" "rate_limit_kbit")
		shape_kbit=$(get_device_field "$devices" "$ip" "shape_kbit")

		local status_line=""
		[ "$blocked" = "true" ] || [ "$blocked" = "1" ] && status_line="${status_line}🚫 Internet blocked\n"
		[ "$wifi_blocked" = "true" ] || [ "$wifi_blocked" = "1" ] && status_line="${status_line}📵 WiFi blocked\n"
		[ "${rl_kbit:-0}" -gt 0 ] 2>/dev/null && status_line="${status_line}⚡ Limiter: ${rl_kbit} kbit/s\n"
		[ "${shape_kbit:-0}" -gt 0 ] 2>/dev/null && status_line="${status_line}🔧 Shaper: ${shape_kbit} kbit/s\n"
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
	load_known

	export TCTL_VIA="telegram"
	export TCTL_SRC="telegram:${TG_CHAT_ID}"
	export TCTL_USER="telegram-bot"

	logger -t trafficctl-tg "Bot started, chat_id=$TG_CHAT_ID"

	local offset response ok update_count i
	local update update_id msg_chat_id msg_text cb_id cb_data cb_msg_id
	local config_reload_at
	config_reload_at=$(($(date +%s) + 60))

	offset=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")

	while true; do
		check_new_devices
		process_dhcp_triggers

		response=$(tg_api "getUpdates" \
			"$(printf '{"offset":%s,"timeout":%d,"allowed_updates":["message","callback_query"]}' \
				"$offset" "$TG_POLL")")

		ok=$(echo "$response" | jsonfilter -e '@.ok' 2>/dev/null)
		[ "$ok" = "true" ] || { sleep 5; continue; }

		update_count=$(echo "$response" | jsonfilter -l '@.result' 2>/dev/null || echo 0)
		i=0
		while [ "$i" -lt "$update_count" ]; do
			update=$(echo "$response" | jsonfilter -e "@.result[$i]" 2>/dev/null)
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
