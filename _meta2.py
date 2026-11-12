import sys, io, json
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
p = r"E:\Documents\Projects\TEMP\nss-ax6-stock\images\immortalwrt-qualcommax-ipq807x-redmi_ax6-stock-squashfs-sysupgrade.bin"
full = open(p, "rb").read()
print("size", len(full))
tail = full[-16384:]
i = tail.find(b"supported_devices")
print("supported_devices at tail offset:", i)
# metadata may be a tar-ish trailing JSON; dump printable region around it
start = max(0, i - 2000) if i >= 0 else 0
seg = tail[start:start+4000]
txt = "".join(chr(c) if 32 <= c < 127 else ("\n" if c in (10, 0) else ".") for c in seg)
print(txt[:2600])
