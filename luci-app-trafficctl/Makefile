include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-trafficctl
PKG_VERSION:=1.28.2
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Denis Iusupov <yusdyr@gmail.com>

LUCI_TITLE:=LuCI Traffic Control
LUCI_DESCRIPTION:=Per-device traffic monitoring, rate limiting (nft/iptables), \
 traffic shaping (tc/HTB), internet blocking, and WiFi MAC filtering.
# The backend (helper scripts, init scripts, hotplug hooks, the config and the
# metrics CGI) is its own package, ../trafficctl. What is left here is the
# view, its rpcd plugin, the ACL and the menu entry.
#
# The backend's runtime dependencies are repeated here although this package
# does not call them itself. Releases up to 1.28.x were one package that
# depended on them directly, and when that package is upgraded to this one in
# the same run that installs trafficctl, opkg sees conntrack, curl, iw and
# hostapd-utils lose their only installed dependent and removes them as
# orphans: it does not count trafficctl, which is unpacked but not yet
# configured. Measured on OpenWrt 24.10.6 with `opkg install trafficctl.ipk
# luci-app-trafficctl.ipk` and with `opkg upgrade` from a feed. Keeping them
# here costs nothing, since trafficctl needs them anyway.
LUCI_DEPENDS:=+trafficctl +conntrack +curl +tc +iw +hostapd-utils +luci-base +rpcd
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# rpcd only learns about a plugin when it starts, so without the restart below
# every ubus call lands on "Object not found" (-32000) and the dashboard is
# empty until the router is rebooted. build-ipk.sh and build-apk.sh have always
# done this in their own postinst; this Makefile did not, and the RELEASED
# packages are the ones built from here through the SDK — so the bug only ever
# reached the people installing the published artifacts.
#
# The LuCI index and module caches are dropped as well, as luci.mk's default
# postinst does, so a changed menu entry shows up without a re-login.
#
# Guarded on IPKG_INSTROOT: when it is set the package is being unpacked into
# an image being built, where there is no running rpcd to talk to.
#
# trafficctl-opkg.backup is the copy opkg makes of a modified
# /etc/config/trafficctl when this package, which owned it up to 1.28.x, is
# upgraded to one that no longer does. trafficctl's postinst removes it too,
# but when trafficctl was installed in an earlier run the copy only appears
# with this upgrade. The config itself is kept by trafficctl, so the copy is
# removed only while the real file is there.
#
# The config mode, the services and the cut release on removal belong to the
# backend and live in ../trafficctl/Makefile.
define Package/$(PKG_NAME)/postinst
#!/bin/sh
if [ -z "$${IPKG_INSTROOT}" ]; then
	if [ -f /etc/config/trafficctl ]; then
		rm -f /etc/config/trafficctl-opkg.backup
	fi
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache
	/etc/init.d/rpcd restart 2>/dev/null || true
fi
exit 0
endef

# No explicit $(eval $(call BuildPackage,...)) here: luci.mk already calls it
# for the main package, so the explicit call was a duplicate. Spotted by
# @ntbowen in #73.

# call BuildPackage - OpenWrt buildroot signature
