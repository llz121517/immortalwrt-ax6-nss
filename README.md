# Redmi AX6（改机 1G/1G）+ ImmortalWrt + Qualcomm NSS/ECM 硬件加速

在**硬件改造过的 Redmi AX6**（IPQ8071A，1 GiB RAM / 1 GiB NAND）上运行 **ImmortalWrt**，
有线和 WiFi 转发都交给 Qualcomm **NSS/ECM** 硬件加速。**不改 U-Boot**，只用 `sysupgrade`，
保留小米官方 HTTP 恢复能力。

> 命名：`redmi_ax6-stock` / `board_name = redmi,ax6-stock` 里的 "stock" 只指**出厂单卷 UBI
> 分区布局**（`0 kernel / 1 rootfs / 2 rootfs_data`，U-Boot 不参与 A/B），不代表固件。
> 固件是 ImmortalWrt，只是沿用了这个设备档案，好处是不用动 U-Boot。

| | |
|---|---|
| SoC / 目标 | IPQ8071A（`qualcommax` / `ipq807x`，aarch64_cortex-a53）|
| 基线 | ImmortalWrt 25.12-SNAPSHOT `r0-761b7ff`，内核 6.12.116（nftables-only）|
| 分区 | `qcom,smem-part` 单卷 UBI，`root=/dev/ubiblock0_1`，无 A/B |
| U-Boot | 2016.01 未修改，HTTP 恢复 `http://192.168.1.1` |
| NSS / WiFi 固件 | `NSS.FW.12.5-210-HK.R` / `WLAN.HK.2.9.0.1-02146-QCAHKSWPL_SILICONZ-1` |

## 现状

| 阶段 | 内容 | 镜像 |
|---|---|---|
| Phase 1 | `qca-nss-dp`/`qca_ssdk`/`qca-nss-drv`/`qca-nss-ecm` + NSS dtsi；有线 `accel_mode=2`、`accelerated_count` 14→19 | [`v25.12-nss`](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss)，34,621,716 B，sha256 `ea0b8fe9…` |
| Phase 2 | ath11k/mac80211 NSS 补丁（97 个）；`nss_offload=1`、`frame_mode=2`；WiFi 连接实测 `nss_v4.ported.accel_mode=2`，`accelerated_count` 18→22 | [`v25.12-nss-p2`](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss-p2)，36,034,836 B，sha256 `a3bb091c…` |

WiFi 加速证据（真机 `ecm_dump.sh`，下载进行中抓取）：

```
conns.conn.485.sip_address=192.168.10.108        # WiFi 客户端
conns.conn.485.nss_v4.ported.accel_mode=2        # NSS 硬件加速
conns.conn.485.is_routed=1
dmesg: ath11k c000000.wifi: nss init soc nss if_num 203 userpd_id 0
```

## 移植内容

**内核/NSS（`port-nss-to-immortalwrt.sh`，幂等）**：加 `nss_packages` feed + 20 个内核钩子补丁
（ECM CORE/PPPoE/bonding/macvlan/qdisc/bridge-mgr/skb recycler）+ 3 个 NSS dtsi +
`platform.sh` 改单卷升级 + NSS kmods 进 `DEFAULT_PACKAGES` + `uci-defaults/99-nss-offload`
关掉 nft flow offloading。

**WiFi（`port-wifi-nss.py`）**：qosmio 的 ath11k/mac80211 NSS 补丁共 97 个
（`subsys` 27 + `ath10k` 1 + `ath11k` 69）移植到 backports-6.18.55。补丁间有隐式依赖，
不能裁剪；某个 hunk 因上游漂移失败时用 `regen-nss-hunks.py` 按真实文件状态重生成。
关键配置：

```kconfig
CONFIG_ATH11K_NSS_SUPPORT=y
CONFIG_ATH11K_MEM_PROFILE_1G=y
CONFIG_PACKAGE_MAC80211_NSS_SUPPORT=y
CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE=y
CONFIG_NSS_DRV_WIFI_EXT_VDEV_ENABLE=y
```

`MAC80211_NSS_MESH_SUPPORT` 关闭。补丁来源：qosmio/openwrt-ipq（`main-nss`）、
qosmio/nss-packages（`NSS-12.5-K6.x`）。`patches/0600-3-...-rebased.patch` 是手工 rebase 产物。

## 必须关闭 nft flow offloading

fw4 的 `flow add @ft` 会让 nft 软件 flowtable 抢走已建立连接，ECM 看不到回程方向，
`accelerated_count` 永远是 0。所以默认配置写死（`uci-defaults/99-nss-offload`）：

```sh
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
```

## 构建

Arch / Kali / Debian，≥20 GB 空闲磁盘：

```bash
git clone https://github.com/llz121517/immortalwrt-ax6-nss.git
cd immortalwrt-ax6-nss
chmod +x build-ax6-nss.sh
./build-ax6-nss.sh     # 依赖、上游克隆、NSS/WiFi 移植、feeds、.config、make 一条龙
```

产物：

```
immortalwrt/bin/targets/qualcommax/ipq807x/immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin
```

只补 WiFi 补丁时：`python3 port-wifi-nss.py <immortalwrt-tree> <qosmio-tree>`。

镜像自带的常用工具（均已验证可用）：`htop` `tmux` `iperf3` `jq` `ncdu` `lsof` `socat`
`rsync` `iftop` `nload` `nano` `zstd` `lspci` `lsusb` `tcpdump` `traceroute`
`ttyd`+`luci-app-ttyd`。`mtr` 被 defconfig 丢弃，需要时 `apk add mtr-nojson`
（构建脚本里已加 `CONFIG_PACKAGE_mtr-nojson=y`，下次重编进镜像）。

## 兼容性警告

**只适用于「改机 + 出厂单卷布局」的 AX6（`redmi,ax6-stock`），不能刷未改造的 AX6（`redmi,ax6`）。**

两者 DTS/分区/U-Boot 变量完全不同（单卷 vs 小米 A/B）。正常刷 `sysupgrade` 会因 board
不匹配拒绝；强行 `-F` 能写进去但起不来，只能 U-Boot 恢复救砖。要给未改造的 AX6 用，
需用它的 `redmi_ax6` profile 重新构建：WiFi NSS 补丁与布局无关，但 DTS include 和
`platform.sh` 要换成 A/B 版本。

## 刷机

```bash
# 备份（救砖靠 U-Boot HTTP 192.168.1.1）
ssh root@192.168.10.1 'sysupgrade -b /tmp/backup-$(date +%F).tar.gz'
scp root@192.168.10.1:/tmp/backup-*.tar.gz .

# 刷入：必须脱离 SSH 会话，否则通道断开时 SIGPIPE 会杀死 sysupgrade
scp *redmi_ax6-stock*sysupgrade.bin root@192.168.10.1:/tmp/
ssh root@192.168.10.1 '( sysupgrade -v /tmp/<镜像名> >/tmp/upgrade.log 2>&1 </dev/null & )'
```

保留配置升级时 `/etc` 保留（OpenClash 配置由 keep.d 规则保留），**已装软件包不保留**。

## 验证

```sh
# NSS / WiFi 是否启用
lsmod | grep -E 'qca_nss|ecm|ath11k'
cat /sys/module/ath11k/parameters/nss_offload          # 1
cat /sys/module/ath11k/parameters/frame_mode            # 2
cat /sys/module/mac80211/parameters/nss_redirect        # N（ath11k 用 nss_offload）
dmesg | grep -iE 'nss.*(booted|init complete|fw version)|nss init soc'
nss_diag -c

# 硬件加速判据：跑流量时
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count   # > 0
ecm_dump.sh | grep 'nss_v4.ported.accel_mode' | head       # 出现 accel_mode=2
```

判据是 `accelerated_count > 0` + `accel_mode=2`，**不是** `nf_conntrack` 的 `HW_OFFLOAD`
（qca-nss-ecm 不走 nf_flow_table，那个标记始终是 0）。

测 WiFi 加速：先 `/etc/init.d/openclash stop`（fake-IP/tproxy 会让流量走用户态，永不加速），
流量必须真从 WiFi 网卡出去（PC 同时插网线时用 `curl --interface <WiFi IP>` 或加 /32 路由），
测完 `start` 回来即可。`accelerated_count` 是当前连接数，要在流量进行中采样。
WiFi offload 生效后 `iw station dump` 字节数不再增长属正常（数据面绕过主机）。

## 已知坑

1. nft flow offloading 不关 → ECM 永不加速（默认已关）。
2. 前台 SSH 跑 `sysupgrade` 必失败，要用 `( sysupgrade ... & )`。
3. 刷机后 DNS 断网：旧配置 dnsmasq 指向 OpenClash 端口而程序不在了，改回公共 DNS 应急。
4. `bonding` 不能裁（ECM/bridge-mgr/vlan 硬依赖），且要打 rebase 补丁才有 `bond_cb`。
5. WiFi NSS 补丁不能按需裁剪，失败用 `regen-nss-hunks.py` 重生成，不要手写 hunk。
6. 补丁验证只认 `make package/kernel/mac80211/prepare`（fuzz 2），`patch -p1` 默认 fuzz 会误报。
7. PC 上的代理（FlClash 等）fake-IP 会污染测试，测加速前处理掉。

## 仓库结构

```
nss-ax6-stock/
├── build-ax6-nss.sh             # 一键构建（phase-2 镜像）
├── port-nss-to-immortalwrt.sh   # 内核/NSS 移植（6 步，幂等）
├── port-wifi-nss.py             # WiFi NSS 补丁移植（97 个）
├── regen-nss-hunks.py           # 失败的 hunk 用 diff 重生成
├── patch-platform-sh.py         # platform.sh 单卷升级
├── patch-ecm-vxlan-offload.py   # ECM 关 VXLAN 卸载
├── patches/  files/             # 内核补丁、NSS dtsi 等源文件
├── images/                      # SHA256SUMS + 说明（二进制走 Release）
├── tools/                       # SSH 助手、verify-offload.py
└── docs/JOURNAL.md              # 构建时间线与失败记录
```

## 风险 / 下载 / 许可

- `ubiblock0_1` 写错会砖（官方 DTS 正确，脚本不改它）；U-Boot 无自动回滚，失败走 HTTP 恢复。
- WiFi NSS 失效时把 `ath11k.nss_offload` 置 0（或 `nss_offload=0` 启动参数）回退原生 ath11k。
- 镜像与校验和：[v25.12-nss-p2](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss-p2)
  （sha256 `a3bb091c…`）、[v25.12-nss](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss)（sha256 `ea0b8fe9…`），
  见 [images/SHA256SUMS](images/SHA256SUMS)。
- 代码与脚本 GPL-2.0；`patches/`、`files/` 保留上游许可；不含 Qualcomm 专有固件。
- 文档：[docs/JOURNAL.md](docs/JOURNAL.md)、[CREDITS.md](CREDITS.md)。
