import io, sys, os
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
R = r"E:\Documents\Projects\TEMP\nss-ax6-stock"

def read(f): return open(os.path.join(R, f), encoding="utf-8").read()
def write(f, t): open(os.path.join(R, f), "w", encoding="utf-8", newline="\n").write(t)

def cut(text, start_marker, end_marker, include_end=True):
    i = text.index(start_marker)
    j = text.index(end_marker, i)
    if include_end: j += len(end_marker)
    return i, j

# ---------------- build-ax6-nss.sh ----------------
p = read("build-ax6-nss.sh")
# P0-4: replace duplicated python heredoc with a call to the tested patcher
s = p.index('\tpython3 - "$PLATFORM" <<\'PY\'')
e = p.index("\nPY\n", s) + len("\nPY\n")
p = p[:s] + '\tpython3 "$(dirname "$0")/patch-platform-sh.py" "$PLATFORM"\n' + p[e:]
# P0-5: nft offload must stay OFF
s = p.index("cat > \"$UCI_DIR/99-nss-offload\" <<'SH'")
e = p.index("\nSH\n", s) + len("\nSH\n")
p = p[:s] + '''cat > "$UCI_DIR/99-nss-offload" <<'SH'
#!/bin/sh
# nft flow offloading must stay OFF: fw4's software flowtable takes over
# established flows before ECM's conntrack hook runs, so ECM never sees the
# return direction and ecm_classifier_default denies acceleration forever.
# Let qca-nss-ecm own the fast path (verified: accel_mode=2, accelerated_count>0).
uci -q set firewall.@defaults[0].flow_offloading='0'
uci -q set firewall.@defaults[0].flow_offloading_hw='0'
uci -q commit firewall
exit 0
SH
''' + p[e:]
p = p.replace("# uci-defaults 开启硬件 offload", "# uci-defaults 关闭 nft offload（ECM 独占快路径）")
# P2-14: wrong acceptance criterion
p = p.replace(
 "grep -c HW_OFFLOAD /proc/net/nf_conntrack     # 期望 > 0（刷前是 0）",
 "cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count  # 跑流量时 > 0（实测 14~20）\n"
 "ecm_dump.sh | grep 'nss_v4.ported.accel_mode' | head      # 出现 accel_mode=2")
write("build-ax6-nss.sh", p)
print("build-ax6-nss.sh patched")

# ---------------- build-in-kali.sh ----------------
q = read("build-in-kali.sh")
q = q.replace("""# Wi-Fi data path offload (ath11k -> NSS)
CONFIG_ATH11K_NSS_WIFI=y
CONFIG_PACKAGE_kmod-nss-wifi-drv=y""",
"""# NSS firmware 12.5: the 11.4 choice is the default and its driver tree does
# not build on 6.12.x; qca-nss-ecm only adds -DNSS_FIRMWARE_VERSION_12_5 here.
CONFIG_NSS_FIRMWARE_VERSION_12_5=y""")
write("build-in-kali.sh", q)
print("build-in-kali.sh patched")

# ---------------- port-nss-to-immortalwrt.sh (P1-4) ----------------
r = read("port-nss-to-immortalwrt.sh")
# 1) device-level packages instead of target-level DEFAULT_PACKAGES
old_dev = "\\t$(call Device/redmi_ax6)\\n"
new_dev = ("\\t$(call Device/redmi_ax6)\\n"
           "\\tDEVICE_PACKAGES += kmod-qca-nss-dp kmod-qca-nss-drv kmod-qca-nss-ecm \\\\\\n"
           "\\t\\tkmod-qca-nss-drv-bridge-mgr kmod-qca-nss-vlan\\n")
assert r.count(old_dev) == 1, "device anchor not found"
r = r.replace(old_dev, new_dev)
# 2) drop the target-wide DEFAULT_PACKAGES injection
s = r.index('if grep -q \'kmod-qca-nss-drv\' "$MAKEFILE"; then')
e = r.index('\nfi\n', s) + len('\nfi\n')
r = r[:s] + """# NSS kmods are added to Device/redmi_ax6-stock's DEVICE_PACKAGES above, not
# to qualcommax's DEFAULT_PACKAGES: target-wide injection would pull ~2.5 MB of
# NSS kmods into every other ipq807x image, none of which has NSS nodes.
""" + r[e:]
# 3) uci-defaults: only act on this board
r = r.replace("""cat > "$FW_DEFAULTS/99-nss-offload" <<'SH'
#!/bin/sh""", """cat > "$FW_DEFAULTS/99-nss-offload" <<'SH'
#!/bin/sh
# Only this board has the NSS/ECM layout that needs nft offload disabled.
[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = "redmi,ax6-stock" ] || exit 0""")
write("port-nss-to-immortalwrt.sh", r)
print("port script P1-4 patched")
