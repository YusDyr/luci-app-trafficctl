# Changelog

All notable changes to luci-app-trafficctl since v1.0.0.

---

## [1.3.0](https://github.com/YusDyr/luci-app-trafficctl/compare/v1.2.1...v1.3.0) (2026-05-26)


### Features

* redesign Telegram Bot settings with mode toggle, live preview, and template variables ([#2](https://github.com/YusDyr/luci-app-trafficctl/issues/2)) ([8d49873](https://github.com/YusDyr/luci-app-trafficctl/commit/8d498737de53db551648f254d005a1ecf0b5d4bc))


### CI

* add release-please for automated changelog and releases ([f1c9834](https://github.com/YusDyr/luci-app-trafficctl/commit/f1c9834b37a19ae091b5c6b993e1309a06c74709))

## [1.2.1] — 2026-05-26

### Bug Fixes

- **Fix broken IPK format** — package was built with Debian `ar` format instead of OpenWrt's gzip-tar format; `opkg` rejected it with `Malformed package file` on all devices ([#1](https://github.com/YusDyr/luci-app-trafficctl/issues/1))
- **Fix rpcd binary path** — binary was installed as `trafficctl` but rpcd expects `luci.trafficctl`
- **Fix ShellCheck SC2086** — unquoted variable in `uci` call in `trafficctl-fw.sh`
- **Fix ESLint no-redeclare** — duplicate `chipActiveStyle` declaration in `status.js`

### CI

- Per-test badges: ShellCheck, ESLint, Tests each have their own status badge
- Release is blocked from publishing if any test fails
- OpenWrt compatibility matrix: tested across 3 versions (21.02, 22.03, snapshot) × 4 architectures (x86-64, aarch64, arm\_a15, armvirt-32)
- All CI jobs moved to GitHub-hosted runners

### Installation

- Install directly on the router without `scp`:
  ```sh
  opkg install https://github.com/YusDyr/luci-app-trafficctl/releases/latest/download/luci-app-trafficctl.ipk
  ```
- Install via LuCI web UI — **System → Software → Upload Package**
- Stable download URLs: [`luci-app-trafficctl.ipk`](https://github.com/YusDyr/luci-app-trafficctl/releases/latest/download/luci-app-trafficctl.ipk), [`luci-app-trafficctl_all.ipk`](https://github.com/YusDyr/luci-app-trafficctl/releases/latest/download/luci-app-trafficctl_all.ipk), [`luci-app-trafficctl_latest_all.ipk`](https://github.com/YusDyr/luci-app-trafficctl/releases/latest/download/luci-app-trafficctl_latest_all.ipk)

---

## [1.2.0] — 2026-05-26

### New Features

- **Interactive speed graph popup** — hover any device's sparkline to see a full-size graph with download + upload dual lines, gradient fill, min/max band, rate limit overlay line, and an interactive crosshair showing precise values at any point in time. History starts from page load and is never lost.
- **Recent devices quick-access bar** — selecting a device (via table click or search) adds it to a chip bar below the search field. Up to 6 recent devices persist across page reloads (localStorage). One-click switching between frequently monitored devices.
- **Activity logging** — all mutable actions (blocks, rate limits, shapes, WiFi denials, config changes) are logged with timestamp, source IP, username, and trigger (LuCI / Telegram / CLI). Logs are viewable in the UI and optionally forwarded to syslog.
- **Reboot persistence for blocks & rate limits** — new `persist_rules` option in Settings. When enabled, internet blocks and rate limits are saved to `/etc/trafficmon/rules.json` and automatically restored on boot alongside traffic shaping rules.
- **New device detection** — instant notification when a new device joins the network. Detects via ARP, DHCP leases, and WiFi station list. DHCP hotplug trigger provides near-realtime alerts. Integrates with Telegram notifications.
- **Per-device column toggles** — show/hide individual table columns (MAC, Speed, Conns, etc.) from the Connections table settings section.
- **Settings panel collapsed by default** — cleaner look on page load; expand on demand.

### Improvements

- **WiFi blocking no longer restarts WiFi** — uses `hostapd_cli deny_acl` + `deauthenticate` to disconnect only the target client. Other WiFi clients stay connected with zero interruption.
- **Speed display in bits (not bytes)** — sparkline and graph values now show Kbit/s and Mbit/s as expected for network speeds. Clean labels: no trailing ".0" for whole numbers (e.g., "10 Mbit/s" not "10.0 Mbit/s").
- **Stable graph scale** — spike filter caps speed at 1 Gbit/s (link ceiling) to discard conntrack counter resets. Y-axis uses 98th percentile scaling so occasional spikes don't crush the useful range.
- **Nice Y-axis values** — graph ticks are multiples of 100 or 500 Kbit/s (or 1/5/10 Mbit/s for faster links) with at least 5 gridlines for readability.
- **Upload speed tracking** — graphs now show both download (solid blue) and upload (dashed green) simultaneously.
- **Compact table headers** — limiter, drop, and queue columns use icon-only headers to save horizontal space.
- **Sort by name** — device table can be sorted alphabetically by hostname.
- **Sparkline rate limit line** — a subtle horizontal line on each sparkline shows the active speed limit for that device.
- **Redesigned speed limit UI** — pill-style chip picker for rate presets + segmented toggle for shaper/limiter mode selection.

### Bug Fixes

- Fixed speed showing in bytes instead of bits.
- Fixed graph popup not showing rate limit line for shaped devices (fallback to summary data).
- Fixed initial page load sometimes showing blank table.
- Fixed WiFi capture disconnecting all clients during screenshot automation.
- Fixed rate limit removal failing to match by IP on some configurations.

---

## [1.1.0] — 2025-05-18

### New Features

- **Telegram bot** — remote control from your phone. Send `/devices` to see active devices with inline keyboard buttons for block, unblock, rate limit, shape, WiFi deny. Long polling — runs entirely on the router, no external server needed.
- **New device notifications** — Telegram alerts when an unknown device joins your network.
- **Bot configuration UI** — token, chat ID, notification toggles, and a "Test" button directly in LuCI Settings.

### Improvements

- CI pipeline with ShellCheck, ESLint, and automated tests.
- CodeQL security scanning enabled.
- System requirements documented (RAM, flash, CPU).

---

## [1.0.0] — 2025-05-10

Initial release.

- Real-time per-device traffic monitoring via conntrack.
- Internet blocking (nftables / iptables auto-detection).
- Rate limiting (nft policer with drop counters).
- Traffic shaping (tc/HTB with fq_codel, persistent across reboots).
- WiFi MAC filtering.
- Interface detection (2.4G / 5G / 6G / LAN port).
- Live speed sparklines with configurable poll interval.
- Reverse DNS lookup for destination IPs.
- Searchable device picker (command palette style).
- Dark / light theme support.
- OpenWrt 21.02–23.05 compatibility.
