# Redmi AX6（ax6-stock）移植 NSS 硬件加速 — 交付说明

目标：在 **保留 ImmortalWrt 25.12** 的前提下，为改机版 Redmi AX6 启用 Qualcomm NSS/ECM 硬件 offload（有线 + WiFi 数据面），产出一个可 sysupgrade 的镜像，**不修改 U-Boot**。

---

## 一、为什么需要移植（实测依据）

| 检查项 | 实测结果 |
|---|---|
| `board_name` | `redmi,ax6-stock` |
| NAND 分区 | `qcom,smem-part`（bootloader 经 SMEM 传入，DTS 里无固定分区表） |
| UBI 卷 | `0 kernel` / `1 rootfs` / `2 rootfs_data` |
| ubiblock | 仅 `/dev/ubiblock0_1` → `root=` 必须是 `_1`（不是 `_0`） |
| U-Boot | `2016.01-ga67790948d`，25 个环境变量，**只有** `flag_boot_success=1` |
| 缺失变量 | 无 `flag_boot_rootfs` / `flag_last_success` / `flag_try_sys*` |
| 缺失分区 | **无 `rootfs_1`**（A/B 双系统不可用） |
| 当前 NSS 状态 | 无 `qca-nss-drv`/`qca-nss-ecm`，DTB 无 NSS 节点，`HW_OFFLOAD=0` |
| U-Boot 恢复能力 | 有 HTTP 恢复服务器（192.168.1.1）+ TFTP + 串口 → 有救砖兜底 |

**关键结论：**

1. 现有固件缺的是内核驱动 + DTB 节点，不是几个 apk 包 → 必须换内核/固件。
2. ImmortalWrt 官方 `ipq8071-ax6-stock.dts` **已经是正确的**（`ubiblock0_1` + `smem-part`），不用改。
3. **但** `platform.sh` 的 `redmi,ax6-stock` 分支是给小米 A/B U-Boot 写的，在这台机器上会因 `[ "" -eq "1" ]` 报 `ash: out of range` 而**升级失败** → 必须修。

---

## 二、移植内容（6 步，脚本自动化）

`port-nss-to-immortalwrt.sh` 在干净 ImmortalWrt 25.12 树上端到端实测通过（RC=0）：

| 步骤 | 改动 | 验证输出 |
|---|---|---|
| 1 | 加 `nss_packages` feed（`NSS-12.5-K6.x`，含 `0026-nss-drv-add-support-for-kernel-6.12.patch`） | ✅ |
| 2 | 装 9 个 NSS/ECM 内核钩子补丁（ECM CORE、PPPoE、bonding、macvlan、qdisc、bridge-mgr 等） | `nss patches: 9` |
| 3 | 加 3 个 NSS dtsi，并给 `ipq8071-ax3600.dtsi` 加 1 行 `#include "ipq8074-nss.dtsi"` | `nss dtsi: 3` |
| 4 | 校验 `ipq8071-ax6-stock.dts`（官方已正确，仅验证） | `root=: /dev/ubiblock0_1` |
| 5 | **`platform.sh` 改为单卷升级**（替换 A/B 逻辑） | `platform.sh: 1` |
| 6 | NSS kmods 进 `DEFAULT_PACKAGES` + `uci-defaults/99-nss-offload` 开启 `flow_offloading_hw` | `nss kmods: 2` |

### 内核补丁应用性 — 已实测（最有价值的验证）

用 **linux-6.12.116 官方源码**（与 ImmortalWrt 25.12 完全同版本）逐条 `patch` 实测：

| 补丁 | 结果 |
|---|---|
| `0600-0` rename nss region | ✅ PASS（依赖 ImmortalWrt 的 `0102` 先应用，顺序正确即可） |
| `0600-1` ECM CORE (30KB) | ✅ PASS |
| `0600-2` PPPoE offload | ✅ PASS |
| `0600-3` net bonding | ✅ PASS |
| `0600-5` macvlan | ✅ PASS |
| `0602-1` qdisc | ✅ PASS |
| `0603-1` qdisc clients | ✅ PASS |
| `0603-6` bridge-mgr | ✅ PASS |
| `0606-1` bridge VLAN fix | ✅ PASS |
| `0600-8` disable fraglist GRO | ❌ **不需要** — 6.12.116 上游已包含该改动，打不上也无影响 |

**结论：9/9 必需补丁全部能干净应用。**

### 为什么两边能对得上

移植来源 `qosmio/openwrt-ipq` 的 `main-nss` 分支**同样使用内核 6.12**，与 ImmortalWrt 25.12 一致：

- 两个 `ipq8071-ax3600.dtsi` **只差 1 行**（qosmio 多 `#include "ipq8074-nss.dtsi"`）
- `ipq8074-ess.dtsi` 两边 **MD5 完全相同**
- `nss-packages` 的 `qca-nss-drv` 有 `0026-nss-drv-add-support-for-kernel-6.12.patch`，原生支持 6.12

---

## 三、Kali 里怎么编译

前置：Kali 装好后，确认有 **≥20 GB 空闲磁盘**，网卡为 NAT 模式。

1. 把 `nss-ax6-stock/` 整个目录拷进 Kali（共享文件夹 / scp / U 盘均可），例如放到 `~/ax6-nss/port/`：

   ```bash
   mkdir -p ~/ax6-nss/port
   # 把这 15 个文件放进去（4 个脚本 + patches/ 下 10 个补丁）
   ```

2. 执行：

   ```bash
   cd ~/ax6-nss/port
   chmod +x build-in-kali.sh
   ./build-in-kali.sh
   ```

   脚本会自动：装依赖 → 克隆 3 个仓库 → 移植 → `feeds update/install` → 写 `.config` → `make -j$(nproc)` → 打印镜像路径。

首次编译约 **40–90 分钟**（取决于 CPU 核数）。日志在 `~/ax6-nss/build.log`。

3. 产物：

   ```
   ~/ax6-nss/immortalwrt/bin/targets/qualcommax/ipq807x/*redmi_ax6-stock*squashfs-sysupgrade.bin
   ```

---

## 四、刷机前必做（回滚保险）

```bash
# 1) 备份当前配置
ssh root@192.168.10.1 'sysupgrade -b /tmp/backup-$(date +%F).tar.gz'
scp root@192.168.10.1:/tmp/backup-*.tar.gz .

# 2) 记下当前固件版本，必要时可回刷官方 ImmortalWrt 25.12.1
ssh root@192.168.10.1 'cat /etc/os-release | head -3'
```

**救砖方式（已确认存在）**：断电 → 按住 reset → 上电 → 浏览器打开 **http://192.168.1.1** → HTTP 恢复页上传固件。

> 注意：U-Boot 里**没有** `bootcount`/`altbootcmd`，所以**不会自动回滚**，失败需手动进恢复模式。

---

## 五、刷入与验证

```bash
scp *redmi_ax6-stock*squashfs-sysupgrade.bin root@192.168.10.1:/tmp/
ssh root@192.168.10.1 'sysupgrade -v /tmp/<镜像名>'
# 等约 2-3 分钟自动重启
```

重启后验证 NSS 是否真正工作：

```sh
# 1) 驱动加载了吗
lsmod | grep -E 'qca_nss|ecm'
ls /dev/nss*            # 应出现 NSS 字符设备
ls /sys/kernel/debug/nss* 2>/dev/null

# 2) 硬件 offload 生效了吗（关键判据）
grep -c HW_OFFLOAD /proc/net/nf_conntrack     # 应 > 0
grep -c '\[OFFLOAD\]' /proc/net/nf_conntrack

# 3) NSS 固件版本
dmesg | grep -i nss | head -20
cat /sys/module/qca_nss_drv/parameters/* 2>/dev/null

# 4) 负载对比（刷机前 CPU ~5.9% @ 97Mbps）
top -bn1 | head -3
```

**成功判据**：`HW_OFFLOAD` 计数 > 0（此前是 0，只有 `OFFLOAD` 软件加速）。

---

## 六、风险与已知不确定

| 项 | 等级 | 说明 |
|---|---|---|
| `ubiblock0_1` 写错 | 🔴 会砖 | 已确认官方 DTS 就是 `_1`，且未改动 |
| `platform.sh` 未修 | 🟠 升级失败 | 已由 `patch-platform-sh.py` 修复并实测 |
| NSS 驱动编译失败 | 🟡 可控 | 补丁针对 6.12，但 ImmortalWrt 补丁基座有 3 个差异补丁，可能需要微调 |
| WiFi offload 稳定性 | 🟡 未知 | qosmio README 只把 AX3600 列为测试板；AX6 同 SoC/同 dtsi，理论同构但无硬件证据 |
| 首次编译耗时 | 🟢 低 | 40–90 分钟 |

**真正会变砖的路径只有一条**：`root=` 卷号写错。这一点已被官方 DTS 规避，且脚本不修改它。

---

## 七、交付物

```
nss-ax6-stock/
├── port-nss-to-immortalwrt.sh    # 主移植脚本（6 步，幂等）
├── patch-platform-sh.py          # platform.sh 单卷升级补丁器（可独立运行）
├── build-in-kali.sh              # Kali 一键编译脚本
├── apply-ax6-stock.sh            # 早期版本，仅加 profile（已被主脚本取代）
└── patches/                      # 10 个 NSS/ECM 内核补丁
```

---

## 八、进度状态

- [x] 三条现网取证（U-Boot 变量 / UBI 卷序 / MTD 分区）
- [x] 确认 NSS 包原生支持内核 6.12（`0026-nss-drv-add-support-for-kernel-6.12.patch`）
- [x] 确认两边 dtsi/ess.dtsi 兼容性（`ax3600.dtsi` 仅差 1 行、`ess.dtsi` MD5 相同）
- [x] 确认 platform.sh 硬性阻断并写出修复
- [x] 移植脚本端到端实测通过（RC=0）
- [x] **9 个内核补丁在 linux-6.12.116 上逐条实测通过**
- [x] Kali 一键编译脚本
- [ ] **在 Kali 内实际编译**（等待 Kali 安装/网络就绪）
- [ ] 产出并验证 sysupgrade 镜像
- [ ] 刷机并验证 `HW_OFFLOAD > 0`

---

## 九、验证证据摘要（2026-11-11）

**设备侧实测**
```
board_name                 redmi,ax6-stock
partitions                 qcom,smem-part, 10 qcomsmem partitions found
UBI volumes                0 kernel / 1 rootfs / 2 rootfs_data
ubiblock                   only /dev/ubiblock0_1
U-Boot                     2016.01-ga67790948d, 25 vars, flag_boot_success=1 only
fw_printenv flag_boot_rootfs   rc=1, empty        -> A/B 不可用
grep rootfs_1 /proc/mtd    0                       -> 无第二分区
HW_OFFLOAD in conntrack    0                       -> 硬件 offload 未启用
OFFLOAD in conntrack       90                      -> 仅软件 offload
CPU @ 97 Mbps / 7500 pps   5.9% total (1.3%/core)  -> 现状不瓶颈，但 NSS 可释放
```

**补丁应用性实测**（linux-6.12.116 官方源码 + ImmortalWrt `0102` 前置）
```
PASS  0600-0 rename nss region
PASS  0600-1 ECM CORE
PASS  0600-2 PPPoE offload
PASS  0600-3 net bonding
PASS  0600-5 macvlan
PASS  0602-1 qdisc
PASS  0603-1 qdisc clients
PASS  0603-6 bridge-mgr
PASS  0606-1 bridge VLAN fix
N/A   0600-8 disable fraglist GRO   (6.12.116 已含此改动)
```

---

## 夜间编译进度（2026-11-11 22:5x，交接备忘）

### 已完成的基建
- 构建树已从 **5400rpm 机械盘（/dev/sdb1）搬到 SSD（/dev/sda2）**，用 bind 挂载保持原路径 `/home/neko/ax6`，并写入 `/etc/fstab`（`bind,nofail`）。迁移后逐文件校验：415,098 files / 6,520,166,210 B 完全一致。
- 迁移前丢掉了半成品内核目录 `build_dir/target-aarch64_cortex-a53_musl/linux-qualcommax_ipq807x`，避免被 SIGTERM 截断的 `.o`（mtime 新于 `.c`）在链接 `vmlinux` 时才爆错。
- 工具链所有 stamp 完好（`.gcc_final_installed` 22:38 完成）：**无需重编工具链**。
- 构建机是 Dell Inspiron 15-3567 / i5-7200U（2C4T）；**风扇由 Dell EC 管，Linux 写 `pwm1_enable` 返回 EINVAL，不可控**。满载温度 76–82 °C（Tjmax 100）。关掉 Firefox 后速度快约一倍。

### 日志与关键监控点
```
远程日志        /home/neko/ax6/build3.log
续跑标记        === MIGRATED_TO_SSD_RESUME ===
成功标记        EXIT_CODE=0          （注意：54084 行有迁移前的 EXIT_CODE=143，是 SIGTERM，不是失败）
镜像输出        immortalwrt/bin/targets/qualcommax/ipq807x/
本地监控记录    E:\Documents\Projects\TEMP\build_monitor.txt
```

### 恢复/续跑方法（若中途断了）
```bash
ssh neko
cd /home/neko/ax6/immortalwrt
make -j4 V=s >> /home/neko/ax6/build3.log 2>&1; echo EXIT_CODE=$? >> /home/neko/ax6/build3.log
```

### 出镜像后的验收清单（未做，明天一起）
1. `ls bin/targets/qualcommax/ipq807x/` 有 `*redmi_ax6-stock*squashfs-sysupgrade.bin`
2. `.manifest` 含 `kmod-qca-nss-drv`、`kmod-qca-nss-ecm`、`kmod-qca-nss-drv-bridge-mgr`、`kmod-qca-nss-dp`、`nss-firmware-ipq807x`
3. 编出的 DTB 里存在 `nss@40000000` 节点
4. 内核 cmdline 是 `root=/dev/ubiblock0_1`（**唯一真正的砖机风险点**）
5. `platform.sh` 里 `redmi,ax6-stock` 走 `NSS-STOCK-SINGLE-VOLUME` 单卷分支

### 已备份
- 路由器现场快照 10 份 + 配置备份 `router-preflash/preflash-cfg-20261111-221115.tar.gz`（16.7 MB，MD5 a59d8888734167d0f5061cd5db45c574）
- 路由器 U-Boot 有 HTTP 恢复（http://192.168.1.1），但**无 A/B 回滚**

### 23:17 首次失败与修复（重要，勿删）
内核编完后 `qca-nss-ecm` 编译失败：
```
frontends/ecm_front_end_common.c:32:10: fatal error:
  net/netfilter/nf_conntrack_dscpremark_ext.h: No such file or directory
ERROR: package/feeds/nss_packages/qca-nss-ecm failed to build
```
根因：移植时**漏了 `0600-6` 内核补丁**。`nss-packages/qca-nss-ecm/Makefile` 里硬编码
`KCONFIG:=CONFIG_NF_CONNTRACK_DSCPREMARK_EXT=y`，且默认开 `ECM_CLASSIFIER_DSCP_ENABLE=y`，
所以这个 netfilter DSCP-remark 扩展是**编译必需**，不是可选项。

修复（已写入 `port-nss-to-immortalwrt.sh` 第 2 步，脚本 422 行，`bash -n` 通过）：
```
patches-6.12/0600-6-qca-nss-ecm-support-netfilter-DSCPREMARK.patch
patches-6.12/0600-7-qca-nss-ecm-fix-IPv6-user-route-change-event-calls.patch   (顺便补的 IPv6 修复)
files/include/net/netfilter/nf_conntrack_dscpremark_ext.h
files/net/netfilter/nf_conntrack_dscpremark_ext.c
```
注意：`0600-6` 只改 Kconfig/Makefile/extend 注册，**真正实现**在那两个 `files/` 源文件里，
OpenWrt 会把 `target/linux/qualcommax/files/**` 覆盖进内核树 —— 漏了源文件照样编不过。

验证记录：
```
make target/linux/prepare   PREPARE_RC=0   （日志 prepare.log）
内核 .config                 CONFIG_NF_CONNTRACK_DSCPREMARK_EXT=y   ✅
内核树                       net/netfilter/{Kconfig,Makefile}, nf_conntrack_extend.h 均含 DSCPREMARK ✅
23:24 重启编译               === RESUME_AFTER_DSCP_FIX === 内核重编中，63°C
```

### 散热/静音设置（临时，凌晨恢复）
```
no_turbo=1  max_perf_pct=75  RAPL pl1=11W   -> 满载 ~63-65°C（原始 15W/100% 时 80°C）
恢复满速：no_turbo=0, max_perf_pct=100, pl1=15000000
```
风扇由 Dell EC 直管，`pwm1_enable` 写入返回 EINVAL，**软件无法控制**，只能靠压温度。

### 兜底
Windows 端计划任务 `AX6-AutoSleep-Fallback`（07:00 休眠），任务完成后应删除。

### 23:45–23:56 第二轮失败与修复（ECM conntrack API / PPP / skb recycler，重要）

第二轮 `EXIT_CODE=2` 是三组独立问题叠在一起，全部已修：

**1) ECM 的 conntrack notifier 类型不匹配 —— 根因是 ImmortalWrt 的 fullcone**

```
ecm_conntrack_notifier.c:438: passing argument 2 of 'nf_conntrack_register_notifier'
                              from incompatible pointer type
ecm_conntrack_notifier.c:484: too few arguments to function 'nf_conntrack_unregister_notifier'
```
内核 6.12.116 的头文件是二选一：
```c
#ifdef CONFIG_NF_CONNTRACK_CHAIN_EVENTS
  int  nf_conntrack_register_notifier(struct net *, struct notifier_block *);
  int  nf_conntrack_unregister_notifier(struct net *, struct notifier_block *);
#else
  void nf_conntrack_register_notifier(struct net *, const struct nf_ct_event_notifier *);
  void nf_conntrack_unregister_notifier(struct net *);
#endif
```
ECM 是按下面那套（`nf_ct_event_notifier`）写的。我们内核里 `CONFIG_NF_CONNTRACK_CHAIN_EVENTS=y`
来自 **`kmod-nft-fullcone` 的 Makefile 硬写 `KCONFIG:=CONFIG_NF_CONNTRACK_CHAIN_EVENTS=y`**，
而 `firewall4` 又硬依赖 `+kmod-nft-fullcone`（ImmortalWrt 的全锥 NAT 特性）→ 每次 `make defconfig` 都把它带回来。

修复（NSS 已经在硬件层做 offload，软件全锥本来就冗余）：
```
package/network/config/firewall4/Makefile  去掉 "+kmod-nft-fullcone"
.config                                    # CONFIG_PACKAGE_kmod-nft-fullcone is not set
```
注意：只在 `.config` 里关掉没用，`firewall4` 的依赖会在 `defconfig` 时重新拉起来；
只改 Makefile 而不关 `.config` 也没用，因为 defconfig 会保留已有选择。**两处都要改。**

**2) ECM 无条件引用 PPP/PPTP/L2TP 内核 API**

```
ecm_interface.c: error: implicit declaration of function '__ppp_is_multilink'
ecm_interface.c: error: implicit declaration of function '__ppp_hold_channels'
ecm_interface.c: error: storage size of 'info' isn't known
ecm_interface.c: error: implicit declaration of function 'pppol2tp_channel_addressing_get'
ecm_interface.c: error: implicit declaration of function 'pptp_session_find'
ecm_interface.c: error: implicit declaration of function 'pptp_channel_addressing_get'
```
这些不是"开了 PPP 功能才编"，而是 ECM 源码里无条件调用 → **必须**补内核补丁：
`0603-2-qca-nss-clients-add-l2tp-support.patch`、`0603-3-qca-nss-clients-add-PPTP-support.patch`。

**3) 补丁集扩到 20 个，并逐个验证可应用性**

之前只挑了 11 个，太窄。现在镜像 qosmio 的 `patches-6.12` 全集，排除 4 个不适用的：
```
0600-8   upstream 6.12.116 已含同样内容（NETIF_F_SOFT_FEATURES_OFF），hunk 冲突且无需
0600-4   LAG over bonding，include/net/bonding.h hunk 5 打不上，我们不用链路聚合
0603-5   VXLAN，drivers/net/vxlan/vxlan_core.c hunk 5 打不上，kmod-vxlan 未启用
0607-2   IPsec，net/xfrm/xfrm_state.c hunk 4 打不上，kmod-ipsec 未启用
```
最终 20 个：`0600-{0,1,2,3,5,6,7}`, `0602-1`, `0603-{1,2,3,4,6,7,8}`, `0604-1`, `0605-1`,
`0606-1`, `0607-1`, `0981-1`。

> 2026-11-12 更新：上面的 `0600-4` 后来还是需要了 —— ECM 的 bond notifier 和
> qca-nss-clients 的 bridge/vlan mgr 会无条件调用 `bond_register_cb()` /
> `struct bond_cb` / `bond_get_id()`，没有它就编不过（详见「01:02–01:30 最后一关」）。
> 现在用的是 `patches/0600-3-qca-nss-ecm-support-bonding-rebased.patch`：
> 原始 6.12.116 → 最终树的 diff（合并 0600-3 + 0600-4，但丢掉 0600-4 最后两个
> LAG 发包热路径 hunk），对原始源码 `patch -p1 --dry-run` 干净通过。
> 脚本里的补丁清单仍写 0600-3 这个名字，只是内容换成了 rebase 版。

**4) skb recycler（nss-drv 必需）**

`qca-nss-drv` 要驱动 `0981-1` 引入的 skb recycler。两个坑：
- hunk #29 打不上：6.12.116 的 `pskb_carve_inside_nonlinear()` 在 `skb_release_data()` 之前
  多了 `if (skb_zcopy(skb)) net_zcopy_get(...)` 两行。已在本地 `patches/0981-1-...patch`
  里把该 hunk 上下文补上（本仓库自带副本，脚本优先用它，不动 qosmio 原件）。
- `make syncconfig` 直接 abort：
  ```
  Enable preallocation of SKBs (SKB_RECYCLER_PREALLOC) [N/y/?] (NEW)
  scripts/kconfig/Makefile:85: syncconfig Error 1
  ```
  新符号必须写进 `target/linux/qualcommax/config-6.12`，否则非交互配置失败。已加：
  ```
  CONFIG_SKB_RECYCLER=y
  CONFIG_SKB_RECYCLER_MULTI_CPU=y
  # CONFIG_SKB_RECYCLER_PREALLOC is not set   （16384 x 4K = 64MB，1GB 内存路由器不划算）
  CONFIG_SKB_RECYCLE_SIZE=2304
  # CONFIG_ALLOC_SKB_PAGE_FRAG_DISABLE is not set
  ```

验证记录：
```
make target/linux/prepare   PREPARE6_RC=0   （20 个补丁全部干净应用，日志 prepare6.log）
23:56:38 重启编译           === RESUME_AFTER_KCONFIG_FIX ===  内核重编中
```
`port-nss-to-immortalwrt.sh` 已同步：新增第 2b 步（recycler 符号 + 剥 firewall4 fullcone 依赖）、
补丁清单扩到 20、优先使用仓库内 `patches/` 副本、`files/` 里补了 dscpremark 的 .h/.c。

### 固件版本必须选 12.5（不是默认的 11.4）

`nss-packages/firmware/nss-firmware/Makefile` 的 choice **默认是 11.4**，而 feed 分支叫
`NSS-12.5-K6.x`。这个符号同时决定 `qca-nss-drv` 用哪套驱动源码：

```make
ifeq ($(CONFIG_NSS_FIRMWARE_VERSION_11_4),y)
  PKG_SOURCE_DATE:=2021-09-13        # nss-drv 11.4.0.5，2021 年基线
  PATCH_DIR:=$(CURDIR)/patches-11.4
  QSDK_VERSION:=11.4.0.5
endif
```
- 12.5 驱动树里有 `patches/0026-nss-drv-add-support-for-kernel-6.12.patch`
- 11.4 树没有 6.12 支持（2021 年只有 5.4），在 6.12.116 上基本是坑
- `qca-nss-ecm/Makefile:171` 只在 12.5 模式下加 `-DNSS_FIRMWARE_VERSION_12_5`

所以 `.config` 必须显式写：
```
CONFIG_NSS_FIRMWARE_VERSION_12_5=y
# CONFIG_NSS_FIRMWARE_VERSION_11_4 is not set
```
改这个**不需要重编内核**（只影响包），已编好的内核 .o 会复用。

### WiFi NSS：本版先不合并（第二阶段）

`.config` 里我原先写的 `CONFIG_ATH11K_NSS_WIFI=y` / `CONFIG_PACKAGE_kmod-nss-wifi-drv=y`
在 defconfig 时被**静默丢弃**了：ImmortalWrt 树里没有任何包提供它们。真正的 NSS WiFi offload 需要：
```
qosmio-ipq/package/kernel/mac80211/patches/nss/ath11k   69 个补丁
qosmio-ipq/package/kernel/mac80211/patches/nss/subsys   27 个补丁
qosmio-ipq/package/kernel/mac80211/patches/nss/ath10k   2 个补丁
+ qca-nss-drv 的 CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE 等一套内核配置
```
98 个 mac80211 补丁要对着 ImmortalWrt 的 ath11k 版本重排，风险和工作量都不小，
不适合在凌晨一次搞定（编坏了还得刷机验证）。**今晚先出「有线 NSS offload + 原生 WiFi 正常」的镜像**，
WiFi 也走 NSS 作为第二阶段，明天一起做、用 sysupgrade 迭代验证。

### 00:04 自己踩的坑：两次 make 并发把内核编译搞坏了（别再犯）

为切 NSS 固件版本，我 `pkill -f 'make -j4 V=s'` 后立刻重启了编译 —— 但顶层 make 死了，
**内核子 make 还活着**（子进程 cmdline 里没有 `-j4 V=s`，匹配不到）。结果两个 make 同时编译同一批文件：

```
make[9]: cannot open jobserver /tmp/GMfifo1039378: No such file or directory
  CC      drivers/irqchip/irq-gic-v4.o      <- 同一文件被编译两次
fixdep: error opening file: drivers/irqchip/.irq-gic-v4.o.d: No such file or directory
make[9]: *** [scripts/Makefile.build:229: drivers/irqchip/irq-gic-v4.o] Error 2
```
后半段 `fs/ext4/hash.o Error 2`、`built-in.a Error 123` 都是同一个原因。

正确做法：
```bash
pgrep -af 'immortalwrt|linux-6.12.116'      # 先把所有相关进程列出来
pkill -9 -f 'linux-6.12.116'
pkill -9 -f 'immortalwrt/build_dir'
sleep 2; pgrep -af 'immortalwrt'            # 确认 count=0 再重启
rm -rf build_dir/target-*/linux-qualcommax_ipq807x   # 被并发写坏的 .o/.d 全删，别指望增量
```
**教训：改内核相关配置必须停干净再重启；被并发踩过的内核目录只能整个删掉重编。**

验证记录（进行中）：
```
00:07:17 清理后重启   === RESUME_AFTER_CLEANKERNEL ===  内核从头重编
```

### 镜像与验证结果（09:46 最终版）

```
EXIT_CODE=0
bin/targets/qualcommax/ipq807x/immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin
17,705,236 B   sha256 df0418b89842db21079dfc1d823c3bf2500ac738a3e24f6e1bb2c522b378d9ad
内核: 5,620,152 B（含内嵌 DTB）
版本: ImmortalWrt 25.12-SNAPSHOT r0-761b7ff, kernel 6.12.116
```

> 01:32 那版 sha256 是 `4a266cc5…`，bonding 里少两条 LAG 发包路径；09:46 补回后已重打，
> 两版大小相同（17,705,236 B）但内容不同，**以 09:46 这版为准**。

镜像已复制两份（等今天一起刷）：
- Arch: `~/ax6/out/immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin`
- Windows: `E:\Documents\Projects\TEMP\nss-ax6-stock\images\`（含 `.manifest` 和 `SHA256SUMS.txt`）

逐项验证（全部通过）：

| 检查 | 结果 |
|---|---|
| manifest 里 NSS 包 | `kmod-qca-nss-dp`、`kmod-qca-nss-drv` 12.5.2024.11.13、`kmod-qca-nss-drv-bridge-mgr`、`kmod-qca-nss-drv-vlan-mgr`、`kmod-qca-nss-ecm` 12.5.2024.11.06、`nss-firmware` + `nss-firmware-ipq807x` 2025.05.01 |
| `kmod-nft-fullcone` | 不在 manifest（0 处）——fullcone 关闭，ECM conntrack notifier 才编得过 |
| `firewall4` | 在（2025.03.17-r2），nftables 防火墙正常 |
| 内核命令行 | `root=/dev/ubiblock0_1` ✔（唯一真砖点，必须这个值） |
| 内嵌 DTB | `nss@40000000`、`nss@40800000`、`nss@4b000000`、`qcom,nss*` 全在 |
| NSS 固件 | `qca-nss0-retail.bin` 836,448 B / `qca-nss1-retail.bin` 295,356 B |
| NSS 内核模块 | `qca-nss-dp.ko`、`qca-nss-drv.ko`(478K)、`qca-nss-bridge-mgr.ko`、`qca-nss-vlan.ko` |
| UCI/初始化 | `/etc/config/ecm`、`/etc/config/nss`、`init.d/qca-nss-drv`、`init.d/qca-nss-ecm`、`init.d/skb_recycler` |
| sysctl | `sysctl.d/qca-nss-ecm.conf` |
| platform.sh | 含 `NSS-STOCK-SINGLE-VOLUME`（单 UBI volume 直写，不做 A/B） |

### 01:02–01:30 最后一关：ECM 的 bonding 依赖（0600-4 的取舍）

`qca-nss-ecm` 连挂三次，全部指向同一个根因链：

1. `ecm_bond_notifier.c` 用了 `struct bond_cb` / `bond_register_cb()` ——
   这套 QCA 扩展 API 只由 `0600-4-qca-nss-ecm-support-net-bonding-over-LAG-interface.patch` 提供。
2. 试过 `# CONFIG_PACKAGE_kmod-bonding` 关掉它，defconfig 又变回 `=y` —— 因为
   `qca-nss-drv-bridge-mgr` / `vlan-mgr` / `nss-clients` 都**硬依赖** `+kmod-bonding`。
3. 转头把 0600-4 打上：`patch -F3` 能过，但 `bond_3ad.c hunk#3` 和 `bond_main.c` 最后两个
   hunk（`bond_3ad_xor_xmit` / `__bond_start_xmit` 的 LAG 发包改写）在 6.12.116 上需要 fuzz 2~3、
   偏移 55~119 行 —— 结果 fuzz 把声明插进了内核 doc 注释里，还插错到相近函数
   `ad_enable_collecting()`（不是 `ad_enable_collecting_distributing()`）。
4. 最终做法：**先打 0600-4 的 22 个 hunk，砍掉最后两个 LAG 发包热路径 hunk**（当晚先出镜像），
   然后手工把 `bond_3ad.c hunk#3` 的声明放到正确函数里。
   之后 `ecm.ko`、`qca-nss-bridge-mgr.ko`、`qca-nss-vlan.ko` 全部编过。

结果：`bond_get_id` / `bond_cb` / `bond_3ad_get_tx_dev` 三个 API 都在内核里，
ECM 的 bond frontend 正常编入。

**09:43 已把砍掉的两个 LAG 发包 hunk 手工接回来了**（详见下一节），现在 24 个 hunk 全齐。

**已顺手做完**：把修复结果固化成 `patches/0600-3-qca-nss-ecm-support-bonding-rebased.patch`
（原始 6.12.116 → 最终树的完整 diff，744 行、24 个 hunk 全齐），
对原始源码 `patch -p1 --dry-run` 干净通过；移植脚本已改用它，下次从头构建不用再手改。

### 09:35–09:46 把 LAG 发包 hunk 也接回来了（强迫症治愈）

起因：用户「这个功能能加回来吗 我有强迫症哎」。评估后发现不难 —— 缺的只是**两个调用点**，
地基（`bond_3ad_get_tx_dev()` 完整实现、`bond_xmit_xor()` 完整实现、`bond_get_id`/`bond_cb`）
在 22-hunk 版本里早就有了。

做法：**不用 `patch -F3` 让 fuzz 猜位置，而是对着 6.12.116 的真实函数体手写改写**
（`_port_lag_tx.py`，幂等）：

1. `bond_3ad_xor_xmit()`（bond_main.c:5658）：选口改成
   `outdev = bond_3ad_get_tx_dev(skb, NULL, NULL, NULL, NULL, 0, dev, NULL)`，
   选不出 `dev_kfree_skb()` + `NETDEV_TX_OK`，选出来 `bond_dev_queue_xmit()`。
2. `__bond_start_xmit()`（bond_main.c:5915）：6.12.116 比 qosmio 基于的版本多了
   `bond_should_broadcast_neighbor()` 分支和 8023AD→XOR 的 fallthrough，所以不能照抄原 hunk。
   正确移植：`BOND_MODE_8023AD` 保持自己的 `bond_3ad_xor_xmit()`（去掉 fallthrough），
   `BOND_MODE_XOR` 单独走 `bond_xmit_xor()`。否则 8023AD 会误走 XOR 的哈希选路。

验证（这次的证据链比"能编过"硬）：
```
旧镜像 bonding.ko 224,760 B  sha 02ef7202…   bond_3ad_get_tx_dev 调用 1 次
新镜像 bonding.ko 224,904 B  sha ede41431…   bond_3ad_get_tx_dev 调用 2 次   ← 新增那处就是 bond_3ad_xor_xmit
新镜像 bonding.ko 里 bond_cb / bond_register_cb / bond_get_id 符号都在
rootfs 里 bonding.ko / ecm.ko / 4 个 nss ko / 2 个 nss 固件全在
```

耗时：增量重编 **约 4 分钟**（09:43 启动 → 09:46 出新镜像，只重编 `bond_main.o` → `bonding.ko`
→ vmlinux 重链 → 重打 rootfs）；`EXIT_CODE=0`，零错误。

补丁已重新生成：744 行（原 705 行 + 这两个 hunk），dry-run 干净，仓库和 Arch 上
`~/ax6/scripts/patches/` 都已更新。

### 收尾状态

- 编译结束 01:30，09:46 又补了 LAG 发包路径重打一次；两次都 `EXIT_CODE=0`。
- 性能已恢复满速：`no_turbo=0`、`max_perf_pct=100`、PL1 `15000000`（09:43 设置）。
- 两台机器昨晚都挂起（Arch 笔记本 + Windows PC），Arch 上的兜底计划任务
  `AX6-AutoSleep-Fallback` 已删除；今早 09:35 用户手动按电源键唤醒 Arch。
- **没有刷机**，等今天一起；路由器现在还是原厂 ImmortalWrt 25.12.1 r37978，bash 5.3.20 已装、
  默认 shell 仍是 `/bin/ash`、OpenClash 保留规则模式。
- 顺便确认：原厂固件其实带了 `qca-nss-dp.ko`，但没有 `nss-drv`/`ecm`，所以 NSS 从来没真正跑起来
  （与 `HW_OFFLOAD=0`、kallsyms 无 `nss_drv` 一致）。
- 今天议程：① 一起确认镜像→刷机（sysupgrade -n，救援靠 U-Boot HTTP `http://192.168.1.1`）；
  ② 刷好后验 `nss_drv` 加载、`HW_OFFLOAD=1`、桥/VLAN 流量走 NSS、CPU 占用；
  ③ 第二阶段 WiFi NSS（98 个 mac80211 补丁）。
