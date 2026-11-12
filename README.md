# ImmortalWrt + Qualcomm NSS/ECM — Redmi AX6 (stock layout)

给硬件改机版 **Redmi AX6**（IPQ8071A，1 GiB RAM / 1 GiB NAND，原厂 UBI 布局）在
**ImmortalWrt 25.12** 上启用 Qualcomm **NSS/ECM 硬件 offload** 的完整移植工程。
不修改 U-Boot，保留官方 HTTP 恢复能力。

> **状态：已在真机验证** —— 有线与 WiFi 流量都由 NSS 硬件加速
> （`accelerated_count` 14→20，`accel_mode=2`，CPU 空闲 98%+）。
> 镜像 SHA256 `38f5b6f7…`，见 [Releases](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss)。

| | |
|---|---|
| 设备 | Redmi AX6（硬件改机 1G/1G），`board_name = redmi,ax6-stock` |
| SoC | IPQ8071A（target `qualcommax` / subtarget `ipq807x`）|
| 基线固件 | ImmortalWrt 25.12-SNAPSHOT `r0-761b7ff` |
| 内核 | 6.12.116 |
| NSS 固件 | `NSS.FW.12.5-210-HK.R`（NSS 12.5，core 0 + core 1）|
| 分区 | `qcom,smem-part`，UBI 单 rootfs，`root=/dev/ubiblock0_1`，无 A/B |
| U-Boot | 2016.01-**未修改**，HTTP 恢复 `http://192.168.1.1` 可用 |

---

## 验证结果（真机）

```
kernel 6.12.116 / ImmortalWrt 25.12-SNAPSHOT r0-761b7ff
qca-nss 39000000.nss: NSS fw version: NSS.FW.12.5-210-HK.R
qca-nss 39000000.nss: NSS core 0 booted successfully
qca-nss 39400000.nss: NSS core 1 booted successfully
ECM init complete
bonding 139264 3 ecm,qca_nss_bridge_mgr,qca_nss_vlan     ← 手工移植的 bond_cb/bond_get_id 在跑

有线 Windows -> WAN 下载:  accelerated_count 14→19, accel_mode=2
WiFi Arch    -> WAN 下载:  accelerated_count 19→20, accel_mode=2
吞吐 ~85 Mbit/s（宽带上限，不是转发瓶颈），CPU 空闲 98%+
```

---

## 为什么原厂固件 NSS 不工作

| 检查 | 原厂 ImmortalWrt 25.12.1 | 结论 |
|---|---|---|
| `qca-nss-dp` / `qca_ssdk` | 有（仅数据面依赖） | 驱动栈不完整 |
| `qca-nss-drv` / `qca-nss-ecm` | **无** | NSS 核心与连接管理器缺失 |
| DTB NSS 节点 | **无** | 驱动没有可绑定的设备 |
| `HW_OFFLOAD` | 0 | 只有软件 `OFFLOAD`（nft flowtable），NSS 从未参与 |

另有一个会直接让升级失败的问题：`platform.sh` 里 `redmi,ax6-stock` 分支是按小米 A/B
U-Boot 写的，在这台单分区机器上 `[ "" -eq "1" ]` 会报 `ash: out of range`，
`sysupgrade` 直接失败。本工程用 `patch-platform-sh.py` 把它改成单卷升级逻辑。

---

## 移植做了什么（6 步，脚本自动化）

`port-nss-to-immortalwrt.sh` 在干净 ImmortalWrt 25.12 树上端到端实测通过（RC=0），幂等可重复执行：

| 步骤 | 改动 |
|---|---|
| 1 | 加 `nss_packages` feed（`NSS-12.5-K6.x`，自带 `0026-nss-drv-add-support-for-kernel-6.12.patch`）|
| 2 | 应用 11 个 NSS/ECM 内核钩子补丁（ECM CORE、PPPoE、bonding、macvlan、qdisc、bridge-mgr、skb recycler 等）|
| 3 | 加 3 个 NSS dtsi，并给 `ipq8071-ax3600.dtsi` 加一行 `#include "ipq8074-nss.dtsi"` |
| 4 | 校验 `ipq8071-ax6-stock.dts`（官方已正确，仅验证 `ubiblock0_1`）|
| 5 | `platform.sh` 改为单卷升级（替换 A/B 逻辑）|
| 6 | NSS kmods 进 `DEFAULT_PACKAGES` + `uci-defaults/99-nss-offload` **关闭** nft flow offloading |

补丁来源是 [qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq)（`main-nss`）与
[qosmio/nss-packages](https://github.com/qosmio/nss-packages)（`NSS-12.5-K6.x`），
两者都已是内核 6.12 基线。`patches/0600-3-...-rebased.patch` 是**手工 rebase 产物**
（744 行 / 24 hunk，含两条 LAG 发包路径 hunk），不是上游原样拷贝——原因见
[docs/JOURNAL.md](docs/JOURNAL.md)。

---

## 关键设计决定：为什么必须关闭 nft flow offloading

fw4 的 `forward` 链第一行是：

```
meta l4proto { tcp, udp } flow add @ft
```

它会把已建立的 TCP/UDP 流交给 **nft 软件 flowtable** 接管。而 qca-nss-ecm 的加速是
**conntrack hook 驱动**的：软件 flowtable 抢走包之后，ECM 看不到回程方向
（`slow_path_packets=1`、`default.pr.accel=denied`），于是 `accelerated_count` 永远是 0。

所以本工程在默认配置里关闭两个开关（`uci-defaults/99-nss-offload`）：

```sh
uci set firewall.@defaults[0].flow_offloading='0'
uci set firewall.@defaults[0].flow_offloading_hw='0'
```

关闭后 ECM 独占快路径，NSS 硬件加速立即生效。**这不是性能回退**：被 NSS 加速的
连接完全不经 CPU；未被加速的连接走普通内核转发，与"没开 offload"等价。

---

## 构建

Arch / Kali / Debian 均可（需要 ≥20 GB 空闲磁盘）：

```bash
git clone https://github.com/llz121517/immortalwrt-ax6-nss.git
cd immortalwrt-ax6-nss
chmod +x build-ax6-nss.sh
./build-ax6-nss.sh          # 装依赖、克隆上游、移植、feeds、写 .config、make
```

产物：

```
immortalwrt/bin/targets/qualcommax/ipq807x/immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin
```

首次全量编译约 40–90 分钟（取决于 CPU），增量重编内核约 4–5 分钟。
`build-in-kali.sh` / `apply-ax6-stock.sh` 是早期脚本，仅作历史参考，主流程用 `build-ax6-nss.sh`。

---

## 兼容性警告（刷机前必读）

**这个镜像只适用于 stock 布局（`redmi,ax6-stock`），不能刷到未扩容的原厂 AX6 上。**

镜像 metadata 写死了 `supported_devices: ["redmi,ax6-stock"]`，而两者的分区布局完全不同：

| | `redmi,ax6-stock`（本镜像） | `redmi,ax6`（未扩容原厂 AX6） |
|---|---|---|
| DTS | `ipq8071-ax6-stock.dts`，`compatible = "redmi,ax6-stock"` | `ipq8071-ax6.dts`，`compatible = "redmi,ax6"` |
| 分区 | `qcom,smem-part` 单卷：`0 kernel / 1 rootfs / 2 rootfs_data` | 小米 A/B：`rootfs` + `rootfs_1`，由 U-Boot 变量切换 |
| U-Boot 变量 | 只有 `flag_boot_success`，无 `flag_boot_rootfs` | 有 `flag_boot_rootfs` / `flag_last_success` |
| platform.sh | 单卷逻辑（本工程改的） | `xiaomi_initramfs_prepare` + A/B 逻辑 |

- **正常刷**：`sysupgrade` 会因 board 不匹配拒绝（`Device redmi,ax6 not supported by this image`）。
- **强行 `-F`**：能写进去，但单卷逻辑写到 A/B 机器的卷上，U-Boot 按 `flag_boot_rootfs` 引导另一个卷 → 起不来，只能进 U-Boot 恢复模式救砖。
- 内存不是问题（DTS 未写死 memory，由 U-Boot 注入，512 MB 机器理论上能跑）；硬阻断只有布局差异。
- 要给未扩容原厂 AX6 用，需用它的 `redmi_ax6` profile 重新构建（NSS 补丁本身与布局无关，但要把 DTS include 接到 `ipq8071-ax6.dts` 并保留 A/B 版 `platform.sh`）。

---

## 刷机

**先备份**（配置 + 状态快照；救砖靠 U-Boot HTTP `192.168.1.1`）：

```bash
ssh root@192.168.10.1 'sysupgrade -b /tmp/backup-$(date +%F).tar.gz'
scp root@192.168.10.1:/tmp/backup-*.tar.gz .
```

刷入（**必须让 sysupgrade 完全脱离 SSH 会话**，否则通道断开时 SIGPIPE 会
把它杀死在 "Saving config files"）：

```bash
scp *redmi_ax6-stock*squashfs-sysupgrade.bin root@192.168.10.1:/tmp/
ssh root@192.168.10.1 '( sysupgrade -v /tmp/<镜像名> >/tmp/upgrade.log 2>&1 </dev/null & )'
```

约 2–3 分钟自动重启。保留配置（不加 `-n`）时 LAN IP / WiFi / 服务配置都会保留，
但**已安装的软件包不会保留**（`sysupgrade` 只留 `/etc`）。

---

## 验证

```sh
# 1) 驱动与固件
lsmod | grep -E 'qca_nss|ecm'
dmesg | grep -iE 'nss|ecm' | grep -E 'booted|init complete|fw version'

# 2) 硬件加速是否生效（真正的判据）
#    前提：nft offloading 已关（默认镜像已关）
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count     # 跑流量时应 > 0（实测 14~20）
ecm_dump.sh | grep 'nss_v4.ported.accel_mode' | head          # 应出现 accel_mode=2

# 3) CPU 占用
top -bn1 | head -3
```

**成功判据是 `accelerated_count > 0` + `accel_mode=2`**，不是
`/proc/net/nf_conntrack` 里的 `HW_OFFLOAD` 标记——qca-nss-ecm 不经过 nf_flow_table，
刷机后 `HW_OFFLOAD` 仍然是 0，但加速确实在跑。

---

## 已知坑（按踩坑顺序）

1. **nft flow offloading 影子 ECM**：症状是 `accelerated_count=0`、
   `default.pr.accel=denied`。修法见上文。默认镜像已内置。
2. **前台 SSH 触发 sysupgrade 会失败**：必须用 `( sysupgrade ... & )` 脱离会话。
3. **刷机后 DNS 断网**：如果旧配置里 dnsmasq 指向 OpenClash 的 `127.0.0.1#7874`，
   而 OpenClash 程序本体不随 sysupgrade 保留，解析全挂。临时改回 `223.5.5.5`。
4. **`bonding` 不能裁掉**：`kmod-qca-nss-ecm`/`bridge_mgr`/`vlan` 硬依赖它，
   但上游 bonding 缺少 NSS 需要的 `bond_cb` 注册回调 → 必须打 rebase 补丁。

---

## 仓库结构

```
nss-ax6-stock/
├── README.md                    # 本文档
├── CREDITS.md                   # 上游来源与许可
├── port-nss-to-immortalwrt.sh   # 主移植脚本（6 步，幂等）
├── build-ax6-nss.sh             # 一键构建（含完整 .config）
├── patch-platform-sh.py         # platform.sh 单卷升级补丁器
├── patches/                     # 11 个内核补丁（含手工 rebase 的 bonding）
├── files/                       # NSS DTS + 内核源码文件（skb recycler 等）
├── images/                      # manifest + SHA256SUMS（二进制走 Release）
├── tools/                       # SSH 助手（凭证走环境变量）
└── docs/JOURNAL.md              # 完整构建时间线与失败记录
```

---

## 风险与回滚

| 风险 | 说明 |
|---|---|
| `ubiblock0_1` 写错 | 唯一会砖的路径；官方 DTS 已正确，脚本不修改它 |
| U-Boot 无自动回滚 | 没有 `bootcount`/`altbootcmd`；失败需手动进 HTTP 恢复模式 |
| 已装包丢失 | `sysupgrade` 只保留 `/etc`；OpenClash 等需重装 |
| WiFi NSS | 本版是**原生 ath11k**（无 NSS WiFi 加速），第二阶段再上 |

真机备份（配置 tar + mtd0-8 含不可再生的 `art`）不在本仓库，属于个人设备数据。

---

## 文档

- [docs/JOURNAL.md](docs/JOURNAL.md) — 逐小时构建记录、失败尝试与修复过程
- [CREDITS.md](CREDITS.md) — 每个文件的上游来源、许可与手工改动说明

## 下载 / 许可

- Release：[`v25.12-nss`](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss)（sysupgrade 镜像 + SHA256）
- 代码与脚本：GPL-2.0（与 OpenWrt / ImmortalWrt / NSS 驱动一致）
- `patches/`、`files/` 保留其上游项目许可；不含 Qualcomm 专有固件（由 `nss-firmware` 包自行下载）
