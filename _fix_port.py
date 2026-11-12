import io, sys
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

p = r"E:\Documents\Projects\TEMP\nss-ax6-stock\port-nss-to-immortalwrt.sh"
text = open(p, encoding="utf-8").read()
lines = text.split("\n")

# --- locate the QS-gated patch block (1-based 131..213) ---
start = None
for i, ln in enumerate(lines):
    if ln.startswith('if [ -n "$QS" ] && [ -d "$QS/target/linux/qualcommax/patches-6.12" ]; then'):
        start = i
        break
assert start is not None, "patch block not found"
# find the matching `fi` line for this if: scan forward until a line == "fi"
end = None
for j in range(start + 1, len(lines)):
    if lines[j] == "fi":
        end = j
        break
assert end is not None, "matching fi not found"
print("replacing lines", start + 1, "..", end + 1)

new_block = r'''# Every patch below is vendored in this repo, so the qosmio tree is optional
# here: it is only consulted as a fallback when the repo copy is missing.
FAIL=0
PATCHES=(
	0600-0-arm64-dts-ipq8074-rename-nss-region.patch
	0600-1-qca-nss-ecm-support-CORE.patch
	0600-2-qca-nss-ecm-support-PPPOE-offload.patch
	0600-3-qca-nss-ecm-support-bonding-rebased.patch
	0600-5-qca-nss-ecm-support-macvlan.patch
	0600-6-qca-nss-ecm-support-netfilter-DSCPREMARK.patch
	0600-7-qca-nss-ecm-fix-IPv6-user-route-change-event-calls.patch
	0602-1-qca-nss-drv-add-qdisc-support.patch
	0603-1-qca-nss-clients-add-qdisc-support.patch
	0603-2-qca-nss-clients-add-l2tp-support.patch
	0603-3-qca-nss-clients-add-PPTP-support.patch
	0603-4-qca-nss-clients-add-iptunnel-support.patch
	0603-6-qca-nss-clients-add-bridge-mgr-support.patch
	0603-7-qca-nss-clients-iptunnel-lock-this-cpu.patch
	0603-8-qca-nss-clients-add-tls-mgr-support.patch
	0604-1-qca-add-mcs-support.patch
	0605-1-qca-nss-cfi-support.patch
	0606-1-qca-nss-ecm-bridge-Fixes-for-Bridge-VLAN-Filtering.patch
	0607-1-qca-nss-clients-iptunnel-fixes.patch
	0981-1-qca-skb_recycler-support.patch
)
installed=0
for p in "${PATCHES[@]}"; do
	# Prefer the copy shipped in this repo: it may carry a locally
	# rebased hunk (0981-1's last hunk needs extra context lines that
	# 6.12.116 has and qosmio's 6.12 snapshot did not).
	s="$SRC/patches/$p"
	if [ ! -f "$s" ] && [ -n "$QS" ]; then
		s="$QS/target/linux/qualcommax/patches-6.12/$p"
	fi
	if [ ! -f "$s" ]; then
		printf '   [!!] missing source patch %s\n' "$p"
		FAIL=1
		continue
	fi
	if [ -f "$QC/patches-6.12/$p" ]; then
		skip "$p already present"
		continue
	fi
	cp "$s" "$QC/patches-6.12/$p"
	installed=$((installed + 1))
	ok "$p"
done
printf '   installed %d kernel patches\n' "$installed"

# 0600-6 only patches Kconfig/Makefile/extend registration; the actual
# netfilter DSCP-remark extension lives in two plain source files that
# OpenWrt copies into the kernel tree from target/linux/<target>/files/.
# Miss them and qca-nss-ecm cannot compile.
# 0981-1 does the same thing for the skb recycler: net/core/skbuff.c gets
# `#include "skbuff_recycle.h"` and net/core/Makefile gets
# `obj-$(CONFIG_SKB_RECYCLER) += skbuff_recycle.o`, but the implementation
# is not in the patch.  Without these two files the kernel dies with
#   net/core/skbuff.c:95:10: fatal error: skbuff_recycle.h: No such file
#   or directory
for kf in \
	include/net/netfilter/nf_conntrack_dscpremark_ext.h \
	net/netfilter/nf_conntrack_dscpremark_ext.c \
	net/core/skbuff_recycle.c \
	net/core/skbuff_recycle.h \
	net/core/skbuff_debug.c \
	net/core/skbuff_debug.h \
	net/core/skbuff_notifier.c \
	net/core/skbuff_notifier.h
do
	dst="$QC/files/$kf"
	if [ -f "$dst" ]; then
		skip "$kf already present"
		continue
	fi
	src="$QS/target/linux/qualcommax/files/$kf"
	if [ ! -f "$src" ]; then
		src="$SRC/files/$(basename "$kf")"
	fi
	if [ -f "$src" ]; then
		mkdir -p "$(dirname "$dst")"
		cp "$src" "$dst"
		ok "kernel file $kf"
	else
		printf '   [!!] missing kernel file %s -- qca-nss-ecm will NOT build\n' "$kf"
		FAIL=1
	fi
done'''

lines = lines[:start] + new_block.split("\n") + lines[end + 1:]
text = "\n".join(lines)

def sub(old, new, count=1):
    global text
    assert text.count(old) >= 1, "missing: " + old[:60]
    text = text.replace(old, new, count)

# dtsi fallback failure
sub("""	printf '   [!!] cannot find %s\\n' "$name"
}""", """	printf '   [!!] cannot find %s\\n' "$name"
	FAIL=1
}""")

# stock dts failures (must be fatal to avoid bricking)
sub("""		printf '   [!!] %s exists but is not the stock-layout version; check it by hand\\n' "$STOCK_DTS\"""",
    """		printf '   [!!] %s exists but is not the stock-layout version; check it by hand\\n' "$STOCK_DTS"
		FAIL=1""")
sub("""	printf '   [!!] %s missing -- this ImmortalWrt branch is too old for the stock layout\\n' "$STOCK_DTS\"""",
    """	printf '   [!!] %s missing -- this ImmortalWrt branch is too old for the stock layout\\n' "$STOCK_DTS"
	FAIL=1""")

# platform.sh arm missing
sub("""	printf '   [!!] no redmi,ax6-stock arm in %s -- check the tree\\n' "$PLATFORM\"""",
    """	printf '   [!!] no redmi,ax6-stock arm in %s -- check the tree\\n' "$PLATFORM"
	FAIL=1""")

# fatal exit after verification block
sub("""printf 'nss kmods:     '; grep -c 'kmod-qca-nss-drv' "$MAKEFILE" || true

echo""",
    """printf 'nss kmods:     '; grep -c 'kmod-qca-nss-drv' "$MAKEFILE" || true

if [ "$FAIL" -ne 0 ]; then
	printf '\\n[FAIL] one or more required pieces are missing -- tree will NOT build\\n' >&2
	exit 1
fi

echo""")

open(p, "w", encoding="utf-8", newline="\n").write(text)
print("patched, lines:", len(text.split("\n")))
