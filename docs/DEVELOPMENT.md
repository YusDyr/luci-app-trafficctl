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
scp trafficctl/files/usr/libexec/trafficctl/trafficctl-*.sh root@192.168.0.1:/usr/libexec/trafficctl/
ssh root@192.168.0.1 'chmod +x /usr/libexec/trafficctl/trafficctl-*.sh'

# Deploy the ucode modules and the CLI: the rpcd plugin imports lib.uc and
# runs /usr/sbin/trafficctl for every delegated method
ssh root@192.168.0.1 'mkdir -p /usr/share/ucode/trafficctl'
scp trafficctl/files/usr/share/ucode/trafficctl/*.uc root@192.168.0.1:/usr/share/ucode/trafficctl/
scp trafficctl/files/usr/sbin/trafficctl root@192.168.0.1:/usr/sbin/
ssh root@192.168.0.1 'chmod +x /usr/sbin/trafficctl'

# Deploy the rpcd plugin
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
./scripts/feeds install luci-app-trafficctl   # links trafficctl too, as a dependency

make menuconfig  # Select: LuCI > Applications > luci-app-trafficctl
make package/trafficctl/compile package/luci-app-trafficctl/compile V=s
```

---

## Project Structure

```
luci-app-trafficctl/                     # repository
├── trafficctl/                          # package trafficctl: the backend
│   ├── Makefile                         # OpenWrt package build (package.mk, lists every file)
│   └── files/
│       ├── etc/
│       │   ├── config/trafficctl        # UCI config (the conffile)
│       │   ├── init.d/                  # trafficctl-telegram, trafficctl-history, trafficctl-cut
│       │   └── hotplug.d/
│       │       ├── iface/99-trafficctl-shapes      # Restore tc rules on boot
│       │       └── dhcp/99-trafficctl-newdevice    # New-device detection
│       ├── lib/upgrade/keep.d/trafficctl          # /etc/trafficctl/ kept across sysupgrade
│       ├── usr/sbin/trafficctl          # The CLI (ucode): subnets, names, rdns, rdns-refresh, ifaces, bytes, totals,
│       │                                #   ratelimit-stats, shape-stats, rules, summary, device, metrics, netify
│       ├── usr/share/ucode/trafficctl/
│       │   ├── lib.uc                   # Shared helpers: uci/ubus, commands, JSON, validation, files, log
│       │   ├── net.uc                   # Subnets, interface roles, reverse DNS, byte samples, totals
│       │   ├── ctl.uc                   # Read-only nft/tc readers: limits, blocks, shapes, the Rules tab
│       │   └── report.uc                # Summary, device detail, Prometheus exporter, netifyd DPI
│       ├── usr/libexec/trafficctl/
│       │   ├── trafficctl-fw.sh         # Firewall abstraction (sourced)
│       │   ├── trafficctl-summary.sh    # Wrapper: `trafficctl summary` (all-device summary)
│       │   ├── trafficctl-device.sh     # Wrapper: `trafficctl device` (per-device detail)
│       │   ├── trafficctl-bytes.sh      # Wrapper: `trafficctl bytes` (byte counters for speed)
│       │   ├── trafficctl-totals.sh     # Wrapper: `trafficctl totals` (lifetime totals, UI + exporter)
│       │   ├── trafficctl-ifaces.sh     # Wrapper for `trafficctl ifaces`
│       │   ├── trafficctl-block.sh      # Internet block
│       │   ├── trafficctl-unblock.sh    # Internet unblock
│       │   ├── trafficctl-shape.sh      # tc/HTB shaping
│       │   ├── trafficctl-shape-stats.sh      # Wrapper: `trafficctl shape-stats`
│       │   ├── trafficctl-ratelimit.sh  # nft policer
│       │   ├── trafficctl-ratelimit-stats.sh  # Wrapper: `trafficctl ratelimit-stats`
│       │   ├── trafficctl-macfilter-add.sh
│       │   ├── trafficctl-macfilter-remove.sh
│       │   ├── trafficctl-rdns.sh       # Wrapper for `trafficctl rdns`
│       │   ├── trafficctl-rules.sh      # Wrapper: `trafficctl rules` (every restriction, online or not; "Rules" tab)
│       │   └── ...                      # the rest of the helpers
│       └── www/cgi-bin/trafficctl-metrics          # Prometheus scrape endpoint
├── luci-app-trafficctl/                 # package luci-app-trafficctl: the web interface
│   ├── Makefile                         # OpenWrt package build (luci.mk), depends on trafficctl
│   ├── htdocs/luci-static/resources/view/trafficctl/
│   │   ├── status.js                    # Frontend (single ES5 file)
│   │   ├── rules.js                     # "Rules" tab
│   │   ├── portfw.js                    # "Port Forwards" tab
│   │   └── status.css                   # Frontend styles
│   ├── root/usr/
│   │   ├── libexec/rpcd/luci.trafficctl # rpcd plugin (ucode): settings in process, the rest via the CLI
│   │   └── share/
│   │       ├── luci/menu.d/luci-app-trafficctl.json
│   │       └── rpcd/acl.d/luci-app-trafficctl.json
│   └── po/                              # i18n: templates/trafficctl.pot, <lang>/trafficctl.po
├── build-ipk.sh, build-apk.sh           # Standalone builders, emit both packages
├── docs/                                # Documentation
├── .github/workflows/                   # CI
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
ssh root@192.168.0.1 '/usr/sbin/trafficctl summary' | python3 -m json.tool

# Per-device
ssh root@192.168.0.1 '/usr/sbin/trafficctl device 192.168.0.111 all' | python3 -m json.tool

# Shaping
ssh root@192.168.0.1 '/usr/libexec/trafficctl/trafficctl-shape.sh add 192.168.0.100 5000 test'
ssh root@192.168.0.1 '/usr/libexec/trafficctl/trafficctl-shape.sh status 192.168.0.100'
ssh root@192.168.0.1 'trafficctl shape-stats' | python3 -m json.tool
ssh root@192.168.0.1 '/usr/libexec/trafficctl/trafficctl-shape.sh remove 192.168.0.100'

# Verify kernel state
ssh root@192.168.0.1 'tc -s class show dev br-lan'
ssh root@192.168.0.1 'nft list chain inet fw4 forward'
```

### Linting

```sh
# Shell (requires shellcheck)
shellcheck trafficctl/files/usr/libexec/trafficctl/trafficctl-*.sh

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
bash tests/test_meter_per_chain.sh    # Each-mode meters per chain, per-port success, nft 1.0/1.1
bash tests/test_portfw.sh             # Port-forward control, port ranges
bash tests/test_netify.sh             # Netify (DPI) integration
bash tests/test_openwrt_compat.sh     # BusyBox ash compatibility / no bashisms
bash tests/test_security.sh           # Input validation and injection resistance
bash tests/test_block.sh              # Internet block/unblock
bash tests/test_macfilter.sh          # WiFi MAC deny/allow
bash tests/test_metrics_cgi.sh        # Metrics CGI gate and token check
bash tests/test_regressions.sh        # Regressions for previously fixed bugs
bash tests/test_telegram.sh           # Telegram bot units
bash tests/test_telegram_mock.sh      # Telegram bot with mocked API responses
bash tests/test_telegram_e2e.sh       # End-to-end bot tests
bash tests/test_build_ipk.sh          # IPK package build verification
```

The ucode backend's tests need ucode, uci and ubus built for the host, at the
oldest (2022-12-02, OpenWrt 22.03) and the newest version supported;
`tools/ci/build-ucode.sh` builds them into `~/.cache/trafficctl-ucode/<version>`:

```sh
tools/ci/build-ucode.sh 2022-12-02
export UCODE_PREFIX=~/.cache/trafficctl-ucode/2022-12-02
bash tests/test_ucode_lib.sh          # lib.uc helpers, subnets
bash tests/test_names.sh              # Device aliases + reverse-DNS cache
bash tests/test_ifaces.sh             # Per-interface counters and roles
bash tests/test_totals.sh             # Byte samples and the lifetime accumulator
bash tests/test_metrics.sh            # Prometheus exporter (runs the accumulator)
bash tests/test_byte_overflow.sh      # Counters past 2^31 and 2^53
bash tests/test_rpcd.sh               # rpcd plugin: every method, dispatch, uci commits, 0600
bash tests/test_readers.sh            # nft -j readers of both nft versions: block comments, 1.1 meters
bash tests/test_rules.sh              # Rules tab backend: restrictions of offline devices
bash tests/test_rl_lookup.sh          # Rate limit read-back: units, prefixes, ratelimit-stats
bash tests/test_shape_lookup.sh       # Shape classid lookup, shape-stats
bash tests/test_subnet_limits.sh      # Subnet limits: stats, persisted mode, the restore hook
bash tests/test_rpcd_contract.sh      # every rpc.declare in the views against the plugin's list
bash tests/equiv.sh                   # ucode output == the v1.30.0 shell output, rpcd methods included
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

GitHub Actions (`.github/workflows/`). Only three workflows have triggers of
their own — everything else is reached through `workflow_call`:

| Workflow | Trigger | What it checks |
|----------|---------|----------------|
| `ci.yml` | push to main, PR | Calls the three below plus the OpenWrt rootfs test |
| `tests.yml` | called by `ci.yml` | Unit, mock, E2E, security, and build tests |
| `shellcheck.yml` | called by `ci.yml` | ShellCheck (`-S warning`) on every script with a shell shebang |
| `eslint.yml` | called by `ci.yml` | ESLint on the frontend — `ecmaVersion: 5` plus `no-restricted-syntax`, so ES6 syntax fails the build |
| `compat.yml` | PR, called by `auto-release.yml` | OpenWrt rootfs compatibility (52 version/arch combos); installs the built package and tests upgrades; job `live-ratelimit` runs `tools/ci/live-ratelimit.sh` (real nft, a bridge with two dummy ports) on 22.03.7 and 25.12.4 |
| `auto-release.yml` | push to main | Waits for `ci.yml` **and** `compat.yml`, then bumps the version, tags, builds and publishes; job `pages` then rebuilds the signed opkg/apk feed on GitHub Pages with `tools/build-feed.sh` |

The nesting is why the leaf workflows carry no `push`/`pull_request` triggers.
When they did, each check ran twice on a pull request — once standalone and
once inside `ci.yml`, which is why the checks list showed both `ShellCheck` and
`shellcheck / ShellCheck` — and three times on a push to main, where
`auto-release.yml` calls `ci.yml` a second time. `compat.yml` lost its push
trigger for the same reason: on main it already runs inside `auto-release.yml`,
and it is by far the most expensive job here.

#### OpenWrt SDK cache

Every OpenWrt SDK build (`tools/sdk-build.sh` in `auto-release.yml` and
`compat.yml`, `tests/test_feed_install.sh` in `feed-install.yml`) restores and
saves a cache through `actions/cache` and `tools/sdk-cache.sh`. Almost all of
a cold SDK build is spent compiling dependencies (hostapd in ~30 variants,
iproute2, curl, openssl, luci-base, …), not our two packages, so the cache
carries them: `dl/`, the official feed checkouts, and the build stamps,
staging and `bin/` output of every dependency.

- **Key:** `sdk-<salt>-<driver>-<image tag>-<image digest>-<hash>`, where the
  hash covers `tools/sdk-cache.sh`, the driver script and the `DEPENDS` lines
  of both Makefiles. The restore key drops the hash, so a new dependency
  starts from the previous entry. Bump `SALT` in `sdk-cache.sh` to drop every
  entry. A pull request restores `main`'s entry (written by the release) but
  saves its own, which only that pull request can read.
- **Our packages are never cached:** every path containing `trafficctl` is
  left out on save and skipped on restore, so they are compiled from scratch
  each time.
- **Not cached:** a feed pinned to a tag rather than a commit (24.10's
  `base ...;v24.10.6`): `feeds update` runs `git pull` on an existing
  checkout, which fails on a detached tag, so that feed is cloned fresh and
  its packages rebuilt every run. A feed on a branch (23.05's `base`) is
  cached and pulled.
- **Still slow when warm:** the 25.12 SDK repackages all ~480 kmods on every
  `package/<pkg>/compile`, cached or not (~3 min per package).
- A run whose cache is broken can be made cold by deleting its entry:
  `gh cache list` / `gh cache delete <id>`.

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
3. Run `shellcheck` and `eslint`.
4. Submit PR with description of what and why.
