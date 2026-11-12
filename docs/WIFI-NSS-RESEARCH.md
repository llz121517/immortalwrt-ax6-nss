# Redmi AX6 阶段二：WiFi 数据面 NSS 硬件加速 — 预调研报告

> 只读调研。结论均基于构建机 `192.168.10.133` 实测；未实测项标注**未验证**。树：`immortalwrt@761b7ff`(openwrt-25.12, kernel 6.12.116)、`qosmio-ipq@92a2d10`(main-nss)、`nss-packages@0d970db`(NSS-12.5-K6.x)。
> 试验副本：`/tmp/bt/backports-6.18.55`（自 `immortalwrt/dl/backports-6.18.55.tar.zst` 解出）、`/tmp/full/base`。**两棵源码树零改动**。

---

## 一、架构：ath11k → mac80211 → NSS.WIFI → NSS core
```
   ┌── 控制面 (A53 Host) ──────────────────────────────┐
   │ hostapd/wpa_supplicant ─ nl80211 ─ cfg80211       │
   │            └─ mac80211(NSS补丁) ─ ath11k.ko       │
   │                 ┌─────────┴──────────┐            │
   │           nss.c │ ath11k_nss_*   原生dp_rx        │
   │                 ▼                    ▼            │
   │      NSS.WIFI(wifili) 消息 ──▶ WMI/HTC ──▶ Q6 FW  │
   └─────────────────┬─────────────────────────────────┘
                     │ nss_wifi_* API
   ┌─────────────────▼─────────────────────────────────┐
   │ qca-nss-drv.ko   ← dev.nss.general.redirect 开关   │
   └─────────────────┬─────────────────────────────────┘
                     │ qca-nss{0,1}-retail.bin
   ┌─────────────────▼─────────────────────────────────┐
   │ NSS core 0/1: NSS.WIFI → NSS.ECM 流表 → EDMA → WAN│
   └───────────────────────────────────────────────────┘
     ▲ 数据面全程不过 A53；例外包经 redirect 回 mac80211
```| 通路 | 机制 | 证据 |
|---|---|---|
| **TX** WiFi→WAN | 802.3 帧交 `ath11k_nss_tx()` → NSS.WIFI 直入 NSS，**跳过** TCL/EDMA 环 | `patches/nss/ath11k/199-003:89-200`（`CPTCFG_ATH11K_NSS_SUPPORT`） |
| **RX** WAN→WiFi | ECM 流表命中 → NSS.WIFI 直出空口，Host 不下发 | `qca-nss-ecm.init:198` `[ -d .../ecm_nss_ipv4 ] && sysctl -w dev.nss.general.redirect=1` |
| **例外回注** | 未命中/MCBC/EAPOL/4addr → `nss_redirect` 回 mac80211 | `subsys/207-mac80211-add-nss-redirect-support.patch` |

**`nss_offload=1` 时 Host 中断被裁掉**：`199-003:45-70` 中 `if (!nss_offload && ab->hw_params.ring_mask->tx[i] ...)` —— TCL completion / REO dest / ERR / h2rxdma 环在 NSS 模式**不注册中断**。这是"真加速"与"软件 offload"的分界。

## 二、组件清单

| # | 组件 | 来源 | 现状 |
|---|---|---|---|
| 1 | mac80211 NSS 补丁(subsys) | `qosmio-ipq/…/patches/nss/subsys/` | ❌ 27 个 |
| 2 | ath11k NSS 补丁 | `…/patches/nss/ath11k/` | ❌ 69 个（新增 `nss.c` 5090 行 + `nss.h`） |
| 3 | ath10k NSS 补丁 | `…/patches/nss/ath10k/` | ❌ 2 个，本机无 ath10k，**不打** |
| 4 | mac80211 Makefile 钩子 | `qosmio-ipq/…/mac80211/Makefile:49,379-399` | ❌ 不存在 |
| 5 | ath.mk Kconfig 声明 | `qosmio-ipq/…/mac80211/ath.mk:379-397` | ❌ 不存在 |
| 6 | NSS core 固件 | `nss-packages/firmware/nss-firmware` | ✅ `NSS.FW.12.5-210-HK.R` 已装 |
| 7 | ath11k 固件 | `immortalwrt/…/ath11k-firmware` | ⚠️ `2.9.0.1-02146`（qosmio 用 2.12） |
| 8 | `NSS_DRV_WIFIOFFLOAD_ENABLE` | `nss-packages/qca-nss-drv/Config.in:249` | ❌ `not set` |
| 9 | `/etc/init.d/qca-nss-pbuf` | `qosmio-ipq/…/files/qca-nss-pbuf.init` | ❌ 不存在（**必需**） |
| 10 | `nss_diag.sh` / ECM wifi redirect | `…/files/nss_diag.sh`；`…/qca-nss-ecm.init:198` | ❌ 不存在（可选）/ ✅ 脚本已在 |

**无用户态守护进程**。NSS WiFi offload 是纯内核态：ath11k 内建 `nss.c` 直接调 `qca-nss-drv` 导出的 `nss_wifi_*` API。第 9 项是唯一必需的运行时初始化脚本（配 `n2h_wifi_pool_buf`）。

---

## 三、补丁盘点

### 3.1 总量
```
$ for d in subsys ath10k ath11k; do echo "$d files=$(ls $P/$d/*.patch|wc -l) hunks=$(cat $P/$d/*.patch|grep -c '^@@')"; done
subsys files=27 hunks=242 | ath10k files=2 hunks=5 | ath11k files=69 hunks=1027
合计 98 文件 / 1274 hunk
```

### 3.2 版本对齐 —— **不一致**
| 项 | ImmortalWrt | qosmio | 差异 |
|---|---|---|---|
| mac80211 `PKG_VERSION` | **6.18.55**（`Makefile:13`） | **6.18.26**（`Makefile:13`） | 差 29 个 backports |
| backports hash | `ca3666d1…` | `2ad578c6…` | 不同 |
| 自有 ath11k / subsys 补丁 | 21 / 19 | 20 / 23 | qosmio 少 `984-…memory-leak` 多 `949-…monitor-rx-pktlen`；subsys **差 4 个** |

**但两树同为 6.18.x 代**，hunk 上下文同源 —— 这是可打性 93/98 的根本原因。IW 的 `patches/subsys/`、`patches/ath11k/` 是**独立维护**的补丁集，导致少量冲突。

### 3.3 可打性实测（真实构建顺序）
方法：`/tmp/full/base` ← 解 `backports-6.18.55`，**先按 IW Makefile 顺序打 13 个目录共 160 个 IW 自有补丁**，**再按 `NSS_PATCH:= subsys ath10k ath11k` 打 98 个 NSS 补丁**（均 `-F2 --forward`）。

```
#### PHASE A: IW 自有补丁（复现真实构建态）
IWDIR build 20/0fail subsys 19/0 ath 8/0 ath5k 5/0 ath9k 24/0 ath10k 11/0
IWDIR ath11k 21/0 ath12k 6/0 rt2x00 21/0 mt7601u 2/0 mwl 6/0 brcm 16/0 rtl 1/0
#### PHASE B: NSS 补丁叠加
NSS on top of IW: OK=93  FAIL=5  fuzz>0=2      ← 94.9%
```
> 注：仅对 NSS 补丁逐个孤立 dry-run 会得到 40/58 的误导性结果（序列补丁需按序叠加）。

| 失败补丁 | 目标 | 失败 hunk | .rej 原文要点 | 归类 |
|---|---|---|---|---|
| `subsys/203-…fw-dynamic-muedca` | `nl80211.h:1361` | 1/4 | `NL80211_CMD_UPDATE_HE_MUEDCA_PARAMS` 枚举插入点被挤走 | rebase（纯位置） |
| `subsys/300-…mesh-offload` | `mac80211/tx.c:2986` | 1/11 | `ieee80211_build_hdr` 的 `nss_mesh:` 标签处已重构 | rebase（mesh，可跳过） |
| `ath11k/068-…rx-histogram-stats` | `ath11k/hal_rx.c:1541` | 1/4 | `ath11k_hal_rx_parse_mon_status_tlv` 签名 `ab`→`ar` | rebase（monitor，非核心） |
| `ath11k/211-002-…WDS-offload-STA` | `ath11k/dp_rx.c:2882` | 1/2 | `ath11k_dp_rx_h_find_peer(ab,…)`→`(ar,…)` | rebase（4addr，非核心） |
| `ath11k/999-900-bss-transition` | `mac.c:912`/`wmi.c:161` | 3/154 | `WMI_TAG_WDS_ADDR_EVENT` 等 TLV 表插入点漂移 | rebase（802.11v，非核心） |

**核心补丁全部干净落地**：`subsys/199-001`、`ath11k/199-002`+`199-003` 零失败。验证：
```
$ ls -la /tmp/full/base/drivers/net/wireless/ath/ath11k/nss.c
-rw-r--r-- 1 neko neko 142597  nss.c        ← 5090 行，完整生成（nss.h 15694 B）
$ grep -c ATH11K_NSS_SUPPORT …/ath11k/Kconfig      → 2
$ grep -c MAC80211_NSS_SUPPORT /tmp/full/base/local-symbols → 1
$ grep -c 'nss.o' …/ath11k/Makefile                → 2
```
fuzz>0 的 2 个：`ath11k/237-006`(fuzz=1)、`ath11k/335-0002`(fuzz=2) —— 已应用但需人工复核。

### 3.4 与 IW 补丁集的交集
ImmortalWrt **无 NSS 相关补丁**（`grep -nE 'nss|NSS' package/kernel/mac80211/Makefile` → **0 命中**），无 `patches/nss/`，`ath.mk` 无 NSS 符号。NSS 补丁叠加在 IW 补丁集之后，语义冲突仅上述 5 处。

---

## 四、必需配置符号（已验证存在）

### 4.1 kernel 符号 —— **由补丁新增**，当前树不存在
| 符号 | 声明位置 | 作用 |
|---|---|---|
| `ATH11K_NSS_SUPPORT` | 补丁 `ath11k/199-002:26-35` → `ath11k/Kconfig` | 编译 `nss.o`；`depends on ATH11K`，`select MAC80211_NSS_SUPPORT` |
| `MAC80211_NSS_SUPPORT` | 补丁 `subsys/199-001` → `net/mac80211/Kconfig` | mac80211 侧钩子 |
| `ATH11K_NSS_MESH_SUPPORT` | 补丁 `ath11k/300` | 802.11s offload |
| `MAC80211_NSS_SUPPORT=` | 补丁写入 `local-symbols` | **backports 符号白名单，缺失则静默丢符号** |

> **`CONFIG_ATH11K_NSS_WIFI` 不存在的根因**：真实符号是 `ATH11K_NSS_SUPPORT`，且由**补丁**引入；未打补丁的树里不存在，写进 defconfig 会被 kconfig 静默丢弃（Kconfig 无此 symbol → 无警告）。

### 4.2 package 符号 —— 由 `ath.mk` 新增（当前 `.config` 全部**无此行**）
`CONFIG_ATH11K_NSS_SUPPORT`(`ath.mk:379`, 默认 y)、`CONFIG_ATH11K_NSS_MESH_SUPPORT`(`ath.mk:396`, n)、`CONFIG_PACKAGE_MAC80211_NSS_SUPPORT`(`mac80211/Makefile:157`, y)、`CONFIG_PACKAGE_MAC80211_NSS_REDIRECT`(`mac80211/Makefile:162`, n，ath11k 不需要)。

`ath.mk:335-338` 自动依赖（开 `ATH11K_NSS_SUPPORT` 会连锁）：`+ATH11K_NSS_SUPPORT:kmod-qca-nss-drv` / `+@(ATH11K_NSS_SUPPORT):NSS_DRV_WIFIOFFLOAD_ENABLE` / `+@(ATH11K_NSS_SUPPORT):NSS_DRV_WIFI_EXT_VDEV_ENABLE`；`ath.mk:341-343` 自动加 `MODPARAMS.ath11k:=nss_offload=1 frame_mode=2`。

### 4.3 阶段二需打开的全部符号（含现状实测）
| # | 符号 | 现状 |
|---|---|---|
| 1 | `CONFIG_ATH11K_NSS_SUPPORT` | 不存在（需移植 ath.mk） |
| 2 | `CONFIG_PACKAGE_MAC80211_NSS_SUPPORT` | 不存在（需移植 Makefile） |
| 3 | `CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE` | **`# … is not set`（`.config:3047`）** ← 致命 |
| 4 | `CONFIG_NSS_DRV_WIFI_EXT_VDEV_ENABLE` | 不存在（被 3 连带） |
| 5 | `CONFIG_NSS_FIRMWARE_VERSION_12_5` | **`=y`（`.config:2327`）** ✅ |
| 6 | `CONFIG_NSS_MEM_PROFILE_HIGH` | **`=y`（`.config:3010`）** ✅ |
| 7 | `CONFIG_ATH11K_MEM_PROFILE_1G` | **IW 树无此符号**（`grep MEM_PROFILE ath.mk` → 0） |
| 8 | `CONFIG_PACKAGE_kmod-qca-nss-drv-wifi-meshmgr` | **`not set`（`.config:3067`）**，仅 mesh 需要 |

**关键**：`NSS_DRV_WIFIOFFLOAD_ENABLE` 当前 `not set` → 现有 nss-drv **没编译 wifili 代码**，ath11k 打补丁后会在链接期找不到 `nss_wifi_*` 符号。

---

## 五、固件清单

| 固件 | 文件名（实测） | 来源 | 体积 | 状态 |
|---|---|---|---|---|
| NSS core WiFi | `BIN-NSS.FW.12.5-210-HK.R.tar.bz2` → `retail_router{0,1}.bin` | `nss-packages/firmware/nss-firmware`（`PKG_VERSION:=2025.05.01`，`github.com/qosmio/qca-sdk-nss-fw`） | 压缩 282,564 B；装后 `qca-nss0-retail.bin` **836,448 B** + `qca-nss1-retail.bin` **295,356 B** = **1.11 MB** | ✅ 已装 |
| ath11k | `WLAN.HK.2.9.0.1-02146-QCAHKSWPL_SILICONZ-1/*` | IW `ath11k-firmware`（`PKG_SOURCE_DATE:=2024-10-14`） | IPQ8074 目录 5.4 MB（含全部版本） | ✅ 已装 |
| ath11k（qosmio 推荐） | `WLAN.HK.2.12-01460-QCAHKSWPL_SILICONZ-1/*` | `qosmio-ipq/…/ath11k-firmware:11` | **未验证** | ❌ 未装 |

版本串实测：`strings retail_router0.bin | grep Version` → **`Version: NSS.FW.12.5-210-HK.R`**。
打包逻辑（`nss-firmware/Makefile:44-56`）：`NSS_PROFILE:=R`，ipq807x 用 `NSS_SOC:=HK`，**两个 core 都装**。

**空间压力：无。** 镜像现状 `sysupgrade.bin` **17,705,236 B（16.9 MiB）**、`factory.ubi` 18,743,296 B；**WiFi offload 不新增任何固件文件** —— NSS.WIFI 功能代码就在已装的 `qca-nss{0,1}-retail.bin`（1.11 MB）内部，由 `NSS_DRV_WIFIOFFLOAD_ENABLE` 决定是否加载；1 GiB NAND + single-volume UBI（`platform.sh:262-272` `CI_UBIPART="rootfs"`）余量充足。

---

## 六、实施方案

**Step 0 前置校验（0.5 天）**：确认 `Config.in:249` 可开、`Makefile:320` 的 `ifndef` 分支；确认 `STAGING_DIR/usr/include/qca-nss-drv` 头文件可用（`mac80211/Makefile:312-314` 的 `IREMAP_CFLAGS` 依赖它）。

**Step 1 移植构建钩子（1 天）** —— 搬运 qosmio 3 处改动到 IW `package/kernel/mac80211/`：
- `Makefile`：`NSS_PATCH`(:49)、`PKG_CONFIG_DEPENDS` 两项(:39-40)、`PatchDir`/`Quilt-RefreshDir` 块(:394-399,416-419)、`KernelPackage/ath11k/install` 段(:442-453)
- `ath.mk`：Kconfig 声明(:379-397)、`config-$(…)+= ATH11K_NSS_SUPPORT`(:74)、`DEPENDS+=` 三行(:335-338)、`MODPARAMS`(:341-343)、`PKG_CONFIG_DEPENDS` 两项(:23-24)
- 拷贝 `files/qca-nss-pbuf.init`、`pbuf.uci`、`nss_diag.sh`、`disable_mesh_chksum_ath11k.hotplug`

**Step 2 拷贝补丁（0.5 天）**：`cp -a qosmio-ipq/…/patches/nss immortalwrt/…/patches/`；ath10k 子目录只留 `100-ath10k-move-peer-unmap-warning-to-debug.patch`。

**Step 3 处理 5 个冲突（2–4 天）**：
| 补丁 | 处理 | 工作量 |
|---|---|---|
| `subsys/203` nl80211.h | `NL80211_CMD_UPDATE_HE_MUEDCA_PARAMS` 插到 `@NL80211_CMD_MAX` 前 | 0.3 天 |
| `ath11k/068` hal_rx.c | 适配 `ab`→`ar` 签名，改 hunk 上下文 | 0.5 天 |
| `ath11k/211-002` dp_rx.c | `ath11k_dp_rx_h_find_peer(ar,…)` 已是 IW 形态，改写或删该 hunk | 0.5 天 |
| `ath11k/999-900` wmi.c/mac.c | 154 hunk 中 3 处 TLV 表插入点对位 | 1 天 |
| `subsys/300` tx.c(mesh) | **首版直接跳过**；需 mesh 时再 rebase | 1–2 天（可选） |

**Step 4 配置与编译（1 天）**：
```
CONFIG_ATH11K_NSS_SUPPORT=y
CONFIG_PACKAGE_MAC80211_NSS_SUPPORT=y
CONFIG_NSS_DRV_WIFIOFFLOAD_ENABLE=y
CONFIG_NSS_DRV_WIFI_EXT_VDEV_ENABLE=y
CONFIG_NSS_FIRMWARE_VERSION_12_5=y     # 已 y
CONFIG_ATH11K_MEM_PROFILE_1G=y          # 需先移植符号；AX6 为 1 GiB
```
编译顺序 `nss-drv → mac80211 → ath11k`。**首轮必有编译错误**（结构体成员差异），预留返工。

**Step 5 运行时校验（0.5 天）**：
```
cat /sys/module/ath11k/parameters/nss_offload      # 期望 1
cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count
sysctl dev.nss.general.redirect                     # 期望 1
logread | grep -i 'nss\|wifili'                     # vdev/peer create 成功；nss_diag 查版本
```
**验收**：WiFi 打流时 `accelerated_count` 增长，且 `nft list ruleset` 中 flowtable 仍为 0（阶段一约束）。

**Step 6 回归（1–2 天）**：WPA2/WPA3、HE160、双频并发、多次 `wifi reload`、STA+AP、重启 20 次。

---

## 七、风险表

| # | 风险 | 级 | 证据 / 说明 |
|---|---|---|---|
| R1 | **`NSS_DRV_WIFIOFFLOAD_ENABLE` 未开 → 链接失败** | 🔴 | `.config:3047` 为 `not set`；`nss-drv/Makefile:320` `ifndef` 分支传 `NSS_DRV_WIFIOFFLOAD_ENABLE=n` → `nss_wifi_*` 全缺 |
| R2 | **`local-symbols` 未打补丁 → 符号静默丢弃** | 🔴 | 白名单 507 行（`local-symbols:53` 附近）；缺 `MAC80211_NSS_SUPPORT=` 则 kconfig 丢弃且无报错 |
| R3 | **加密卸载 EAPOL/TKIP** | 🟠 | `subsys/657:8` 原文：*"EAP Frames over NL80211 Control port are 802.11 Native WiFi encapsulated by default, but for a vdev operating in 802.3, when FW doesn't advertise WMI_SERVICE_EAPOL_OVER_NWIFI, it cannot accept an 802.11 Native WiFi frame"* → **EAPOL 走错路径直接致 WPA 握手失败**；`subsys/146` 为 encap offload 特判 TKIP |
| R4 | **ath11k 固件 2.9.0.1 vs qosmio 2.12** | 🟠 | IW 用 `2.9.0.1-02146`，qosmio 用 `2.12-01460`。NSS WiFi 可能依赖 2.12 的 WMI 服务位。**未验证** 2.9 是否可用 |
| R5 | **MCBC 不做 PN 校验** | 🟠 | `ath11k/301:6` 原文：*"Since NSS FW is not supporting PN check for MCBC pkts, those pkts are excepted from NSS offload to pass through mac80211 PN check"* → 组播走软路径，性能不升但**不破坏安全性** |
| R6 | **mesh 与 NSS 12.5 固件不兼容** | 🟡 | `nss-firmware/Makefile` choice help：12.5 *"does NOT work with NSS MESH (802.11s)"*，仅 `11_4` *"WORKS with NSS MESH"*；`.config:2327` 是 12.5 → **mesh 不可用** |
| R7 | **threaded NAPI 必须开** | 🟡 | `ath11k/999-800` 给 ext_irq_grp 加 `dev_set_threaded(...,true)`；不开影响收包延迟 |
| R8 | **fast-rx 丢统计** | 🟡 | `ath11k/237-006` 引入 `stats_disable`；`qca-nss-pbuf.init:126-130` 默认取 `1`（`pbuf.uci` 内该行被注释），开启后丢 per-packet 统计 |
| R9 | **`n2h_wifi_pool_buf` 配错限并发** | 🟡 | `qca-nss-pbuf.init:86-106`：`1g*`→`36864`/`extra_pbuf_core0=10000000`；`512m*`→`8192`。AX6 1 GiB 必须 `1gb`（脚本注释：*"Enable if you have issues connecting more than 65 clients"*） |
| R10 | **802.11ax / HE160 回归** | 🟠 | **未验证**。NSS 补丁改 `mac.c` vdev 起停路径，HE 配置可能被绕过 |
| R11 | **与 Lead 并发编译冲突** | 🟡 | 本报告全部实测在 `/tmp` 完成；实施须待编译结束 |
| R12 | **fw 11.4/12.5 代码分叉** | 🟢 | `ath11k/999-312` 用 `#ifndef CONFIG_NSS_FIRMWARE_VERSION_11_4` 包裹 addr4 逻辑；当前 12.5 → 走非 11.4 分支，**路径正确** |

---

## 八、GO / NO-GO

### 结论：**GO — 条件性可行**

| 维度 | 评估 | 依据 |
|---|---|---|
| 补丁可打性 | ✅ **优** 93/98 = **94.9%** | `/tmp/full/base` 实测，仅 6 hunk 被拒 |
| 核心代码完整性 | ✅ **优** | `nss.c` 5090 行完整生成；Kconfig/local-symbols/Makefile 全落地 |
| 版本基线 | ✅ **可接受** | 两树 mac80211 同为 6.18.x，hunk 同源 |
| 固件 / 空间 | ✅ **就绪** | `NSS.FW.12.5-210-HK.R` 已装，无新增文件；16.9 MiB 镜像 / 1 GiB NAND |
| 配置符号 | ⚠️ **需移植** | 4 个 package + 3 个 kernel 符号当前全不存在 |
| 编译 / 运行时风险 | 🟠 **中高** | 结构体差异致首轮编译报错；加密卸载、固件版本、pbuf 需实测调优 |

**最大障碍**：① `NSS_DRV_WIFIOFFLOAD_ENABLE` 未开（R1）—— 一行配置，不改则链接必失败；② 构建钩子整体移植（Step 1）—— 3 文件约 60 行，纯手工；③ 5 个补丁 rebase（Step 3）—— 6 hunk 全是签名/位置漂移，**无逻辑重写**；④ 加密卸载路径（R3）—— EAPOL/TKIP 决定 WPA 握手成败。

**不建议**：① 不要一次打开 `ATH11K_NSS_MESH_SUPPORT` —— 12.5 固件明确不支持（R6），且 mesh 补丁正是失败项；② 不要先把 ath11k 固件升到 2.12 —— 先验证 2.9.0.1，避免引入第二变量；③ 不要动 `nft flowtable` —— 阶段一约束仍有效。

**工作量：6–10 人天**（不含 mesh；mesh 另加 2 人天且需降级到 NSS 固件 11.4）。

**三档分类**

| 档位 | 数量 | 说明 |
|---|---|---|
| **直接应用** | **93** | 零干预；其中 2 个带 fuzz（`237-006` fuzz=1、`335-0002` fuzz=2）需人工复核 |
| **需要 rebase** | **5** | 6 个 hunk，位置/签名漂移，无逻辑冲突 |
| **需要重写** | **0** | 未发现需重写逻辑的补丁 |

---

*基于 `/tmp/bt/backports-6.18.55` + `/tmp/full/base` 实测。标注**未验证**者未做实测。*