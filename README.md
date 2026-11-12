# Redmi AX6（改机 1G/1G）+ ImmortalWrt + Qualcomm NSS/ECM 硬件加速

在**硬件改造过的 Redmi AX6**（IPQ8071A，1 GiB RAM / 1 GiB NAND）上，把 **ImmortalWrt 25.12**
做成 Qualcomm **NSS/ECM 硬件 offload** 全开的固件：有线转发和 WiFi 转发都交给 NSS 处理，
CPU 只承担控制面。全程**不改 U-Boot**，只用 `sysupgrade` 升级，保留小米官方的 HTTP 恢复能力。

> **先把命名说清楚**：仓库里的 `redmi_ax6-stock`、`board_name = redmi,ax6-stock`、
> DTS 文件名里的 "stock"，指的是**小米出厂时的单卷 UBI 分区布局**
> （`qcom,smem-part`，`0 kernel / 1 rootfs / 2 rootfs_data`，U-Boot 不参与 A/B 切换）。
> 它**不是**指固件——本工程的固件是 **ImmortalWrt**，不是小米出厂固件，也不是
> ImmortalWrt 的默认构建，只是沿用了这台机器在 ImmortalWrt 里的设备档案，
> 好处是**不需要动 U-Boot**。
>
> 所以本文里说 "stock 布局" = 出厂分区布局，说 "ImmortalWrt" = 实际跑的系统。

| | |
|---|---|
| 设备 | Redmi AX6（硬件改机 1 GiB RAM / 1 GiB NAND）|
| SoC | IPQ8071A（target `qualcommax` / subtarget `ipq807x`，aarch64_cortex-a53）|
| 固件基线 | ImmortalWrt 25.12-SNAPSHOT `r0-761b7ff` |
| 内核 | 6.12.116（nftables-only）|
| 分区 | `qcom,smem-part` 单卷 UBI，`root=/dev/ubiblock0_1`，无 A/B |
| U-Boot | 2016.01 **未修改**，HTTP 恢复 `http://192.168.1.1` 可用 |
| NSS 固件 | `NSS.FW.12.5-210-HK.R`（core 0 + core 1）|
| WiFi 固件 | `WLAN.HK.2.9.0.1-02146-QCAHKSWPL_SILICONZ-1`（NSS offload 支持的版本）|

---

## 现状（两个阶段）

### Phase 1 — 有线转发走 NSS（已发布）

- `qca-nss-dp` + `qca_ssdk` + `qca-nss-drv` + `qca-nss-ecm` 四件套进固件，DTS 挂上 NSS 节点；
- NSS 双核 `booted successfully`，ECM `init complete`；
- 有线 Windows → WAN 下载实测：`accelerated_count` 14→19、`accel_mode=2`，CPU 空闲 98%+；
- 镜像随 Release [`v25.12-nss`](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss) 发布。

### Phase 2 — WiFi 转发也走 NSS（本分支，已构建并刷入）

- ath11k 打上 NSS 移植补丁（`ath11k_nss_tx()` / `CPTCFG_ATH11K_NSS_SUPPORT`），NSS.WIFI
  与 NSS.ECM flow table、EDMA 打通；
- 相关开关：`ath11k.nss_offload=1`、`ath11k.frame_mode=2`、`mac80211.nss_redirect=N`；
- 真机日志已确认 WiFi 侧 NSS 初始化成功：
  `ath11k c000000.wifi: nss init soc nss if_num 203 userpd_id 0`；
- 5 GHz / 2.4 GHz 双频正常起 AP、WPA2 握手正常、`nss_diag` 正常输出；
- 镜像 SHA256 `a3bb091c…`（36,034,836 B），已 sysupgrade 刷入真机。

> WiFi 加速实测（真机）：连续下载时抓 `ecm_dump.sh`，WiFi 客户端那条连接为
>
> ```
> conns.conn.485.sip_address=192.168.10.108        ← PC 的 WiFi 地址
> conns.conn.485.snode_address=a0:51:0b:5f:db:92   ← 该客户端的 WiFi MAC
> conns.conn.485.dip_address=101.6.15.130          ← 清华镜像（CN，DIRECT 转发）
> conns.conn.485.is_routed=1
> conns.conn.485.nss_v4.ported.can_accel=1
> conns.conn.485.nss_v4.ported.accel_mode=2        ← NSS 硬件加速
> conns.conn.485.nss_v4.ported.slow_path_packets=3
> conns.conn.485.classifiers.default.pr.accel=wanted
> ```
>
> 同一时间窗内 `accelerated_count` 从 18 升到 22、`ecm_dump.sh` 里 `accel_mode=2`
> 的连接 18→22：WiFi→WAN 的转发确实走了 NSS，而不是 CPU 软转发。
>
> 测 WiFi 加速的前提：先停掉 OpenClash（fake-IP DNS + tproxy 会让流量走用户态，
> 永不加速），并让测试流量真正从 WiFi 网卡出去（PC 同时插网线时要绑源地址或给目标
> 加 /32 路由，否则测到的是有线路径）；测完再启动 OpenClash 即可，配置不变。
> 另外 WiFi offload 生效后主机侧 `iw station dump` 的字节计数可能不再增长
> （数据面绕过主机），这是正常现象，不能当判据。

---

## 为什么默认的 ImmortalWrt 构建没有 NSS

| 检查项 | ImmortalWrt 25.12 默认构建 | 结论 |
|---|---|---|
| `qca-nss-dp` / `qca_ssdk` | 有（仅数据面依赖） | 驱动栈不完整 |
| `qca-nss-drv` / `qca-nss-ecm` | **无** | NSS 核心与连接管理器缺失 |
| DTB NSS 节点 | **无** | 驱动没有可绑定的设备 |
| `HW_OFFLOAD` 标记 | 0 | 只有软件 `OFFLOAD`（nft flowtable），NSS 从未参与 |
| ath11k NSS WiFi | **无** | 没有 `nss.c`、MAC80211 也没开 NSS 支持 |

另一个会直接让升级失败的问题：`platform.sh` 里 `redmi,ax6-stock` 分支是按小米 A/B
U-Boot 写的，在这台单卷机器上 `[ "" -eq "1" ]` 会报 `ash: out of range`，`sysupgrade`
直接失败。本工程用 `patch-platform-sh.py` 把它改成单卷升级逻辑。

---

## 移植做了什么

### 内核 / NSS 侧（`port-nss-to-immortalwrt.sh`，幂等，6 步）

| 步骤 | 改动 |
|---|---|
| 1 | 加 `nss_packages` feed（`NSS-12.5-K6.x`，自带 `0026-nss-drv-add-support-for-kernel-6.12.patch`）|
| 2 | 应用 20 个 NSS/ECM 内核钩子补丁（ECM CORE、PPPoE、bonding、macvlan、qdisc、bridge-mgr、skb recycler 等）|
| 3 | 加 3 个 NSS dtsi，并给 `ipq8071-ax3600.dtsi` 加一行 `#include "ipq8074-nss.dtsi"` |
| 4 | 校验 `ipq8071-ax6-stock.dts`（官方已正确，仅验证 `ubiblock0_1`）|
| 5 | `platform.sh` 改为单卷升级（替换 A/B 逻辑）|
| 6 | NSS kmods 进 `DEFAULT_PACKAGES` + `uci-defaults/99-nss-offload` **关闭** nft flow offloading |

### WiFi 侧（`port-wifi-nss.py`，phase-2 新增）

把 qosmio 的 ath11k / mac80211 NSS 补丁系列（97 个 patch）移植到 ImmortalWrt 的
backports-6.18.55 上：

| 目录 | 内容 |
|---|---|
| `package/kernel/mac80211/patches/nss/subsys/` | 27 个 mac80211 / nl80211 / cfg80211 补丁 |
| `package/kernel/mac80211/patches/nss/ath11k/` | 69 个 ath11k NSS 补丁（含 `nss.c` / `nss.h`）|
| `package/kernel/mac80211/patches/nss/ath10k/` | 1 个 ath10k 补丁 |

补丁必须原样、按顺序、带 fuzz 2 应用（`make package/kernel/mac80211/prepare`），
任何"看起来无关"的补丁都不能跳——比如 `subsys/300`（mesh offload）在 mesh 关闭时
依然被后续补丁依赖（`include/net/mac80211.h`、`debugfs.c`、`tx.c` 的改动），删了会连环失败。

`regen-nss-hunks.py` 是配套的 hunk 重生成工具：对每个应用失败的 hunk，用真实文件
状态**生成规范 diff** 再写回 patch 文件，而不是手写上下文（手写行数容易算错）。

需要的配置开关（`.config`）：

```kconfig
CONFIG_ATH11K_NSS_SUPPORT=y
CONFIG_ATH11K_MEM_PROFILE_1G=y
CONFIG_PACKAGE_MAC80211_NSS_SUPPORT=y
CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE=y
CONFIG_NSS_DRV_WIFI_EXT_VDEV_ENABLE=y
```

`MAC80211_NSS_MESH_SUPPORT` 保持关闭；`pbuf.uci`、`qca-nss-pbuf.init`、
`disable_mesh_chksum_ath11k.hotplug`、`nss_diag.sh` 由 mac80211 包安装逻辑带进镜像。

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

phase-2 的 WiFi NSS 补丁由 `port-wifi-nss.py` 在构建前打入 ImmortalWrt 源码树：

```bash
python3 port-wifi-nss.py <immortalwrt-tree> <qosmio-tree>
# 若某个 hunk 因上游漂移失败，再跑 hunk 重生成工具（需要一份已应用 ImmortalWrt 补丁的
# backports 干净树作为 <scratch-dir>/pristine）：
python3 regen-nss-hunks.py <immortalwrt-tree> <scratch-dir>
```

产物：

```
immortalwrt/bin/targets/qualcommax/ipq807x/immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin
```

首次全量编译约 40–90 分钟（取决于 CPU），增量重编内核约 4–5 分钟。
`build-in-kali.sh` / `apply-ax6-stock.sh` 是早期脚本，仅作历史参考，主流程用 `build-ax6-nss.sh`。

### phase-2 镜像里多带的常用工具（已逐个验证可运行）

| 工具 | 版本 | | 工具 | 版本 |
|---|---|---|---|---|
| `htop` | 3.5.3 | | `iftop` | 1.0 |
| `tmux` | 3.6a | | `nload` | 0.7.4 |
| `iperf3` | 3.22 | | `nano` | 8.x |
| `jq` | 1.8.1 | | `zstd` | 1.5.7 |
| `ncdu` | 1.22 | | `ttyd` (+`luci-app-ttyd`) | 1.7.7 |
| `lsof` | 4.99.5 | | `lsusb`（`usbutils`）| 018 |
| `socat` | 1.8.0 | | `lspci`（`pciutils`）| 3.14 |
| `rsync` | 3.5.1 | | | |

`ttyd` 配了 Luci 入口，浏览器里直接开路由器终端；`nss_diag -c` 可随时查看 NSS/ath11k
固件版本与各接口 checksum 状态。`sysupgrade` 只保留 `/etc`，所以这些工具属于镜像内容、
不会因升级丢失；后续用 `opkg/apk` 手动装的包则会丢，需要重装。

---

## 兼容性警告（刷机前必读）

**这个镜像只适用于"改机 + 单卷布局"的 AX6（设备档案 `redmi,ax6-stock`），不能刷到未改造的 AX6 上。**

镜像 metadata 写死了 `supported_devices: ["redmi,ax6-stock"]`，而两者的分区布局完全不同：

| | `redmi,ax6-stock`（本镜像，单卷布局） | `redmi,ax6`（未改造 AX6，小米 A/B 布局） |
|---|---|---|
| DTS | `ipq8071-ax6-stock.dts`，`compatible = "redmi,ax6-stock"` | `ipq8071-ax6.dts`，`compatible = "redmi,ax6"` |
| 分区 | `qcom,smem-part` 单卷：`0 kernel / 1 rootfs / 2 rootfs_data` | `rootfs` + `rootfs_1`，由 U-Boot 变量切换 |
| U-Boot 变量 | 只有 `flag_boot_success`，无 `flag_boot_rootfs` | 有 `flag_boot_rootfs` / `flag_last_success` |
| platform.sh | 单卷逻辑（本工程改的） | `xiaomi_initramfs_prepare` + A/B 逻辑 |

- **正常刷**：`sysupgrade` 会因 board 不匹配拒绝（`Device redmi,ax6 not supported by this image`）。
- **强行 `-F`**：能写进去，但单卷逻辑写到 A/B 机器的卷上，U-Boot 按 `flag_boot_rootfs`
  引导另一个卷 → 起不来，只能进 U-Boot 恢复模式救砖。
- 内存不是问题（DTS 未写死 memory，由 U-Boot 注入，512 MB 机器理论上能跑）；
  硬阻断只有布局差异。
- 要给未改造的 AX6 用，需用它的 `redmi_ax6` profile 重新构建：NSS 补丁本身与布局无关，
  但要把 DTS include 接到 `ipq8071-ax6.dts`，并保留 A/B 版 `platform.sh`。

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
但**已安装的软件包不会保留**（`sysupgrade` 只留 `/etc`；`/etc/openclash` 由 keep.d 规则保留）。

---

## 验证

```sh
# 1) 驱动与固件
lsmod | grep -E 'qca_nss|ecm|ath11k'
dmesg | grep -iE 'nss|ecm' | grep -E 'booted|init complete|fw version|nss init'

# 2) NSS WiFi 是否启用（phase-2）
cat /sys/module/ath11k/parameters/nss_offload        # 应为 1
cat /sys/module/ath11k/parameters/frame_mode         # 应为 2
cat /sys/module/mac80211/parameters/nss_redirect     # 应为 N（ath11k 用 nss_offload，不需要 redirect）
nss_diag -c                                          # 应打印 NSS FW / ATH11K FW / 各接口 checksum 状态

# 3) 硬件加速是否生效（真正的判据）
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count   # 跑流量时应 > 0
ecm_dump.sh | grep 'nss_v4.ported.accel_mode' | head       # 应出现 accel_mode=2

# 4) CPU 占用
top -bn1 | head -3
```

**成功判据是 `accelerated_count > 0` + `accel_mode=2`**，不是
`/proc/net/nf_conntrack` 里的 `HW_OFFLOAD` 标记——qca-nss-ecm 不经过 nf_flow_table，
刷机后 `HW_OFFLOAD` 仍然是 0，但加速确实在跑。

测 WiFi 加速时注意：**先停掉 OpenClash**（fake-IP DNS + tproxy 会让流量走用户态，
永不加速），并且让测试流量真正从 WiFi 网卡出去（PC 同时插着网线时要绑定源地址或加
/32 路由），否则 `accelerated_count` 测到的是有线路径。

### WiFi 加速验证（可直接照抄）

```sh
# 路由器：暂停代理，抓一次当前加速连接数
/etc/init.d/openclash stop
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count

# 客户端：绑定 WiFi 源地址持续下载（示例用清华镜像的固定 IP + Host 头，绕开 DNS）
curl --interface <WiFi 地址> -o /dev/null -H 'Host: mirrors.tuna.tsinghua.edu.cn' \
     --max-time 40 http://101.6.15.130/ubuntu/ls-lR.gz

# 路由器：在流量进行中抓 dump，确认这条 WiFi 连接是 accel_mode=2
ecm_dump.sh > /tmp/ecm.txt
grep -A3 "sip_address=<WiFi 地址>" /tmp/ecm.txt | head
grep    "nss_v4.ported.accel_mode=2" /tmp/ecm.txt | head
grep -c "accel_mode=2" /tmp/ecm.txt      # 应明显 > 0

/etc/init.d/openclash start              # 测完恢复（rule 模式配置不变）
```

---

## 已知坑（按踩坑顺序）

1. **nft flow offloading 影子 ECM**：症状是 `accelerated_count=0`、
   `default.pr.accel=denied`。修法见上文。默认镜像已内置。
2. **前台 SSH 触发 sysupgrade 会失败**：必须用 `( sysupgrade ... & )` 脱离会话。
3. **刷机后 DNS 断网**：如果旧配置里 dnsmasq 指向 OpenClash 的 `127.0.0.1#7874`，
   而 OpenClash 程序本体不随 sysupgrade 保留，解析全挂。临时改回 `223.5.5.5`。
4. **`bonding` 不能裁掉**：`kmod-qca-nss-ecm`/`bridge_mgr`/`vlan` 硬依赖它，
   但上游 bonding 缺少 NSS 需要的 `bond_cb` 注册回调 → 必须打 rebase 补丁。
5. **WiFi NSS 补丁不能"按需裁剪"**：补丁之间有隐式依赖，失败一个就整条链重来；
   用 `regen-nss-hunks.py` 重新生成 hunk，而不是手写。
6. **`make package/kernel/mac80211/prepare` 是唯一可靠的补丁验证方式**：直接
   `patch -p1` 用 fuzz 0 会误报，真实构建用 fuzz 2。
7. **PC 上的代理/双栈会污染 offload 测试**：FlClash 之类的 fake-IP 会把域名解析成
   `198.18.x.x`，让测试流量根本到不了路由器转发路径。

---

## 仓库结构

```
nss-ax6-stock/
├── README.md                    # 本文档
├── CREDITS.md                   # 上游来源与许可
├── port-nss-to-immortalwrt.sh   # 主移植脚本（6 步，幂等）
├── build-ax6-nss.sh             # 一键构建（含完整 .config）
├── port-wifi-nss.py             # phase-2：WiFi NSS 补丁移植
├── regen-nss-hunks.py           # phase-2：失败的 hunk 用 diff 重生成
├── patch-platform-sh.py         # platform.sh 单卷升级补丁器
├── patches/                     # 20 个内核补丁（含手工 rebase 的 bonding）
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
| WiFi NSS 失效 | 可把 `ath11k.nss_offload` 置 0（或 `nss_offload=0` 启动参数）回退到原生 ath11k 路径 |

真机备份（配置 tar + mtd0-8 含不可再生的 `art`）不在本仓库，属于个人设备数据。

---

## 文档

- [docs/JOURNAL.md](docs/JOURNAL.md) — 逐小时构建记录、失败尝试与修复过程
- [CREDITS.md](CREDITS.md) — 每个文件的上游来源、许可与手工改动说明

## 下载 / 许可

- Release：[`v25.12-nss`](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss)（sysupgrade 镜像 + SHA256）
- 代码与脚本：GPL-2.0（与 OpenWrt / ImmortalWrt / NSS 驱动一致）
- `patches/`、`files/` 保留其上游项目许可；不含 Qualcomm 专有固件（由 `nss-firmware` 包自行下载）
