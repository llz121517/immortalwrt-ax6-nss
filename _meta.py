import sys, io, re
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
p = r"E:\Documents\Projects\TEMP\nss-ax6-stock\images\immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin"
b = open(p, "rb").read(8192)
for key in (b"board_name", b"supported_devices", b"metadata_version", b"target", b"version_number"):
    i = b.find(key)
    if i >= 0:
        seg = b[i:i+160]
        j = seg.find(b"\x00")
        print(seg[:j if j > 0 else 160].decode("ascii", "replace"))
