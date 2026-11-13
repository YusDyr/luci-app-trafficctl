# API Reference

All backend functionality is exposed through the `/usr/sbin/trafficctl` CLI and the shell scripts in `/usr/libexec/trafficctl/trafficctl-*.sh` it runs for the commands not yet ported to ucode. The LuCI frontend calls them via JSON-RPC through the rpcd plugin at `/usr/libexec/rpcd/luci.trafficctl`, an exec plugin written in ucode: it handles the settings, their validation, the activity log and the device names itself, and runs `trafficctl <command>` for everything else, with every argument quoted and the caller (`TCTL_VIA`, `TCTL_SRC`, `TCTL_USER`) in the environment.

---

## Common Conventions

- **Input validation**: scripts that take an address validate it with regex + octet range (0–255, no leading zeros: `010.0.0.1` is refused) via `tctl_validate_ip`; `tctl_validate_target` additionally accepts a CIDR (prefix length without a leading zero) or `all`.
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
| `ratelimit` — download | ✅ | ✅ | `ip daddr` **+** `meta protocol ip6 ip6 daddr @tctl_v6_<slug>`, a set fed by `ether saddr <mac>` at LAN ingress |
| `shape_add` (tc/HTB) | ✅ | ❌ | `u32 match ip src`/`dst`; the `mirred` redirect into the IFB is itself `protocol ip` |
| `portfw` pause/limit | ✅ | ❌ | `ip daddr` |
| `bytes`, `totals`, `summary`, metrics | ✅ | ❌ | conntrack rows parsed as IPv4 |

**Why MAC and not `ip6 saddr`.** A client's IPv6 addresses are not stable:
SLAAC with privacy extensions gives it several at once and rotates them on a
timer. A rule written against one stops matching when it rotates, silently —
the same bypass as having no rule, reached more slowly. A MAC does not rotate.

**Where a MAC is not usable.**

- **Download** is not matched on the MAC directly. On the LAN egress hook the
  outgoing L2 header does not exist yet — the destination MAC a packet carries
  there is the previous hop's — so `ether daddr` is not the client. It is
  matched on the client's addresses, `ip6 daddr @tctl_v6_<slug>`, and the set
  is filled by the data path rather than from a neighbour-table snapshot: at LAN
  ingress, where the frame is still the client's own, the `_v6` rule
  `meta protocol ip6 ether saddr <mac> ip6 saddr != fe80::/10 update
  @tctl_v6_<slug> { ip6 saddr }` adds each source address with a one-hour
  timeout (`flags dynamic,timeout`) that every packet renews. A rotated privacy
  address is in the set from its first packet and the old one ages out, so the
  set cannot go stale. Not covered: download that no packet from the client ever
  preceded (unsolicited inbound), which for TCP does not exist. The feed rule
  sits before the upload policer, so a packet that policer drops still renews
  its address. If the set cannot be created, neither rule is installed and the
  reply says so.
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

**The IPv6 scope expression differs by family.** The block lives in `inet fw4
forward` and uses `meta nfproto ipv6`. The limiter's chains are in the **netdev**
family, where nft rejects that outright — *"meta nfproto is only useful in the
inet family"* — so those rules use `meta protocol ip6`. Same intent; using the
wrong one does not under-match quietly, the rule fails to load. Scoping at all
is required: an unscoped `ether saddr` rule would match a dual-stack client's
IPv4 as well and police it twice, halving the ceiling it was given.

**Comment suffixes.** The v6 rules carry no address, so their comment is the
only handle on them: `tctl_block_<slug>_mac` for a block, and
`rl_ratelimit_<slug>_ul6` (upload), `_dl6` (download) and `_v6` (the set feed)
for a limit. The set `tctl_v6_<slug>` is deleted after those rules, since nft
refuses to delete a set that a rule still references. Removal matches comments **in
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

"Script" is what `trafficctl <command>` runs; "(in plugin)" methods run inside the plugin.

| Method | Script | Params | ACL |
|--------|--------|--------|-----|
| `summary` | `trafficctl summary` (ucode) | (none) | read |
| `device` | `trafficctl device` (ucode) | `ip`, `proto` | read |
| `bytes` | `trafficctl-totals.sh` | (none) | read |
| `ifaces` | `trafficctl ifaces` (ucode) | (none) | read |
| `rdns` | `trafficctl rdns` (ucode) | `ip` | read |
| `ratelimit_stats` | `trafficctl ratelimit-stats` (ucode) | (none) | read |
| `subnets` | `trafficctl subnets` (ucode) | (none) | read |
| `shape_stats` | `trafficctl shape-stats` (ucode) | (none) | read |
| `shape_status` | `trafficctl-shape.sh status` | `ip` | read |
| `names_list` | (in plugin) | (none) | read |
| `portfw_list` | `trafficctl-portfw.sh list` | (none) | read |
| `rules_list` | `trafficctl rules list` (ucode) | (none) | read |
| `netify_status` | `trafficctl netify status` (ucode) | (none) | read |
| `netify_list` | `trafficctl netify list` (ucode) | (none) | read |
| `config_get` | (in plugin) | (none) — returns `enabled`, `default_mode`, `offload_mode`, `sw`, `hw`, `poll_interval`, `avg_window` | read |
| `telegram_config_get` | (in plugin) | (none) — `bot_token` is masked as `***`; `bot_running` comes from procd (`ubus call service list`) | read |
| `logging_config_get` | (in plugin) | (none) | read |
| `newdevice_config_get` | (in plugin) | (none) — returns `enabled`, `limit_kbit`, `limit_mode`, plus `seeded` and `seen_count` describing the seen-MAC ledger | read |
| `version` | (in plugin) | (none) — the installed `luci-app-trafficctl` version, read from the opkg status file or the apk database; `dev` when neither lists it | read |
| `cut_status` | `trafficctl-cut.sh status` | (none) | **write** — see below |
| `cut_set` | `trafficctl-cut.sh engage`/`release` | `active` (bool), `duration` (seconds, `0` = indefinite), `persist` (bool) | write |
| `block` | `trafficctl-block.sh` | `ip`, `label` | write |
| `unblock` | `trafficctl-unblock.sh` | `ip`, `label` | write |
| `ratelimit` | `trafficctl-ratelimit.sh` | `ip` (host, CIDR or `all`), `rate_kbit`, `label`, `mode` (`each`\|`shared`) | write |
| `shape_add` | `trafficctl-shape.sh add` | `ip`, `rate_kbit`, `label` | write |
| `shape_remove` | `trafficctl-shape.sh remove` | `ip`, `label` | write |
| `macfilter_add` | `trafficctl-macfilter-add.sh` | `ip` | write |
| `macfilter_remove` | `trafficctl-macfilter-remove.sh` | `ip` or `mac` (`mac` wins when both are sent) | write |
| `name_set` | (in plugin) | `ip`, `name` (empty `name` clears the alias) | write |
| `name_clear` | (in plugin) | `ip` | write |
| `portfw_ctl` | `trafficctl-portfw.sh` | `action`, `scope`, `proto`, `ip`, `port`, `rate_kbit` | write |
| `netify_collect` | `trafficctl netify collect` (ucode) | `secs` (1–30, default 3) | write |
| `config_set` | (in plugin) | `enabled`, `default_mode`, `sw`, `hw`, `poll_interval`, `avg_window` (all optional) | write |
| `telegram_config_set` | (in plugin) | `enabled`, `bot_token`, `chat_id`, `poll_interval`, `notify_new_device`, `notify_known_device`, `control_enabled`, `notify_template`, `btn_block_inet`, `btn_block_wifi`, `btn_limiter`, `btn_shaper` | write |
| `telegram_test` | `trafficctl telegram-test` (ucode) | `bot_token`, `chat_id`, `message` — the token goes to the plugin's wrapping shell on stdin, which exports it as `TCTL_TG_TOKEN` for the command; it is never in an argument list | write |
| `notify_config_get` | (in plugin) | (none) — the Notifications tab: `enabled`, `scan`, `scan_interval`, `scan_wanted`, `events`, `types`, `msmtp`, `hotplug_scripts`, `bot_token_set`, `bot_chat_id`, `senders` (secrets as `***` plus `<option>_set`) | read |
| `notify_config_set` | (in plugin) | `sender` (a type or a section name; empty = the global options), `enabled`, `events`, `scan`, `scan_interval`, and the sender's own options (see [Notifications](#notifications)) | write |
| `notify_test` | `trafficctl notify test` (ucode) | `sender` | write |
| `logging_config_set` | (in plugin) | `enabled`, `log_file`, `max_lines`, `syslog`, `log_blocks`, `log_ratelimits`, `log_shapes`, `log_telegram`, `log_config`, `persist_rules` (stored as `main.persist_rules`) | write |
| `newdevice_config_set` | (in plugin) | `enabled`, `limit_kbit`, `limit_mode` (`limiter`\|`shaper`) | write |
| `activity_log` | (in plugin) | `lines` (default 50, capped at 1000) | write |

`notify_config_set` runs `trafficctl notify migrate` first, validates every
value before it writes any, refuses to switch on a sender that lacks what it
needs (`telegram needs a bot token and a chat id`, `mail needs msmtp`, ...),
then commits, enables `/etc/init.d/trafficctl-notify` and restarts it. Since
1.31 `telegram_config_get` reads `notify_new_device`, `notify_known_device` and
`notify_template` back from the `notify_telegram` sender once it exists, and
`telegram_config_set` writes them there.

`telegram_config_set` keeps `/etc/init.d/trafficctl-telegram` enabled in rc.d
while `telegram.enabled` is 1 and disabled while it is 0, then reloads the bot.
Boot starts only what rc.d enables, so a reload alone left a bot switched on
from the UI running until the next reboot. The package postinst applies the same
rule on install and upgrade, for the bot and for `history.enabled`.

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

`port` accepts a single port or a `lo-hi` range.

`history_config_set` takes a `dir` below `/etc/trafficctl`, `/mnt`, `/media`,
`/srv` or `/tmp`, at least one level down, and every component a name: no
empty, `.` or `..` component. `/mnt/.` or `/mnt//` would otherwise pass the
prefix check and make a mount root the store, whose prune deletes inside it.
The sampler's own check (`hist_validate_dir`) applies the same rule to the
stored value.

**Failures.** A setter whose commit fails (a read-only or full overlay)
replies `{"ok":false,"msg":"could not save the trafficctl settings"}` (or
`firewall`), logs nothing and leaves nothing staged in `/tmp/.uci`; `cut_set`
then engages nothing. A delegated command still running after 60 s is killed
and the reply is `{"ok":false,"msg":"trafficctl <command> did not finish within
60 s"}`; rpcd itself gives an exec plugin 120 s. Only the CLI process is
killed: on 22.03 nothing can give it a process group of its own (busybox has
no `setsid`, ash no job control without a terminal), so what it started runs
to its end. A method that answers `{"result": ...}` keeps that key on an error
(`{"result":null,"ok":false,"msg":...}`), an internal one included.

The plugin reads the whole of its stdin: rpcd writes the arguments and closes
the pipe (checked against rpcd on 22.03 by `tests/test_install.sh`). It asks
rpcd's session for the login name, for the activity log, only on the `write`
methods; the `read` methods are the dashboard's polls.

---

## Query Scripts

`trafficctl-subnets.sh`, `trafficctl-names.sh`, `trafficctl-rdns.sh`,
`trafficctl-rdns-refresh.sh`, `trafficctl-ifaces.sh`, `trafficctl-bytes.sh`,
`trafficctl-totals.sh`, `trafficctl-ratelimit-stats.sh`,
`trafficctl-shape-stats.sh`, `trafficctl-rules.sh`, `trafficctl-summary.sh`,
`trafficctl-device.sh`, `trafficctl-metrics.sh` and `trafficctl-netify.sh` are
two-line wrappers for the ucode CLI: `/usr/sbin/trafficctl
subnets|names|rdns|rdns-refresh|ifaces|bytes|totals|ratelimit-stats|shape-stats|rules|summary|device|metrics|netify`
takes the same arguments and prints the same bytes (differences listed under
each command). The metrics CGI (`/www/cgi-bin/trafficctl-metrics`) checks the
token, then execs `trafficctl metrics`. `bytes-nft` and its wrapper
are gone (see `trafficctl-bytes.sh` below). The byte commands print their arrays
sorted by address, where the shell printed awk hash order.

### trafficctl-summary.sh (`trafficctl summary`)

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
    "rate_limit_kbit_up": 0,
    "shape_kbit": 10000,
    "shape_kbit_up": 2000
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
| `rate_limit_kbit` | number | Active policer rate in kbit/s (0 = not limited). The download ceiling |
| `rate_limit_kbit_up` | number | The policer's upload ceiling in kbit/s, read from its own rule. Equal to `rate_limit_kbit` for a symmetric limit, different for a split one, 0 if there is no upload rule |
| `shape_kbit` | number | Active shaper rate in kbit/s (0 = not shaped). The download class on the LAN device |
| `shape_kbit_up` | number | The shaper's upload ceiling in kbit/s: the class with the same classid on the IFB device. 0 with `shape_kbit` set means upload is not shaped (no `kmod-ifb`) |

---

### trafficctl-device.sh (`trafficctl device`)

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
  "wifi_filter": "full",
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
      "oif": "wan2",
      "oif_dev": "eth2"
    }
  ],
  "rate_limit_kbit": 0,
  "rate_limit_kbit_up": 0,
  "shape_kbit": 10000,
  "shape_kbit_up": 2000
}
```

`wifi_filter` says what a WiFi block can do on this router, router-wide:
`"full"` (hostapd_cli is installed, blocks go into the running ACL),
`"temporary"` (WiFi exists but the optional `hostapd-utils` is not installed,
so a block is a timed hostapd ban over ubus and `macfilter_add` reports
`"enforcement":"ban"`), or `"none"` (no wifi-iface in uci, e.g. a wired-only
build; `macfilter_add` answers `"no wifi interfaces found"`). The LuCI view
hides the WiFi block button for `"none"` and marks it for `"temporary"`.

Each connection's `oif` is the egress interface, resolved via
`ip route get <dst> mark <mark>` from the connection's conntrack fwmark. It is
only populated for **policy-routed** connections (a non-zero connmark, e.g.
mwan3, which restores the routing mark). For connections with mark `0` (plain
single-WAN, or policy-routing that doesn't restore the connmark such as podkop)
`oif` is empty. The LuCI connections table exposes it as an optional, hidden-by-default
"Iface" column.

`oif` is the **uci interface name** (`wan2`, `Finland`) — what the user called the
network — and `oif_dev` is the kernel device the route resolved to (`eth2`, `awg3`).
The name comes from the role map `trafficctl-ifaces.sh` memoizes in
`/tmp/trafficctl_ifroles`; a device with no uci interface gets its device name in
both fields. The table shows the device next to the name only when they differ.

---

### trafficctl-bytes.sh (`trafficctl bytes`)

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
| `bytes_tcp` | number | TCP bytes, both directions |
| `bytes_udp` | number | UDP bytes, both directions |
| `src` | string | Always `ct` (conntrack). Releases up to 1.30.x could also report `nft` |
| `degraded` | bool | `true` when these counters are **frozen** for offloaded flows — see below |

`degraded` is about *trust*; `src` is about *magnitude*. They are separate
fields because conntrack counters are continuous across a change in trust, so
folding the two together would make a trust change look like a source change
and throw away a real delta.

`degraded` is `true` when the router has **uncountered** flow offload (plain
`hardware` or `software`: fw4 on OpenWrt 22.03, or a custom flowtable declared
without `counter`). The counters then stop moving for every offloaded flow while
traffic continues, so any total built from them is a lower bound that stalls.
Consumers must refuse to present it as a total. The first such sample per
offload mode also logs a warning to syslog (tag `trafficctl`) that says to
disable flow offloading or upgrade to 23.05 or later.

The sample always comes from conntrack. With a counter-flagged flowtable (fw4
from 23.05 on, modes `software-counter` and `hardware-counter`) offloaded byte
counts are synced back to conntrack, so it stays accurate. Without the flag
nothing else can count offloaded packets: the flowtable hooks netdev ingress,
so they never reach an inet forward chain at any priority, and counting
downloads where they leave the router would need a netdev egress hook (kernel
5.16+). Releases up to 1.30.x tried nftables counter maps on a forward chain
at priority `-200` (`trafficctl bytes-nft`); no OpenWrt kernel accepted their
map type, offloaded packets would have bypassed the chain anyway, and the path
was removed.

Counters are 64-bit integers end to end: a value past 2^53 comes out exact.

`-1` in a protocol field means "not measurable", never "zero". A consumer that
renders it as 0 is claiming the device sent no TCP at all. A sample from
conntrack always has the split; `-1` comes from `totals` (below).

---

### trafficctl-totals.sh (`trafficctl totals`)

Wraps `trafficctl bytes` with a **monotonic per-device accumulator** — the
lifetime totals behind both the LuCI Bytes / TCP / UDP columns and the
`trafficctl_device_bytes_total` metric. Neither raw source is a lifetime total:
conntrack reports only flows that still exist (so a device's number collapses
when they expire — [#26](https://github.com/YusDyr/luci-app-trafficctl/issues/26)).

**Arguments:** `--all` (optional) — also emit devices that have left the sample
but still carry a total. Used by the exporter so a Prometheus series does not
vanish and reappear every time an idle device's last flow expires.

**Output:** the `trafficctl bytes` array, extended per element:

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
| `bytes_tcp_total` | number | Lifetime TCP bytes, or `-1` without a protocol baseline (a state line from before the split, or from 1.30.x on its nft maps) |
| `bytes_udp_total` | number | Lifetime UDP bytes, or `-1` likewise |
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
- **A source switch rebaselines.** The source is stored per device and a
  change starts a fresh baseline. The sampler only reads conntrack now, but a
  state file written by 1.30.x can record `nft` (counter maps, cumulative since
  their table was built, a magnitude unrelated to conntrack): the first sample
  after the upgrade rebaselines that device instead of adding the difference.
- **Totals reset on reboot.** The store is `/tmp/trafficctl_totals.state`, i.e.
  tmpfs. Deliberate: it is rewritten on every LuCI poll (2–10 s) and every
  scrape, and that write volume into flash would wear the router out. Surviving
  a reboot would mean a much coarser periodic flush into `/etc/trafficctl`
  (kept across sysupgrade by `lib/upgrade/keep.d`).
- **Totals advance only while something samples.** The LuCI page polling, or a
  Prometheus scrape, is what drives accumulation. With the page closed and no
  scraper configured, the counters stand still. There is no background tick.
- **Concurrent samplers are serialised** with an atomic `mkdir` lock, so a LuCI
  poll and a scrape landing together cannot discard one another's delta. The
  lock is `/tmp/trafficctl_totals.lock.d`, an empty directory, as the 1.30.x
  shell writer held it: either writer takes it over from the other after about
  3 s, so an upgrade or a downgrade with a sampler running loses nothing. A
  holder that does not let go is waited for about 3 s; then the sample is
  accumulated anyway. The lock is released on an error inside the locked
  section too.
- **A failed sample is an empty one**, as the shell's empty pipe was: nothing
  is accumulated, and `totals --all` still lists every stored device with
  `live: false`, so no Prometheus series vanishes for that scrape.
- **The store format is the shell's**, one line per device:
  `ip rx_acc tx_acc rx_last tx_last seen tcp_acc udp_acc tcp_last udp_last src
  since degraded`. Lines of 5, 6, 10 and 12 fields from older versions load
  too, and 1.30.x reads what this one writes.
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

`trafficctl ratelimit-stats`. Returns drop counters from the nftables
rate-limiter.

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
nft meter keyed on the address is what makes a bucket per-device. The rules are
read from `nft -j list table netdev tm_ratelimit`; of the expressions only
matches, limits, meters, counters and the verdict are read, so the meter's
name does not matter (`tctl_m_<slug>_<chain>` since 1.30.5, one per target
before). nftables 1.1 (OpenWrt 25.12) lists a meter as a named set the rule
adds to; the v1.30.0 shell reader looked for the word `meter` and reported
those limits as `shared`, the CLI reports `each`. `pass_packets`/`pass_bytes`
are always 0, as before.

One entry per target: the download rule is installed on every LAN device's
egress chain, so a router with several bridges holds several copies of the same
limit, and their counters are summed here. Only the copy on the device the
target sits behind ever matches.

Returns `[]` if no rate limits are active.

---

### trafficctl-shape-stats.sh

`trafficctl shape-stats`. Returns tc/HTB class statistics for all shaped
devices, read from the text of `tc -s class show` and `tc -s qdisc show` (one
call each) on the LAN device: iproute2 5.15 (OpenWrt 22.03) prints `tc -j
class` as text, and its JSON qdisc stats give the fq_codel target in kernel
microseconds (4999 for `5ms`). Classes are mapped to addresses through
`shapes.json`, parsed as JSON. The shell reader printed a class listed before
the root or default class twice; the CLI prints it once.

**Arguments:** None

**Output:**

```json
[
  {"ip": "192.168.0.111", "rate_kbit": 10000, "bytes": 45678901, "packets": 32456, "backlog": 4096}
]
```

Returns `[]` if tc is not installed or no HTB qdisc exists. All 15 fields:
`ip`, `rate_kbit`, `bytes`, `packets`, `backlog`, `drops`, `overlimits`,
`requeues`, `lended`, `borrowed`, `ecn_mark`, `new_flows`, `old_flows`
(always 0: iproute2 prints `new_flows_len`), `target_us`, `memory_used`.

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

### trafficctl-rules.sh

`trafficctl rules [list]`. Every restriction the app holds, whether or not the device is online: internet
blocks, speed limits (subnets and `all` included), shapes and WiFi deny-list
entries. This feeds the **Rules** tab. The device table is built from live
conntrack entries, so a device that goes offline drops out of it while its
restrictions keep applying.

**Arguments:** `list` (the default)

**Output:**

```json
{"fw":"nft","persist_rules":true,"wifi_allow_ifaces":0,"rules":[
  {"type":"block","target":"192.168.1.50","ip":"192.168.1.50","mac":"aa:aa:aa:aa:aa:50","name":"kid-tablet","online":false,"applied":true,"persisted":true},
  {"type":"ratelimit","target":"10.0.20.0/24","ip":"","mac":"","name":"","online":null,"applied":true,"persisted":false,"rate_kbit":2000,"rate_kbit_up":2000,"mode":"each"},
  {"type":"shape","target":"192.168.1.70","ip":"192.168.1.70","mac":"","name":"Console","online":false,"applied":false,"persisted":true,"rate_kbit":3000,"rate_kbit_up":3000},
  {"type":"wifi","target":"aa:aa:aa:aa:aa:99","ip":"","mac":"aa:aa:aa:aa:aa:99","name":"","online":null,"applied":false,"persisted":true,"enforcement":"none"}
]}
```

Each restriction is read from where it is enforced and from where it is saved,
and the two are merged:

| `type` | Live state | Saved state |
|--------|------------|-------------|
| `block` | drop rules in `inet fw4 forward` on an `ip saddr` whose comment starts with `tctl_block_` (`tctl_block_<slug>`, or the caller's label on a block written before v1.13.2), or whose comment is exactly `tctl_block_<slug>_mac` (the IPv6 rule, folded into the same record) | `rules.json`, only while `persist_rules` is on |
| `ratelimit` | `ratelimit-stats` (download) and the `ip saddr` rule (upload) | `rules.json`, only while `persist_rules` is on |
| `shape` | HTB classes on the LAN device and on `tctl-ifb0`, mapped through `shapes.json` | `shapes.json` (always written) |
| `wifi` | hostapd's running deny ACL, or a ubus ban | uci `maclist` of `macfilter=deny` interfaces |

- The nft rules are read from `nft -j`. A rule's handle is carried along, not
  matched on. An each-mode limit reads `each` on nftables 1.1 as well (see
  `ratelimit-stats`).
- Unblocking a block written before v1.13.2 (`tctl_block_tg` from Telegram,
  `tctl_block_block_<ip>` or a typed label from LuCI) works with any label,
  the empty one the Rules tab sends included: `trafficctl-unblock.sh` also
  removes every drop rule on that exact `ip saddr` whose comment starts with
  `tctl_block_`.
- `applied`: in the kernel or on the radio now. `persisted`: survives a reboot.
  A saved record that is not applied is restored at the next `ifup lan`; a live
  rule that is not saved is lost at the next reboot. Live rates win over saved ones.
- With `persist_rules` off the restore hook ignores `rules.json`, so its records
  are not listed: they restrict nothing.
- `online` is `null` for a CIDR target and for a WiFi entry with no known address. Otherwise it is true when the address
  has a conntrack entry or a REACHABLE/DELAY/PROBE/PERMANENT neighbour entry.
- `name` follows the usual order: alias, DHCP lease, cached PTR.
- `wifi` records are keyed on the MAC, and `enforcement` uses the words of
  `trafficctl-macfilter-add.sh` (below), plus `unknown` when the radio state
  cannot be read. `applied` is `null` then.
- A radio with `macfilter=allow` blocks every device missing from its list, which
  cannot be enumerated: only their number is reported, in `wifi_allow_ifaces`.
- Port-forward pauses (own tab) and the global cut (own control) are not listed.

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
- Inserts a drop rule matching `ip saddr` in `inet fw4 forward`.
- Inserts a second drop rule matching `meta nfproto ipv6 ether saddr <mac>`
  when the device has a resolvable MAC and is not a routed next hop. `insert`,
  not `add`: fw4's forward chain accepts established and offloaded flows near
  the top, and a rule below that never fires.
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
absent from `trafficctl/files/lib/upgrade/keep.d/trafficctl`: a cut outliving a *firmware upgrade* is
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

**Partial results are kept and reported.** The download rule goes on the
egress chain of every LAN device (`dl_<dev>`) and the upload rule on the
ingress chain of every bridge port (`ul_<port>`). A device that refuses its
rule (a port hostapd is re-creating during the boot restore, say) does not
take the others down with it: the rules that went in stay, the failure is
logged with the device and nft's reason, and the result says which devices
the limit misses. `partial` is `true` whenever some device is missing a rule;
the `ipv6_*` flags and the IPv6 note describe the v6 rules that are actually
loaded:

```json
{"ok": true, "partial": true, "ipv6_upload": false, "ipv6_download": false, "nss": "none", "persist": true, "msg": "rate limit 5000 kbit/s for 10.0.20.0/24 (both directions, each) — PARTIAL: upload rule failed on lan2: Operation not supported [IPv4 only]"}
```

When a direction went in on no device at all, the message says `UPLOAD ONLY`
or `DOWNLOAD ONLY` with the reason. `ok` is `false` only if nothing went in, in
either direction. Applying the limit again (or the next `ifup lan`) replaces
the rules and fills the missing device in. The restore hook logs
`Restored ratelimit for <target> (<rate>kbit) PARTIALLY: ...` for a partial
restore and `Failed to restore ratelimit ...` when nothing went in.

**Meters are per chain.** In `each` mode every chain gets its own meter,
`tctl_m_<target slug>_<chain>` (`tctl_m_10_0_20_0_24_ul_lan1`). Releases up to
1.30.4 used one name per target in every chain: nftables 1.0 (OpenWrt 22.03)
binds a meter to the one rule that declares it and refused the second port's
rule with `Could not process rule: Resource busy`, so clients on `lan2` and
later uploaded unlimited while the limit was reported as applied. nftables 1.1
turns a meter into a named set that outlives its rules; removing a limit now
deletes the meters its rules used, including those old per-target names, so a
new rate does not meet the buckets of the old one.

**Persistence:** with `persist_rules` on, the target, rate **and mode** are
written to `/etc/trafficctl/rules.json` and restored on `ifup lan`. Records
written before the mode was stored fall back to the same default the CLI would
have picked for that target. A restore that finds the limit already in the
kernel (an `ifup` without a reboot) replaces it rather than adding a copy; it
looks for the target's exact comments, so restoring `192.168.1.1` leaves the
limit on `192.168.1.10` alone.

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

**Arguments:** `<ip>`; the remove script also takes `<mac>`. A device that has
been offline long enough has no lease or neighbour entry left to find its MAC
by, and the deny list is keyed on the MAC.

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

## Notifications

`trafficctl.notify` (`/usr/share/ucode/trafficctl/notify.uc`) turns what
happens on the router into events, and hands each event to three consumers:

1. **ubus**: event `trafficctl.notify` with `{ "event", "time", ...fields }`,
   always (`ubus listen trafficctl.notify`).
2. **hotplug**: every script in `/etc/hotplug.d/trafficctl/` through
   `hotplug-call trafficctl`, with `ACTION=<event>`, `TIME=<epoch>` and each
   field upper-cased (`IP`, `MAC`, `RATE_KBIT`, ...), always.
3. **senders**: each enabled sender subscribed to the event, unless
   `notify.enabled` is `0` (that switch silences the senders only).

Steps 2 and 3 run in a detached `trafficctl notify dispatch`: the command that
caused the event never waits on the network.

| Event | Emitted by | Fields |
|-------|------------|--------|
| `new_device` | the device scan, the DHCP hotplug | `mac`, `ip`, `name`, `link` |
| `known_device` | the device scan (a known MAC back online) | `mac`, `ip`, `name`, `link` |
| `limit_applied` | `trafficctl-ratelimit.sh`, `trafficctl-shape.sh add` | `ip`, `rate_kbit`, `rate_kbit_up`, `mode` (`limiter`\|`shaper`) |
| `block_applied` | `trafficctl-block.sh`, `trafficctl-macfilter-add.sh` | `ip`, `mac`, `kind` (`internet`\|`wifi`) |
| `cut_engaged` | `trafficctl-cut.sh engage` | `duration` (seconds left, `0` = indefinite), `persist` |

Every event also carries `via` (`luci`, `telegram`, `cli`) and `src` (the
caller's address or `local`). Unknown fields are dropped, and so is a text
field with a control character or over 256 bytes, or a number field that is
not a number.

### Senders

One uci section per sender, of type `notify_<type>`, each with `enabled` and
`list events` (unset: every event):

```
config notify 'notify'
	option enabled '1'          # 0: senders off; ubus and hotplug still get every event
	option scan 'auto'          # 1, 0, or auto: only when something wants new_device/known_device
	option scan_interval '30'   # seconds, 0 or 10..86400

config notify_telegram 'notify_telegram'
	option enabled '1'
	list events 'new_device'
	option template ''          # new_device message, {{ name }} {{ ip }} ... ; empty = built-in
	# bot_token, chat_id: optional, default to the bot's (trafficctl.telegram)

config notify_ntfy 'notify_ntfy'
	option server 'https://ntfy.sh'
	option topic 'my-router'
	option token ''             # optional access token
	option priority '3'         # 1..5

config notify_webhook 'notify_webhook'
	option url 'https://example.com/hook'
	option auth ''              # optional Authorization header value

config notify_mail 'notify_mail'
	list to 'me@example.com'
	option from ''
	option account ''           # msmtp account, needs msmtp and /etc/msmtprc
```

- **telegram**: `sendMessage` with HTML; values are HTML-escaped. Sends only:
  the bot is a separate service.
- **ntfy**: a JSON publish (`topic`, `title`, `message`, `priority`, `tags`).
- **webhook**: a JSON POST of `event`, `time`, `router`, `title`, `text` and the
  event's fields; any 2xx is success.
- **mail**: a plain-text message through `msmtp`.

Tokens and URLs go to curl as a config file on stdin, never in an argument
list (`ps` shows argv to every local user).

### The device scan

`new_device` and `known_device` come from a scan of the neighbour table, the
DHCP leases and the WiFi station lists every `scan_interval` seconds, run by
`/etc/init.d/trafficctl-notify` (`trafficctl notify watch`). The service starts
only when `trafficctl notify wanted` says something listens: `scan '1'`, or
`auto` with a sender taking either event, or a hotplug script. The DHCP hotplug
(`/etc/hotplug.d/dhcp/99-trafficctl-newdevice`) reports a new lease at once
through `trafficctl notify dhcp`. The scan keeps the bot's state files:
`/etc/trafficctl/telegram_known.json` (the known-device ledger; a missing or
empty one is seeded from what is on the network, so switching notifications on
does not report the whole LAN) and `/tmp/trafficctl_tg_online`.

### CLI

```
trafficctl notify emit <event> [key=value...]      # ubus now, the rest in the background
trafficctl notify dispatch <event> [key=value...]  # hotplug and senders now: [{sender,type,ok,msg}]
trafficctl notify scan                             # one scan pass: {ok,new,online,devices}
trafficctl notify watch                            # scan forever (the service)
trafficctl notify wanted                           # exit 0 when the scan is needed
trafficctl notify dhcp <mac> [ip] [name]           # new_device for an unknown MAC
trafficctl notify migrate                          # the bot's old options to notify_telegram
trafficctl notify test <sender>                    # a test message through one sender
```

Shell scripts emit through `tctl_notify <event> key=value...`
(`trafficctl-fw.sh`), which adds `via` and `src`; ucode callers use
`notify.emit(ev, fields)`.

### Migration

Up to 1.30 the bot's section held `notify_new_device`, `notify_known_device`
and `notify_template`. `trafficctl notify migrate` (run by the postinst and by
`/etc/uci-defaults/80_trafficctl-notify`, and by `notify_config_set`) creates
the `notify` section once and, when there is no `notify_telegram` yet, moves
those options into one: the events that were on, `enabled` as the bot's
`enabled` (off when no event was on), the template. It removes the old
options. Until it has run, the old options act as a Telegram sender, so
notifications keep working mid-upgrade.

---

## Telegram Bot

### trafficctl telegram (package `trafficctl-telegram`)

```
trafficctl telegram
```

Bot daemon using Telegram long polling, in ucode (`trafficctl.telegram`,
`/usr/share/ucode/trafficctl/telegram.uc`). It is its own process,
`/usr/libexec/trafficctl/trafficctl-telegram.uc`, which imports only `lib` and
the bot, so the resident bot does not load the CLI's other modules; procd runs
that file (`/etc/init.d/trafficctl-telegram`), and `trafficctl telegram` and
`trafficctl-telegram.sh` run it too. Without the package, `trafficctl telegram`
replies `{"ok":false,"msg":"trafficctl-telegram is not installed"}`, exit 1.

It reads `trafficctl.telegram` (`enabled`, `bot_token`, `chat_id`,
`poll_interval` in seconds, at least 2, default 3, `control_enabled`, `btn_*`) at start and every
60 s, exits 0 when `enabled` is not 1 and 1 without a token or chat id. The
token is in the request URL, which goes to curl in a config on stdin, never in
argv. The poll offset is `/tmp/trafficctl_tg_offset`; the device list is the
summary, cached 5 s in `/tmp/trafficctl_tg_devices.json`. Actions run the
CLI with `TCTL_VIA=telegram`, `TCTL_SRC=telegram:<chat_id>`,
`TCTL_USER=telegram-bot`.

**Commands:**
- `/devices` -- inline keyboard with all active devices
- `/status` -- text summary of blocked/limited devices
- `/help` -- usage

Only messages and callbacks from `chat_id` are answered.

**Callback data format:** `act:<verb>:<ip>[:<param>]`

| Callback | Action |
|----------|--------|
| `act:menu:<ip>` | Show device action buttons |
| `act:block:<ip>` | Block internet (`trafficctl block <ip> tg`) |
| `act:unblock:<ip>` | Unblock internet (`trafficctl unblock <ip> tg`) |
| `act:wblock:<ip>` | Block WiFi (`trafficctl macfilter-add <ip>`) |
| `act:wunblock:<ip>` | Unblock WiFi (`trafficctl macfilter-remove <ip>`) |
| `act:limit:<ip>:<rate>` | Apply limiter, rate in kbit/s (`trafficctl ratelimit <ip> <rate> tg`) |
| `act:unlimit:<ip>` | Remove limiter (`trafficctl ratelimit <ip> 0 tg`) |
| `act:shape:<ip>:<rate>` | Apply shaper (`trafficctl shape add <ip> <rate> tg`) |
| `act:unshape:<ip>` | Remove shaper (`trafficctl shape remove <ip>`) |
| `act:back` | Return to device list |

The address must be dotted digits and the rate digits (`invalid IP`,
`invalid param`), anything else is refused before a command is built. The
toast is the action's `msg`, cut to 196 bytes on a character boundary.

Differences from the v1.30.0 shell bot: device names are HTML-escaped (a `<`
used to break `parse_mode=HTML`) and sent with their backslashes as they are
(printf `%b` used to interpret them); the toast is cut on a UTF-8 boundary; an
empty device list gives a keyboard that is valid JSON (v1.30.0 built `[]]}`);
a garbage or empty offset file means offset 0; callback data with a control
character is refused; a summary that is not JSON reads as no devices.

**Known devices file:** `/etc/trafficctl/telegram_known.json` -- tracks MACs
for new device notifications. Since 1.31 the scan behind those notifications
is `trafficctl notify watch` (see [Notifications](#notifications)); the bot no
longer runs it, and notifications do not need the bot package.

### trafficctl-telegram-test.sh (`trafficctl telegram-test`)

```
trafficctl telegram-test <token> <chat_id> [message]
TCTL_TG_TOKEN=<token> trafficctl telegram-test - <chat_id> [message]
```

Validates token format and chat_id, sends a test message (`message` is a
template, filled with sample values). Returns `{"ok":true,"msg":"..."}`, exit 0
either way. The script is a wrapper for the ucode command. Differences from
v1.30.0: `{{ wan_ip }}` reads the WAN interface (v1.30.0's lookup was a
jsonfilter syntax error and always fell back to the route's source address),
the request body goes to curl on stdin instead of argv, and an API error text
is JSON-escaped in the reply.

---

## rpcd ACL

The ACL file at `/usr/share/rpcd/acl.d/luci-app-trafficctl.json` grants execution permissions. The rpcd backend at `/usr/libexec/rpcd/luci.trafficctl` handles method dispatch and parameter validation.
