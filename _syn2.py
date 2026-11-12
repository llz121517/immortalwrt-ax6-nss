import sys, io, base64
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.path.insert(0, r"E:\Documents\Projects\TEMP\nss-ax6-stock\tools")
import arch as A
c = A.connect(timeout=30)
for f in ["build-ax6-nss.sh", "build-in-kali.sh", "port-nss-to-immortalwrt.sh"]:
    data = open(r"E:\Documents\Projects\TEMP\nss-ax6-stock\" + f, "rb").read()
    b64 = base64.b64encode(data).decode()
    cmd = "echo '%s' | base64 -d > /tmp/chk.sh && bash -n /tmp/chk.sh && echo OK-%s" % (b64, f)
    rc, out, err = A.run(cmd, client=c, timeout=60)
    print(f, "->", (out.strip().splitlines() or ["?"])[-1], "|", err.strip()[:120])
c.close()
