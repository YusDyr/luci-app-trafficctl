# Architecture

This document describes the internal architecture of luci-app-trafficctl.

---

## Design Principles

1. **No daemon** -- All operations are on-demand. No background process runs when the UI is closed.
2. **No compiled code** -- Pure shell scripts and JavaScript. Runs on any architecture without compilation.
3. **Firewall agnostic** -- Automatically detects nftables or iptables at runtime. The same package works on OpenWrt 21.02 (fw3) through 23.05+ (fw4).
4. **Minimal dependencies** -- Only requires `conntrack` and `luci-base`. Traffic shaping requires `tc-full` and `kmod-sched-htb` (optional).

---

## Component Diagram

```mermaid
graph TD
    subgraph "Browser (Client)"
        JS["status.js<br/>LuCI view.extend()"]
        LS["localStorage<br/>(preferences, poll, recent devices)"]
        JS <--> LS
    end

    subgraph "Router (Server)"
        subgraph "rpcd + uhttpd"
            ACL["luci-app-trafficctl.json<br/>(ACL definitions)"]
            RPC["/usr/libexec/rpcd/luci.trafficctl<br/>(JSON-RPC dispatch)"]
        end

        subgraph "Query Scripts — /usr/local/bin/"
            SUM["trafficctl-summary.sh<br/>(all active devices)"]
            DEV["trafficctl-device.sh<br/>(per-device connections)"]
            BYT["trafficctl-bytes.sh<br/>(conntrack byte counters)"]
            BYTNFT["trafficctl-bytes-nft.sh<br/>(nft counter init helper)"]
            IFA["trafficctl-ifaces.sh<br/>(per-interface counters + role map)"]
            RLS["trafficctl-ratelimit-stats.sh<br/>(nft drop counters)"]
            SHS["trafficctl-shape-stats.sh<br/>(tc class stats)"]
            RDNS["trafficctl-rdns.sh<br/>(reverse DNS — Telegram/CLI)"]
        end

        subgraph "Action Scripts — /usr/local/bin/"
            BLK["trafficctl-block.sh"]
            UBK["trafficctl-unblock.sh"]
            RL["trafficctl-ratelimit.sh"]
            SH["trafficctl-shape.sh"]
            MFA["trafficctl-macfilter-add.sh"]
            MFR["trafficctl-macfilter-remove.sh"]
        end

        subgraph "Firewall Abstraction Layer"
            FWSH["trafficctl-fw.sh<br/>(sourced by all scripts)"]
        end

        subgraph "Kernel Subsystems"
            NFT["nftables<br/>(inet fw4 forward,<br/>netdev tm_ratelimit)"]
            IPT["iptables<br/>(mangle FORWARD)"]
            TC["tc<br/>(HTB qdisc on br-lan)"]
            CTMOD["/proc/net/nf_conntrack"]
            IW["iw + brctl<br/>(WiFi/bridge detection)"]
            HOSTAPD["hostapd_cli<br/>(WiFi deny ACL + deauth)"]
        end

        subgraph "Persistence"
            SHAPES["/etc/trafficctl/shapes.json"]
            HOTPLUG["/etc/hotplug.d/iface/<br/>99-trafficctl-shapes"]
        end
    end

    JS -->|"HTTP POST<br/>JSON-RPC"| RPC
    RPC -->|"ACL check"| ACL
    RPC --> SUM & DEV & BYT & RLS & SHS & RDNS
    RPC --> BLK & UBK & RL & SH & MFA & MFR

    SUM --> CTMOD
    SUM --> IW
    DEV --> CTMOD
    DEV --> IW
    BYT --> CTMOD

    BLK & UBK --> FWSH
    RL --> FWSH
    FWSH -->|"fw4 detected"| NFT
    FWSH -->|"fw3 detected"| IPT

    SH --> TC
    SHS --> TC

    MFA & MFR --> HOSTAPD

    SH -->|"save_shape()"| SHAPES
    HOTPLUG -->|"on ifup lan"| SH
```

---

## Data Flow

### Dashboard (All Devices View)

```mermaid
sequenceDiagram
    participant B as Browser
    participant R as rpcd
    participant S as trafficctl-summary.sh
    participant BY as trafficctl-bytes.sh

    B->>R: summary()
    R->>S: exec
    S->>S: read /proc/net/nf_conntrack
    S->>S: iw station dump (WiFi MACs)
    S->>S: brctl showmacs (bridge ports)
    S->>S: check nft/iptables block status
    S->>S: check tc class (shape status)
    S-->>B: JSON array of devices

    loop Every N seconds (poll)
        B->>R: bytes()
        R->>BY: exec
        BY->>BY: parse /proc/net/nf_conntrack
        BY-->>B: [{ip, bytes_in, bytes_out}]
        B->>B: calculate speed = delta_bytes / delta_time
    end
```

### Per-Device View

```mermaid
sequenceDiagram
    participant B as Browser
    participant R as rpcd
    participant D as trafficctl-device.sh
    participant DNS as trafficctl-rdns.sh

    B->>R: device(ip, proto)
    R->>D: exec ip proto
    D->>D: conntrack grep src=ip
    D->>D: iw station dump (conn_type)
    D->>D: brctl showmacs (port name)
    D->>D: nft/iptables check (block status)
    D->>D: tc class check (shape status)
    D-->>B: {ip, name, mac, conn_type, connections[], ...}

    opt rDNS resolution (if enabled)
        B->>R: network.rrdns.lookup(addrs[], timeout, limit)
        Note over R: rpcd-mod-rrdns resolves all IPs in one batch
        R-->>B: {ip1: "host1", ip2: "host2", ...}
    end
```

### Action Flow (Example: Apply Shaper)

```mermaid
sequenceDiagram
    participant B as Browser
    participant R as rpcd
    participant SH as trafficctl-shape.sh
    participant TC as tc kernel
    participant FS as shapes.json

    B->>R: shape_add(ip, 10000, label)
    R->>SH: exec add ip 10000 label
    SH->>TC: ensure root HTB qdisc
    SH->>TC: tc class add ... rate 10000kbit
    SH->>TC: tc qdisc add ... fq_codel
    SH->>TC: tc filter add ... match ip dst
    SH->>FS: write {ip, rate_kbit} to shapes.json
    SH-->>B: {"ok":true, "msg":"..."}

    Note over TC,FS: On reboot...
    FS->>SH: hotplug reads shapes.json
    SH->>TC: restore all tc classes
```

---

## Firewall Abstraction Layer

The file `trafficctl-fw.sh` is sourced by all scripts. It provides a unified API regardless of the firewall backend:

```sh
. /usr/local/bin/trafficctl-fw.sh

# Detection result stored in:
# TCTL_FW = "nft" | "iptables"
```

### Detection Logic

```
if command -v nft exists AND nft list tables returns results:
    TCTL_FW = "nft"
else:
    TCTL_FW = "iptables"
```

### Provided Functions

| Function | nft implementation | iptables implementation |
|----------|-------------------|------------------------|
| `tctl_ratelimit_add` | `nft add rule netdev tm_ratelimit dl ip daddr ... limit rate over ... drop` | `iptables -t mangle -A FORWARD ... -m hashlimit ... -j DROP` |
| `tctl_ratelimit_remove` | Delete rules by handle from `netdev tm_ratelimit dl` | `iptables -t mangle -D FORWARD ... -m comment --comment ...` |
| `tctl_block_add` | `nft add rule inet fw4 forward ip saddr ... drop` | `iptables -I FORWARD -s ... -j DROP` |
| `tctl_block_remove` | Delete rules by handle from `inet fw4 forward` | `iptables -D FORWARD -s ... -j DROP` (loop until gone) |
| `tctl_is_blocked` | grep nft forward chain | grep iptables FORWARD chain |
| `tctl_get_wan_device` | `uci get network.wan.device` (fallback to `.ifname`) | Same |
| `tctl_get_lan_device` | `uci get network.lan.device` (fallback to `.ifname`) | Same |
| `tctl_validate_ip` | regex + octet range check | Same |
| `tctl_get_wifi_interfaces` | `uci show wireless` parsing | Same |

---

## tc/HTB Hierarchy

Traffic shaping uses a single HTB qdisc on the LAN bridge egress (br-lan). This controls download speed to LAN devices.

```mermaid
graph TD
    ROOT["root qdisc<br/>handle 1: htb<br/>default fffe<br/>r2q 10"]

    ROOT_CLASS["class 1:1<br/>htb rate 1000mbit<br/>ceil 1000mbit<br/>(root class)"]

    DEFAULT["class 1:fffe<br/>htb rate 1000mbit<br/>prio 0<br/>(unshaped traffic)"]

    FQ_DEFAULT["qdisc fq_codel<br/>(fair queuing)"]

    DEV_A["class 1:164<br/>htb rate 10000kbit<br/>ceil 10000kbit<br/>(192.168.1.100)"]

    FQ_A["qdisc fq_codel"]

    DEV_B["class 1:165<br/>htb rate 5000kbit<br/>ceil 5000kbit<br/>(192.168.1.101)"]

    FQ_B["qdisc fq_codel"]

    FILTER_A["filter u32<br/>match ip dst 192.168.1.100/32<br/>flowid 1:164"]

    FILTER_B["filter u32<br/>match ip dst 192.168.1.101/32<br/>flowid 1:165"]

    ROOT --> ROOT_CLASS
    ROOT_CLASS --> DEFAULT
    ROOT_CLASS --> DEV_A
    ROOT_CLASS --> DEV_B
    DEFAULT --> FQ_DEFAULT
    DEV_A --> FQ_A
    DEV_B --> FQ_B
    FILTER_A -.->|"classify"| DEV_A
    FILTER_B -.->|"classify"| DEV_B
```

### Class ID Encoding

Each device gets a unique class ID derived from its IP address:

```
classid = 1:<hex(third_octet * 256 + fourth_octet)>

Example: 192.168.1.100
  third_octet  = 1
  fourth_octet = 100
  decimal      = 1 * 256 + 100 = 356
  hex          = 0x164
  classid      = 1:164
```

This means:
- No collision between devices on the same subnet.
- Supports up to 65534 devices (the full /16 range minus reserved IDs).
- Class ID `1:1` is the root class, `1:fffe` is the default (unshaped) class.

### Filter Matching

A u32 filter routes packets to the correct class:

```
tc filter add dev br-lan parent 1:0 prio 10 protocol ip u32 \
    match ip dst <IP>/32 flowid 1:<hex_id>
```

---

## Interface Detection

The system detects how each device is connected (WiFi band or LAN port):

```mermaid
graph LR
    MAC["Device MAC"]

    subgraph "WiFi check"
        IW["iw dev <iface> station dump"]
        CH["iw dev <iface> info → channel"]
        BAND["ch ≤ 14 → 2.4G<br/>ch ≤ 177 → 5G<br/>else → 6G"]
    end

    subgraph "Bridge check (fallback)"
        BRCTL["brctl showmacs br-lan"]
        SYSFS["/sys/class/net/br-lan/brif/*/port_no"]
        PORT["port_no → interface name<br/>(lan2, lan3, lan4)"]
    end

    MAC --> IW
    IW -->|"found"| CH --> BAND
    IW -->|"not found"| BRCTL --> SYSFS --> PORT
```

---

## Polling Architecture

The frontend uses independent polling loops:

| Poll | Interval | Script | Purpose |
|------|----------|--------|---------|
| Bytes | Configurable (default 2s, 1s–5s, or off) | `trafficctl-bytes.sh` | Bandwidth speed = delta bytes / delta time |
| Interfaces | Same tick as Bytes, only while the Overview panel is open | `trafficctl-ifaces.sh` | Per-interface throughput for the global overview. Deliberately has no timer of its own, so it inherits the Poll interval |
| Drops | 5s | `trafficctl-ratelimit-stats.sh` | nft policer drop counters |
| Shape stats | 5s | `trafficctl-shape-stats.sh` | tc class stats (backlog, drops, overlimits) |
| Summary | On-demand / auto-refresh (5s–60s) | `trafficctl-summary.sh` | Full device list refresh |

### Speed Calculation

Speed is calculated as `(bytes_now - bytes_prev) / dt` for both download and upload. A spike filter caps values at 1 Gbit/s (125 MB/s) to discard counter resets. The frontend maintains two histories per device:

- `_speedHistory` -- sliding window (trimmed to avgWindow/pollInterval samples) for sparkline and averaging.
- `_fullHistory` -- never trimmed, used by the popup graph to show the entire session.

### Graph Features

Two rendering contexts use the same `renderFullGraph()` function:

**Hover popup** (any sparkline): interactive SVG overlay.
**Inline device graph** (device detail view): static SVG rendered below the action buttons when a specific device is selected. Updates on every bytes poll.

Both share:
- Dual lines: download (solid blue) + upload (dashed green)
- Gradient area fill with linear gradient
- Min/max band (rolling window ±5 points)
- Rate limit line (from shapeMap or summary data)
- Nice Y-axis ticks (multiples of 100/500 Kbit/s, min 5 grid lines)
- 98th percentile scaling (outliers don't crush the graph)

The popup additionally has an interactive crosshair with precise DL/UL values.

Polling stops when:
- The browser tab is hidden (`document.hidden === true`).
- The user switches to per-device view (only device-specific polls run).
- The user sets poll to "Off".
- The user navigates away (timers cleared in `handleTeardown()`).

---

## WiFi MAC Filtering

WiFi MAC filtering does not hardcode interface names. It dynamically discovers all wifi-iface sections:

```sh
uci show wireless | grep '=wifi-iface' | cut -d= -f1
```

This returns paths like `wireless.default_radio0`, `wireless.default_radio1`, etc. The scripts then:
1. Set `macfilter=deny` on each interface (UCI).
2. Add/remove the target MAC from each interface's `maclist` (UCI).
3. `uci commit wireless` persists the change.
4. At runtime, use `hostapd_cli` to apply immediately without wifi reload:
   - **Block:** `hostapd_cli -i wlanX deny_acl ADD_MAC <mac>` + `hostapd_cli -i wlanX deauthenticate <mac>`
   - **Unblock:** `hostapd_cli -i wlanX deny_acl DEL_MAC <mac>`

This approach disconnects only the target client. All other WiFi clients remain connected.

---

## Persistence

| Feature | Persisted | Storage | Rationale |
|---------|-----------|---------|-----------|
| Shaping (tc/HTB) | Always | `/etc/trafficctl/shapes.json` | Long-term bandwidth allocation |
| Rate limiting (nft policer) | Optional (`persist_rules`) | `/etc/trafficctl/rules.json` | Configurable -- may be temporary or permanent |
| Internet blocking | Optional (`persist_rules`) | `/etc/trafficctl/rules.json` | Configurable -- may be temporary or permanent |
| WiFi MAC filtering | Always | `uci commit wireless` | Committed to `/etc/config/wireless` |

The hotplug script triggers on `ACTION=ifup` and `INTERFACE=lan`, with a readiness loop (waits up to 10s for tc to be available on the bridge device). When `persist_rules` is enabled, blocks and ratelimits are saved/removed from `/etc/trafficctl/rules.json` alongside shape operations.

---

## Telegram Bot

Optional long-polling daemon (`trafficctl-telegram.sh`) running under procd.

```
Telegram API  ←──curl long poll──  trafficctl-telegram.sh (procd)
                                        │
                                        ├── trafficctl-summary.sh (device list)
                                        ├── trafficctl-block.sh / unblock.sh
                                        ├── trafficctl-macfilter-add/remove.sh
                                        ├── trafficctl-ratelimit.sh
                                        └── trafficctl-shape.sh
```

- **Polling:** `getUpdates?timeout=N` acts as both fetch and sleep — no separate timer needed.
- **Security:** Only responds to messages from the configured `chat_id`. Unauthorized messages are silently dropped.
- **Device cache:** Summary output is cached for 5 seconds in `/tmp/trafficctl_tg_devices.json`.
- **Known devices:** `/etc/trafficctl/telegram_known.json` tracks MACs for new device notifications.
- **Configuration:** UCI section `trafficctl.telegram` with token, chat_id, notification and button toggles. Token is masked (never returned to the frontend).
- **Init:** procd `respawn 3600 5 5` + `service_triggers` for auto-reload on UCI commit.

---

## Security Model

- All script execution is gated by rpcd ACLs (`luci-app-trafficctl.json`).
- Only authenticated LuCI admin users can invoke scripts.
- IP validation: regex + octet range (0–255) before any operation.
- Label/comment sanitization: `tr -cd 'a-zA-Z0-9_.-'` strips injection characters.
- Protocol parameter: `case` whitelist (`tcp|udp|all`), not interpolated.
- No user-supplied strings are passed to shell eval.
- File locking for concurrent `shapes.json` writes.
- Telegram bot token stored in UCI with file mode 0600; token is masked in rpcd responses (`***`).
