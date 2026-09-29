#!/bin/bash
# Unit tests for trafficctl-fw.sh helper functions.

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf "FAIL: %s\n  expected: '%s'\n  actual:   '%s'\n" "$desc" "$expected" "$actual"
    fi
}

# Stub out commands that don't exist outside OpenWrt
uci() { echo ""; }
nft() { return 1; }
command() { return 1; }
export -f uci nft command

# Source the firewall library (will fall back to iptables mode)
. "$(dirname "$0")/../luci-app-trafficctl/root/usr/local/bin/trafficctl-fw.sh"

# --- tctl_validate_ip ---

assert_eq "valid IP 192.168.1.1" 0 "$(tctl_validate_ip '192.168.1.1' && echo 0 || echo 1)"
assert_eq "valid IP 10.0.0.1" 0 "$(tctl_validate_ip '10.0.0.1' && echo 0 || echo 1)"
assert_eq "valid IP 255.255.255.255" 0 "$(tctl_validate_ip '255.255.255.255' && echo 0 || echo 1)"
assert_eq "valid IP 0.0.0.0" 0 "$(tctl_validate_ip '0.0.0.0' && echo 0 || echo 1)"

assert_eq "invalid IP empty" 1 "$(tctl_validate_ip '' && echo 0 || echo 1)"
assert_eq "invalid IP letters" 1 "$(tctl_validate_ip 'abc.def.ghi.jkl' && echo 0 || echo 1)"
assert_eq "invalid IP 256.1.1.1" 1 "$(tctl_validate_ip '256.1.1.1' && echo 0 || echo 1)"
assert_eq "invalid IP 1.1.1.999" 1 "$(tctl_validate_ip '1.1.1.999' && echo 0 || echo 1)"
assert_eq "invalid IP too few octets" 1 "$(tctl_validate_ip '192.168.1' && echo 0 || echo 1)"
assert_eq "invalid IP with spaces" 1 "$(tctl_validate_ip '192.168.1.1 ; rm -rf /' && echo 0 || echo 1)"
assert_eq "invalid IP CIDR" 1 "$(tctl_validate_ip '192.168.1.0/24' && echo 0 || echo 1)"
assert_eq "invalid IP trailing dot" 1 "$(tctl_validate_ip '192.168.1.1.' && echo 0 || echo 1)"

# --- tctl_get_lan_device (fallback) ---

assert_eq "lan device fallback" "br-lan" "$(tctl_get_lan_device)"

# --- tctl_get_wan_device ---
# With nothing resolvable it must FAIL rather than return the literal "wan":
# that is an interface name, not a device, and nft silently refuses to hook it.

# tctl_get_wan_device also consults `ip route show default` and then checks the
# candidate really exists under /sys/class/net. On any host that HAS a default
# route (i.e. every CI runner) that resolves a genuine device, so the
# "nothing resolves" precondition below would not hold and these two cases
# would fail — while the function was in fact behaving correctly. Run them in a
# subshell that stubs the remaining lookups and points the sysfs probe at an
# empty directory, so the case is deterministic on every host.
_EMPTY_SYSFS=$(mktemp -d)
_wan_device_no_candidates() (
    ip() { return 1; }
    ubus() { return 1; }
    jsonfilter() { return 1; }
    export TCTL_SYSFS_NET="$_EMPTY_SYSFS"
    tctl_get_wan_device
)

assert_eq "wan device: fails when nothing resolves" 1 "$(_wan_device_no_candidates >/dev/null && echo 0 || echo 1)"
assert_eq "wan device: emits no bogus name" "" "$(_wan_device_no_candidates 2>/dev/null)"
rmdir "$_EMPTY_SYSFS" 2>/dev/null

# --- TCTL_FW detection ---

assert_eq "firewall mode is iptables when nft unavailable" "iptables" "$TCTL_FW"

# --- tctl_get_offload_mode ---
# Each case runs in a subshell with stubbed uci/nft, sources the library fresh,
# then returns the mode string which assert_eq compares.

_offload_mode() {
    local sw="$1" hw="$2" nft_out="$3"
    (
        _sw="$sw"; _hw="$hw"; _nft_out="$nft_out"
        uci() {
            case "$3" in
                "firewall.@defaults[0].flow_offloading")    echo "$_sw" ;;
                "firewall.@defaults[0].flow_offloading_hw") echo "$_hw" ;;
            esac
        }
        nft() {
            [ "$1" = "list" ] && [ "$2" = "flowtables" ] || return 1
            [ -n "$_nft_out" ] || return 1
            printf '%s\n' "$_nft_out"
        }
        export -f uci nft
        . "$(dirname "$0")/../luci-app-trafficctl/root/usr/local/bin/trafficctl-fw.sh"
        tctl_get_offload_mode
    )
}

assert_eq "offload_mode: none (both disabled)" \
    "none" "$(_offload_mode 0 0 "")"
assert_eq "offload_mode: software" \
    "software" "$(_offload_mode 1 0 "")"
assert_eq "offload_mode: hardware (no counter flag in flowtable)" \
    "hardware" "$(_offload_mode 0 1 "flowtable ft { hook ingress priority 0; devices = { eth0 }; }")"
assert_eq "offload_mode: hardware-counter (counter flag present)" \
    "hardware-counter" "$(_offload_mode 0 1 "flowtable ft { flags { offload, counter }; devices = { eth0 }; }")"

# --- tctl_get_wifi_filter_mode ---
# Only an explicit "allow" is a whitelist; everything else (including unset, and
# any unexpected value) must report "deny", because that is the policy the
# package creates on demand. Getting this backwards would invert an
# administrator's ACL — see the wifi allow-mode fix.

_filter_mode() {
    # $1 = value uci returns for wireless.<iface>.macfilter. Held in a variable
    # because the stub's own $1 is the "-q" flag, not the configured value.
    _MACFILTER="$1"
    uci() { echo "$_MACFILTER"; }
    tctl_get_wifi_filter_mode wifiX
}

assert_eq "wifi filter mode: allow" "allow" "$(_filter_mode allow)"
assert_eq "wifi filter mode: deny" "deny" "$(_filter_mode deny)"
assert_eq "wifi filter mode: unset defaults to deny" "deny" "$(_filter_mode '')"
assert_eq "wifi filter mode: unknown value defaults to deny" "deny" "$(_filter_mode bogus)"


# --- tctl_wifi_block_pending ---
# "Listed as WiFi-blocked, yet associated on a radio right now" is the only
# evidence available at poll time that the running hostapd ACL never got the
# block. It is what the dashboard needs in order to stop reporting a device as
# blocked while it is browsing. Keyed off conn_type rather than the station
# dump so it still works where iw is missing and the connection type came from
# the bridge port instead.

_pending() { tctl_wifi_block_pending "$1" "$2" && echo yes || echo no; }

assert_eq "pending: blocked + on 5G = not enforced" "yes" "$(_pending 1 5G)"
assert_eq "pending: blocked + on 2.4G = not enforced" "yes" "$(_pending 1 2.4G)"
assert_eq "pending: blocked + on 6G = not enforced" "yes" "$(_pending 1 6G)"
assert_eq "pending: blocked + generic wifi (bridge-port path) = not enforced" "yes" "$(_pending 1 wifi)"
# A block that actually works makes the device stop associating, so these are
# the states a working block leaves behind — never "pending".
assert_eq "pending: blocked + unreachable is not proof of anything" "no" "$(_pending 1 '?')"
assert_eq "pending: blocked + on cable says nothing about the radio" "no" "$(_pending 1 ethernet)"
assert_eq "pending: blocked + behind a downstream router" "no" "$(_pending 1 routed)"
# Not blocked at all: never pending, whatever the device is connected over.
assert_eq "pending: not blocked + on 5G" "no" "$(_pending 0 5G)"
assert_eq "pending: not blocked + unreachable" "no" "$(_pending 0 '?')"
assert_eq "pending: empty blocked flag" "no" "$(_pending '' 5G)"

# --- tctl_enforce_rank ---
# Ordering matters: a block applied on one radio and missed on another must
# report the miss, so the worst outcome has to sort lowest.
assert_eq "enforce rank: acl is best" "3" "$(tctl_enforce_rank acl)"
assert_eq "enforce rank: ban is partial" "2" "$(tctl_enforce_rank ban)"
assert_eq "enforce rank: none is worst" "1" "$(tctl_enforce_rank none)"
assert_eq "enforce rank: unknown words sort as worst" "1" "$(tctl_enforce_rank wat)"

# --- tctl_get_hostapd_ifaces ---
# An empty list must be distinguishable from a failed query: reading "ubus is
# not usable" as "no AP is running" would let a router report a block as
# applied with nothing enforcing it. The `command` stub at the top of this file
# makes `command -v ubus` fail, i.e. ubus is unavailable here.
assert_eq "hostapd ifaces: unusable ubus returns non-zero, not an empty success" \
    "1" "$(tctl_get_hostapd_ifaces >/dev/null 2>&1 && echo 0 || echo 1)"

# --- Results ---

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
