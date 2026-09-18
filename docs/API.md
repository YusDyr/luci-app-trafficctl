# API Reference

All backend functionality is exposed through shell scripts in `/usr/local/bin/trafficctl-*.sh`. The LuCI frontend calls them via JSON-RPC through the rpcd backend at `/usr/libexec/rpcd/luci.trafficctl`.

---

## Common Conventions

- **Input validation**: scripts that take an address validate it with regex + octet range (0–255) via `tctl_validate_ip`; `tctl_validate_target` additionally accepts a CIDR or `all`.
- **Error format**: `{"ok":false,"msg":"Human-readable error message"}`
- **Success format (actions)**: `{"ok":true,"msg":"Human-readable success message"}`
- **Rate units**: All rate values are in **kbit/s** (kilobits per second).
- **Exit codes**: 0 on success, 1 on input validation failure.
- **Label sanitization**: `block`, `unblock`, `ratelimit` and `shape_add` strip their label to `[a-zA-Z0-9_.-]`.
- **Labels do not identify rules.** A label is recorded in the activity log only. Firewall rule comments are derived from the target (`tctl_block_<slug>`, `rl_ratelimit_<slug>`), so a control created from one surface can be removed from another — a label-derived comment made a block placed in LuCI un-removable from the Telegram bot.
- **`log_file` is constrained** to `/tmp/trafficctl/*` or `/var/log/*`, and `max_lines` to 20–100000. The path is both an append target and a `tail`/rewrite target, so an unconstrained value was an arbitrary root read and truncate.

---

## rpcd Methods

The frontend calls these via `rpc.declare()`:

Every method is listed here. The ACL group is `luci-app-trafficctl`
(`/usr/share/rpcd/acl.d/luci-app-trafficctl.json`): read-only methods sit under
`read`, everything that changes state under `write`. `activity_log` is a **write**
method because it returns the contents of the configured log file.

| Method | Script | Params | ACL |
|--------|--------|--------|-----|
| `summary` | `trafficctl-summary.sh` | (none) | read |
| `device` | `trafficctl-device.sh` | `ip`, `proto` | read |
| `bytes` | `trafficctl-bytes.sh` | (none) | read |
| `rdns` | `trafficctl-rdns.sh` | `ip` | read |
| `ratelimit_stats` | `trafficctl-ratelimit-stats.sh` | (none) | read |
| `shape_stats` | `trafficctl-shape-stats.sh` | (none) | read |
| `shape_status` | `trafficctl-shape.sh status` | `ip` | read |
| `names_list` | `trafficctl-names.sh list` | (none) | read |
| `portfw_list` | `trafficctl-portfw.sh list` | (none) | read |
| `netify_status` | `trafficctl-netify.sh status` | (none) | read |
| `netify_list` | `trafficctl-netify.sh list` | (none) | read |
| `config_get` | (inline) | (none) — returns `enabled`, `default_mode`, `offload_mode`, `sw`, `hw` | read |
| `telegram_config_get` | (inline) | (none) — `bot_token` is masked as `***` | read |
| `logging_config_get` | (inline) | (none) | read |
| `newdevice_config_get` | (inline) | (none) — returns `enabled`, `limit_kbit`, `limit_mode`, plus `seeded` and `seen_count` describing the seen-MAC ledger | read |
| `version` | (inline) | (none) | read |
| `cut_status` | `trafficctl-cut.sh status` | (none) | **write** — see below |
| `cut_set` | `trafficctl-cut.sh engage`/`release` | `active` (bool), `duration` (seconds, `0` = indefinite), `persist` (bool) | write |
| `block` | `trafficctl-block.sh` | `ip`, `label` | write |
| `unblock` | `trafficctl-unblock.sh` | `ip`, `label` | write |
| `ratelimit` | `trafficctl-ratelimit.sh` | `ip`, `rate_kbit`, `label`, `mode` (`each`\|`shared`) | write |
| `shape_add` | `trafficctl-shape.sh add` | `ip`, `rate_kbit`, `label` | write |
| `shape_remove` | `trafficctl-shape.sh remove` | `ip`, `label` | write |
| `macfilter_add` | `trafficctl-macfilter-add.sh` | `ip` | write |
| `macfilter_remove` | `trafficctl-macfilter-remove.sh` | `ip` | write |
| `name_set` | `trafficctl-names.sh set` | `ip`, `name` (empty `name` clears the alias) | write |
| `name_clear` | `trafficctl-names.sh remove` | `ip` | write |
| `portfw_ctl` | `trafficctl-portfw.sh` | `action`, `scope`, `proto`, `ip`, `port`, `rate_kbit` | write |
| `netify_collect` | `trafficctl-netify.sh collect` | `secs` | write |
| `config_set` | (inline) | `enabled`, `default_mode`, `sw`, `hw` (all optional) | write |
| `telegram_config_set` | (inline) | `enabled`, `bot_token`, `chat_id`, `poll_interval`, `notify_new_device`, `notify_known_device`, `control_enabled`, `notify_template`, `btn_block_inet`, `btn_block_wifi`, `btn_limiter`, `btn_shaper` | write |
| `telegram_test` | `trafficctl-telegram-test.sh` | `bot_token`, `chat_id`, `message` | write |
| `logging_config_set` | (inline) | `enabled`, `log_file`, `max_lines`, `syslog`, `log_blocks`, `log_ratelimits`, `log_shapes`, `log_telegram`, `log_config` | write |
| `newdevice_config_set` | (inline) | `enabled`, `limit_kbit`, `limit_mode` (`limiter`\|`shaper`) | write |
| `activity_log` | (inline) | `lines` (default 50, capped at 1000) | write |

Setting `newdevice.enabled` to true seeds the seen-MAC ledger
(`/etc/trafficctl/seen_macs`) from the current DHCP leases and neighbour table, so
switching the feature on does not classify the devices already on the network as
new. The ledger is authoritative: the hotplug hook applies nothing at all on a run
that finds no ledger, because a missing one cannot distinguish "new device" from
"router has not noticed this device yet".

`port` accepts a single port or a `lo-hi` range. On the iptables path a range is
passed through as `lo:hi`; it used to be truncated to the low port, which left the
rest of the range open while the UI reported the whole range paused.

---

## Query Scripts

### trafficctl-summary.sh

Returns a summary of all active LAN devices with traffic control status and connection type.

**Arguments:** None

**Output:** JSON array of device objects.

```json
[
  {
    "ip": "192.168.0.111",
    "name": "MacBookPro",
    "mac": "06:2b:92:a8:bd:8c",
    "conn_type": "5G",
    "conns": 42,
    "total": 1958278,
    "tcp": 1900000,
    "udp": 58278,
    "blocked": false,
    "block_bytes": 0,
    "wifi_blocked": false,
    "rate_limit_kbit": 0,
    "shape_kbit": 10000
  }
]
```

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `ip` | string | Device LAN IP address |
| `name` | string | Hostname from DHCP lease, or `*` if unknown |
| `mac` | string | MAC address (lowercase), empty if not resolved |
| `conn_type` | string | `"2.4G"`, `"5G"`, `"6G"`, `"lan2"`, `"lan3"`, `"lan4"`, or `"ethernet"` |
| `conns` | number | Active connection count (unique dst IPs) |
| `total` | number | Total bytes in conntrack (reply direction = download) |
| `tcp` | number | TCP bytes |
| `udp` | number | UDP bytes |
| `blocked` | boolean | Whether internet is blocked |
| `block_bytes` | number | Bytes matched by the block rule (cumulative) |
| `wifi_blocked` | boolean | Whether MAC is in WiFi deny list |
| `rate_limit_kbit` | number | Active policer rate in kbit/s (0 = not limited) |
| `shape_kbit` | number | Active shaper rate in kbit/s (0 = not shaped) |

---

### trafficctl-device.sh

Returns detailed connection information for a single device.

**Arguments:**

| Position | Required | Description |
|----------|----------|-------------|
| 1 | Yes | IPv4 address |
| 2 | No | Protocol filter: `tcp`, `udp`, or `all` (default: `all`) |

**Output:**

```json
{
  "ip": "192.168.0.111",
  "name": "MacBookPro",
  "mac": "06:2b:92:a8:bd:8c",
  "conn_type": "5G",
  "timestamp": 1779742529,
  "blocked": false,
  "block_packets": 0,
  "block_bytes": 0,
  "wifi_blocked": false,
  "total": 101,
  "protocols": {"tcp": 91, "udp": 10, "other": 0},
  "tcp_states": {"established": 22, "time_wait": 3, "syn_sent": 63, "close_wait": 0},
  "connections": [
    {
      "proto": "tcp",
      "dst": "140.82.121.3",
      "host": "",
      "port": 443,
      "service": "https",
      "bytes": 17261,
      "state": "ESTABLISHED",
      "oif": "wan2"
    }
  ],
  "rate_limit_kbit": 0,
  "shape_kbit": 10000
}
```

Each connection's `oif` is the egress interface, resolved via
`ip route get <dst> mark <mark>` from the connection's conntrack fwmark. It is
only populated for **policy-routed** connections (a non-zero connmark, e.g.
mwan3, which restores the routing mark). For connections with mark `0` (plain
single-WAN, or policy-routing that doesn't restore the connmark such as podkop)
`oif` is empty. The LuCI connections table exposes it as an optional, hidden-by-default
"Iface" column.

---

### trafficctl-bytes.sh

Returns raw byte counters from conntrack for bandwidth speed calculation.

**Arguments:** None

**Output:**

```json
[
  {"ip": "192.168.0.111", "bytes_in": 456789012, "bytes_out": 12345678}
]
```

| Field | Type | Description |
|-------|------|-------------|
| `ip` | string | Device IP |
| `bytes_in` | number | Total bytes received (download = conntrack reply direction) |
| `bytes_out` | number | Total bytes sent (upload = conntrack original direction) |

---

### trafficctl-ratelimit-stats.sh

Returns drop counters from the nftables rate-limiter.

**Arguments:** None

**Output:**

```json
[
  {"ip": "192.168.0.100", "rate_kbit": 5000, "packets": 1423, "bytes": 2134567}
]
```

Returns `[]` if no rate limits are active or on iptables backends.

---

### trafficctl-shape-stats.sh

Returns tc/HTB class statistics for all shaped devices.

**Arguments:** None

**Output:**

```json
[
  {"ip": "192.168.0.111", "rate_kbit": 10000, "bytes": 45678901, "packets": 32456, "backlog": 4096}
]
```

Returns `[]` if tc is not installed or no HTB qdisc exists.

---

### trafficctl-rdns.sh

Reverse DNS lookup for a single IP. Used by the Telegram bot and the rpcd `rdns` ubus
method. The LuCI frontend uses `network.rrdns.lookup` directly for batch resolution.

**Arguments:** `<ip>`

**Output:**

```json
{"ip": "140.82.121.3", "host": "lb-140-82-121-3-iad.github.com"}
```

Uses `ubus call network.rrdns lookup` (rpcd-mod-rrdns, ships with rpcd) with BusyBox
`nslookup` as a fallback. No `bind-dig` required.

---

## Action Scripts

### trafficctl-block.sh / trafficctl-unblock.sh

Block/unblock a device's internet access.

**Arguments:** `<ip> [label]`

**Output:**
```json
{"ok": true, "msg": "blocked 192.168.0.100 (label: Kids-iPad)"}
```

**Side effects (block):**
- Inserts drop rule in `inet fw4 forward` (nft) or `FORWARD` chain (iptables).
- Kills existing conntrack entries for the device.

---

### trafficctl-cut.sh

Cut internet access for **every** device at once while the LAN keeps working.

**Arguments:** `engage <seconds|0> [persist]` · `release` · `status` · `restore` · `tick` · `keeper`

`seconds` is `0` (indefinite) or 60–604800. `persist` is `0`/`1`.

**Output (`status`, and the reply to `engage`/`release`):**
```json
{"ok":true,"active":true,"rule_present":true,"supported":true,
 "expires_at":1700000900,"remaining":845,"started_at":1700000000,
 "persist":false,"keeper_running":true,"lan_devices":"br-lan br-guest",
 "default_duration":900,"default_persist":false,"msg":""}
```

`active` is what the state file says; **`rule_present` is what the kernel
says**, and the UI renders the control as ON only when both hold. The two can
disagree, and when they do the honest answer is "switched on but not in force",
never a plain ON.

**Mechanism.** One rule in its **own** table:

```
table inet tctl_cut {
    chain cut_forward {
        type filter hook forward priority -190; policy accept;
        oifname != { "br-lan", … } counter drop comment "tctl_cut"
    }
}
```

- **Own table, not `inet fw4`.** fw4 tears down and rebuilds its own table on
  every reload, and the `ifup lan` restore hook does not fire for that — a bare
  `fw4 reload` would drop a rule placed there with nothing to put it back. Our
  table survives a firewall rebuild structurally. (Same reasoning as
  `inet tctl_pfw` and `netdev tm_ratelimit`.)
- **Priority −190** is after DNAT and before fw4's flowtable rule at filter
  priority 0, so an offloaded flow cannot bypass the drop.
- **Interface matching, not addresses.** IPv4 *and* IPv6 are cut by the same
  rule — the per-device block matches `ip saddr` and is v4-only, which for a
  global cut would let a device walk out over a SLAAC address. LAN↔LAN, VLAN
  ↔VLAN and downstream routed subnets all leave via a LAN device and are
  spared; same-subnet traffic is bridged and never reaches the forward hook.
- **`forward`, not `input`.** Traffic addressed to the router itself is
  untouched: LuCI from the LAN and a VPN terminating *on* the router keep
  working. What does stop is remote access that lands on a LAN host first
  (Tailscale on a NAS, a tunnel from a LAN box, a jump host).
- **Inbound is deliberately not cut.** WAN→LAN flows through a port forward
  keep working; those exist only where the operator created them, and
  `portfw_ctl pause` is the control for them.
- `conntrack -D` is issued per monitored subnet on engage (established and
  offloaded flows outlive a new drop rule), never as a global `conntrack -F`.

**Persistence.** The engaged state lives in `/var/run/trafficctl/cut.state`
(tmpfs), so a reboot always clears it. This is the one control that can lock out
its own operator, and the remedy must never become "be physically present".
Ticking *Keep after reboot* additionally writes `/etc/trafficctl/cut.state`,
restored on `ifup lan` by `trafficctl-cut.sh restore` — guarded on that file's
own `persist=1`, **not** on the global `persist_rules` flag, and honouring the
original absolute deadline rather than restarting the clock. It is deliberately
absent from `root/lib/upgrade/keep.d/`: a cut outliving a *firmware upgrade* is
strictly worse than one outliving a reboot.

**Auto-revert.** `/etc/init.d/trafficctl-cut` supervises a keeper that ticks
every 5s: it enforces the deadline and re-asserts the rule if the table went
missing (a wholesale `nft flush ruleset` still takes it). `status` reconciles
independently — it releases a cut whose deadline has passed and starts a
replacement keeper if one died — which is why it is a **write** method despite
reading like one, the same reasoning that makes `activity_log` a write method.

---

### trafficctl-ratelimit.sh

Set or remove a download rate limit (policer).

**Arguments:** `<ip> <rate_kbit> [label]`

Rate of `0` removes the limit.

**Output:**
```json
{"ok": true, "msg": "rate limit set: 5000 kbit/s for 192.168.0.100"}
```

---

### trafficctl-shape.sh

Manage tc/HTB traffic shaping.

**Arguments:** `<add|remove|status> <ip> [rate_kbit] [label]`

**Output (add):**
```json
{"ok": true, "msg": "shape 10000 kbit/s applied to 192.168.0.111 (class 1:6f)"}
```

**Output (status):**
```json
{"ok": true, "ip": "192.168.0.111", "classid": "1:6f", "info": "rate 10000Kbit"}
```

**Persistence:** Writes to `/etc/trafficctl/shapes.json` on every add/remove.

---

### trafficctl-macfilter-add.sh / trafficctl-macfilter-remove.sh

Block/unblock a device from WiFi (MAC filter).

**Arguments:** `<ip>`

**Output:**
```json
{"ok": true, "msg": "wifi blocked for 06:2b:92:a8:bd:8c on 2 interface(s)"}
```

**Side effects:**
- Sets `macfilter=deny` on all wifi-iface sections.
- Adds/removes MAC from `maclist`.
- Applies at runtime via `hostapd_cli deny_acl` + `deauthenticate` (no wifi reload -- only target client affected).

---

## Telegram Bot

### trafficctl-telegram.sh

Bot daemon using Telegram long polling. Runs under procd.

**Commands:**
- `/devices` -- inline keyboard with all active devices
- `/status` -- text summary of blocked/limited devices
- `/help` -- usage

**Callback data format:** `act:<verb>:<ip>[:<param>]`

| Callback | Action |
|----------|--------|
| `act:menu:<ip>` | Show device action buttons |
| `act:block:<ip>` | Block internet |
| `act:unblock:<ip>` | Unblock internet |
| `act:wblock:<ip>` | Block WiFi |
| `act:wunblock:<ip>` | Unblock WiFi |
| `act:limit:<ip>:<rate>` | Apply limiter (rate in kbit/s) |
| `act:unlimit:<ip>` | Remove limiter |
| `act:shape:<ip>:<rate>` | Apply shaper |
| `act:unshape:<ip>` | Remove shaper |
| `act:back` | Return to device list |

**Known devices file:** `/etc/trafficctl/telegram_known.json` -- tracks MACs for new device notifications.

### trafficctl-telegram-test.sh

```
trafficctl-telegram-test.sh <token> <chat_id>
```

Validates token format and chat_id, sends a test message. Returns `{"ok":true,"msg":"..."}`.

---

## rpcd ACL

The ACL file at `/usr/share/rpcd/acl.d/luci-app-trafficctl.json` grants execution permissions. The rpcd backend at `/usr/libexec/rpcd/luci.trafficctl` handles method dispatch and parameter validation.
