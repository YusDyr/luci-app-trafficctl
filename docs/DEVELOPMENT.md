# Development Guide

---

## Prerequisites

- A Linux or macOS workstation
- An OpenWrt router (physical or QEMU) for testing
- SSH access to the router
- Basic familiarity with shell scripting and JavaScript

---

## Development Setup

### Option 1: Direct Deploy to Router (fastest iteration)

```sh
# Deploy all backend scripts
scp luci-app-trafficctl/root/usr/local/bin/trafficctl-*.sh root@192.168.0.1:/usr/local/bin/
ssh root@192.168.0.1 'chmod +x /usr/local/bin/trafficctl-*.sh'

# Deploy rpcd backend
scp luci-app-trafficctl/root/usr/libexec/rpcd/luci.trafficctl root@192.168.0.1:/usr/libexec/rpcd/
ssh root@192.168.0.1 'chmod +x /usr/libexec/rpcd/luci.trafficctl && /etc/init.d/rpcd restart'

# Deploy frontend
scp luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js \
    luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.css \
    root@192.168.0.1:/www/luci-static/resources/view/trafficctl/
```

After deploying, hard-refresh the browser (Ctrl+Shift+R) to pick up JavaScript changes.

### Option 2: QEMU Virtual Router

```sh
# Download OpenWrt x86_64 image
wget https://downloads.openwrt.org/releases/23.05.4/targets/x86/64/openwrt-23.05.4-x86-64-generic-ext4-combined.img.gz
gunzip openwrt-23.05.4-x86-64-generic-ext4-combined.img.gz

qemu-system-x86_64 \
  -drive file=openwrt-23.05.4-x86-64-generic-ext4-combined.img,format=raw \
  -m 256M \
  -netdev user,id=wan,hostfwd=tcp::2222-:22,hostfwd=tcp::8080-:80 \
  -device virtio-net-pci,netdev=wan \
  -nographic

# Access: ssh -p 2222 root@localhost / http://localhost:8080
```

Install required packages:
```sh
opkg update && opkg install conntrack luci tc-full kmod-sched-core kmod-sched-htb iw-full
```

### Option 3: OpenWrt Build System (for .ipk packages)

```sh
git clone https://git.openwrt.org/openwrt/openwrt.git
cd openwrt && git checkout v23.05.4

echo "src-link trafficctl /path/to/luci-app-trafficctl" >> feeds.conf
./scripts/feeds update trafficctl
./scripts/feeds install luci-app-trafficctl

make menuconfig  # Select: LuCI > Applications > luci-app-trafficctl
make package/luci-app-trafficctl/compile V=s
```

---

## Project Structure

```
luci-app-trafficctl/
├── luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/
│   ├── status.js                        # Frontend (single ES5 file, ~3100 lines)
│   └── status.css                       # Frontend styles (~610 lines)
├── luci-app-trafficctl/root/
│   ├── etc/
│   │   ├── config/trafficctl            # UCI config placeholder
│   │   └── hotplug.d/iface/
│   │       └── 99-trafficctl-shapes     # Restore tc rules on boot
│   ├── usr/
│   │   ├── libexec/rpcd/
│   │   │   └── luci.trafficctl         # rpcd backend (JSON-RPC dispatch)
│   │   ├── local/bin/
│   │   │   ├── trafficctl-fw.sh        # Firewall abstraction (sourced)
│   │   │   ├── trafficctl-summary.sh   # All-device summary
│   │   │   ├── trafficctl-device.sh    # Per-device detail
│   │   │   ├── trafficctl-bytes.sh     # Byte counters for speed (conntrack)
│   │   │   ├── trafficctl-bytes-nft.sh # nft counter init helper
│   │   │   ├── trafficctl-ifaces.sh    # Per-interface counters (global overview)
│   │   │   ├── trafficctl-block.sh     # Internet block
│   │   │   ├── trafficctl-unblock.sh   # Internet unblock
│   │   │   ├── trafficctl-shape.sh     # tc/HTB shaping
│   │   │   ├── trafficctl-shape-stats.sh
│   │   │   ├── trafficctl-ratelimit.sh # nft policer
│   │   │   ├── trafficctl-ratelimit-stats.sh
│   │   │   ├── trafficctl-macfilter-add.sh
│   │   │   ├── trafficctl-macfilter-remove.sh
│   │   │   └── trafficctl-rdns.sh      # Reverse DNS (Telegram/CLI)
│   │   └── share/
│   │       ├── luci/menu.d/
│   │       │   └── luci-app-trafficctl.json
│   │       └── rpcd/acl.d/
│   │           └── luci-app-trafficctl.json
├── Makefile                             # OpenWrt package build
├── po/templates/                        # i18n template
├── docs/                                # Documentation
├── .github/workflows/ci.yml             # CI (shellcheck + eslint)
└── .eslintrc.json                       # ES5 linting config
```

---

## Code Style

### Shell Scripts

- `#!/bin/sh` — POSIX sh (BusyBox ash/dash). No bashisms.
- Source `trafficctl-fw.sh` for firewall detection and validation helpers.
- Validate all IP inputs via `tctl_validate_ip` before use.
- Output only valid JSON to stdout.
- Use `2>/dev/null` on commands that may fail.
- Quote all variable expansions.

**Allowed:**
```sh
local var="value"        # local variables (in functions)
$((expr))                # arithmetic
case/esac                # pattern matching
[ condition ]            # POSIX test
$(command)               # command substitution
```

**Forbidden:**
```sh
[[ condition ]]          # bash-only extended test
declare -A               # bash associative arrays
${var,,}                 # bash case modification
<(command)               # process substitution
function name {}         # use name() {} instead
```

### JavaScript

- ES5 syntax only — no `let`, `const`, arrow functions, template literals, `class`, destructuring.
- `'use strict';` at the top.
- No external dependencies, no npm runtime, no bundlers.
- Use LuCI's `E()` for DOM creation.
- CSS variables (via the `C` object) for all colors — supports light/dark mode.
- All user-visible strings wrapped in `_()` for future i18n.

### JSON Output

- Always valid JSON.
- Field naming: `snake_case`.
- Numbers for numeric values (not strings).
- Booleans for boolean values (not `"true"`/`"false"` strings).
- Empty arrays `[]` for absent collections.

---

## Testing

### Script Testing via SSH

```sh
# Summary
ssh root@192.168.0.1 '/usr/local/bin/trafficctl-summary.sh' | python3 -m json.tool

# Per-device
ssh root@192.168.0.1 '/usr/local/bin/trafficctl-device.sh 192.168.0.111 all' | python3 -m json.tool

# Shaping
ssh root@192.168.0.1 '/usr/local/bin/trafficctl-shape.sh add 192.168.0.100 5000 test'
ssh root@192.168.0.1 '/usr/local/bin/trafficctl-shape.sh status 192.168.0.100'
ssh root@192.168.0.1 '/usr/local/bin/trafficctl-shape-stats.sh' | python3 -m json.tool
ssh root@192.168.0.1 '/usr/local/bin/trafficctl-shape.sh remove 192.168.0.100'

# Verify kernel state
ssh root@192.168.0.1 'tc -s class show dev br-lan'
ssh root@192.168.0.1 'nft list chain inet fw4 forward'
```

### Linting

```sh
# Shell (requires shellcheck)
shellcheck luci-app-trafficctl/root/usr/local/bin/trafficctl-*.sh

# JavaScript (requires node + eslint)
npm install   # installs eslint from package.json devDependencies
npx eslint luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js
```

### Automated Tests

Run all tests locally. These run on the host with fake `nft`/`tc`/`ip`/`uci`/
`curl` binaries on `PATH`, so they need no router:

```sh
bash tests/test_fw.sh                 # Firewall helper library
bash tests/test_direction.sh          # Bidirectional limit/shape, classid allocation
bash tests/test_portfw.sh             # Port-forward control, port ranges
bash tests/test_names.sh              # Device aliases + reverse-DNS cache
bash tests/test_netify.sh             # Netify (DPI) integration
bash tests/test_metrics.sh            # Prometheus exporter
bash tests/test_bytes_nft.sh          # nftables byte-counter parsing
bash tests/test_openwrt_compat.sh     # BusyBox ash compatibility / no bashisms
bash tests/test_security.sh           # Input validation and injection resistance
bash tests/test_rpcd.sh               # rpcd/ubus backend — every method, dispatch, ACL
bash tests/test_block.sh              # Internet block/unblock
bash tests/test_macfilter.sh          # WiFi MAC deny/allow
bash tests/test_metrics_cgi.sh        # Metrics CGI gate and token check
bash tests/test_regressions.sh        # Regressions for previously fixed bugs
bash tests/test_telegram.sh           # Telegram bot units
bash tests/test_telegram_mock.sh      # Telegram bot with mocked API responses
bash tests/test_telegram_e2e.sh       # End-to-end bot tests
bash tests/test_build_ipk.sh          # IPK package build verification
```

Four further tests only run inside the OpenWrt rootfs containers that
`compat.yml` builds, because they install a real package — they fail on a
developer machine by design:

```
tests/test_dependencies.sh  tests/test_install.sh
tests/test_upgrade.sh       tests/test_feed_install.sh
```

`tests/test_telegram_integration.sh` talks to the real Telegram API and skips
unless `TEST_TELEGRAM_TOKEN` and `TEST_TELEGRAM_CHAT_ID` are set. In CI it also
skips for pull requests from forks, which cannot see repository secrets.

A test must exercise the real script rather than a local copy of the function it
names — see the "Writing tests" section of `CONTRIBUTING.md` for why, and use
`tests/test_direction.sh` as the template.

**E2E tests** (`test_telegram_e2e.sh`) run the real bot script with mocked externals (curl, uci, iw, ip, jsonfilter) and verify:
- Command processing (`/devices`, `/status`, `/help`)
- Callback handling (block, unblock, limit, shape, WiFi block)
- Authorization (unauthorized chat rejection)
- Input validation (invalid IP in callbacks)
- New device detection and notifications
- Known device online notifications
- DHCP trigger processing
- Template tag substitution (17 tags: `{{name}}`, `{{ip}}`, `{{mac}}`, `{{link}}`, `{{date}}`, `{{time}}`, `{{datetime}}`, `{{router}}`, `{{ssid}}`, `{{signal}}`, `{{freq}}`, `{{iface}}`, `{{clients}}`, `{{uptime}}`, `{{wan_ip}}`, `{{load}}`, `{{conns}}`)
- Notification throttling

### CI

GitHub Actions (`.github/workflows/`) runs on every push and PR:

| Workflow | What it checks |
|----------|----------------|
| `tests.yml` | Unit, mock, E2E, security, and build tests |
| `shellcheck.yml` | ShellCheck (`-S warning`) on every script with a shell shebang |
| `eslint.yml` | ESLint on the frontend — `ecmaVersion: 5` plus `no-restricted-syntax`, so ES6 syntax fails the build |
| `compat.yml` | OpenWrt rootfs compatibility (52 version/arch combos); installs the built package and tests upgrades |
| `auto-release.yml` | Waits for `ci.yml` **and** `compat.yml`, then bumps the version, tags, builds and publishes (on main only) |

The release depends on the compatibility matrix as well as the fast checks —
otherwise a tag and the `releases/latest/download` URL could publish an
uninstallable package minutes before `compat` went red. Note that `main` has no
branch protection at the time of writing, so none of these are *required* checks:
a red PR can still be merged, and the release will then publish it.

---

## Debugging

**"Permission denied" from LuCI:**
- Check ACL file exists at `/usr/share/rpcd/acl.d/luci-app-trafficctl.json`
- Ensure rpcd backend is executable: `chmod +x /usr/libexec/rpcd/luci.trafficctl`
- Restart rpcd: `/etc/init.d/rpcd restart`

**Script works via SSH but not from LuCI:**
- rpcd backend needs `list` and method handlers. Check `/usr/libexec/rpcd/luci.trafficctl`.

**tc commands fail:**
- Verify `tc-full` (not minimal `tc`): `opkg install tc-full kmod-sched-htb`
- Check kernel module: `lsmod | grep sch_htb`

**Shaping not restored after reboot:**
- Check `/etc/trafficctl/shapes.json` exists with valid JSON
- Test hotplug manually: `ACTION=ifup INTERFACE=lan sh /etc/hotplug.d/iface/99-trafficctl-shapes`

**Debug logging:**
```sh
# Temporarily add to any script:
exec 2>/tmp/trafficctl-debug.log
set -x
```

---

## Screenshots & GIF Capture

The `docs/capture.js` script automates screenshot and GIF generation using Playwright (Chromium CDP).

### Prerequisites

```sh
npm install playwright
# Requires ffmpeg for GIF generation
brew install ffmpeg  # macOS
```

### Running

1. Open the LuCI page in Chrome/Chromium with remote debugging:
   ```sh
   /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
     --remote-debugging-port=9222 "https://router.local/cgi-bin/luci/admin/status/trafficctl"
   ```
2. Run the capture script:
   ```sh
   node docs/capture.js
   ```

### Output

| File | Content |
|------|---------|
| `docs/img/dark/*.png` | Static screenshots (dark theme) |
| `docs/img/light/*.png` | Static screenshots (light theme) |
| `docs/img/speed-graph-{dark,light}.gif` | Live speed sparklines |
| `docs/img/graph-popup-{dark,light}.gif` | Graph popup hover with crosshair |
| `docs/img/block-internet-{dark,light}.gif` | Block/unblock internet sequence |
| `docs/img/rate-limit-{dark,light}.gif` | Limiter → shaper → off sequence |
| `docs/img/column-toggle-{dark,light}.gif` | Column visibility toggle demo |
| `docs/img/telegram-toggle-{dark,light}.gif` | Telegram bot enable/disable |
| `docs/img/settings-walkthrough-{dark,light}.gif` | All settings subsections |

### Privacy Masking

The script automatically masks sensitive data before every screenshot:
- **MAC addresses**: replaced with `XX:XX:XX:XX` (keeps first 2 octets for OUI)
- **Router hostname**: replaced with `router.local`

No manual redaction needed.

### Device Selection

The script auto-detects a target device from the overview table, preferring (in order): `Eugene-Asus`, `vivo-X200`, any phone-like device, any WiFi device.

---

## Contributing

1. Fork the repo, create a feature branch.
2. Test on real hardware (or QEMU).
3. Ensure both nft and iptables paths work if touching firewall code.
4. Run `shellcheck` and `eslint`.
5. Submit PR with description of what and why.
