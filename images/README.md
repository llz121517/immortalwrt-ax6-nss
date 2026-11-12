# images/

镜像二进制不放进 git（体积 + 校验），随 GitHub Releases 发布。两个 Release 的
asset 文件名相同，本地校验时按下表重命名，再 `sha256sum -c SHA256SUMS`。

| Release | 内容 | 大小 | 校验时重命名为 | sha256 |
|---|---|---|---|---|
| [v25.12-nss-p2](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss-p2) | phase-2：有线 + WiFi NSS，含工具/cifs/samba4 | 36,034,836 B | `immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade-p2.bin` | `a3bb091c889de7048efa83b8a97de106990d778bf9055446360197dc19313016` |
| [v25.12-nss](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss) | phase-1：有线 NSS | 34,621,716 B | `immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade-p1.bin` | `ea0b8fe95f228115e8f4ccee161be2dc664792ba6e4da6a900f4f0d375557215` |

校验：

``sh
sha256sum -c SHA256SUMS
``

两个版本都只适用于改机单卷布局（`redmi,ax6-stock`），不要刷到未改造的 AX6。
