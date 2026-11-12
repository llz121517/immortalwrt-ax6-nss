#!/bin/bash
# ============================================================================
# build-ax6-nss.sh -- 一键构建 Redmi AX6 (ax6-stock) 的 NSS 硬件加速固件
#
# 在 Arch / Kali / Ubuntu / Debian 上以普通用户运行（需要 sudo 装依赖）：
#
#     mkdir -p ~/ax6 && cd ~/ax6
#     # 把本文件 + patches/ 目录放进来
#     chmod +x build-ax6-nss.sh
#     ./build-ax6-nss.sh
#
# 脚本做的事：
#   1. 检查环境（磁盘 ≥25GB、内存、CPU）
#   2. 装编译依赖（Arch 用 pacman，Debian 系用 apt）
#   3. 克隆 ImmortalWrt 25.12 + qosmio NSS 包
#   4. 移植 NSS：加 feed、9 个内核补丁、3 个 dtsi、profile、修 platform.sh
#   5. 配置并编译
#   6. 打印镜像路径
#
# 全程幂等：中断后重跑会跳过已完成步骤。
# ============================================================================

set -uo pipefail

WORK="${WORK:-$HOME/ax6}"
PORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IW="$WORK/immortalwrt"
QS="$WORK/qosmio-ipq"
NSS="$WORK/nss-packages"
LOG="$WORK/build.log"

# 目标配置
IW_REPO="https://github.com/immortalwrt/immortalwrt.git"
IW_BRANCH="openwrt-25.12"
QS_REPO="https://github.com/qosmio/openwrt-ipq.git"
QS_BRANCH="main-nss"
NSS_REPO="https://github.com/qosmio/nss-packages.git"
NSS_BRANCH="NSS-12.5-K6.x"

say()  { printf '\n\033[1;36m=== %s ===\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# ============================================================================
say "0/7 环境检查"
# ============================================================================
[ "$(id -u)" -ne 0 ] || die "请用普通用户运行，不要 root（脚本内部会调用 sudo）"

DISTRO=""
if [ -f /etc/arch-release ]; then DISTRO="arch"
elif command -v apt-get >/dev/null 2>&1; then DISTRO="debian"
else die "只支持 Arch 或 Debian 系（Kali/Ubuntu/Debian）"
fi
info "发行版: $DISTRO"

mkdir -p "$WORK" || die "无法创建 $WORK"
AVAIL_KB=$(df -Pk "$WORK" | awk 'NR==2 {print $4}')
AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
info "可用磁盘: ${AVAIL_GB} GB (需要 ≥25 GB)"
[ "$AVAIL_GB" -ge 25 ] || die "磁盘不足，需要至少 25 GB"

CORES=$(nproc)
MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
MEM_GB=$((MEM_KB / 1024 / 1024))
info "CPU: ${CORES} 核, 内存: ${MEM_GB} GB"
[ "$MEM_GB" -ge 4 ] || warn "内存 <4GB，编译可能 OOM"

# ============================================================================
say "1/7 安装编译依赖"
# ============================================================================
if [ "$DISTRO" = "arch" ]; then
	NEED=()
	for p in base-devel git python rsync unzip wget bc flex bison gawk \
	         ncurses openssl zlib libelf xz zstd patch; do
		pacman -Q "$p" >/dev/null 2>&1 || NEED+=("$p")
	done
	if [ ${#NEED[@]} -gt 0 ]; then
		info "安装: ${NEED[*]}"
		sudo pacman -S --needed --noconfirm "${NEED[@]}" || die "pacman 失败"
	else
		ok "依赖齐全"
	fi
else
	MISSING=()
	for c in gcc make git python3 rsync unzip wget bc flex bison gawk; do
		command -v "$c" >/dev/null 2>&1 || MISSING+=("$c")
	done
	[ -f /usr/include/ncurses.h ] || MISSING+=("libncurses-dev")
	[ -f /usr/include/openssl/ssl.h ] || MISSING+=("libssl-dev")
	if [ ${#MISSING[@]} -gt 0 ]; then
		info "安装 Debian 依赖"
		sudo apt-get update -qq
		sudo apt-get install -y build-essential clang flex bison g++ gawk \
			gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
			python3 python3-setuptools rsync swig unzip zlib1g-dev file wget \
			libelf-dev bc || die "apt 失败"
	else
		ok "依赖齐全"
	fi
fi

# ============================================================================
say "2/7 获取源码"
# ============================================================================
cd "$WORK" || die "cd $WORK 失败"

if [ -d "$IW/.git" ]; then
	ok "ImmortalWrt 已存在"
else
	info "克隆 ImmortalWrt ($IW_BRANCH)..."
	git clone --depth 1 -b "$IW_BRANCH" "$IW_REPO" "$IW" || die "克隆 ImmortalWrt 失败"
fi

if [ -d "$QS/.git" ]; then
	ok "qosmio/openwrt-ipq 已存在"
else
	info "克隆 qosmio/openwrt-ipq ($QS_BRANCH)..."
	git clone --depth 1 -b "$QS_BRANCH" "$QS_REPO" "$QS" || die "克隆 qosmio 失败"
fi

if [ -d "$NSS/.git" ]; then
	ok "nss-packages 已存在"
else
	info "克隆 nss-packages ($NSS_BRANCH)..."
	git clone --depth 1 -b "$NSS_BRANCH" "$NSS_REPO" "$NSS" || die "克隆 nss-packages 失败"
fi

# ============================================================================
say "3/7 移植 NSS 内核补丁"
# ============================================================================
QC="$IW/target/linux/qualcommax"
PDIR="$QC/patches-6.12"
[ -d "$PDIR" ] || die "找不到 $PDIR（ImmortalWrt 分支不对？）"

# 实测顺序：0102 (ImmortalWrt 自带) 先插入 nss@40000000，0600-0 才能改名
PATCHES=(
	0600-0-arm64-dts-ipq8074-rename-nss-region.patch
	0600-1-qca-nss-ecm-support-CORE.patch
	0600-2-qca-nss-ecm-support-PPPOE-offload.patch
	0600-3-qca-nss-ecm-support-net-bonding.patch
	0600-5-qca-nss-ecm-support-macvlan.patch
	0602-1-qca-nss-drv-add-qdisc-support.patch
	0603-1-qca-nss-clients-add-qdisc-support.patch
	0603-6-qca-nss-clients-add-bridge-mgr-support.patch
	0606-1-qca-nss-ecm-bridge-Fixes-for-Bridge-VLAN-Filtering.patch
)
ADDED=0
for p in "${PATCHES[@]}"; do
	if [ -f "$PDIR/$p" ]; then
		ok "$p 已存在"
		continue
	fi
	src=""
	[ -f "$PORT_DIR/patches/$p" ] && src="$PORT_DIR/patches/$p"
	[ -z "$src" ] && [ -f "$QS/target/linux/qualcommax/patches-6.12/$p" ] && \
		src="$QS/target/linux/qualcommax/patches-6.12/$p"
	if [ -z "$src" ]; then
		warn "缺少 $p"
		continue
	fi
	cp "$src" "$PDIR/$p" && ADDED=$((ADDED+1)) && ok "$p"
done
info "新增 $ADDED 个补丁"
# 确认 ImmortalWrt 自带 0102（0600-0 的前置）
[ -f "$PDIR/0102-arm64-dts-ipq8074-add-reserved-memory-nodes.patch" ] \
	&& ok "0102 前置补丁存在" \
	|| warn "0102 不存在，0600-0 可能打不上"

# ============================================================================
say "4/7 移植 NSS 设备树"
# ============================================================================
DTS_DIR="$QC/files/arch/arm64/boot/dts/qcom"
[ -d "$DTS_DIR" ] || die "找不到 DTS 目录 $DTS_DIR"

for d in ipq8074-nss.dtsi ipq6018-nss.dtsi ipq5018-nss.dtsi; do
	if [ -f "$DTS_DIR/$d" ]; then
		ok "$d 已存在"
		continue
	fi
	src=""
	[ -f "$PORT_DIR/files/$d" ] && src="$PORT_DIR/files/$d"
	[ -z "$src" ] && src="$(find "$QS" -name "$d" -print -quit 2>/dev/null)"
	if [ -z "$src" ]; then
		warn "缺少 $d"
		continue
	fi
	cp "$src" "$DTS_DIR/$d" && ok "$d"
done

# 给 ax3600.dtsi 加 include（与 qosmio 的唯一差异）
BASE_DTSI="$DTS_DIR/ipq8071-ax3600.dtsi"
if grep -q 'ipq8074-nss\.dtsi' "$BASE_DTSI" 2>/dev/null; then
	ok "ax3600.dtsi 已含 nss include"
else
	sed -i 's|^\(#include "ipq8074-ess\.dtsi"\)$|\1\n#include "ipq8074-nss.dtsi"|' "$BASE_DTSI" \
		&& ok "ax3600.dtsi += include ipq8074-nss.dtsi" \
		|| warn "修改 ax3600.dtsi 失败"
fi

# ============================================================================
say "5/7 校验 ax6-stock profile"
# ============================================================================
STOCK_DTS="$DTS_DIR/ipq8071-ax6-stock.dts"
if [ -f "$STOCK_DTS" ]; then
	if grep -q 'ubiblock0_1' "$STOCK_DTS" && grep -q 'smem-part' "$STOCK_DTS"; then
		ok "ipq8071-ax6-stock.dts 正确（ubiblock0_1 + smem-part）"
	else
		warn "ax6-stock.dts 不是预期版本，请检查"
	fi
else
	die "缺少 $STOCK_DTS —— 这个 ImmortalWrt 分支太旧，不支持 stock 布局"
fi

MK="$QC/image/ipq807x.mk"
if grep -q '^define Device/redmi_ax6-stock' "$MK" 2>/dev/null; then
	ok "redmi_ax6-stock profile 已定义"
else
	grep -q '^TARGET_DEVICES += redmi_ax6$' "$MK" || die "$MK 结构不符"
	python3 - "$MK" <<'PY'
import sys
path = sys.argv[1]
anchor = "TARGET_DEVICES += redmi_ax6\n"
block = """
define Device/redmi_ax6-stock
\t$(call Device/redmi_ax6)
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
	ok "已添加 redmi_ax6-stock profile"
fi

# ============================================================================
say "6/7 修复 platform.sh（关键！）"
# ============================================================================
PLATFORM="$QC/ipq807x/base-files/lib/upgrade/platform.sh"
if [ ! -f "$PLATFORM" ]; then
	warn "找不到 platform.sh"
elif grep -q 'NSS-STOCK-SINGLE-VOLUME' "$PLATFORM"; then
	ok "platform.sh 已修复"
else
	# 本机实测：这台 AX6 的 U-Boot 没有 flag_boot_rootfs，也没有 rootfs_1，
	# ImmortalWrt 的 A/B 分支会 `[ "" -eq "1" ]` 报 "ash: out of range" 而中止。
	python3 "$(dirname "$0")/patch-platform-sh.py" "$PLATFORM"
	if grep -q 'NSS-STOCK-SINGLE-VOLUME' "$PLATFORM"; then
		ok "platform.sh: A/B 分支已改为单卷升级"
	else
		warn "platform.sh 修改失败，请手工检查"
	fi
fi

# ============================================================================
say "7/7 NSS 包与 offload 默认开启"
# ============================================================================
MKQ="$QC/Makefile"
if grep -q 'kmod-qca-nss-drv' "$MKQ" 2>/dev/null; then
	ok "NSS kmods 已在 DEFAULT_PACKAGES"
else
	python3 - "$MKQ" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
if "kmod-qca-nss-drv" in text:
    sys.exit(0)
marker = "DEFAULT_PACKAGES += \\\n"
i = text.find(marker)
if i < 0:
    sys.exit("DEFAULT_PACKAGES not found")
j = i + len(marker)
end = j
while True:
    nl = text.find("\n", end)
    if nl < 0:
        break
    line = text[end:nl]
    if not line.rstrip().endswith("\\"):
        break
    end = nl + 1
ins = "\tkmod-qca-nss-dp kmod-qca-nss-drv kmod-qca-nss-ecm \\\n\tkmod-qca-nss-drv-bridge-mgr \\\n"
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text[:end] + ins + text[end:])
PY
	ok "已添加 NSS kmods"
fi

# feed
FEEDS="$IW/feeds.conf"
[ -f "$FEEDS" ] || FEEDS="$IW/feeds.conf.default"
if grep -q 'nss_packages' "$FEEDS" 2>/dev/null; then
	ok "nss feed 已配置"
else
	echo 'src-git nss_packages https://github.com/qosmio/nss-packages.git;NSS-12.5-K6.x' >> "$FEEDS"
	ok "已添加 nss_packages feed"
fi

# uci-defaults 关闭 nft offload（ECM 独占快路径）
UCI_DIR="$QC/ipq807x/base-files/etc/uci-defaults"
mkdir -p "$UCI_DIR"
cat > "$UCI_DIR/99-nss-offload" <<'SH'
#!/bin/sh
# nft flow offloading must stay OFF: fw4's software flowtable takes over
# established flows before ECM's conntrack hook runs, so ECM never sees the
# return direction and ecm_classifier_default denies acceleration forever.
# Let qca-nss-ecm own the fast path (verified: accel_mode=2, accelerated_count>0).
uci -q set firewall.@defaults[0].flow_offloading='0'
uci -q set firewall.@defaults[0].flow_offloading_hw='0'
uci -q commit firewall
exit 0
SH
chmod +x "$UCI_DIR/99-nss-offload"
ok "uci-defaults/99-nss-offload 已写入"

# ============================================================================
say "更新 feeds"
# ============================================================================
cd "$IW"
./scripts/feeds update -a >"$LOG" 2>&1 || die "feeds update 失败，见 $LOG"
./scripts/feeds install -a >>"$LOG" 2>&1 || die "feeds install 失败，见 $LOG"
ok "feeds 更新完成"

# ============================================================================
say "生成 .config"
# ============================================================================
cat > .config <<'EOF'
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq807x=y
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6-stock=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y

CONFIG_PACKAGE_kmod-qca-nss-dp=y
CONFIG_PACKAGE_kmod-qca-nss-drv=y
CONFIG_PACKAGE_kmod-qca-nss-ecm=y
CONFIG_PACKAGE_kmod-qca-nss-drv-bridge-mgr=y
CONFIG_PACKAGE_nss-firmware=y
CONFIG_PACKAGE_nss-firmware-ipq807x=y

# The NSS feed ships two complete driver trees and picks one by this choice:
#   11_4 -> nss-drv 11.4.0.5 (2021 baseline, patches-11.4/)
#   12_5 -> nss-drv 12.5 (patches/0026-nss-drv-add-support-for-kernel-6.12.patch)
# Kernel 6.12 only has support in the 12.5 tree, and qca-nss-ecm compiles with
# -DNSS_FIRMWARE_VERSION_12_5 only in this mode, so the firmware blob and the
# driver must both be 12.5.  Leaving the default (11_4) gives a 2021 driver that
# was never ported to 6.12.
CONFIG_NSS_FIRMWARE_VERSION_12_5=y
# CONFIG_NSS_FIRMWARE_VERSION_11_4 is not set

# NSS WiFi offload is a separate phase: it needs qosmio's 98 mac80211 patches
# (package/kernel/mac80211/patches/nss/: ath11k 69 + subsys 27 + ath10k 2) plus
# a kmod-nss-wifi-drv provider, none of which exist in the ImmortalWrt tree, so
# these symbols are dropped by defconfig and WiFi stays on stock ath11k.
# CONFIG_ATH11K_NSS_WIFI is not set
# CONFIG_PACKAGE_kmod-nss-wifi-drv is not set

CONFIG_PACKAGE_ethtool-full=y
CONFIG_PACKAGE_iperf3=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_curl=y

# MUST stay off.  kmod-nft-fullcone's Makefile does
#   KCONFIG:=CONFIG_NF_CONNTRACK_CHAIN_EVENTS=y
# which switches nf_conntrack_register_notifier() to the notifier_block
# signature, while qca-nss-ecm is written against the nf_ct_event_notifier
# one.  Leaving it on breaks the ECM build with
#   "passing argument 2 of 'nf_conntrack_register_notifier' from incompatible
#    pointer type" + "too few arguments to nf_conntrack_unregister_notifier".
# (firewall4's +kmod-nft-fullcone dependency is stripped by the port script.)
# CONFIG_PACKAGE_kmod-nft-fullcone is not set
EOF
make defconfig >>"$LOG" 2>&1 || die "make defconfig 失败"
info "已选中的关键项："
grep -E 'DEVICE_redmi_ax6-stock|kmod-qca-nss|nss-firmware|NSS_WIFI' .config | sed 's/^/    /'

# ============================================================================
say "开始编译（约 40-90 分钟，日志 $LOG）"
# ============================================================================
info "CPU ${CORES} 核，开始时间 $(date '+%H:%M:%S')"
make -j"$CORES" V=s 2>&1 | tee -a "$LOG"
BUILD_RC=${PIPESTATUS[0]}

if [ "$BUILD_RC" -ne 0 ]; then
	echo
	warn "编译失败（rc=$BUILD_RC）"
	info "查看错误："
	info "  grep -nE 'Error [0-9]|error:' $LOG | tail -40"
	die "见 $LOG"
fi

# ============================================================================
say "完成"
# ============================================================================
BIN="$IW/bin/targets/qualcommax/ipq807x"
echo
ls -lh "$BIN"/*ax6*stock*sysupgrade* 2>/dev/null || ls -lh "$BIN"/*.bin 2>/dev/null

IMG=$(ls "$BIN"/*ax6*stock*squashfs-sysupgrade.bin 2>/dev/null | head -1)
if [ -z "$IMG" ]; then
	warn "没找到 ax6-stock 镜像，请检查编译输出"
	exit 1
fi

cat <<EOF

镜像：$IMG
大小：$(du -h "$IMG" | cut -f1)
SHA256：$(sha256sum "$IMG" | cut -d' ' -f1)

===== 刷机（在路由器上执行）=====
scp "$(basename "$IMG")" root@192.168.10.1:/tmp/
ssh root@192.168.10.1 'sysupgrade -v /tmp/$(basename "$IMG")'

===== 事先备份（强烈建议）=====
ssh root@192.168.10.1 'sysupgrade -b /tmp/backup-\$(date +%F).tar.gz'
scp root@192.168.10.1:/tmp/backup-*.tar.gz .

===== 救砖 =====
断电 -> 按住 reset -> 上电 -> 浏览器打开 http://192.168.1.1 上传固件
（本机 U-Boot 已确认有 HTTP 恢复服务器）

===== 刷完验证 NSS 是否真的工作 =====
lsmod | grep -E 'qca_nss|ecm'
ls /dev/nss* 2>/dev/null
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count  # 跑流量时 > 0（实测 14~20）
ecm_dump.sh | grep 'nss_v4.ported.accel_mode' | head      # 出现 accel_mode=2
dmesg | grep -i nss | head -20
EOF
