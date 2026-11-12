# 构建时间线与踩坑记录（原始日志）

> 这是移植过程中逐小时留下的原始记录：失败尝试、修复过程、验证输出。
> 保留下来供未来升级内核 / 排错时对照。
> 可用的使用文档见 [README](../README.md)，上游来源见 [CREDITS](../CREDITS.md)。

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


### 11:39–11:47 platform.sh 双反斜杠：sysupgrade 被自己的补丁毒死（重要）

带 OpenClash 的镜像（27,658,516 B，sha256 `4f77e48ce03a753ad92fa35b6fde985879ae218aa5eb7bcf8d7d38c03d05c5b4`）
上传到 `/tmp/oc-image.bin`、sha256 核对一致，执行 `sysupgrade -v` 后立刻中止：

```
/sbin/sysupgrade: /lib/upgrade/platform.sh: line 263: syntax error: unexpected newline (expecting ")")
```

**设备没被写坏**：sysupgrade 在 source platform.sh 阶段就退出，还没碰 flash。但后果同样严重——
这台机器当时**完全无法升级**，任何一次 sysupgrade 都会停在这一行。

根因在构建树的 `target/linux/qualcommax/ipq807x/base-files/lib/upgrade/platform.sh`：

```
^Iredmi,ax6-stock|\\$          ← 行尾是「两个」反斜杠
```

shell 里 `\\` 是「转义后的反斜杠字面量」，不是续行符；`case` 的模式在换行处被截断，
于是解析到换行时报 `unexpected newline`。正确写法是单个 `\`。

来源：**最早那版 `build-ax6-nss.sh` 的 heredoc 写进 `\\\\`（shell 折叠成 `\\`）**，
后来虽然把这段 heredoc 换成调用 `patch-platform-sh.py`，但树里已被写坏的文件没人回头修，
而每次编译都把它原样打进 rootfs。也就是说：

- `patch-platform-sh.py` 本身是**对的**（普通字符串里 `\\` → 单反斜杠）。事后端到端复核：
  拿 `git show HEAD:…/platform.sh` 原始 363 行文件跑一遍，输出 `redmi,ax6-stock|\`，
  `sh -n` 通过，再跑一次打印 `already patched`（幂等）。
- 真正的问题是「坏脚本看起来专业，但只有它被真正执行过」——审查报告 P0-4 早已写出这个风险，
  只是没人把它当作必须先验证的阻断项。

修复：

1. 树里的两行（`redmi,ax6-stock|`、`xiaomi,ax3600-stock|`）改成单反斜杠，`sh -n` 通过；
2. 设备上同一文件同样修好（`/lib/upgrade/platform.sh` 备份在 `/tmp/platform.sh.broken`），
   `sh -n` 通过，设备恢复「可升级」能力；
3. 给两个脚本加了**硬断言**：`port-nss-to-immortalwrt.sh` 补丁后 `sh -n` 失败则 `FAIL=1`；
   `build-ax6-nss.sh` 失败则打印 `sh -n` 前 3 行并 `exit 1`。两个脚本 `bash -n` 均通过。

教训：**凡是往 rootfs 里塞 shell 脚本的移植步骤，编译前必须 `sh -n`**。
一个字符的转义错误不会在编译期报错，只会在你最需要刷机的那天报错。

顺带：这次也确认了 `4f77e48c` 这个镜像不可作为发布产物（platform.sh 是坏的），
所以后续还要重编一次，正好把「常用内核模块」一并编进去。