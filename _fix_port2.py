import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
R = r"E:\Documents\Projects\TEMP\nss-ax6-stock"
p = R + r"\port-nss-to-immortalwrt.sh"
r = open(p, encoding="utf-8").read()

old_dev = "\\t$(call Device/redmi_ax6)\n"
new_dev = ("\\t$(call Device/redmi_ax6)\n"
           "\\tDEVICE_PACKAGES += kmod-qca-nss-dp kmod-qca-nss-drv kmod-qca-nss-ecm \\\\\n"
           "\\t\\tkmod-qca-nss-drv-bridge-mgr kmod-qca-nss-vlan\n")
assert r.count(old_dev) == 1, "device anchor count=%d" % r.count(old_dev)
r = r.replace(old_dev, new_dev)

s = r.index('if grep -q \'kmod-qca-nss-drv\' "$MAKEFILE"; then')
e = r.index('\nfi\n', s) + len('\nfi\n')
r = r[:s] + """# NSS kmods are added to Device/redmi_ax6-stock's DEVICE_PACKAGES above, not
# to qualcommax's DEFAULT_PACKAGES: target-wide injection would pull ~2.5 MB of
# NSS kmods into every other ipq807x image, none of which has NSS nodes.
""" + r[e:]

r = r.replace("""cat > "$FW_DEFAULTS/99-nss-offload" <<'SH'
#!/bin/sh""", """cat > "$FW_DEFAULTS/99-nss-offload" <<'SH'
#!/bin/sh
# Only this board has the NSS/ECM layout that needs nft offload disabled.
[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "redmi,ax6-stock" ] || exit 0""")

open(p, "w", encoding="utf-8", newline="\n").write(r)
print("port script P1-4 patched; lines:", len(r.split("\n")))
