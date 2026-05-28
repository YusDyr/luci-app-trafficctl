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
scp luci-app-trafficctl/root/usr/libexec/rpcd/trafficctl root@192.168.0.1:/usr/libexec/rpcd/
ssh root@192.168.0.1 'chmod +x /usr/libexec/rpcd/trafficctl && /etc/init.d/rpcd restart'

# Deploy frontend
scp luci-app-trafficctl/htdocs/luci-static/resources/view/trafficctl/status.js \
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
│   └── status.js                        # Frontend (single ES5 file, ~1800 lines)
├── luci-app-trafficctl/root/
│   ├── etc/
│   │   ├── config/trafficctl            # UCI config placeholder
│   │   └── hotplug.d/iface/
│   │       └── 99-trafficctl-shapes     # Restore tc rules on boot
│   ├── usr/
│   │   ├── libexec/rpcd/
│   │   │   └── trafficctl              # rpcd backend (JSON-RPC dispatch)
│   │   ├── local/bin/
│   │   │   ├── trafficctl-fw.sh        # Firewall abstraction (sourced)
│   │   │   ├── trafficctl-summary.sh   # All-device summary
│   │   │   ├── trafficctl-device.sh    # Per-device detail
│   │   │   ├── trafficctl-bytes.sh     # Byte counters for speed
│   │   │   ├── trafficctl-block.sh     # Internet block
│   │   │   ├── trafficctl-unblock.sh   # Internet unblock
│   │   │   ├── trafficctl-shape.sh     # tc/HTB shaping
│   │   │   ├── trafficctl-shape-stats.sh
│   │   │   ├── trafficctl-ratelimit.sh # nft policer
│   │   │   ├── trafficctl-ratelimit-stats.sh
│   │   │   ├── trafficctl-macfilter-add.sh
│   │   │   ├── trafficctl-macfilter-remove.sh
│   │   │   └── trafficctl-rdns.sh      # Reverse DNS
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

Run all tests locally:

```sh
bash tests/test_fw.sh              # Shell unit tests (firewall scripts)
bash tests/test_telegram.sh        # Telegram bot unit tests
bash tests/test_telegram_mock.sh   # Telegram bot with mocked API responses
bash tests/test_telegram_e2e.sh    # End-to-end bot tests (61 tests)
bash tests/test_security.sh        # Security tests (injection, path traversal)
bash tests/test_build_ipk.sh       # IPK package build verification
```

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
| `shellcheck.yml` | ShellCheck on all `.sh` files |
| `eslint.yml` | ESLint on `status.js` (ES5 mode) |
| `compat.yml` | OpenWrt rootfs compatibility (52 version/arch combos) |
| `auto-release.yml` | CI + build IPK/APK + create GitHub release (on main only) |

---

## Debugging

**"Permission denied" from LuCI:**
- Check ACL file exists at `/usr/share/rpcd/acl.d/luci-app-trafficctl.json`
- Ensure rpcd backend is executable: `chmod +x /usr/libexec/rpcd/trafficctl`
- Restart rpcd: `/etc/init.d/rpcd restart`

**Script works via SSH but not from LuCI:**
- rpcd backend needs `list` and method handlers. Check `/usr/libexec/rpcd/trafficctl`.

**tc commands fail:**
- Verify `tc-full` (not minimal `tc`): `opkg install tc-full kmod-sched-htb`
- Check kernel module: `lsmod | grep sch_htb`

**Shaping not restored after reboot:**
- Check `/etc/trafficmon/shapes.json` exists with valid JSON
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
