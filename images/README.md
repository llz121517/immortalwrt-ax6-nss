# images/

镜像二进制不放进 git（体积 + 需要校验发布），随 GitHub Releases 发布：

| 版本 | 内容 | 镜像大小 | sha256 |
|---|---|---|---|
| [v25.12-nss-p2](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss-p2) | phase-2：有线 + WiFi 都由 NSS 加速，带常用工具 | 36,034,836 B | `a3bb091c…` |
| [v25.12-nss](https://github.com/llz121517/immortalwrt-ax6-nss/releases/tag/v25.12-nss) | phase-1：有线 NSS 加速（WiFi 为原生 ath11k） | 34,621,716 B | `ea0b8fe9…` |

完整校验和见 `SHA256SUMS`。两个版本都只适用于改机单卷布局（`redmi,ax6-stock`），
不要刷到未改造的 AX6 上。
