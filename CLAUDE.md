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
    status.js                               — Main frontend (single-file LuCI view)
    status.css                              — Frontend styles
  root/usr/local/bin/
    trafficctl-fw.sh                        — Shared library (fw detection, validation, persistence helpers)
    trafficctl-summary.sh                   — All devices summary (JSON array)
    trafficctl-device.sh                    — Per-device detail + connections
    trafficctl-block.sh                     — Block internet (nft/iptables)
    trafficctl-unblock.sh                   — Unblock internet
    trafficctl-macfilter-add.sh             — WiFi MAC deny (hostapd_cli, no wifi reload)
    trafficctl-macfilter-remove.sh          — WiFi MAC allow
    trafficctl-ratelimit.sh                 — nft policing (drop-based)
    trafficctl-ratelimit-stats.sh           — Limiter counters
    trafficctl-shape.sh                     — tc/HTB shaping (queue-based)
    trafficctl-shape-stats.sh               — Shaper counters
    trafficctl-bytes.sh                     — Per-device byte counters
    trafficctl-bytes-nft.sh                 — nftables counters for software flow offload
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
- WiFi detection: `iw dev <iface> station dump` → list of connected MACs
- WiFi MAC filter: `hostapd_cli deny_acl ADD_MAC` + `deauthenticate` (no wifi reload)
- tc/HTB shaping: classid derived from IP octets (`1:<hex(o3*256+o4)>`)
- Reserved HTB classids: `1:1` (root), `1:fffe` (default) — skip these
- Burst calculation for tc: `rate_kbit * 125 / 100` (10ms of data, min 1600 bytes)
- Persistent shapes stored in `/etc/trafficctl/shapes.json`
- Persistent blocks/ratelimits stored in `/etc/trafficctl/rules.json` (when `persist_rules` enabled)
- Note: Only `/etc/config/trafficctl` is tracked as a conffile for package upgrades; runtime JSON files are non-essential and can be regenerated
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
