---
name: Bug report
about: Something does not work on your router
labels: bug
---

## What happened

## What you expected instead

## Router

- OpenWrt version (`cat /etc/openwrt_release | grep DESCRIPTION`):
- Device / architecture:
- Package version (`opkg list-installed | grep trafficctl` or `apk info luci-app-trafficctl`):
- Firewall backend (`nft --version`):

## Reproduction

1.
2.

## Diagnostics

Run the affected command by hand over SSH and paste its output — every command
prints JSON, and the message usually names the missing piece (a kernel module, a
device that could not be resolved). For example:

```sh
/usr/sbin/trafficctl shape status 192.168.1.50
/usr/sbin/trafficctl summary | head -c 2000
logread | grep trafficctl | tail -30
```

If the problem is in the web UI, the browser console output matters more than a
screenshot.

Please redact MAC addresses, public IPs and your Telegram bot token.
