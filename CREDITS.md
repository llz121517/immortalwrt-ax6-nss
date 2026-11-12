# Credits & upstream sources

This repository is a *port*, not an original NSS implementation. The heavy
lifting is done by other projects — here is exactly what came from where, so
future readers can trace every file.

## Kernel patches, DTS and NSS driver stack

| Component | Upstream | Pinned ref used while porting |
|---|---|---|
| Kernel patches (`0600-*`, `0602-*`, `0603-*`, `0606-*`, `0981-1`) | [qosmio/openwrt-ipq](https://github.com/qosmio/openwrt-ipq) | branch `main-nss` (2026-11 snapshot; pin a commit when rebuilding) |
| NSS packages (`qca-nss-dp`, `qca_ssdk`, `qca-nss-drv`, `qca-nss-ecm`, bridge/vlan mgr, firmware) | [qosmio/nss-packages](https://github.com/qosmio/nss-packages) | branch `NSS-12.5-K6.x` |
| NSS device trees (`ipq8074-nss.dtsi`, `ipq6018-nss.dtsi`, `ipq5018-nss.dtsi`) | qosmio/openwrt-ipq | `target/linux/qualcommax/files/...` |
| `nf_conntrack_dscpremark_ext.[ch]`, `skbuff_recycle.[ch]`, `skbuff_debug.[ch]`, `skbuff_notifier.[ch]` | qosmio/openwrt-ipq + Qualcomm NSS drivers | copied from `files/net/core` and `files/net/netfilter` |

## Base firmware

- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt) `openwrt-25.12` branch
  (ImmortalWrt is OpenWrt-derived, GPL-2.0)
- [OpenWrt](https://github.com/openwrt/openwrt) — firewall4/nftables, procd,
  sysupgrade infrastructure used by the target

## Patches we modified

`patches/0600-3-qca-nss-ecm-support-bonding-rebased.patch` is **not** a straight
copy: it is a pristine-6.12.116 → final-tree diff of four `net/bonding` files
that folds qosmio's `0600-3` + `0600-4` together and restores the two LAG
transmit hunks by hand (see README for why `patch -F3` could not be trusted on
6.12.116). `patches/0981-1-...patch` also carries a local context fix for
hunk #29 plus explicit Kconfig symbols for the skb recycler.

## License

The scripts and documentation here are GPL-2.0 (matching the OpenWrt /
ImmortalWrt / NSS driver licenses). Files under `patches/` and `files/` remain
under the license of their upstream projects (GPL-2.0 for kernel/OpenWrt code,
Qualcomm's NSS driver terms for the driver stack).

No Qualcomm proprietary firmware is included in this repository; the NSS
firmware images (`qca-nss0-retail.bin`, `qca-nss1-retail.bin`) are downloaded by
the `nss-firmware` package from its own upstream.
