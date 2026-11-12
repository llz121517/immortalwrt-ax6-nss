import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.path.insert(0, r"E:\Documents\Projects\TEMP\nss-ax6-stock\tools")
import arch as A
c = A.connect(timeout=30)
rc, out, err = A.run(
    "cd /home/neko/ax6/immortalwrt/target/linux/qualcommax/patches-6.12 && "
    "ls -1 06* 09*.patch 2>/dev/null | sort; echo '---count---'; ls -1 06* 09*.patch 2>/dev/null | wc -l",
    client=c, timeout=60)
print(out)
# pull every patch that is missing locally
import os, re
local = r"E:\Documents\Projects\TEMP\nss-ax6-stock\patches"
have = set(os.listdir(local))
names = [l.strip() for l in out.splitlines() if l.strip().endswith(".patch")]
missing = [n for n in names if n not in have]
print("have:", len(have), "remote:", len(names), "missing:", missing)
sf = c.open_sftp()
for n in missing:
    sf.get("/home/neko/ax6/immortalwrt/target/linux/qualcommax/patches-6.12/" + n, os.path.join(local, n))
    print("pulled", n)
sf.get("/home/neko/ax6/immortalwrt/target/linux/qualcommax/patches-6.12/../Makefile", os.path.join(local, "_qualcommax-Makefile"))
sf.close()
c.close()
