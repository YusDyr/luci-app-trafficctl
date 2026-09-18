# CLAUDE.md

## Project

luci-app-trafficctl — OpenWrt LuCI plugin for real-time traffic monitoring and per-device control (block, rate-limit, shape, WiFi deny).

## Target Platform

- OpenWrt 23.x (kernel 5.15+)
- Router: 192.168.0.1, shell is **fish** (use `ssh root@192.168.0.1 sh -c '"command"'` or pipe via stdin)
- Firewall: fw4 / nftables (with iptables fallback detection)
- Shell scripts: POSIX sh / dash (NOT bash) — no arrays, no `[[`, no `<<<`
- BusyBox utilities (limited awk, no gawk features like match() with arrays)

## Directory Structure

All package files live under `luci-app-trafficctl/` (feed-compatible layout — required for
`./scripts/feeds update` to pick up the Makefile, which uses `-mindepth 1`).

```
luci-app-trafficctl/
  Makefile                                  — OpenWrt package Makefile (LuCI)
  htdocs/luci-static/resources/view/trafficctl/
    status.js                               — Main frontend (single-file LuCI view, "Devices" tab)
    portfw.js                               — "Port Forwards" tab (inbound traffic control)
    status.css                              — Frontend styles (shared by both views)
  root/usr/local/bin/
    trafficctl-fw.sh                        — Shared library (fw detection, validation, persistence helpers)
    trafficctl-summary.sh                   — All devices summary (JSON array)
    trafficctl-device.sh                    — Per-device detail + connections
    trafficctl-block.sh                     — Block internet (nft/iptables)
    trafficctl-unblock.sh                   — Unblock internet
    trafficctl-macfilter-add.sh             — WiFi MAC deny (hostapd_cli, no wifi reload)
    trafficctl-macfilter-remove.sh          — WiFi MAC allow
    trafficctl-names.sh                     — Manual device aliases (/etc/trafficctl/names)
    trafficctl-rdns-refresh.sh              — Background PTR resolver → /tmp/trafficctl_rdns_cache
    trafficctl-metrics.sh                   — Prometheus/OpenMetrics exporter (stdout)
    trafficctl-netify.sh                    — Optional netifyd DPI app labels (status/collect/list/raw)
    trafficctl-portfw.sh                    — Port-forward/open-port list + inbound pause/limit
    trafficctl-ratelimit.sh                 — nft policing (drop-based)
    trafficctl-ratelimit-stats.sh           — Limiter counters
    trafficctl-shape.sh                     — tc/HTB shaping (queue-based)
    trafficctl-shape-stats.sh               — Shaper counters
    trafficctl-bytes.sh                     — Per-device byte counters (one sample, not a total)
    trafficctl-bytes-nft.sh                 — nftables counters for software flow offload
    trafficctl-totals.sh                    — Monotonic lifetime totals; the ONLY accumulator (UI + Prometheus share its store)
    trafficctl-rdns.sh                      — Reverse DNS lookup
    trafficctl-telegram.sh                  — Telegram bot daemon (long polling)
    trafficctl-telegram-test.sh             — Send test message to Telegram
  root/usr/libexec/rpcd/
    luci.trafficctl                         — rpcd/ubus backend (JSON object output, not arrays)
  root/etc/init.d/
    trafficctl-telegram                     — procd init script for the bot
  root/etc/hotplug.d/
    iface/99-trafficctl-shapes              — Restore shapes+blocks+ratelimits on boot (ifup lan)
    dhcp/99-trafficctl-newdevice            — New device detection via DHCP events
  po/templates/                             — i18n templates

docs/
  capture.js                                — Playwright screenshot/GIF automation (masks MACs & hostname)
```

## JavaScript Conventions

- **ES5 only** — no `let`, `const`, arrow functions, template literals, destructuring
- `var` everywhere, `function` keyword only
- LuCI globals available: `E()`, `_()`, `L`, `view`, `rpc`, `dom`, `ui`, `form`, `fs`
- `rpc.declare()` for ubus calls
- ESLint config: `.eslintrc.json` (no-var: off, prefer-const: off)
- Run `node --check status.js` for syntax validation

## Shell Script Conventions

- Shebang: `#!/bin/sh`
- All scripts output JSON to stdout
- rpcd scripts (`luci-app-trafficctl/root/usr/libexec/rpcd/trafficctl`) must output JSON **objects** (not bare arrays) — wrap with `{"result": ...}`
- Validate IPs with `tctl_validate_ip` from trafficctl-fw.sh
- Use `2>/dev/null` on commands that may fail (nft, tc, iptables)
- Filter `dig` output: `grep -v '^;;'` to remove error messages

## Releases & Changelog

Releases are **fully automatic**: any `feat:` or `fix:` commit merged to `main` triggers version bump, tag, GitHub Release, and IPK build via `auto-release.yml`.

**Commit message format (Conventional Commits):**

```
feat: add per-device DNS override
fix: handle empty chat_id in telegram bot
ci: add aarch64 compat test
refactor: extract rate-limit validation to helper
docs: update install instructions
chore: bump ESLint config
```

- `feat:` → minor version bump (1.2.0 → 1.3.0)
- `fix:` / `perf:` / `refactor:` / `ci:` → patch version bump (1.3.0 → 1.3.1)
- `feat!:` or `fix!:` (with `!`) → major version bump
- `docs:`, `chore:`, `style:` → no release

**Flow:** merge to main → CI passes → auto-release creates tag + release + IPK. No manual steps.

**Manual trigger:** `auto-release.yml` also supports `workflow_dispatch` to re-run.

## Deployment

scp does NOT work to the router. Deploy files like this:

```sh
ssh root@192.168.0.1 sh -c '"cat > /path/to/file"' < local/file
# For scripts, also chmod:
ssh root@192.168.0.1 sh -c '"cat > /usr/local/bin/script.sh && chmod +x /usr/local/bin/script.sh"' < luci-app-trafficctl/root/usr/local/bin/script.sh
# Frontend:
ssh root@192.168.0.1 sh -c '"cat > /www/luci-static/resources/view/trafficctl/status.js"' < luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js
ssh root@192.168.0.1 sh -c '"cat > /www/luci-static/resources/view/trafficctl/status.css"' < luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.css
```

## Key Technical Details

- Traffic data comes from `/proc/net/nf_conntrack` (conntrack parsing)
- Monitored sources = connected LAN subnets + subnets routed via a LAN next-hop (downstream routers) + `trafficctl.main.extra_subnets` (optional CIDRs); independently, any flow SNAT/masqueraded by this router (reply dst ≠ original src) is picked up as a forwarded client with zero config. Such devices get `conn_type: "routed"`.
- WiFi detection: `iw dev <iface> station dump` → list of connected MACs
- WiFi MAC filter: `hostapd_cli deny_acl ADD_MAC` + `deauthenticate` (no wifi reload)
- Limit targets may be a host, a CIDR (`10.0.20.0/24`), or `all`. Mode `each` (default for any block wider than /32) gives every address its own bucket via an nft `meter` keyed by address; `shared` caps the block in aggregate — a shared cap lets one device starve the rest, hence the default
- Limits and shapes are **bidirectional**: the limiter polices download at LAN **egress** on the bridge (`ip daddr`, chain `dl_<landev>`) — at WAN ingress a reply is still addressed to the router's masqueraded WAN address, since conntrack only restores the client address in prerouting, which runs after the netdev ingress hook (WAN ingress remains a fallback for kernels < 5.16 without the egress hook) and upload at LAN ingress (`ip saddr`, one `ul_<dev>` chain per device). The two hooks are asymmetric and both halves matter: **a netdev ingress hook bound to a bridge never sees bridged traffic** — packets are received on the bridge's ports — so `tctl_ingress_devices` expands bridges to their `brif/*` ports; hooking `br-lan` matches nothing. **Egress is the mirror image**: the IP stack transmits to `br-lan`, so an egress hook on a PORT never fires for routed traffic and must bind the bridge itself (verified on kernel 6.12: br-lan egress counted every packet, ports counted none). `TCTL_SYSFS_NET` overrides the sysfs root for tests; the shaper builds a matching HTB class on the LAN device (`match ip dst`, download) and on an **IFB device** fed by `mirred` from LAN-side ingress (`match ip src`, upload). Upload must NOT be shaped at WAN egress: POSTROUTING has already masqueraded the source to the router's WAN address there, so a per-client src filter matches nothing. Needs `kmod-ifb`; without it the shaper applies download only and says so. Policing upload on the way *in* is what makes it work for routed/downstream clients. Both halves must be removed together
- tc/HTB shaping: the classid minor is **allocated**, not derived from the address, and persisted in `shapes.json` next to the rate. Deriving it from the last two octets (the original `1:<hex(o3*256+o4)>`) put `192.168.0.1` on the reserved root class `1:1` — so shaping it ran `tc class del ... 1:1` and tore down every other device's shape — put `x.x.255.254` on the default class `1:fffe`, and collided across subnets (`192.168.1.50` and `10.0.1.50` both mapped to `1:132`), which matters because routed/downstream clients live in other subnets. `lookup_classid` reads the recorded minor, `alloc_classid` hands out the lowest free one in 2..65533 (checking both the persisted file and live `tc` state), and `legacy_classid` reproduces the old derivation for the single purpose of cleaning up shapes persisted before the upgrade. `trafficctl-shape-stats.sh` therefore maps classid→IP purely from `shapes.json` and skips classes it does not know rather than reconstructing an address
- Reserved HTB classids: `1:1` (root), `1:fffe` (default) — never allocated
- `ensure_root_qdisc` only replaces a root qdisc it recognises as default (`pfifo_fast`, `fq_codel`, `noqueue`, `mq`, its own `htb`, …). Anything else — cake from SQM, a foreign HTB hierarchy — is somebody's QoS setup, so shaping declines instead of silently deleting it
- Firewall rule comments are derived from the **target**, not from the caller's label: `tctl_block_comment` / `tctl_ratelimit_comment` in `trafficctl-fw.sh`. Labels used to build the comment, so LuCI (label `block_<ip>`) and the Telegram bot (label `tg`) produced different comments for the same device and neither could remove the other's rule — while still reporting success, because the removal loop always exits 0. Removal also matches the **full quoted comment**: a substring match meant unblocking `192.168.1.1` deleted the rule for `192.168.1.10`
- Burst calculation for tc: `rate_kbit * 125 / 100` (10ms of data, min 1600 bytes)
- Persistent shapes stored in `/etc/trafficctl/shapes.json`
- Persistent blocks/ratelimits stored in `/etc/trafficctl/rules.json` (when `persist_rules` enabled)
- Note: Only `/etc/config/trafficctl` is tracked as a conffile for package upgrades. The runtime state under `/etc/trafficctl/` (names, shapes.json, rules.json, telegram_known.json) is not a conffile but IS listed in `root/lib/upgrade/keep.d/luci-app-trafficctl`, because default sysupgrade preserves `/etc/config/*` only — without that file every device alias and shaping rule was lost on a firmware upgrade
- The config file holds the Telegram bot token and the metrics token, so it is kept at mode 0600. `uci` rewrites the file at the default mode on every commit, hence the single `tctl_commit` helper in the rpcd backend that re-applies the mode after each one
- Activity logging: `trafficctl.logging.log_file` is constrained to `/tmp/trafficctl/*` or `/var/log/*` and `max_lines` to 20..100000 (`tctl_validate_log_file` / `tctl_log_max_lines`). The path is both an append target and a `tail`+`mv` rotation target, so an unconstrained value gave the write ACL an arbitrary root file read (via `activity_log`) and truncate — `max_lines=1` rounded the rotation keep-count to zero and emptied whatever the path pointed at. `activity_log` is a **write** method for that reason
- Port-forward control: own nft table `inet tctl_pfw`, chains at forward/input priority -190 (post-DNAT, before the flowtable offload rule); pause = drop rule + conntrack flush, limit = `limit rate over` drop. Rule comments `tctl_pfw_<pause|limit>_<proto>_<ip|local>_<port>` are the source of truth for state
- Device names: manual alias (`/etc/trafficctl/names`) > DHCP lease > cached reverse DNS. Routed devices have no lease here, so PTR (or an alias) is their only name source; `trafficctl.main.rdns_server` is a space-separated resolver list tried before the system resolver — point it at the downstream router. Lookups never block a poll: the summary reads the cache and spawns `trafficctl-rdns-refresh.sh` detached (max 8 IPs/poll, TTL `rdns_ttl`, `-` = negative cache)
- Netifyd (DPI) integration is optional and inert unless the agent is installed and its socket exists: **Agent v5's `netifyd.sock` is a request/response API that never streams flows** — telemetry comes from the socket SINK (`netify-sink-socket.json`, typically `tcp://127.0.0.1:1780`), auto-detected by `netify_endpoint`. The payload is the aggregator's `{"stats":[…]}` form (`application_id` = `"<id>.netify.<app>"`, separate `download`/`upload`); raw per-flow records are still handled for v4. `trafficctl-netify.sh collect` samples it into `/tmp/trafficctl_netify.json`, which the summary reads for the per-device `app` field and refreshes detached when older than `netify_interval`. Agent framing is undocumented, so flow records are parsed by field extraction (tolerant of newline-delimited and length-prefixed output) and totals are tracked per flow `digest` — the agent re-emits growing counters, so summing every sighting would multiply-count. Set `TCTL_NETIFY_FEED` to a recorded file to test without a socket
- Prometheus exporter (`trafficctl-metrics.sh`, off by default via `trafficctl.metrics.enabled`) writes OpenMetrics to stdout, so one implementation serves both a uhttpd CGI scrape endpoint (`/www/cgi-bin/trafficctl-metrics`, optional `?token=`) and a node_exporter textfile collector. **Raw conntrack sums are not monotonic** — a device's total drops when its flows expire — so positive deltas are accumulated into monotonic counters in `/tmp/trafficctl_metrics.state` (tmpfs: no flash wear, ~50 bytes/device); a decrease resyncs the baseline and adds nothing, because those bytes were already counted while the flows lived. Device names/MACs go on a `_info` metric, never as counter labels, so label churn doesn't fork a new time series. `metrics.apps` is off by default (device × application is a cardinality trap)
- Speed measurement: conntrack bytes (BEFORE tc shaper), so reported speed may exceed shaped limit
- Spike filter: cap speed at 125 MB/s (1 Gbit/s), discard anomalous samples
- Y-axis scaling: 98th percentile, nice ticks (multiples of 100/500 Kbit/s, min 5 gridlines)
- Speed units: ×1000 (SI network convention), not ×1024

## CSS / JS Display Gotcha

Elements hidden via a **CSS class** (`display:none` in `.tm-search-dropdown`, `.tm-search-clear`, `.tm-graph-popup`, `.tm-settings-body`, etc.) must be shown with an **explicit value** like `style.display = 'block'` (or `'inline'`, `'flex'`).  
Setting `style.display = ''` removes the inline override and lets the CSS class re-hide the element — it does **not** show it.

Elements hidden with an **inline style** (`style="display:none"` in the `E()` call) work the opposite way: `style.display = ''` correctly removes the inline style and the element becomes visible.

## UI Design Principles

- Colorblind-safe: blue-orange contrast (no red-green reliance)
- Inline pickers (mkInlinePick) instead of `<select>` for settings
- Settings panel collapsed by default (user expands on demand)
- Pointer cursor on interactive elements
- iOS-style toggles for boolean options
- Chip/pill style for column visibility toggles
- Recent devices quick-access bar (localStorage, MRU order, max 6, stores `{ip,name}`)
- Device picker (`searchSelect`) is seeded from DHCP leases at render time but must be kept current via `searchSelect.updateDevices(rows)` after each `callTrafficctl()` poll — otherwise only DHCP-known devices appear
- Command palette style search (filter by name/IP/MAC)
- Interactive graph popup on sparkline hover (crosshair, DL+UL, gradient fill, limit line)
- `fmtSpeed()`: no ".0" for whole numbers, SI units (×1000)

## Capture Script (docs/capture.js)

- Playwright (Chromium CDP on port 9222)
- Auto-masks MACs (`XX:XX:XX:XX`) and router hostname (`router.local`)
- Prefers Eugene-Asus / vivo-X200 as test targets
- Uses `clickApply()` (DOM evaluate) to bypass Playwright visibility limitations
- `ffmpeg` for GIF generation from frame sequences
