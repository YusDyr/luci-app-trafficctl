# Compatibility

This document covers OpenWrt version support, firewall backend feature parity, required packages, and known limitations.

---

## OpenWrt Version Matrix

| OpenWrt Version | Release Date | Firewall | Backend | Status |
|-----------------|-------------|----------|---------|--------|
| 23.05.x         | Oct 2023    | fw4      | nftables | Fully supported (primary target) |
| 22.03.x         | Sep 2022    | fw4      | nftables | Fully supported |
| 21.02.x         | Sep 2021    | fw3      | iptables | Supported (auto-detected) |
| 19.07.x         | Jan 2020    | fw3      | iptables | Not tested, may work |
| Snapshots        | Rolling     | fw4      | nftables | Supported |

### Key Differences by Version

| Feature | 21.02 (fw3) | 22.03+ (fw4) |
|---------|-------------|--------------|
| Network device config | `option ifname` | `option device` |
| Rate limiting | iptables hashlimit | nftables limit rate |
| Internet blocking | iptables FORWARD | nft inet fw4 forward |
| WAN detection | `network.wan.ifname` | `network.wan.device` |
| Flowtable flush on block | N/A | `nft flush flowtable inet fw4 ft` |
| Conntrack kill on block | Yes | Yes |

---

## Architecture Support

The package contains no compiled code (all shell scripts and JavaScript), so it runs on every architecture OpenWrt supports:

| Architecture | Tested | Notes |
|--------------|--------|-------|
| aarch64 (ARM64) | Yes | Most modern routers |
| arm_cortex-a7 | Yes | Common mid-range routers |
| mipsel_24kc | Yes | MediaTek MT7621 (common) |
| mips_24kc | Yes | Qualcomm Atheros |
| x86_64 | Yes | VM/PC-based routers |
| i386 | Not tested | Should work |
| riscv64 | Not tested | Should work |

---

## Required Packages

### Core (always required)

| Package | Purpose | Size |
|---------|---------|------|
| `conntrack` | Connection tracking CLI (`conntrack -L`) | ~15 KB |
| `kmod-nft-netdev` | nftables `netdev` family, which the limiter's table `netdev tm_ratelimit` needs (fw4). firewall4 does not pull it in. A declared dependency | ~10 KB |
| `luci-base` | LuCI framework (provides `view`, `fs`, rpcd) | (part of LuCI) |

### For Traffic Shaping (optional)

| Package | Purpose | Size |
|---------|---------|------|
| `tc-full` | Traffic control utility | ~180 KB |
| `kmod-sched-core` | Kernel scheduler framework | ~20 KB |
| `kmod-sched-htb` | HTB qdisc kernel module | ~15 KB |
| `kmod-ifb` | Intermediate device used to shape upload | ~5 KB |

If `tc` is not installed, the shaping feature gracefully degrades: the UI still works but shaper actions return an error message explaining what to install.

### For Reverse DNS

Reverse DNS uses `ubus call network.rrdns lookup` — the same built-in rpcd module that
the LuCI connections page uses. It is provided by `rpcd-mod-rrdns`, which ships with
`rpcd` on all modern OpenWrt builds and requires no separate install.

BusyBox `nslookup` (always available) is used as a fallback if rpcd-mod-rrdns is absent.

### For Interface Detection (optional)

| Package | Purpose | Notes |
|---------|---------|-------|
| `iw-full` | WiFi station dump, channel info | Shows WiFi band per device |

### For JSON Processing

| Package | Purpose | Notes |
|---------|---------|-------|
| `jsonfilter` | JSON parsing in hotplug | Part of OpenWrt base system |

---

## nftables vs iptables Feature Parity

| Feature | nftables (fw4) | iptables (fw3) | Notes |
|---------|---------------|----------------|-------|
| Internet blocking | Full | Full | |
| Block packet counters | Yes (nft counter) | Limited | iptables counters reset on rule changes |
| Rate limiting (policer) | `limit rate over N bytes/s` | `hashlimit` module | Slightly different semantics |
| Rate limit drop counters | Yes (nft counter) | Not easily accessible | |
| Traffic shaping (tc/HTB) | Full | Full | tc is firewall-independent |
| WiFi MAC filtering | Full | Full | Uses uci/hostapd, not firewall |
| Conntrack queries | Full | Full | Same `conntrack` binary |
| Flowtable bypass | `nft flush flowtable` on block | N/A | Ensures block takes effect immediately |

### Behavioral Differences

**Rate Limiting Semantics:**
- nftables: Uses `limit rate over X bytes/second` (X = kbit × 125) on netdev hooks: LAN egress for download, LAN ingress for upload. Operates at the packet level.
- iptables: Uses `-m hashlimit --hashlimit-above Xb/s --hashlimit-burst Yb` (X = kbit × 125, Y = 2X, capped at 4000000000) in the mangle FORWARD chain. Operates post-routing. The `-s` (upload) rule takes the upload ceiling when it differs from the download one. The highest ceiling hashlimit can express this way is about 30 Gbit/s.
- Until [#123](https://github.com/YusDyr/luci-app-trafficctl/pull/123) the iptables path wrote `--hashlimit-above Xkbit/sec --hashlimit-burst Xkbit`. iptables rejects that burst (checked on 1.8.7, the 21.02 series, and 1.8.10), and the error was discarded, so **no limit was installed on fw3** while the UI reported success. Port forward limits used a plain-number burst, which is accepted, but `Xkbit/sec` is a *packet* rate to hashlimit, so they policed X packets per second instead of X kbit/s. Re-apply port forward limits made on fw3 before that fix: until then the UI shows them as unlimited.

In practice, both achieve the same result (excess packets are dropped), but the measurement granularity differs slightly. nftables tends to be more accurate for bursty traffic.

**Block Rule Placement:**
- nftables: Rule inserted before the `ct state vmap` rule in `inet fw4 forward`, ensuring it catches traffic before connection tracking shortcuts it.
- iptables: Rule inserted at position 1 in the FORWARD chain (`iptables -I FORWARD`).

---

## Known Limitations

### General

1. **IPv6 is covered only where a rule can be keyed on a MAC** -- devices are identified by their IPv4 address, and most enforcement matches on that address. Covered for both families: the global internet cut (interface-matched), the WiFi block (MAC-matched), the per-device internet block (a second `meta nfproto ipv6 ether saddr <mac>` rule in `inet fw4 forward`) and both directions of rate limiting (upload: a second `meta protocol ip6 ether saddr <mac>` rule, since the limiter's chains are netdev, where nft rejects `nfproto`; download: `ip6 daddr` against a set of the client's addresses that its own MAC-matched frames fill, see [API.md](API.md#address-family-coverage-ipv6)). **Not covered**: tc/HTB shaping, port-forward pause/limit, and all byte accounting -- speed graphs, totals and the Prometheus counters understate a dual-stack device's usage. Matching `ip6 saddr` instead is not the fix: SLAAC privacy extensions rotate a client's addresses, so such a rule stops matching without warning. A client with no DHCP lease and no neighbour entry -- anything behind a downstream router -- has no MAC this router can see; its IPv4 rules still apply and the reply says *"IPv4 only"* rather than reporting unqualified success. A downstream router is excluded deliberately, because its MAC is the source of every packet it forwards. See [API.md](API.md#address-family-coverage-ipv6).

   On **fw3 / iptables (21.02)** nothing above applies: that path stays IPv4-only. A partial `ip6tables` implementation would be worse than a stated gap.

2. **Multiple LAN subnets** -- Device discovery is multi-bridge / multi-VLAN aware: all interfaces in non-WAN firewall zones are scanned (VPN/tunnel zones such as WireGuard/AmneziaWG are excluded because they are masqueraded). Devices on different subnets that share their last two octets (e.g. `192.168.0.5` and `10.0.0.5`) can be shaped at the same time: HTB class IDs are allocated per address and persisted, not derived from it (see [ARCHITECTURE.md](ARCHITECTURE.md#class-id-allocation)).

3. **DHCP lease dependency** -- Device names and MACs are resolved from `/tmp/dhcp.leases`. Devices with static IPs that bypass DHCP will show as IP addresses only.

4. **Upload shaping needs `kmod-ifb`** -- both directions are shaped. Download is handled by tc/HTB on the LAN bridge's egress; upload is shaped on an IFB device fed from LAN-side ingress, because a `match ip src` filter on the WAN side sees post-NAT addresses and would match nothing. That requires the `kmod-ifb` kernel module: without it the shaper falls back to download-only and says so, rather than reporting success while leaving upload unlimited.

5. **Rate limiter units** -- a ceiling in kbit/s is SI (1000 bits), as in the UI and in tc, and is written to nft as exact bytes/second (kbit × 125). nft's own `kbytes` is 1024 bytes, so limits set by earlier versions as `rate_kbit / 8 kbytes` police 2.4% above the ceiling (5000 kbit/s → 5120) and are reported at that real rate until re-applied; persisted limits are re-written in the new form on the next boot. nft lists a rate in its largest whole unit, stepping by 1024, and every reader converts it back with that factor.

### OpenWrt 21.02 Specific

The fw3 limiter needs `iptables-mod-hashlimit` (`opkg install iptables-mod-hashlimit`). It is not a declared dependency, because that would install iptables on fw4 routers too. Without it a rate limit is refused with `"ok":false` and a line in the system log.

6. **No flowtable flush** -- When blocking a device on fw3, existing established connections may continue until they time out naturally. On fw4, the flowtable is flushed to force immediate enforcement.

7. **No drop counters for rate limiter** -- The `trafficctl-ratelimit-stats.sh` script parses nft output. On iptables, drop counters are not exposed in the same format, so the "Dropped" column will always show "--".

### Traffic Shaping

8. **tc-full required** -- The `tc` binary from the `tc-full` package is required. The minimal `tc` from `iproute2` may lack HTB support.

9. **Bridge-only** -- Shaping assumes the LAN is bridged (`br-lan`). Routed LAN setups without a bridge will not work with the shaper.

10. **No per-interface shaping** -- All shaping happens on the single bridge device. Per-interface (e.g., per-SSID) shaping is not supported.

### WiFi MAC Filtering

11. **Both ACL modes supported** -- The package adapts to whichever `macfilter` policy each wifi-iface already uses and never changes it. On a `deny` (blacklist) radio, blocking adds the MAC to `maclist`; on an `allow` (whitelist) radio, blocking *removes* it, since there being listed is what grants access. Only when a radio has no `macfilter` set at all does the package create one, using `deny`. Mixed-mode setups are handled per radio: a device counts as wifi-blocked if it is blocked on any radio.

12. **WiFi deauth** -- MAC filter changes are applied via `hostapd_cli deny_acl` + `deauthenticate`. Only the target client is disconnected; other clients are unaffected. Disconnection is near-instant (no wifi reload). `hostapd-utils` is optional for the `trafficctl` backend (it cannot be selected on wired-only builds): without `hostapd_cli` a block is a temporary ubus ban, and on a router with no wifi-iface the WiFi block is not offered.

---

## Testing Checklist

Use this checklist when testing on a new OpenWrt version or backend:

### Basic Functionality

- [ ] Package installs without errors
- [ ] LuCI menu entry appears under Status
- [ ] Dashboard loads and shows active devices
- [ ] Device names resolve from DHCP leases
- [ ] Connection count matches `conntrack -L -s <IP> | wc -l`
- [ ] Auto-refresh works at all intervals (5s, 10s, 30s, 60s)

### Internet Blocking

- [ ] Block a device: traffic stops immediately
- [ ] Block counter increments in stats
- [ ] Unblock a device: traffic resumes
- [ ] Block status persists across page refreshes (not reboots)

### Rate Limiting (Policer)

- [ ] Apply rate limit: speed test shows throttled speed
- [ ] Remove rate limit: full speed restores
- [ ] Drop counter increments while limited
- [ ] Multiple devices can be limited simultaneously

### Traffic Shaping (Queue)

- [ ] tc-full installed check works
- [ ] Apply shaper: speed test shows shaped speed
- [ ] Backlog counter shows queued bytes under load
- [ ] Remove shaper: full speed restores
- [ ] Reboot router: shaper re-applies from shapes.json
- [ ] Multiple devices can be shaped simultaneously

### WiFi MAC Filtering

- [ ] Block device from WiFi: device disconnects
- [ ] Unblock device: device can reconnect
- [ ] Works on all radio interfaces (2.4 + 5 GHz)
- [ ] `uci show wireless` confirms maclist changes

### Live Counters (Dashboard)

- [ ] Download speed updates every 2 seconds
- [ ] Speed shows activity during file transfer
- [ ] Drop counters update every 5 seconds
- [ ] Backlog counters update every 5 seconds
- [ ] Counters stop updating when tab is hidden

### Reverse DNS

- [ ] Enable rDNS checkbox: hostnames resolve
- [ ] Non-resolvable IPs show "--"
- [ ] Private IPs are not looked up

### Backend Detection

- [ ] On 22.03+: verify nftables path is used (`nft list table netdev tm_ratelimit`)
- [ ] On 21.02: verify iptables path is used (`iptables -t mangle -L`)
