import sys, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
sys.path.insert(0, r"E:\Documents\Projects\TEMP\nss-ax6-stock\tools")
import arch as A
c = A.connect(timeout=30)
import base64
data = open(r"E:\Documents\Projects\TEMP\nss-ax6-stock\build-ax6-nss.sh","rb").read()
rc, out, err = A.run_script("cat > /tmp/b.sh <<'EOF'\n" + data.decode() + "\nEOF\nbash -n /tmp/b.sh && echo BASH_OK", timeout=60, client=c)
print("build-ax6-nss.sh:", out.strip() or err.strip()[:200])
c.close()
