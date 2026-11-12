# images/

镜像二进制不放进 git（体积 + 校验），随 GitHub Releases 发布。三个 Release 的
asset 文件名相同，本地校验时按下表重命名，再 `sha256sum -c SHA256SUMS`。

| Release | 内容 | 大小 | 校验时重命名为 | sha256 |
|---|---|---|---|---|
| [v25.12-nss-p3](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss-p3) | phase-3：chain-events/fullcone 支持、镜像尺寸守卫、大包改运行时 apk；WiFi+有线 NSS | 34,058,516 B | `immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade-p3.bin` | `be8086583e0482f07909a39d2bf99107489213fba04f61423db81b39477facef` |
| [v25.12-nss-p2](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss-p2) | phase-2：有线 + WiFi NSS，含工具/cifs/samba4 | 36,034,836 B | `immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade-p2.bin` | `a3bb091c889de7048efa83b8a97de106990d778bf9055446360197dc19313016` |
| [v25.12-nss](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss) | phase-1：有线 NSS | 34,621,716 B | `immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade-p1.bin` | `ea0b8fe95f228115e8f4ccee161be2dc664792ba6e4da6a900f4f0d375557215` |

`immortalwrt-qualcommax-ipq807x.manifest` 是 p3 镜像的已装包清单，可与真机
`cat /lib/apk/db/installed` 对照。

校验：

```sh
sha256sum -c SHA256SUMS
```

三个版本都只适用于改机单卷布局（`redmi,ax6-stock`），不要刷到未改造的 AX6。
