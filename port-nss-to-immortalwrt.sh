#!/bin/bash
# port-nss-to-immortalwrt.sh -- graft the Qualcomm NSS/ECM offload stack onto an
# ImmortalWrt 25.12 (kernel 6.12) qualcommax tree, and add a redmi_ax6-stock
# profile for a Redmi AX6 that kept Xiaomi's SMEM partition layout.
#
# Usage:
#   ./port-nss-to-immortalwrt.sh /path/to/immortalwrt [/path/to/nss-packages] [/path/to/qosmio-openwrt-ipq]
#
# What it does, in order:
#   1. add qosmio's NSS tree (qca-nss-drv/-ecm/-clients + firmware) as a feed
#   2. install the NSS/ECM kernel patches (net-core hooks) into the target
#   3. add ipq8074-nss.dtsi and wire it into ipq8071-ax3600.dtsi
#   4. add the redmi_ax6-stock profile (SMEM layout, root=/dev/ubiblock0_1)
#   5. patch platform.sh: the stock-layout branch is written for Xiaomi's A/B
#      U-Boot and reads flag_boot_rootfs, which this board does not have --
#      replace it with the single-volume sequence
#   6. add the NSS packages to DEFAULT_PACKAGES and enable hw offload in the
#      firewall defaults
#
# Verified facts this script is built on (measured on the target, 2026-11-11):
#   - board_name            redmi,ax6-stock
#   - NAND partitions       qcom,smem-part (bootloader-supplied), no rootfs_1
#   - UBI volumes           0 kernel, 1 rootfs, 2 rootfs_data
#   - /dev/ubiblock0_1      the only ubiblock present -> root= must be _1
#   - U-Boot env            25 vars, only flag_boot_success=1; none of
#                           flag_boot_rootfs / flag_last_success / flag_try_*
#   - U-Boot                HTTP recovery server at 192.168.1.1 (safety net)
#
# Everything is idempotent.

set -euo pipefail

IW="${1:-}"
NSS="${2:-}"
QS="${3:-}"

if [ -z "$IW" ] || [ ! -d "$IW/target/linux/qualcommax" ]; then
	echo "usage: $0 /path/to/immortalwrt [nss-packages] [qosmio-openwrt-ipq]" >&2
	exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
QC="$IW/target/linux/qualcommax"
DTS_DIR="$QC/files/arch/arm64/boot/dts/qcom"
PLATFORM="$QC/ipq807x/base-files/lib/upgrade/platform.sh"
MAKEFILE="$QC/Makefile"

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()  { printf '   [ok] %s\n' "$*"; }
skip(){ printf '   [--] %s\n' "$*"; }

# Git Bash on Windows usually provides `python` but not `python3`; the
# WindowsApps python3 is a Store stub that exits 49 without doing anything,
# so probe that each candidate actually runs.
PY=""
for cand in python3 python; do
	if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import sys' >/dev/null 2>&1; then
		PY="$cand"; break
	fi
done
[ -n "$PY" ] || { echo "ERROR: a working python is required" >&2; exit 1; }

# ---------------------------------------------------------------------------
say "1/6 NSS package feed"
# ---------------------------------------------------------------------------
FEEDS="$IW/feeds.conf"
[ -f "$FEEDS" ] || FEEDS="$IW/feeds.conf.default"
[ -f "$FEEDS" ] || { echo "ERROR: no feeds.conf in $IW" >&2; exit 1; }

if grep -q 'nss_packages' "$FEEDS"; then
	skip "nss feed already in $(basename "$FEEDS")"
else
	printf 'src-git nss_packages https://github.com/qosmio/nss-packages.git;NSS-12.5-K6.x\n' >> "$FEEDS"
	ok "added nss_packages feed (NSS-12.5-K6.x, has 0026-...-kernel-6.12.patch)"
fi

# ---------------------------------------------------------------------------
say "2/6 NSS/ECM kernel patches"
# ---------------------------------------------------------------------------
# These add the hooks into the kernel's net stack that ECM needs in order to
# steer flows into the NSS cores. All eleven of them were verified to apply
# cleanly, in this order, onto upstream linux-6.12.116 (the version this
# ImmortalWrt branch uses) after ImmortalWrt's own 0102 patch.
#
# Not included on purpose (they do not apply / are not needed on 6.12.116):
#   0600-8-net-disable-fraglist-GRO-by-default.patch
#       upstream 6.12.116 already has NETIF_F_SOFT_FEATURES_OFF =
#       (NETIF_F_GRO_FRAGLIST | NETIF_F_GRO_UDP_FWD), which is what the patch
#       produces; applying it fails on that hunk and changes nothing.
#   0600-4-qca-nss-ecm-support-net-bonding-over-LAG-interface.patch
#       is NOT copied verbatim -- its changes are merged into the rebased
#       0600-3 patch below.  Reason: qca-nss-ecm's bond notifier and
#       qca-nss-clients' bridge/vlan mgr call bond_register_cb(),
#       struct bond_cb and bond_get_id(), which only exist after 0600-4.
#       0600-4 on its own needs fuzz 2-3 (offsets up to 119 lines) against
#       6.12.116 and one hunk lands in the wrong function when fuzzed, so
#       patches/0600-3-...-rebased.patch is a pristine->final diff of the
#       four net/bonding files that also drops 0600-4's last two hunks
#       (the LAG start_xmit fast paths -- we do not use link aggregation).
#       Verified with `patch -p1 --dry-run` against linux-6.12.116.
#   0603-5-qca-nss-clients-add-vxlan-support.patch
#       hunk 5 of 6 fails against 6.12.116's drivers/net/vxlan/vxlan_core.c;
#       kmod-vxlan is not enabled here, so ECM's VXLAN interface path is not
#       compiled either.
#   0607-2-qca-nss-clients-add-ipsec-support.patch
#       hunk 4 of 5 fails against net/xfrm/xfrm_state.c; kmod-ipsec is not
#       enabled, so ECM's IPSec interface path is not compiled.
#
# Everything else in qosmio's 06xx series IS included, because qca-nss-ecm
# references those kernel APIs unconditionally from its own sources even when
# the matching feature flag is off -- e.g. ecm_interface.c calls
# pptp_session_find() / pppol2tp_channel_addressing_get() / __ppp_hold_channels()
# no matter what, so the 0603-2 (L2TP) and 0603-3 (PPTP) patches are build
# requirements, not optional features:
#   fatal error: implicit declaration of function '__ppp_is_multilink'
#   error: storage size of 'info' isn't known
#
# 0600-6 is NOT optional either: nss-packages/qca-nss-ecm/Makefile hard-codes
#   KCONFIG:=CONFIG_NF_CONNTRACK_DSCPREMARK_EXT=y, and ECM's
#   frontends/ecm_front_end_common.c includes
#   <net/netfilter/nf_conntrack_dscpremark_ext.h> whenever
#   ECM_CLASSIFIER_DSCP_ENABLE=y (which the package also sets). Without this
#   patch the build dies with "fatal error: nf_conntrack_dscpremark_ext.h: No
#   such file or directory". The patch only wires Kconfig/Makefile/extend
#   hooks, so the two source files under qualcommax/files/ below have to be
#   dropped into the kernel tree as well -- that is what the second half of
#   this step does.
# 0600-7 rides along: it fixes ECM's IPv6 user route change event calls, which
#   otherwise leave stale offload entries after IPv6 route churn.
# 0981-1 adds the skb recycler that qca-nss-drv drives (see step 2b).
# Every patch below is vendored in this repo, so the qosmio tree is optional
# here: it is only consulted as a fallback when the repo copy is missing.
FAIL=0
PATCHES=(
	0600-0-arm64-dts-ipq8074-rename-nss-region.patch
	0600-1-qca-nss-ecm-support-CORE.patch
	0600-2-qca-nss-ecm-support-PPPOE-offload.patch
	0600-3-qca-nss-ecm-support-bonding-rebased.patch
	0600-5-qca-nss-ecm-support-macvlan.patch
	0600-6-qca-nss-ecm-support-netfilter-DSCPREMARK.patch
	0600-7-qca-nss-ecm-fix-IPv6-user-route-change-event-calls.patch
	0602-1-qca-nss-drv-add-qdisc-support.patch
	0603-1-qca-nss-clients-add-qdisc-support.patch
	0603-2-qca-nss-clients-add-l2tp-support.patch
	0603-3-qca-nss-clients-add-PPTP-support.patch
	0603-4-qca-nss-clients-add-iptunnel-support.patch
	0603-6-qca-nss-clients-add-bridge-mgr-support.patch
	0603-7-qca-nss-clients-iptunnel-lock-this-cpu.patch
	0603-8-qca-nss-clients-add-tls-mgr-support.patch
	0604-1-qca-add-mcs-support.patch
	0605-1-qca-nss-cfi-support.patch
	0606-1-qca-nss-ecm-bridge-Fixes-for-Bridge-VLAN-Filtering.patch
	0607-1-qca-nss-clients-iptunnel-fixes.patch
	0981-1-qca-skb_recycler-support.patch
)
installed=0
for p in "${PATCHES[@]}"; do
	# Prefer the copy shipped in this repo: it may carry a locally
	# rebased hunk (0981-1's last hunk needs extra context lines that
	# 6.12.116 has and qosmio's 6.12 snapshot did not).
	s="$SRC/patches/$p"
	if [ ! -f "$s" ] && [ -n "$QS" ]; then
		s="$QS/target/linux/qualcommax/patches-6.12/$p"
	fi
	if [ ! -f "$s" ]; then
		printf '   [!!] missing source patch %s\n' "$p"
		FAIL=1
		continue
	fi
	if [ -f "$QC/patches-6.12/$p" ]; then
		skip "$p already present"
		continue
	fi
	cp "$s" "$QC/patches-6.12/$p"
	installed=$((installed + 1))
	ok "$p"
done
printf '   installed %d kernel patches\n' "$installed"

# 0600-6 only patches Kconfig/Makefile/extend registration; the actual
# netfilter DSCP-remark extension lives in two plain source files that
# OpenWrt copies into the kernel tree from target/linux/<target>/files/.
# Miss them and qca-nss-ecm cannot compile.
# 0981-1 does the same thing for the skb recycler: net/core/skbuff.c gets
# `#include "skbuff_recycle.h"` and net/core/Makefile gets
# `obj-$(CONFIG_SKB_RECYCLER) += skbuff_recycle.o`, but the implementation
# is not in the patch.  Without these two files the kernel dies with
#   net/core/skbuff.c:95:10: fatal error: skbuff_recycle.h: No such file
#   or directory
for kf in \
	include/net/netfilter/nf_conntrack_dscpremark_ext.h \
	net/netfilter/nf_conntrack_dscpremark_ext.c \
	net/core/skbuff_recycle.c \
	net/core/skbuff_recycle.h \
	net/core/skbuff_debug.c \
	net/core/skbuff_debug.h \
	net/core/skbuff_notifier.c \
	net/core/skbuff_notifier.h
do
	dst="$QC/files/$kf"
	if [ -f "$dst" ]; then
		skip "$kf already present"
		continue
	fi
	src="$QS/target/linux/qualcommax/files/$kf"
	if [ ! -f "$src" ]; then
		src="$SRC/files/$(basename "$kf")"
	fi
	if [ -f "$src" ]; then
		mkdir -p "$(dirname "$dst")"
		cp "$src" "$dst"
		ok "kernel file $kf"
	else
		printf '   [!!] missing kernel file %s -- qca-nss-ecm will NOT build\n' "$kf"
		FAIL=1
	fi
done

# ---------------------------------------------------------------------------
say "2b/6 kernel knobs: skb recycler + fullconet conflict"
# ---------------------------------------------------------------------------
# qca-nss-drv drives the skb recycler added by 0981-1; the symbols are not in
# ImmortalWrt's qualcommax config, so the module would otherwise never build.
CFG="$QC/config-6.12"
# SKB_RECYCLER_PREALLOC / SKB_RECYCLE_MAX_PREALLOC_SKBS / SKB_RECYCLE_SIZE /
# ALLOC_SKB_PAGE_FRAG_DISABLE are introduced by the same patch.  They have to be
# listed explicitly: with SKB_RECYCLER_PREALLOC absent, the kernel's
# `make syncconfig` treats it as a brand-new symbol, prints "(NEW)" and aborts
# with "scripts/kconfig/Makefile:85: syncconfig Error 1".  Preallocation is
# left off because its default of 16384 skb x 4 KiB = 64 MiB is too much for a
# 1 GiB router; recycling itself is what NSS needs.
for kv in \
	"CONFIG_SKB_RECYCLER=y" \
	"CONFIG_SKB_RECYCLER_MULTI_CPU=y" \
	"# CONFIG_SKB_RECYCLER_PREALLOC is not set" \
	"CONFIG_SKB_RECYCLE_SIZE=2304" \
	"# CONFIG_ALLOC_SKB_PAGE_FRAG_DISABLE is not set"
do
	sym="${kv%%=*}"; sym="${sym#\# }"; sym="${sym%% *}"
	if grep -q "^$sym=\|^# $sym is not set" "$CFG" 2>/dev/null; then
		skip "$sym already present"
	else
		printf '%s\n' "$kv" >> "$CFG"
		ok "$kv"
	fi
done

# ImmortalWrt's firewall4 hard-depends on kmod-nft-fullcone, whose Makefile
# sets KCONFIG:=CONFIG_NF_CONNTRACK_CHAIN_EVENTS=y.  That flips
# nf_conntrack_register_notifier() from the nf_ct_event_notifier API (what ECM
# is written against) to the notifier_block one, and ECM stops compiling:
#   ecm_conntrack_notifier.c:438: error: passing argument 2 of
#     'nf_conntrack_register_notifier' from incompatible pointer type
#   ecm_conntrack_notifier.c:484: error: too few arguments to function
#     'nf_conntrack_unregister_notifier'
# With NSS doing the offload, the software fullcone implementation is
# redundant anyway, so drop the dependency and keep the API ECM expects.
FW4="$IW/package/network/config/firewall4/Makefile"
if [ -f "$FW4" ] && grep -q 'kmod-nft-fullcone' "$FW4"; then
	sed -i 's/ +kmod-nft-fullcone //' "$FW4"
	ok "firewall4: dropped +kmod-nft-fullcone dependency"
else
	skip "firewall4 has no kmod-nft-fullcone dependency"
fi

# ---------------------------------------------------------------------------
say "3/6 NSS device tree"
# ---------------------------------------------------------------------------
install_nss_dtsi() {
	local name="$1"
	if [ -f "$DTS_DIR/$name" ]; then
		skip "$name already present"
		return
	fi
	if [ -n "$QS" ]; then
		local s
		s="$(find "$QS" -name "$name" -print -quit 2>/dev/null || true)"
		if [ -n "$s" ]; then
			cp "$s" "$DTS_DIR/$name"
			ok "$name (from qosmio tree)"
			return
		fi
	fi
	if [ -f "$SRC/files/$name" ]; then
		cp "$SRC/files/$name" "$DTS_DIR/$name"
		ok "$name (from bundled copy)"
		return
	fi
	printf '   [!!] cannot find %s\n' "$name"
	FAIL=1
}

install_nss_dtsi ipq8074-nss.dtsi
install_nss_dtsi ipq6018-nss.dtsi
install_nss_dtsi ipq5018-nss.dtsi

# wire it into the AX3600/AX6 base dtsi -- this is the only line that differs
# between ImmortalWrt's and qosmio's copy of ipq8071-ax3600.dtsi
BASE="$DTS_DIR/ipq8071-ax3600.dtsi"
if grep -q 'ipq8074-nss\.dtsi' "$BASE"; then
	skip "ipq8071-ax3600.dtsi already includes ipq8074-nss.dtsi"
else
	sed -i 's|^\(#include "ipq8074-ess\.dtsi"\)$|\1\n#include "ipq8074-nss.dtsi"|' "$BASE"
	ok "ipq8071-ax3600.dtsi += #include \"ipq8074-nss.dtsi\""
fi

# ---------------------------------------------------------------------------
say "4/6 redmi_ax6-stock profile"
# ---------------------------------------------------------------------------
# The stock DTS already exists in ImmortalWrt, but inherited from
# ipq8071-ax6.dts it carries bootargs root=/dev/ubiblock0_0 (the custom-U-Boot
# volume numbering). On this board rootfs is volume 1, so it must be _1.
# ImmortalWrt's own ipq8071-ax6-stock.dts is already correct for this board:
#   - bootargs root=/dev/ubiblock0_1  (overrides the _0 inherited from ax3600.dtsi)
#   - &qpic_nand partitions { compatible = "qcom,smem-part"; }
#   - nvmem cells dropped from dp2..dp5 (no ART offsets in the SMEM layout)
# So only verify it rather than rewrite it.
STOCK_DTS="$DTS_DIR/ipq8071-ax6-stock.dts"
if [ -f "$STOCK_DTS" ]; then
	if grep -q 'ubiblock0_1' "$STOCK_DTS" && grep -q 'smem-part' "$STOCK_DTS"; then
		ok "ipq8071-ax6-stock.dts is correct (ubiblock0_1 + smem-part)"
	else
		printf '   [!!] %s exists but is not the stock-layout version; check it by hand\n' "$STOCK_DTS"
		FAIL=1
	fi
else
	printf '   [!!] %s missing -- this ImmortalWrt branch is too old for the stock layout\n' "$STOCK_DTS"
	FAIL=1
fi

MK="$QC/image/ipq807x.mk"
if grep -q '^define Device/redmi_ax6-stock' "$MK"; then
	skip "redmi_ax6-stock profile already defined"
else
	grep -q '^TARGET_DEVICES += redmi_ax6$' "$MK" || {
		echo "ERROR: 'TARGET_DEVICES += redmi_ax6' not found in $MK" >&2; exit 1; }
	"$PY" - "$MK" <<'PY'
import sys
path = sys.argv[1]
anchor = "TARGET_DEVICES += redmi_ax6\n"
block = """
define Device/redmi_ax6-stock
\t$(call Device/redmi_ax6)
\tDEVICE_PACKAGES += kmod-qca-nss-dp kmod-qca-nss-drv kmod-qca-nss-ecm \\
\t\tkmod-qca-nss-drv-bridge-mgr kmod-qca-nss-vlan
\tDEVICE_VARIANT := (stock layout)
\tDEVICE_ALT0_VENDOR := Redmi
\tDEVICE_ALT0_MODEL := AX6
\tDEVICE_ALT0_VARIANT := (custom U-Boot layout)
\tKERNEL_SIZE :=
\tARTIFACTS :=
endef
TARGET_DEVICES += redmi_ax6-stock
"""
with open(path, encoding="utf-8") as fh:
    text = fh.read()
if "define Device/redmi_ax6-stock" not in text:
    i = text.find(anchor)
    if i < 0:
        sys.exit("anchor not found")
    e = i + len(anchor)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text[:e] + block.lstrip("\n") + text[e:])
PY
	ok "added redmi_ax6-stock to image/ipq807x.mk"
fi

# ---------------------------------------------------------------------------
say "5/6 platform.sh: single-volume upgrade for the stock layout"
# ---------------------------------------------------------------------------
# ImmortalWrt's redmi,ax6-stock branch assumes Xiaomi's A/B U-Boot: it reads
# flag_boot_rootfs and switches between rootfs/rootfs_1. This board has
# neither the variables nor the second partition, and `[ "" -eq "1" ]` errors
# out ("out of range"), so an upgrade would abort. Replace the branch body
# with the single-volume sequence, keeping everything else untouched.
if grep -q 'redmi,ax6-stock' "$PLATFORM"; then
	"$PY" "$SRC/patch-platform-sh.py" "$PLATFORM"
else
	printf '   [!!] no redmi,ax6-stock arm in %s -- check the tree\n' "$PLATFORM"
	FAIL=1
fi
# A trailing \\ instead of \ makes the shell treat it as a literal backslash:
# the case pattern breaks at the newline and sourcing the file dies with
# "syntax error: unexpected newline (expecting ")")". sysupgrade then aborts
# before writing anything, so the device can never be upgraded again.
if [ -f "$PLATFORM" ] && ! sh -n "$PLATFORM" 2>/dev/null; then
	printf '   [!!] %s has a syntax error, sysupgrade would abort:\n' "$PLATFORM"
	sh -n "$PLATFORM" 2>&1 | head -3
	FAIL=1
fi

# ---------------------------------------------------------------------------
say "6/6 NSS in DEFAULT_PACKAGES and hardware offload on by default"
# ---------------------------------------------------------------------------
# NSS kmods are added to Device/redmi_ax6-stock's DEVICE_PACKAGES above, not
# to qualcommax's DEFAULT_PACKAGES: target-wide injection would pull ~2.5 MB of
# NSS kmods into every other ipq807x image, none of which has NSS nodes.

# nft flow offloading must stay OFF on NSS builds.
# fw4's software flowtable (`meta l4proto { tcp, udp } flow add @ft`) grabs
# established flows before ECM's conntrack hook sees the return direction, so
# ecm_classifier_default denies acceleration forever (accelerated_count == 0).
# With both firewalld offload switches at 0, qca-nss-ecm owns the whole fast
# path and verified acceleration works (accel_mode=2, accelerated_count > 0).
FW_DEFAULTS="$QC/ipq807x/base-files/etc/uci-defaults"
mkdir -p "$FW_DEFAULTS"
cat > "$FW_DEFAULTS/99-nss-offload" <<'SH'
#!/bin/sh
# Only this board has the NSS/ECM layout that needs nft offload disabled.
[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "redmi,ax6-stock" ] || exit 0
# Do NOT enable nft flow offloading on NSS builds: fw4's software flowtable
# takes over established flows before ECM's conntrack hook runs, which makes
# ecm_classifier_default deny acceleration (accelerated_count stays 0).
# Let qca-nss-ecm own the fast path exclusively.
uci -q set firewall.@defaults[0].flow_offloading='0'
uci -q set firewall.@defaults[0].flow_offloading_hw='0'
uci -q commit firewall
exit 0
SH
chmod +x "$FW_DEFAULTS/99-nss-offload"
ok "added uci-defaults/99-nss-offload (nft offload OFF, ECM owns NSS fast path)"

# luci-app-openclash ships no /lib/upgrade/keep.d rule of its own, so /etc/openclash
# (subscription, rules, GeoIP, the ~35 MB clash core) is wiped by every sysupgrade
# while /etc/config/openclash survives via base-files.  Recreate the keep rule once
# at first boot so it lands on the overlay and holds for all later upgrades.
cat > "$FW_DEFAULTS/97-openclash-keep" <<'SH'
#!/bin/sh
[ -d /etc/openclash ] || exit 0
mkdir -p /lib/upgrade/keep.d
[ -f /lib/upgrade/keep.d/openclash ] || printf '/etc/openclash/\n' > /lib/upgrade/keep.d/openclash
exit 0
SH
chmod +x "$FW_DEFAULTS/97-openclash-keep"
ok "added uci-defaults/97-openclash-keep (/etc/openclash survives sysupgrade)"

# ---------------------------------------------------------------------------
say "6.5/6 ECM: VXLAN offload off (kernel patch 0603-5 is not carried)"
# ---------------------------------------------------------------------------
# As soon as CONFIG_PACKAGE_kmod-vxlan is selected, qca-nss-ecm compiles its
# VXLAN interfacing layer, which calls vxlan_fdb_update_mac().  That helper is
# only added by 0603-5-qca-nss-clients-add-vxlan-support.patch, which this port
# intentionally does not carry, so the build dies with "implicit declaration of
# function 'vxlan_fdb_update_mac'".  Keep the module usable on the slow path and
# skip the offload instead.
ECM_MK="$IW/feeds/nss_packages/qca-nss-ecm/Makefile"
if [ -f "$ECM_MK" ]; then
	"$PY" "$SRC/patch-ecm-vxlan-offload.py" "$ECM_MK" || FAIL=1
else
	printf '   [..] %s not present yet -- run patch-ecm-vxlan-offload.py after feeds install\n' "$ECM_MK"
fi

# ---------------------------------------------------------------------------
say "verification"
# ---------------------------------------------------------------------------
printf 'nss dtsi:      '; ls "$DTS_DIR" | grep -c 'nss\.dtsi' || true
printf 'nss patches:   '; ls "$QC/patches-6.12" 2>/dev/null | grep -c '^06[0-9][0-9]-' || true
printf 'profile:       '; grep -c '^define Device/redmi_ax6-stock' "$MK" || true
printf 'root=:         '; grep -o 'root=/dev/ubiblock0_[01]' "$STOCK_DTS" || true
printf 'platform.sh:   '; grep -c 'NSS-STOCK-SINGLE-VOLUME' "$PLATFORM" || true
printf 'nss kmods:     '; grep -c 'kmod-qca-nss-drv' "$MAKEFILE" || true

if [ "$FAIL" -ne 0 ]; then
	printf '\n[FAIL] one or more required pieces are missing -- tree will NOT build\n' >&2
	exit 1
fi

echo
echo "Next:"
echo "  cd $IW"
echo "  ./scripts/feeds update -a && ./scripts/feeds install -a"
echo "  make menuconfig    # Target -> Qualcomm ... -> Redmi AX6 (stock layout)"
echo "  make -j\$(nproc) V=s"
