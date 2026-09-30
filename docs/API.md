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

## Address family coverage (IPv6)

Every device here is identified by its IPv4 address, and most enforcement
matches on that address. **IPv6 coverage is partial, and this section is the
complete statement of it** (issue #67).

| Control | IPv4 | IPv6 | Match |
|---|:---:|:---:|---|
| `cut` (all devices) | ✅ | ✅ | `fib daddr . iif oifname` / `oifname` — no address at all |
| `macfilter_add` (WiFi) | ✅ | ✅ | MAC, at association |
| `block` / `unblock` | ✅ | ✅ | `ip saddr` **+** `meta nfproto ipv6 ether saddr <mac>` |
| `ratelimit` — upload | ✅ | ✅ | `ip saddr` **+** `meta protocol ip6 ether saddr <mac>` |
| `ratelimit` — download | ✅ | ❌ | `ip daddr` |
| `shape_add` (tc/HTB) | ✅ | ❌ | `u32 match ip src`/`dst`; the `mirred` redirect into the IFB is itself `protocol ip` |
| `portfw` pause/limit | ✅ | ❌ | `ip daddr` |
| `bytes`, `totals`, `summary`, metrics | ✅ | ❌ | conntrack rows parsed as IPv4 |

**Why MAC and not `ip6 saddr`.** A client's IPv6 addresses are not stable:
SLAAC with privacy extensions gives it several at once and rotates them on a
timer. A rule written against one stops matching when it rotates, silently —
the same bypass as having no rule, reached more slowly. A MAC does not rotate.

**Where a MAC is not usable.**

- **Download.** On the LAN egress hook the outgoing L2 header does not exist
  yet — the destination MAC a packet carries there is the previous hop's — so
  `ether daddr` is not the client. Doing this correctly needs a named nft set
  per device fed from `ip -6 neigh`/DHCPv6 and refreshed as addresses rotate.
  That is a data-model change, and a stale set is a silent bypass, so it is
  deliberately **not** attempted here.
- **A client with no DHCP lease and no neighbour entry** (`extra_subnets`, a
  static route, anything behind a downstream router) has no MAC visible to this
  router. `tctl_lookup_mac` **fails** rather than guessing; the IPv4 rules are
  applied unchanged and the reply carries `"ipv6":false` plus an explicit
  *"IPv4 only: no MAC known…"* in `msg`. Installing nothing and reporting
  success is the failure this issue was about.
- **A downstream router** is excluded even when its MAC *is* known
  (`tctl_ip_is_nexthop`): its MAC is the source of every packet it forwards, so
  a MAC-keyed rule would hit every client behind it. Reported the same way,
  naming the reason.
- **fw3 / iptables (21.02)** is IPv4-only throughout; no `ip6tables` path.

**The IPv6 scope expression differs by family.** The block lives in `inet fw4
forward` and uses `meta nfproto ipv6`. The limiter's chains are in the **netdev**
family, where nft rejects that outright — *"meta nfproto is only useful in the
inet family"* — so those rules use `meta protocol ip6`. Same intent; using the
wrong one does not under-match quietly, the rule fails to load. Scoping at all
is required: an unscoped `ether saddr` rule would match a dual-stack client's
IPv4 as well and police it twice, halving the ceiling it was given.

**Comment suffixes.** The v6 rules carry no address, so their comment is the
only handle on them: `tctl_block_<slug>_mac` for a block and
`rl_ratelimit_<slug>_ul6` for an upload limit. Removal matches comments **in
full, closing quote included** — `_ul` is a prefix of `_ul6` and `<slug>` of a
longer slug, so a substring match would delete another device's rules (this
already happened once: unblocking `192.168.1.1` removed `192.168.1.10`'s rule).

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
| `bytes` | `trafficctl-totals.sh` | (none) | read |
| `ifaces` | `trafficctl-ifaces.sh` | (none) | read |
| `rdns` | `trafficctl-rdns.sh` | `ip` | read |
| `ratelimit_stats` | `trafficctl-ratelimit-stats.sh` | (none) | read |
| `subnets` | `trafficctl-subnets.sh` | (none) | read |
| `shape_stats` | `trafficctl-shape-stats.sh` | (none) | read |
| `shape_status` | `trafficctl-shape.sh status` | `ip` | read |
| `names_list` | `trafficctl-names.sh list` | (none) | read |
| `portfw_list` | `trafficctl-portfw.sh list` | (none) | read |
| `netify_status` | `trafficctl-netify.sh status` | (none) | read |
| `netify_list` | `trafficctl-netify.sh list` | (none) | read |
| `config_get` | (inline) | (none) — returns `enabled`, `default_mode`, `offload_mode`, `sw`, `hw`, `poll_interval`, `avg_window` | read |
| `telegram_config_get` | (inline) | (none) — `bot_token` is masked as `***` | read |
| `logging_config_get` | (inline) | (none) | read |
| `newdevice_config_get` | (inline) | (none) — returns `enabled`, `limit_kbit`, `limit_mode`, plus `seeded` and `seen_count` describing the seen-MAC ledger | read |
| `version` | (inline) | (none) | read |
| `cut_status` | `trafficctl-cut.sh status` | (none) | **write** — see below |
| `cut_set` | `trafficctl-cut.sh engage`/`release` | `active` (bool), `duration` (seconds, `0` = indefinite), `persist` (bool) | write |
| `block` | `trafficctl-block.sh` | `ip`, `label` | write |
| `unblock` | `trafficctl-unblock.sh` | `ip`, `label` | write |
| `ratelimit` | `trafficctl-ratelimit.sh` | `ip` (host, CIDR or `all`), `rate_kbit`, `label`, `mode` (`each`\|`shared`) | write |
| `shape_add` | `trafficctl-shape.sh add` | `ip`, `rate_kbit`, `label` | write |
| `shape_remove` | `trafficctl-shape.sh remove` | `ip`, `label` | write |
| `macfilter_add` | `trafficctl-macfilter-add.sh` | `ip` | write |
| `macfilter_remove` | `trafficctl-macfilter-remove.sh` | `ip` | write |
| `name_set` | `trafficctl-names.sh set` | `ip`, `name` (empty `name` clears the alias) | write |
| `name_clear` | `trafficctl-names.sh remove` | `ip` | write |
| `portfw_ctl` | `trafficctl-portfw.sh` | `action`, `scope`, `proto`, `ip`, `port`, `rate_kbit` | write |
| `netify_collect` | `trafficctl-netify.sh collect` | `secs` | write |
| `config_set` | (inline) | `enabled`, `default_mode`, `sw`, `hw`, `poll_interval`, `avg_window` (all optional) | write |
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

`poll_interval` and `avg_window` are the dashboard defaults for a browser that
has not chosen its own; the Poll and Window chips still override them per
browser. Both are bounded: `poll_interval` is 0 (polling off) or 1–300 seconds,
`avg_window` is 2–3600. The bounds are not cosmetic — `avg_window / poll_interval`
is how many samples every open browser keeps *per device*, and each poll costs
the router a conntrack read.

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
    "wifi_block_pending": false,
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
| `wifi_block_pending` | boolean | MAC is on a WiFi deny list **and the device is associated on a radio right now**, so the running hostapd ACL does not carry the block. A device in this state is not blocked, however the deny list reads |
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
  "wifi_block_pending": false,
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

Returns raw byte counters for bandwidth speed calculation. These are a *sample*,
not a lifetime total — see `trafficctl-totals.sh` below.

**Arguments:** None

**Output:**

```json
[
  {"ip": "192.168.0.111", "bytes_in": 456789012, "bytes_out": 12345678,
   "bytes_tcp": 460000000, "bytes_udp": 9134690, "src": "ct"}
]
```

| Field | Type | Description |
|-------|------|-------------|
| `ip` | string | Device IP |
| `bytes_in` | number | Bytes received (download = conntrack reply direction) |
| `bytes_out` | number | Bytes sent (upload = conntrack original direction) |
| `bytes_tcp` | number | TCP bytes, both directions. `-1` when the source cannot split by protocol |
| `bytes_udp` | number | UDP bytes, both directions. `-1` when the source cannot split by protocol |
| `src` | string | `ct` = conntrack, `nft` = nftables counter maps |
| `degraded` | bool | `true` when these counters are **frozen** for offloaded flows — see below |

`degraded` is about *trust*; `src` is about *magnitude*. They are separate
fields because conntrack counters are continuous across a change in trust, so
folding the two together would make a trust change look like a source change
and throw away a real delta.

`degraded` is `true` when the router has **uncountered** flow offload (plain
`hardware` or `software`) *and* the nftables fallback is unavailable — either
because the kernel has no dynamic counter map support (`trafficctl-bytes-nft.sh`
re-execs with `TCTL_FORCE_CONNTRACK=1`), or because the router runs fw3/iptables
and there is no fallback to reach. The counters then stop moving for every
offloaded flow while traffic continues, so any total built from them is a lower
bound that stalls. Consumers must refuse to present it as a total.

Which source is used is decided per call: with flow offload active and no
working `counter` flag, conntrack stops accounting for offloaded flows, so the
script hands over to `trafficctl-bytes-nft.sh`, whose maps sit on the forward
hook at priority `-200`, ahead of the flowtable at `-150`. Those maps are keyed
by address alone, which is why `bytes_tcp` / `bytes_udp` are `-1` there.

`-1` means "not measurable", never "zero". A consumer that renders it as 0 is
claiming the device sent no TCP at all.

---

### trafficctl-totals.sh

Wraps `trafficctl-bytes.sh` with a **monotonic per-device accumulator** — the
lifetime totals behind both the LuCI Bytes / TCP / UDP columns and the
`trafficctl_device_bytes_total` metric. Neither raw source is a lifetime total:
conntrack reports only flows that still exist (so a device's number collapses
when they expire — [#26](https://github.com/YusDyr/luci-app-trafficctl/issues/26)),
and the nft maps count only since the table was built.

**Arguments:** `--all` (optional) — also emit devices that have left the sample
but still carry a total. Used by the exporter so a Prometheus series does not
vanish and reappear every time an idle device's last flow expires.

**Output:** the `trafficctl-bytes.sh` array, extended per element:

```json
[
  {"ip": "192.168.0.111", "bytes_in": 456789012, "bytes_out": 12345678,
   "bytes_tcp": 460000000, "bytes_udp": 9134690, "src": "ct",
   "bytes_in_total": 8123456789, "bytes_out_total": 91234567,
   "bytes_tcp_total": 8100000000, "bytes_udp_total": 114691346,
   "total_since": 1789000000, "live": true}
]
```

| Field | Type | Description |
|-------|------|-------------|
| `bytes_in_total` | number | Lifetime bytes received |
| `bytes_out_total` | number | Lifetime bytes sent |
| `bytes_tcp_total` | number | Lifetime TCP bytes, or `-1` if not measurable |
| `bytes_udp_total` | number | Lifetime UDP bytes, or `-1` if not measurable |
| `total_since` | number | Unix time accumulation began for this device |
| `live` | bool | Whether the device was in this sample (always `true` without `--all`) |

When `live` is `false` (only reachable under `--all`) the device was not in this
sample, so there is no current reading: `bytes_in`, `bytes_out`, `bytes_tcp` and
`bytes_udp` are all `-1`. The `*_total` fields are unaffected — those are
accumulated history and stay exact.

**Semantics worth knowing before you build on it:**

- **Only positive movement counts.** A drop in the raw counter means flows
  expired; their bytes were accumulated while they lived, so the drop rebaselines
  and adds nothing.
- **A source switch rebaselines.** conntrack and nft counters have unrelated
  magnitudes, so toggling flow offload (or the nft path falling back on a kernel
  without dynamic counter maps) must not be differenced. The source is stored
  per device and a change starts a fresh baseline.
- **Totals reset on reboot.** The store is `/tmp/trafficctl_totals.state`, i.e.
  tmpfs. Deliberate: it is rewritten on every LuCI poll (2–10 s) and every
  scrape, and that write volume into flash would wear the router out. Surviving
  a reboot would mean a much coarser periodic flush into `/etc/trafficctl`
  (kept across sysupgrade by `lib/upgrade/keep.d`).
- **Totals advance only while something samples.** The LuCI page polling, or a
  Prometheus scrape, is what drives accumulation. With the page closed and no
  scraper configured, the counters stand still. There is no background tick.
- **Concurrent samplers are serialised** with an atomic `mkdir` lock, so a LuCI
  poll and a scrape landing together cannot discard one another's delta.
- **`degraded` is sticky per device.** A total accumulated from frozen counters
  stays understated for the rest of its life, so one tainted sample marks it
  until the counter resets. Clearing the flag as soon as a later sample looked
  healthy would re-present that same understated number as trustworthy. The
  exporter surfaces it as `trafficctl_device_bytes_degraded`, and the LuCI
  columns show `⚠` instead of a number — a counter that silently stalls reads
  as an idle device, which is how this failure hides.

---

### trafficctl-ifaces.sh

Returns per-interface byte counters from `/proc/net/dev`, with a role map, for
the global (bmon-style) overview. Rates are **not** computed here — the frontend
diffs two samples the same way it does for `trafficctl-bytes.sh`, so the script
is stateless and one sample is cheap.

**Arguments:** None

**Output:**

```json
[
  {"dev":"eth1","label":"wan","role":"wan","tunnel":false,"primary":true,
   "defroute":false,"enslaved":false,"up":true,"rx_bytes":5368709120,"tx_bytes":1234567890}
]
```

| Field | Type | Description |
|-------|------|-------------|
| `dev` | string | Kernel device name |
| `label` | string | uci/ubus interface name for that L3 device, or `dev` if it has none. Several interfaces routinely share one `l3_device` (`wan`, `wan6` and `wan6_alias0` on a dual-stack uplink); the plain name wins over a v6 or alias name, ties breaking on length then lexically, so the choice never depends on ubus dump order |
| `role` | string | `wan`, `lan`, `vpn` or `other` |
| `tunnel` | bool | Device name matches a tunnel pattern (WireGuard, AmneziaWG, GRE, …). `ppp*` is deliberately excluded — `pppoe-wan` is an uplink, not a VPN |
| `primary` | bool | The one interface the overview graphs. Exactly one per response |
| `defroute` | bool | Currently carries a v4 or v6 default route |
| `enslaved` | bool | Device is a bridge port (`/sys/class/net/<dev>/master` exists). Its bytes are also counted by its bridge, so it is forced to role `other` and the UI collapses it |
| `up` | bool | `operstate` is `up` or `unknown` |
| `rx_bytes` | number | Bytes received **by the interface** since boot |
| `tx_bytes` | number | Bytes sent **by the interface** since boot |

`rx`/`tx` are interface-relative, not client-relative: on the WAN `rx` is your
download, on `br-lan` `rx` is what the LAN sent upstream. Counters are 64-bit
and routinely exceed 2 GiB, so they are formatted with `%.0f` — never `%d`,
which busybox awk evaluates through a 32-bit int (see `tests/test_byte_overflow.sh`).

**Role rules**, in priority order — the ordering is what keeps a full-tunnel
router correct:

0. A bridge port is `other`, whatever else it looks like. `lan2`, `lan3` and
   `phy0-ap0` are ports of `br-lan` and report the very same bytes the bridge
   reports; naming cannot tell them apart from top-level devices, so
   enslavement is read from `/sys/class/net/<dev>/master`.
1. A device trafficctl already monitors as a LAN (`tctl_get_lan_devices`) is `lan`.
2. A tunnel-named device is `vpn`, **even when it holds the default route**.
   On a WireGuard/AmneziaWG full-tunnel setup the default route is via `awg0`
   while the physical uplink still carries every byte encapsulated; calling the
   tunnel "the WAN" would hide the real uplink under `other` and count the same
   traffic twice in any WAN total. `defroute` records who actually holds the route.
3. The uci network named `wan`/`wan6`, or any other default-route device, is `wan`.
4. Everything else is `other` (bridge ports, ifb mirrors, dummy devices).
5. If that leaves no `wan` at all — a router whose only default route is a
   tunnel and which has no uci `wan` — the route holder is promoted, so the
   overview always has something to graph.

`primary` picks the uci `wan` first, then a default-route WAN, then the first
WAN. Multi-WAN responses are **not** summed by the frontend: on a failover pair
that double-counts, and on two independent uplinks the sum describes neither
link (see issue #28).

**Caching:** the role map is the expensive part (sourcing `trafficctl-fw.sh`
runs `nft list tables`; `tctl_lan_subnets` forks ubus and jsonfilter per
network), so it is memoized in `/tmp/trafficctl_ifroles` with a 60 s TTL and the
poll path reads only `/proc/net/dev` plus that file. An interface missing from a
still-fresh cache triggers one rebuild and a re-emit inside the same invocation,
so a tunnel coming up is classified on the next poll rather than up to a minute
later. Overridable for testing via `TCTL_IFROLE_CACHE`, `TCTL_IFROLE_TTL`,
`TCTL_PROC_NET_DEV` and `TCTL_SYSFS_NET`.

---

### trafficctl-ratelimit-stats.sh

Returns drop counters from the nftables rate-limiter.

**Arguments:** None

**Output:**

```json
[
  {"ip": "192.168.0.100", "mode": "shared", "rate_kbit": 5000, "packets": 1423, "bytes": 2134567},
  {"ip": "192.168.20.0/24", "mode": "each", "rate_kbit": 5000, "packets": 88, "bytes": 12000}
]
```

`ip` is the limit's target, so it may be a CIDR block rather than a host, and
`mode` is the bucket layout (`each`/`shared`) read back from the live rule — an
nft meter keyed on the address is what makes a bucket per-device.

One entry per target: the download rule is installed on every LAN device's
egress chain, so a router with several bridges holds several copies of the same
limit, and their counters are summed here. Only the copy on the device the
target sits behind ever matches.

Returns `[]` if no rate limits are active.

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
{"ok":true,"ipv6":true,"msg":"internet blocked for 192.168.0.100"}
{"ok":true,"ipv6":false,"msg":"internet blocked for 10.0.5.20 — IPv4 only: no MAC known for 10.0.5.20 (no DHCP lease, no neighbour entry), so IPv6 is not covered"}
```

`ipv6` says whether the IPv6 half of the block is live. It is `false` only when
no MAC can be keyed on — see [Address family coverage](#address-family-coverage-ipv6);
`msg` names the reason, and LuCI and the Telegram bot both surface it.

**Side effects (block):**
- Inserts a drop rule matching `ip saddr` in `inet fw4 forward` (nft) or the
  `FORWARD` chain (iptables).
- Inserts a second drop rule matching `meta nfproto ipv6 ether saddr <mac>`
  (nft only), when the device has a resolvable MAC and is not a routed next
  hop. `insert`, not `add`: fw4's forward chain accepts established and
  offloaded flows near the top, and a rule below that never fires.
- Kills existing conntrack entries for the device — IPv4 by address, and IPv6
  for every address the neighbour table currently maps to that MAC
  (`conntrack -D -f ipv6`). Without the second pass an established v6 flow
  survives the block, and under flow offload it is never re-evaluated against
  the new rule at all.

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

**Mechanism.** Two chains in its **own** table, loaded as one atomic `nft -f`
transaction:

```
table inet tctl_cut {
    chain cut_prerouting {
        type filter hook prerouting priority -300; policy accept;
        fib daddr type { local, broadcast, multicast } accept
        ip6 daddr fe80::/10 accept
        iifname != { "br-lan", … } accept
        fib daddr . iif oifname { "br-lan", … } accept
        counter drop comment "tctl_cut"
    }
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
- **Prerouting is the primary hook, not `forward`.** A forward rule only sees
  traffic the router *forwards*. On a router running a transparent proxy —
  podkop/sing-box, passwall, homeproxy — TPROXY intercepts at prerouting and
  delivers the packet **locally**; the proxy then originates its own outbound
  connections. Neither leg is forwarded (client→router is `input`,
  router→internet is `output`), so a forward-only cut misses all of it while
  reporting success. Priority **−300** (`raw`) is ahead of conntrack (−200),
  `mangle` (−150) and `dstnat` (−100), where those proxies hook. The forward
  chain at −190 is kept as a second layer; it is after DNAT and before fw4's
  flowtable rule at filter priority 0, so an offloaded flow cannot bypass it.
- **The router's own traffic is never touched** — locally-originated packets go
  `output`→`postrouting` and do not traverse prerouting. The proxy's outbound
  path, the router's VPN tunnels and its DNS all keep working.
- **Rule order is a safety property.** `fib daddr type local` is first, before
  anything that depends on the LAN device list being correct: whatever else is
  wrong, LuCI, SSH, DNS, DHCP and a VPN terminating *on* the router are
  accepted. A prerouting drop without that escape hatch would be a total LAN
  lockout, which is also why the install is atomic (see below).
- **Interface matching, not addresses.** IPv4 *and* IPv6 are cut by the same
  rules — an address-keyed cut would let a device walk out over a SLAAC
  address. (The per-device block reaches the same end differently: a second
  rule keyed on the client's MAC. Neither can be keyed on a v6 address,
  because those rotate.) LAN↔LAN, VLAN
  ↔VLAN and downstream routed subnets all resolve to a LAN device and are
  spared; same-subnet traffic is bridged and reaches neither hook. At
  prerouting there is no `oifname` yet, so the same question is put to the FIB:
  `fib daddr . iif oifname` is the interface the packet would leave by.
- **Atomic install.** The ruleset is applied with a single `nft -f`. Adding the
  rules one at a time would, on a kernel without `nft_fib`, apply the accepts
  that parse *and* the final drop — black-holing the LAN. All-or-nothing means
  such a kernel gets nothing, and the fallback below is taken deliberately.
- **Coverage and the fallback.** `status` reports `coverage`: `full` once the
  prerouting chain is in place, `forward` when only the forward chain could be
  installed (no `nft_fib`). `forward` is correct on a plain router and the UI
  says so explicitly — but if a transparent proxy is detected in the ruleset
  (`tproxy`), `engage` **refuses** rather than installing a cut that would miss
  the traffic it claims to stop.
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

Set or remove a rate limit (policer, both directions).

**Arguments:** `<target> <rate_kbit> [label] [each|shared]`

Rate of `0` removes the limit.

`target` is a host (`10.0.20.122`), a **CIDR block** (`10.0.20.0/24`), or `all`
(every address, equivalent to `0.0.0.0/0`).

`mode` decides how many buckets the block gets, and the two readings of
"5 Mbit for the IoT VLAN" are easy to swap:

| Mode | Meaning |
|------|---------|
| `each` | every address inside the target gets its **own** bucket — "5 Mbit **each**" |
| `shared` | the whole target shares **one** bucket — "5 Mbit **between them**", an aggregate cap |

The default is `each` for a block wider than `/32` and `shared` for a single
host (where the two are identical). `each` is the default deliberately: one
device cannot then starve the rest of a subnet. An aggregate VLAN cap — the
usual reason to limit a subnet at all — must ask for `shared` explicitly.

```sh
# 20 Mbit shared by the whole IoT VLAN
trafficctl-ratelimit.sh 192.168.20.0/24 20000 "iot-cap" shared
# 5 Mbit for each device on the guest VLAN
trafficctl-ratelimit.sh 10.0.0.0/24 5000 "guest-cap" each
# remove (mode is irrelevant when removing)
trafficctl-ratelimit.sh 192.168.20.0/24 0 "iot-cap"
```

**Output:**
```json
{"ok": true, "msg": "rate limit 5000 kbit/s for 192.168.0.100 (both directions, shared)"}
```

**Two constraints worth knowing before relying on a subnet limit:**

- **The subnet has to be one this router monitors.** The policing hooks are
  attached to the devices that `tctl_lan_subnets` resolves, which skips
  `wan`/`wan6` and any zone other than `lan` with `masq=1`. A guest VLAN
  isolated with `masq 1` is therefore not covered: the rule is accepted and
  never matches a packet. `trafficctl-subnets.sh` lists what is covered, and
  the dashboard warns when a target falls outside it.
- **`shared` needs nftables.** On the iptables fallback the policer is
  `hashlimit --hashlimit-mode dstip`, which is per-address whatever mode was
  asked for; `trafficctl-ratelimit-stats.sh` reports `each` there for that
  reason.

**Persistence:** with `persist_rules` on, the target, rate **and mode** are
written to `/etc/trafficctl/rules.json` and restored on `ifup lan`. Records
written before the mode was stored fall back to the same default the CLI would
have picked for that target.

---

### trafficctl-subnets.sh

Lists the subnets a limit can actually be enforced on: directly connected LANs,
plus subnets routed via a LAN next-hop and any `trafficctl.main.extra_subnets`.
Backs the dashboard's target picker and its "this subnet is not monitored"
warning.

**Arguments:** None

**Output:**

```json
[
  {"cidr": "192.168.1.0/24", "device": "br-lan", "kind": "lan"},
  {"cidr": "10.0.5.0/24", "device": "br-lan", "kind": "routed"}
]
```

`kind` is `lan` for a directly connected subnet and `routed` for one reached
through a next-hop. A zone excluded from monitoring (see above) appears in
neither.

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
{"ok":true,"enforcement":"acl","msg":"MAC 06:2b:92:a8:bd:8c blocked on wifi for 192.168.1.50"}
```

A WiFi block has two halves: the uci `maclist`, which survives a reboot, and
hostapd's running ACL, which decides whether the device is on the air right
now. `enforcement` reports how far the runtime half actually got, and `ok` is
true only when the operator's intent is in force:

| `enforcement` | `ok` | Meaning |
|---------------|------|---------|
| `acl` | `true` | The running ACL was changed, and the change was read back from hostapd. |
| `no-radio` | `true` | ubus answered and no AP is running, so there is nothing to program; the `maclist` applies when wifi next starts. |
| `ban` | `false` | No usable `hostapd_cli`, so hostapd's ubus `del_client` deauthenticated and banned the client instead. That ban **expires by itself** (one hour) and is not an ACL entry. |
| `none` | `false` | Nothing could be applied or verified on the running radio. The `maclist` is written and takes effect at the next wifi restart; until then the device stays online. |

`msg` always names the remedy for the `ban` and `none` cases (install
`hostapd-utils`, or restart wifi -- which disconnects every client on the
radio, so it is never done automatically).

**Side effects:**
- Sets `macfilter=deny` on all wifi-iface sections that have no policy yet; an existing `allow` (whitelist) policy is respected, and blocking there means dropping the MAC from the accept list.
- Adds/removes MAC from `maclist`.
- Applies at runtime via `hostapd_cli deny_acl`/`accept_acl` + `deauthenticate` (no wifi reload -- only the target client is affected), then reads the ACL back with `deny_acl SHOW` / `accept_acl SHOW` to confirm. An exit status of 0 is not treated as proof.
- Runs the runtime half **unconditionally**, even when uci already listed the MAC, so that a block which was previously only written to config can be repaired by repeating the action.
- Where `hostapd_cli` is unavailable, falls back to `ubus call hostapd.<iface> del_client` with `ban_time`, confirmed via `list_bans`. hostapd's ubus object exposes no ACL method, so this is a timed ban, never a substitute for the durable `maclist` entry.

**Requires:** `hostapd-utils` (declared in `LUCI_DEPENDS`). Without it only the
degraded `ban` path is available and every block reports `ok:false`.

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
