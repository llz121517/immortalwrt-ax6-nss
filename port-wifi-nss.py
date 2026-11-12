#!/usr/bin/env python3
"""Port NSS WiFi offload (ath11k NSS) support into an ImmortalWrt mac80211 package.

Phase 2 of the AX6 NSS project: takes the NSS patch series and the build hooks
from a qosmio/openwrt-ipq "main-nss" checkout and grafts the ath11k-specific
parts onto a vanilla ImmortalWrt tree.

    python3 port-wifi-nss.py <immortalwrt-tree> <qosmio-tree>

Idempotent: every edit is skipped when its result is already present.

What it does:
  1. copies patches/nss/{subsys,ath11k} (+ one ath10k patch) into the tree
  2. copies files/{qca-nss-pbuf.init,pbuf.uci,nss_diag.sh,disable_mesh_chksum_ath11k.hotplug}
  3. adds the NSS hooks to package/kernel/mac80211/Makefile
  4. adds ATH11K_NSS_SUPPORT + MEM_PROFILE + DEBUGFS knobs to package/kernel/mac80211/ath.mk

It deliberately does NOT copy the qosmio tree's other divergences (PKG_VERSION,
ath10k-sdio removal, qmi_helpers relocation, ...).
"""
import os
import shutil
import sys

# ---------------------------------------------------------------- helpers


def die(msg):
    print("ERROR: " + msg, file=sys.stderr)
    sys.exit(1)


def read(path):
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def apply_edits(path, edits, changed):
    """edits: list of (label, old, new). Skips when `new` is already present."""
    text = read(path)
    for label, old, new in edits:
        if new in text:
            print("  [--] %-32s already applied" % label)
            continue
        n = text.count(old)
        if n != 1:
            die("%s: anchor for '%s' matched %d times (expected 1)" % (os.path.basename(path), label, n))
        text = text.replace(old, new)
        print("  [ok] %-32s applied" % label)
        changed.append(label)
    write(path, text)


# ---------------------------------------------------------------- Makefile edits

MAKEFILE_EDITS = [
    (
        "PKG_CONFIG_DEPENDS",
        "\tCONFIG_PACKAGE_MAC80211_TRACING \\\n",
        "\tCONFIG_PACKAGE_MAC80211_TRACING \\\n"
        "\tCONFIG_PACKAGE_MAC80211_NSS_SUPPORT \\\n"
        "\tCONFIG_PACKAGE_MAC80211_NSS_REDIRECT \\\n",
    ),
    (
        "NSS_PATCH vars",
        "WMENU:=Wireless Drivers\n",
        "WMENU:=Wireless Drivers\n"
        "\n"
        "NSS_PATCH:= subsys ath10k ath11k\n"
        "IPQ_BRANCH:=$(shell git -C $(TOPDIR) rev-parse --abbrev-ref HEAD)\n"
        "IPQ_DATE:=$(shell git -C $(TOPDIR) log -1 --format=%cd --date=format:%Y-%m-%d)\n"
        "IPQ_COMMIT:=$(shell git -C $(TOPDIR) log -1 --format=%h)\n",
    ),
    (
        "mac80211 DEPENDS",
        "  DEPENDS+= +kmod-cfg80211 +kmod-crypto-cmac +kmod-crypto-ccm +kmod-crypto-gcm +hostapd-common\n",
        "  DEPENDS+= +kmod-cfg80211 +kmod-crypto-cmac +kmod-crypto-ccm +kmod-crypto-gcm +hostapd-common \\\n"
        "  +ATH11K_NSS_SUPPORT:kmod-qca-nss-drv\n",
    ),
    (
        "mac80211 AUTOLOAD",
        "  FILES:= $(PKG_BUILD_DIR)/net/mac80211/mac80211.ko\n"
        "  ABI_VERSION:=$(PKG_VERSION)-$(PKG_RELEASE)\n",
        "  FILES:= $(PKG_BUILD_DIR)/net/mac80211/mac80211.ko\n"
        "ifdef CONFIG_PACKAGE_MAC80211_NSS_REDIRECT\n"
        "  AUTOLOAD:=$(call AutoProbe, mac80211)\n"
        "  MODPARAMS.mac80211:=nss_redirect=1\n"
        "endif\n"
        "  ABI_VERSION:=$(PKG_VERSION)-$(PKG_RELEASE)\n",
    ),
    (
        "mac80211 NSS config",
        "define KernelPackage/mac80211/config\n"
        "  if PACKAGE_kmod-mac80211\n"
        "\n",
        "define KernelPackage/mac80211/config\n"
        "  if PACKAGE_kmod-mac80211\n"
        "\n"
        "\tif PACKAGE_kmod-qca-nss-drv\n"
        "\t\tconfig PACKAGE_MAC80211_NSS_SUPPORT\n"
        "\t\t\tbool \"Enable NSS support\"\n"
        "\t\t\tdefault y\n"
        "\t\t\thelp\n"
        "\t\t\t  This option enables support for NSS in QCA boards.\n"
        "\n"
        "\t\tconfig PACKAGE_MAC80211_NSS_REDIRECT\n"
        "\t\t\tbool \"Enable autoloading with 'nss_redirect=1' (not needed on ath11k)\"\n"
        "\t\t\tdepends on PACKAGE_MAC80211_NSS_SUPPORT\n"
        "\t\t\tdefault n\n"
        "\t\t\thelp\n"
        "\t\t\t  This option enables autoloading mac80211 with 'nss_redirect=1'.\n"
        "\tendif\n"
        "\n",
    ),
    (
        "NSS CFLAGS/config-y",
        "ifeq ($(BUILD_VARIANT),smallbuffers)\n"
        "\tC_DEFINES+= -DCONFIG_ATH10K_SMALLBUFFERS\n"
        "endif\n",
        "ifeq ($(BUILD_VARIANT),smallbuffers)\n"
        "\tC_DEFINES+= -DCONFIG_ATH10K_SMALLBUFFERS\n"
        "endif\n"
        "\n"
        "ifdef CONFIG_ATH11K_NSS_SUPPORT\n"
        "\tIREMAP_CFLAGS+= -I$(STAGING_DIR)/usr/include/qca-nss-drv -I$(STAGING_DIR)/usr/include/qca-nss-clients\n"
        "endif\n"
        "\n"
        "ifeq ($(CONFIG_NSS_FIRMWARE_VERSION_11_4),y)\n"
        "\tC_DEFINES+= -DCONFIG_NSS_FIRMWARE_VERSION_11_4\n"
        "endif\n"
        "\n"
        "config-$(CONFIG_PACKAGE_MAC80211_NSS_SUPPORT) += MAC80211_NSS_SUPPORT\n",
    ),
    (
        "Build/Patch nss",
        "\t$(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/rtl,rtl/)\n"
        "\t$(if $(QUILT),touch $(PKG_BUILD_DIR)/.quilt_used)\n",
        "\t$(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/rtl,rtl/)\n"
        "ifdef CONFIG_ATH11K_NSS_SUPPORT\n"
        "\t$(foreach driver,$(NSS_PATCH),\n"
        "\t\t$(call PatchDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/nss/$(driver),nss/$(driver)/)\n"
        "\t)\n"
        "endif\n"
        "\t$(if $(QUILT),touch $(PKG_BUILD_DIR)/.quilt_used)\n",
    ),
    (
        "Quilt/Refresh nss",
        "\t$(call Quilt/RefreshDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/rtl,rtl/)\n"
        "endef\n",
        "\t$(call Quilt/RefreshDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/rtl,rtl/)\n"
        "ifdef CONFIG_ATH11K_NSS_SUPPORT\n"
        "\t$(foreach driver,$(NSS_PATCH),\n"
        "\t\t$(call Quilt/RefreshDir,$(PKG_BUILD_DIR),$(PATCH_DIR)/nss/$(driver),nss/$(driver)/)\n"
        "\t)\n"
        "endif\n"
        "endef\n",
    ),
    (
        "KernelPackage/ath11k/install",
        "endef\n"
        "\n"
        "\n"
        "$(eval $(foreach drv,$(PKG_DRIVERS),$(call KernelPackage,$(drv))))\n",
        "endef\n"
        "\n"
        "ifdef CONFIG_ATH11K_NSS_SUPPORT\n"
        "define KernelPackage/ath11k/install\n"
        "\t$(INSTALL_DIR) $(1)/etc/init.d $(1)/etc/config $(1)/usr/bin $(1)/etc/hotplug.d/net\n"
        "\t$(INSTALL_BIN) ./files/qca-nss-pbuf.init $(1)/etc/init.d/qca-nss-pbuf\n"
        "\t$(INSTALL_DATA) ./files/pbuf.uci $(1)/etc/config/pbuf\n"
        "\t$(INSTALL_BIN) ./files/nss_diag.sh $(1)/usr/bin/nss_diag\n"
        "\t$(INSTALL_DATA) ./files/disable_mesh_chksum_ath11k.hotplug $(1)/etc/hotplug.d/net/99-disable_mesh_chksum_ath11k\n"
        "\techo \"IPQ_BRANCH=$(IPQ_BRANCH)\" > $(1)/etc/ipq_release\n"
        "\techo \"IPQ_DATE=$(IPQ_DATE)\" >> $(1)/etc/ipq_release\n"
        "\techo \"IPQ_COMMIT=$(IPQ_COMMIT)\" >> $(1)/etc/ipq_release\n"
        "endef\n"
        "endif\n"
        "\n"
        "$(eval $(foreach drv,$(PKG_DRIVERS),$(call KernelPackage,$(drv))))\n",
    ),
]

# ---------------------------------------------------------------- ath.mk edits

DEPENDS_OLD = (
    "  DEPENDS+= +kmod-ath +@DRIVER_11AC_SUPPORT +@DRIVER_11AX_SUPPORT \\\n"
    "  +kmod-crypto-michael-mic +ATH11K_THERMAL:kmod-hwmon-core \\\n"
    "  +ATH11K_THERMAL:kmod-thermal +kmod-qcom-qmi-helpers\n"
    "  FILES:=$(PKG_BUILD_DIR)/drivers/net/wireless/ath/ath11k/ath11k.ko\n"
)
DEPENDS_NEW = (
    "  DEPENDS+= +kmod-ath +@DRIVER_11AC_SUPPORT +@DRIVER_11AX_SUPPORT \\\n"
    "  +kmod-crypto-michael-mic +ATH11K_THERMAL:kmod-hwmon-core \\\n"
    "  +ATH11K_THERMAL:kmod-thermal +kmod-qcom-qmi-helpers \\\n"
    "  +ATH11K_NSS_SUPPORT:kmod-qca-nss-drv \\\n"
    "  +ATH11K_NSS_MESH_SUPPORT:kmod-qca-nss-drv-wifi-meshmgr \\\n"
    "  +@(ATH11K_NSS_SUPPORT):NSS_DRV_WIFIOFFLOAD_ENABLE \\\n"
    "  +@(ATH11K_NSS_SUPPORT):NSS_DRV_WIFI_EXT_VDEV_ENABLE\n"
    "  FILES:=$(PKG_BUILD_DIR)/drivers/net/wireless/ath/ath11k/ath11k.ko\n"
    "ifdef CONFIG_ATH11K_NSS_SUPPORT\n"
    "  AUTOLOAD:=$(call AutoProbe,ath11k)\n"
    "  MODPARAMS.ath11k:=nss_offload=1 frame_mode=2\n"
    "endif\n"
)

ATHMK_EDITS = [
    (
        "PKG_CONFIG_DEPENDS",
        "\tCONFIG_ATH12K_THERMAL \\\n"
        "\tCONFIG_ATH_USER_REGD\n",
        "\tCONFIG_ATH12K_THERMAL \\\n"
        "\tCONFIG_ATH_USER_REGD \\\n"
        "\tCONFIG_ATH11K_DEBUGFS_STA \\\n"
        "\tCONFIG_ATH11K_DEBUGFS_HTT_STATS \\\n"
        "\tCONFIG_ATH11K_MEM_PROFILE_1G \\\n"
        "\tCONFIG_ATH11K_MEM_PROFILE_512M \\\n"
        "\tCONFIG_ATH11K_MEM_PROFILE_256M \\\n"
        "\tCONFIG_ATH11K_NSS_SUPPORT \\\n"
        "\tCONFIG_ATH11K_NSS_MESH_SUPPORT\n",
    ),
    (
        "config-y NSS lines",
        "config-$(CONFIG_ATH12K_THERMAL) += ATH12K_THERMAL\n",
        "config-$(CONFIG_ATH12K_THERMAL) += ATH12K_THERMAL\n"
        "config-$(CONFIG_ATH11K_MEM_PROFILE_1G) += ATH11K_MEM_PROFILE_1G\n"
        "config-$(CONFIG_ATH11K_MEM_PROFILE_512M) += ATH11K_MEM_PROFILE_512M\n"
        "config-$(CONFIG_ATH11K_MEM_PROFILE_256M) += ATH11K_MEM_PROFILE_256M\n"
        "config-$(CONFIG_ATH11K_NSS_SUPPORT) += ATH11K_NSS_SUPPORT\n"
        "config-$(CONFIG_ATH11K_NSS_MESH_SUPPORT) += ATH11K_NSS_MESH_SUPPORT\n"
        "config-$(CONFIG_ATH11K_DEBUGFS_STA) += ATH11K_DEBUGFS_STA\n"
        "config-$(CONFIG_ATH11K_DEBUGFS_HTT_STATS) += ATH11K_DEBUGFS_HTT_STATS\n",
    ),
    ("ath11k DEPENDS/MODPARAMS", DEPENDS_OLD, DEPENDS_NEW),
    (
        "ath11k conffiles",
        "define KernelPackage/ath11k/description\n"
        "This module adds support for Qualcomm Technologies 802.11ax family of\n"
        "chipsets.\n"
        "endef\n",
        "define KernelPackage/ath11k/description\n"
        "This module adds support for Qualcomm Technologies 802.11ax family of\n"
        "chipsets.\n"
        "endef\n"
        "\n"
        "define KernelPackage/ath11k/conffiles\n"
        "/etc/config/pbuf\n"
        "endef\n",
    ),
    (
        "ath11k NSS config",
        "define KernelPackage/ath11k/config\n"
        "\n"
        "       config ATH11K_THERMAL\n"
        "               bool \"Enable thermal sensors and throttling support\"\n"
        "               depends on PACKAGE_kmod-ath11k\n"
        "               default y if TARGET_qualcommax\n"
        "\n"
        "endef\n",
        "define KernelPackage/ath11k/config\n"
        "\n"
        "       config ATH11K_THERMAL\n"
        "               bool \"Enable thermal sensors and throttling support\"\n"
        "               depends on PACKAGE_kmod-ath11k\n"
        "               default y if TARGET_qualcommax\n"
        "\n"
        "       config ATH11K_DEBUGFS_STA\n"
        "               bool \"Enable ath11k station statistics\"\n"
        "               depends on PACKAGE_kmod-ath11k\n"
        "               depends on PACKAGE_MAC80211_DEBUGFS\n"
        "               default y\n"
        "               help\n"
        "                  Say Y to enable access to the station statistics via debugfs.\n"
        "\n"
        "       config ATH11K_DEBUGFS_HTT_STATS\n"
        "               bool \"Enable ath11k HTT statistics\"\n"
        "               depends on PACKAGE_kmod-ath11k\n"
        "               depends on PACKAGE_MAC80211_DEBUGFS\n"
        "               default y\n"
        "               help\n"
        "                  Say Y to enable access to the HTT statistics via debugfs.\n"
        "\n"
        "       config ATH11K_NSS_SUPPORT\n"
        "               bool \"Enable NSS WiFi offload\"\n"
        "               select ATH11K_MEM_PROFILE_1G if (TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6-stock || \\\n"
        "               	 TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6)\n"
        "               select ATH11K_MEM_PROFILE_512M if (TARGET_qualcommax_ipq807x_DEVICE_edimax_cax1800 || \\\n"
        "               	 TARGET_qualcommax_ipq807x_DEVICE_compex_wpq873 || \\\n"
        "               	 TARGET_qualcommax_ipq807x_DEVICE_linksys_mx4200v1 || \\\n"
        "               	 TARGET_qualcommax_ipq807x_DEVICE_xiaomi_ax3600 || \\\n"
        "               	 TARGET_qualcommax_ipq807x_DEVICE_zte_mf269)\n"
        "               select ATH11K_MEM_PROFILE_256M if TARGET_qualcommax_ipq807x_DEVICE_netgear_wax218\n"
        "               select PACKAGE_kmod-qca-nss-ecm\n"
        "               default y\n"
        "               help\n"
        "                  Say Y to enable NSS WiFi offload support. Requires the NSS feeds.\n"
        "\n"
        "       config ATH11K_NSS_MESH_SUPPORT\n"
        "               bool \"Enable NSS WiFi Mesh offload\"\n"
        "               depends on ATH11K_NSS_SUPPORT\n"
        "               select PACKAGE_MAC80211_MESH\n"
        "               select NSS_FIRMWARE_VERSION_11_4\n"
        "               default n\n"
        "\n"
        "       choice\n"
        "            prompt \"Memory Profile\"\n"
        "            depends on PACKAGE_kmod-ath11k\n"
        "            default ATH11K_MEM_PROFILE_1G\n"
        "            help\n"
        "            	This option allows you to select the memory profile.\n"
        "            	It should correspond to the total RAM of your board.\n"
        "\n"
        "          config ATH11K_MEM_PROFILE_1G\n"
        "               bool \"Use 1G memory profile\"\n"
        "               help\n"
        "                  This allows configuring ath11k for boards with 1GB+ memory.\n"
        "\n"
        "          config ATH11K_MEM_PROFILE_512M\n"
        "               bool \"Use 512MB memory profile\"\n"
        "               help\n"
        "                  This allows configuring ath11k for boards with 512M memory.\n"
        "\n"
        "          config ATH11K_MEM_PROFILE_256M\n"
        "               bool \"Use 256MB memory profile\"\n"
        "               help\n"
        "                  This allows configuring ath11k for boards with 256M memory.\n"
        "       endchoice\n"
        "endef\n",
    ),
]

NSS_FILES = [
    "qca-nss-pbuf.init",
    "pbuf.uci",
    "nss_diag.sh",
    "disable_mesh_chksum_ath11k.hotplug",
]
KEEP_ATH10K = ["100-ath10k-move-peer-unmap-warning-to-debug.patch"]


def main():
    if len(sys.argv) != 3:
        die("usage: %s <immortalwrt-tree> <qosmio-tree>" % sys.argv[0])
    iw, q = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
    mac = os.path.join(iw, "package/kernel/mac80211")
    qmac = os.path.join(q, "package/kernel/mac80211")
    if not os.path.isdir(mac):
        die("%s is not an ImmortalWrt tree (no package/kernel/mac80211)" % iw)
    if not os.path.isdir(os.path.join(qmac, "patches/nss")):
        die("%s has no package/kernel/mac80211/patches/nss" % q)

    # 1. patches
    for sub in ("subsys", "ath11k", "ath10k"):
        src = os.path.join(qmac, "patches/nss", sub)
        dst = os.path.join(mac, "patches/nss", sub)
        os.makedirs(dst, exist_ok=True)
        names = sorted(os.listdir(src))
        if sub == "ath10k":
            names = [n for n in names if n in KEEP_ATH10K]
        for n in names:
            shutil.copy2(os.path.join(src, n), os.path.join(dst, n))
        print("  [ok] patches/nss/%-7s %3d file(s)" % (sub, len(names)))

    # 2. files
    os.makedirs(os.path.join(mac, "files"), exist_ok=True)
    for n in NSS_FILES:
        shutil.copy2(os.path.join(qmac, "files", n), os.path.join(mac, "files", n))
    print("  [ok] files/             %3d file(s)" % len(NSS_FILES))

    # 3/4. build hooks
    print("Makefile:")
    changed = []
    apply_edits(os.path.join(mac, "Makefile"), MAKEFILE_EDITS, changed)
    print("ath.mk:")
    apply_edits(os.path.join(mac, "ath.mk"), ATHMK_EDITS, changed)
    print("\n%d edit(s) applied this run" % len(changed))


if __name__ == "__main__":
    main()
