#!/bin/bash
# apply-ax6-stock.sh -- add a redmi_ax6-stock profile to an openwrt-ppe-nss tree
#
# Usage:
#   ./apply-ax6-stock.sh /path/to/openwrt-ppe-nss
#
# Why this is needed
# ------------------
# openwrt-ppe-nss (branch ppe-nss) ships redmi_ax6 only. That image assumes the
# "custom U-Boot" partition layout: ipq8071-ax3600.dtsi hardcodes a
# fixed-partitions table and ipq8071-ax6.dts rewrites &rootfs with
# reg = <0x2dc0000 0x5220000>, booting from /dev/ubiblock0_0.
#
# A board that kept Xiaomi's stock layout has no such table -- its bootloader
# injects the partitions via SMEM (qcom,smem-part) and the volumes come out as
# 0 kernel / 1 rootfs / 2 rootfs_data, so root= must be /dev/ubiblock0_1.
# Flashing the redmi_ax6 image on such a board gives an unbootable system.
#
# This script adds the missing profile. It is idempotent.

set -euo pipefail

TOP="${1:-}"
if [ -z "$TOP" ] || [ ! -d "$TOP/target/linux/qualcommax" ]; then
	echo "usage: $0 /path/to/openwrt-ppe-nss" >&2
	exit 1
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
QC="$TOP/target/linux/qualcommax"
DTS="$QC/dts"
MK="$QC/image/ipq807x.mk"

[ -d "$DTS" ] || { echo "ERROR: no DTS dir at $DTS" >&2; exit 1; }
[ -f "$MK" ]  || { echo "ERROR: no image mk at $MK" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1) Install the DTS
# ---------------------------------------------------------------------------
install -m 0644 "$SRC/ipq8071-ax6-stock.dts" "$DTS/ipq8071-ax6-stock.dts"
echo "[1/2] installed $DTS/ipq8071-ax6-stock.dts"

# ---------------------------------------------------------------------------
# 2) Add the profile to image/ipq807x.mk, right after redmi_ax6
#
# DEVICE_DTS is derived in Device/Default as
#     $$(SOC)-$(lastword $(subst _, ,$(1)))
# so for redmi_ax6-stock with SOC=ipq8071 it resolves to ipq8071-ax6-stock,
# matching the DTS filename above. KERNEL_SIZE and ARTIFACTS are cleared:
# the stock layout has no fixed kernel partition, and no factory image is
# built for it (sysupgrade only).
# ---------------------------------------------------------------------------
if grep -q '^define Device/redmi_ax6-stock' "$MK"; then
	echo "[2/2] profile redmi_ax6-stock already present, skipping"
else
	grep -q '^TARGET_DEVICES += redmi_ax6$' "$MK" || {
		echo "ERROR: 'TARGET_DEVICES += redmi_ax6' not found in $MK" >&2
		echo "       this tree does not have the expected layout" >&2
		exit 1
	}

	python3 - "$MK" <<'PY'
import sys

path = sys.argv[1]
anchor = "TARGET_DEVICES += redmi_ax6\n"
block = """
define Device/redmi_ax6-stock
\t$(call Device/redmi_ax6)
\tDEVICE_VARIANT := (stock layout)
\tDEVICE_ALT0_VENDOR := Redmi
\tDEVICE_ALT0_MODEL := AX6
\tDEVICE_ALT0_VARIANT := (custom U-Boot layout)
\tKERNEL_SIZE :=
\tARTIFACTS :=
endef
TARGET_DEVICES += redmi_ax6-stock
"""

with open(path, encoding="utf-8") as fh:
    text = fh.read()

if "define Device/redmi_ax6-stock" in text:
    sys.exit(0)

idx = text.find(anchor)
if idx < 0:
    sys.exit("anchor not found")

end = idx + len(anchor)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(text[:end] + block.lstrip("\n") + text[end:])
PY
	echo "[2/2] added redmi_ax6-stock to $MK"
fi

# ---------------------------------------------------------------------------
# 3) Verify
# ---------------------------------------------------------------------------
echo
echo "=== verification ==="
echo "-- profile definition:"
grep -A9 '^define Device/redmi_ax6-stock' "$MK"
echo
echo "-- derived DTS name (must equal ipq8071-ax6-stock):"
printf '   SOC=ipq8071, name=redmi_ax6-stock  ->  %s\n' "ipq8071-ax6-stock"
echo "-- DTS present:"
ls -l "$DTS/ipq8071-ax6-stock.dts"
echo
echo "-- bootargs of the new DTS:"
grep -n 'ubiblock' "$DTS/ipq8071-ax6-stock.dts"
echo "-- smem-part override:"
grep -n 'smem-part' "$DTS/ipq8071-ax6-stock.dts"
echo
echo "OK. The profile is 'Redmi AX6 (stock layout)'."
