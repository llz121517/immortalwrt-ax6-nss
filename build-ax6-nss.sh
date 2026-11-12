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
#   4. 移植 NSS：加 feed、内核补丁、3 个 dtsi、profile、修 platform.sh
#   5. 移植 WiFi NSS：ath11k/mac80211 97 个补丁（phase-2）
#   6. 生成 .config（NSS + WiFi offload + 常用工具）并编译
#   7. 打印镜像路径与验证命令（有线 + WiFi）
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
say "3/7 移植 NSS（内核补丁 + 8 个内核源文件 + DTS + profile + platform.sh）"
# ============================================================================
# 这里不再自己维护补丁清单。port-nss-to-immortalwrt.sh 是唯一来源：
#   20 个内核补丁（0600-0/1/2/3-rebased/5/6/7、0602-1、0603-1/2/3/4/6/7/8、
#   0604-1、0605-1、0606-1、0607-1、0981-1）、8 个内核源文件（DSCPREMARK +
#   skb recycler 等）、config-6.12 符号、3 个 NSS dtsi、profile、platform.sh。
# 两份清单曾经漂移过：本脚本自己那份只有 9 个补丁，缺 0600-6 时死在
# nf_conntrack_dscpremark_ext.h，缺 0603-2/3 时死在 pptp_session_find()，
# 缺 0981-1 时 qca-nss-drv 链接不上 skb recycler —— 产出的镜像根本不可用。
"$PORT_DIR/port-nss-to-immortalwrt.sh" "$IW" "$NSS" "$QS" || die "NSS 移植失败"

# ============================================================================
say "4/7 移植 WiFi NSS 补丁（ath11k/mac80211，phase-2）"
# ============================================================================
# 有线 offload 只解决以太网；WiFi 走的是原生 ath11k 软转发。phase-2 把 qosmio 的
# ath11k/mac80211 NSS 补丁系列移植过来（subsys 27 + ath10k 1 + ath11k 69 = 97 个）。
# 补丁之间有隐式依赖，不能"按需裁剪"；port-wifi-nss.py 是幂等的，重复执行安全。
if python3 "$PORT_DIR/port-wifi-nss.py" "$IW" "$QS" >>"$LOG" 2>&1; then
	ok "WiFi NSS 补丁已移植（97 个：subsys/ath10k/ath11k）"
else
	warn "WiFi NSS 补丁移植失败（上游漂移？）——本次构建将退回原生 ath11k，无线不加速。"
	warn "排查：用 regen-nss-hunks.py 重新生成失败的 hunk，见 README"
fi

# ============================================================================
say "5/7 更新 feeds + ECM 补丁"
# ============================================================================
cd "$IW" || die "cd $IW 失败"
./scripts/feeds update -a >"$LOG" 2>&1 || die "feeds update 失败，见 $LOG"
./scripts/feeds install -a >>"$LOG" 2>&1 || die "feeds install 失败，见 $LOG"
ok "feeds 更新完成"
# ECM 的 feed Makefile 只有 feeds install 之后才存在，所以这一步单独再跑一次：
# 关 VXLAN offload + 装 0007 chain-events 补丁（kmod-nft-fullcone 需要）。
"$PORT_DIR/port-nss-to-immortalwrt.sh" "$IW" "$NSS" "$QS" --ecm-only || die "ECM 补丁失败"

# ============================================================================
say "6/7 生成 .config"
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
# 这台设备 rootfs 卷只有 29 MiB（ubi0_1 = 240 LEB），p2 镜像已经用满，
# bridge-mgr/vlan-mgr 的模块塞不进去；实测 br-lan 转发不装它们也能
# accel_mode=2，所以不选。需要 bridge/VLAN 级 offload 就按 README 用 apk
# 装到 overlay（这两条用 "is not set"，否则符号默认 n 时 defconfig 会把包丢掉）。
# CONFIG_PACKAGE_kmod-qca-nss-drv-bridge-mgr is not set
# CONFIG_PACKAGE_kmod-qca-nss-drv-vlan-mgr is not set
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

# WiFi NSS offload（phase-2）：port-wifi-nss.py 会给 ath11k 加 nss.c、给 mac80211 加
# NSS 支持。这些符号只有在补丁成功移植后才存在；补丁失败时 make defconfig 会把它们丢掉，
# 回落成原生 ath11k（有线仍加速，无线不加速），构建不会失败。
CONFIG_ATH11K_NSS_SUPPORT=y
CONFIG_ATH11K_MEM_PROFILE_1G=y
CONFIG_PACKAGE_MAC80211_NSS_SUPPORT=y
CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE=y
CONFIG_NSS_DRV_WIFI_EXT_VDEV_ENABLE=y
# mesh offload 保持关闭：家里用不到，开着只会增加故障面
# CONFIG_PACKAGE_MAC80211_NSS_MESH_SUPPORT is not set

CONFIG_PACKAGE_ethtool-full=y
CONFIG_PACKAGE_iperf3=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_curl=y

# 常用排障/运维工具（phase-2 一起带上；mtr 在 25.12 的 defconfig 里会被丢掉，
# 所以写成 mtr-nojson，运行时也可 apk add mtr-nojson 临时补）
CONFIG_PACKAGE_tmux=y
CONFIG_PACKAGE_jq=y
CONFIG_PACKAGE_ncdu=y
CONFIG_PACKAGE_lsof=y
CONFIG_PACKAGE_socat=y
CONFIG_PACKAGE_rsync=y
CONFIG_PACKAGE_usbutils=y
CONFIG_PACKAGE_pciutils=y
CONFIG_PACKAGE_iftop=y
CONFIG_PACKAGE_nload=y
CONFIG_PACKAGE_nano=y
CONFIG_PACKAGE_zstd=y
CONFIG_PACKAGE_tcpdump=y
CONFIG_PACKAGE_traceroute=y
CONFIG_PACKAGE_mtr-nojson=y
CONFIG_PACKAGE_ttyd=y
CONFIG_PACKAGE_luci-app-ttyd=y
CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y

# 下面这些用 <M>（module）：OpenWrt 会把它们编成 apk 放在
#   bin/targets/qualcommax/ipq807x/packages/   （kmod 走这里）
#   bin/packages/aarch64_cortex-a53/{base,packages}/
# 但不装进镜像——29 MiB 的 rootfs 卷装不下（见 README 已知坑 11）。
# 刷机后从上面目录把 apk 拷到路由器 apk add 即可，内核符号/版本完全匹配。
#   kmod-nft-fullcone   fullcone/fullcone6；内核已经带 CHAIN_EVENTS（port 脚本 2b）
#   kmod-fs-cifs        ont-usb 挂载光猫 SMB1 共享
#   samba4-*            AX6 侧 SMB2/3 共享（Windows 访问）
#   kmod-qca-nss-drv-{bridge,vlan}-mgr   桥接/VLAN 级 offload（可选）
CONFIG_PACKAGE_kmod-nft-fullcone=m
CONFIG_PACKAGE_kmod-fs-cifs=m
CONFIG_PACKAGE_samba4-server=m
CONFIG_PACKAGE_samba4-client=m
CONFIG_PACKAGE_samba4-utils=m
CONFIG_PACKAGE_kmod-qca-nss-drv-bridge-mgr=m
CONFIG_PACKAGE_kmod-qca-nss-drv-vlan-mgr=m
EOF
make defconfig >>"$LOG" 2>&1 || die "make defconfig 失败"
info "已选中的关键项："
grep -E 'DEVICE_redmi_ax6-stock|kmod-qca-nss|nss-firmware|NSS_WIFI|ATH11K_NSS|MAC80211_NSS|NSS_DRV_WIFI|ttyd|iperf3' .config | sed 's/^/    /'
# 静默失效检查：这几项被 defconfig 丢掉，镜像不是想要的那个。
grep -q '^CONFIG_PACKAGE_kmod-qca-nss-ecm=y' .config || die 'kmod-qca-nss-ecm 没选中'
grep -q '^CONFIG_ATH11K_NSS_SUPPORT=y' .config \
	|| warn "ATH11K_NSS_SUPPORT 没选中：WiFi 补丁没贴上，本次镜像无线不加速"
grep -q '^CONFIG_PACKAGE_ttyd=y' .config || die 'ttyd 没选中'
# 这些包必须是 <M> 而不是 <Y>：=y 会把 rootfs 撑爆 29 MiB 的卷。
for pkg in kmod-nft-fullcone kmod-fs-cifs samba4-server samba4-client samba4-utils; do
	grep -q "^CONFIG_PACKAGE_$pkg=y" .config \
		&& die "CONFIG_PACKAGE_$pkg=y 会把 rootfs 撑爆 29 MiB 的卷，必须是 =m（只编 apk）"
done
grep -q '^CONFIG_PACKAGE_kmod-fs-cifs=m' .config \
	|| warn "kmod-fs-cifs 不是 =m：ont-usb 需要的 cifs 模块没编出来"

# ============================================================================
say "7/7 开始编译（约 40-90 分钟，日志 $LOG）"
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

# ---- 尺寸守卫：这台机器是 stock 单卷布局，卷大小写死在 smem 分区表里 ----
# ubi0_0 kernel = 45 LEB = 5,713,920 B；ubi0_1 rootfs = 240 LEB = 30,474,240 B。
# 镜像 = uImage 内核 + squashfs，超了任何一段 sysupgrade 都会写失败（内核段写完
# 才失败会直接不启动）。p2 镜像当时只剩 ~93 KB 余量，所以这里必须拦。
KERNEL_VOL=5713920
ROOTFS_VOL=30474240
IMG_SIZE=$(stat -c %s "$IMG")
SQ_OFF=$(grep -abo 'hsqs' "$IMG" | head -1 | cut -d: -f1)
[ -n "$SQ_OFF" ] || die "镜像里找不到 squashfs 魔数，格式不对"
ROOTFS_SIZE=$((IMG_SIZE - SQ_OFF))
info "镜像拆分：kernel $SQ_OFF B / $KERNEL_VOL B，rootfs $ROOTFS_SIZE B / $ROOTFS_VOL B"
[ "$SQ_OFF" -le "$KERNEL_VOL" ] || die "内核段 $SQ_OFF > kernel 卷 $KERNEL_VOL，刷机会失败"
[ "$ROOTFS_SIZE" -le "$ROOTFS_VOL" ] || die "rootfs $ROOTFS_SIZE > rootfs 卷 $ROOTFS_VOL，刷机会失败"
info "尺寸检查通过（rootfs 余量 $((ROOTFS_VOL - ROOTFS_SIZE)) B）"

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
（改机 U-Boot 自带 HTTP 网页恢复，非小米官方功能）

===== 刷完装运行时的包（29 MiB rootfs 卷装不进镜像）=====
# 构建已经把这些包编成 apk（<M> 包只编不装），位置：
#   $BIN/packages/                                    # kmod-*（内核对版本，必须用这里的）
#   $IW/bin/packages/aarch64_cortex-a53/packages/      # samba4-* 等
# fullcone（内核侧 CHAIN_EVENTS 已编进内核，ECM 由 feed 补丁 0007 适配）
scp $BIN/packages/kmod-nft-fullcone-*.apk root@192.168.10.1:/tmp/
ssh root@192.168.10.1 'apk add --allow-untrusted /tmp/kmod-nft-fullcone-*.apk'
ssh root@192.168.10.1 'uci set firewall.@defaults[0].fullcone=1; uci set firewall.@defaults[0].fullcone6=1
  uci commit firewall; /etc/init.d/firewall restart; nft list ruleset | grep -c fullcone'
# ont-usb：光猫 SMB1 -> AX6 cifs -> AX6 Samba4
scp $BIN/packages/kmod-fs-cifs-*.apk root@192.168.10.1:/tmp/
ssh root@192.168.10.1 'apk add --allow-untrusted /tmp/kmod-fs-cifs-*.apk'
ssh root@192.168.10.1 'apk add samba4-server samba4-client samba4-utils  # 或装 $IW/bin/packages 里的 apk
  /etc/init.d/samba4 enable; /etc/init.d/samba4 restart'

===== 刷完验证 NSS 是否真的工作 =====
lsmod | grep -E 'qca_nss|ecm|ath11k'
ls /dev/nss* 2>/dev/null
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count  # 跑流量时 > 0
ecm_dump.sh | grep 'nss_v4.ported.accel_mode' | head      # 出现 accel_mode=2
dmesg | grep -i nss | head -20
nft list ruleset | grep -c fullcone                       # 装完 fullcone 后 > 0

===== 验证 WiFi 侧 NSS（phase-2）=====
cat /sys/module/ath11k/parameters/nss_offload   # 1
cat /sys/module/ath11k/parameters/frame_mode     # 2
dmesg | grep 'nss init soc'                      # nss if_num 203
nss_diag -c                                      # NSS FW / ATH11K FW / 接口 checksum
# 测 WiFi 加速：先 /etc/init.d/openclash stop，再用 WiFi 网卡下载，
# 期间 ecm_dump.sh 里该连接的 nss_v4.ported.accel_mode 应为 2；测完 start 回来。
EOF
