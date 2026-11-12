#!/bin/bash
# build-in-kali.sh -- build the NSS-enabled ImmortalWrt image on a Debian/Kali box
#
# Run this INSIDE the Linux VM (Kali/Ubuntu/Debian), as a normal user with sudo.
#
#   ./build-in-kali.sh [workdir]
#
# workdir defaults to ~/ax6-nss. The script is safe to re-run: it skips the
# steps whose output already exists.
#
# Prerequisites it installs: build-essential, git, python3, rsync, unzip,
# wget, the usual OpenWrt host deps, and ~20 GB free disk.

set -euo pipefail

WORK="${1:-$HOME/ax6-nss}"
IW="$WORK/immortalwrt"
QS="$WORK/qosmio-ipq"
NSS="$WORK/nss-packages"
PORT="$WORK/port"            # where port-nss-to-immortalwrt.sh + patches live

IW_REPO="https://github.com/immortalwrt/immortalwrt.git"
IW_BRANCH="openwrt-25.12"
QS_REPO="https://github.com/qosmio/openwrt-ipq.git"
QS_BRANCH="main-nss"
NSS_REPO="https://github.com/qosmio/nss-packages.git"
NSS_BRANCH="NSS-12.5-K6.x"

say() { printf '\n\033[1m=== %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
say "0) checks"
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || { echo "run as a normal user, not root" >&2; exit 1; }

avail_gb=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
echo "free space in \$HOME: ${avail_gb} GB"
[ "$avail_gb" -ge 20 ] || { echo "need >=20 GB free, have ${avail_gb} GB" >&2; exit 1; }

nproc
free -h | head -2

# ---------------------------------------------------------------------------
say "1) build dependencies"
# ---------------------------------------------------------------------------
if ! command -v make >/dev/null || ! command -v gcc >/dev/null; then
	sudo apt-get update
	sudo apt-get install -y build-essential clang flex bison g++ gawk \
		gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev \
		python3 python3-setuptools rsync swig unzip zlib1g-dev file wget \
		libelf-dev bc
else
	echo "toolchain already present"
fi

# ---------------------------------------------------------------------------
say "2) sources"
# ---------------------------------------------------------------------------
mkdir -p "$WORK"

if [ -d "$IW/.git" ]; then
	echo "immortalwrt already cloned"
else
	git clone --depth 1 -b "$IW_BRANCH" "$IW_REPO" "$IW"
fi

if [ -d "$QS/.git" ]; then
	echo "qosmio tree already cloned"
else
	git clone --depth 1 -b "$QS_BRANCH" "$QS_REPO" "$QS"
fi

if [ -d "$NSS/.git" ]; then
	echo "nss-packages already cloned"
else
	git clone --depth 1 -b "$NSS_BRANCH" "$NSS_REPO" "$NSS"
fi

# ---------------------------------------------------------------------------
say "3) graft the NSS stack"
# ---------------------------------------------------------------------------
# The port script and its patches are expected next to this script, in ./port.
if [ ! -f "$PORT/port-nss-to-immortalwrt.sh" ]; then
	echo "ERROR: $PORT/port-nss-to-immortalwrt.sh not found." >&2
	echo "       Copy the nss-ax6-stock directory from the Windows host into" >&2
	echo "       $PORT before running this (see README)." >&2
	exit 1
fi

bash "$PORT/port-nss-to-immortalwrt.sh" "$IW" "$NSS" "$QS"

# ---------------------------------------------------------------------------
say "4) feeds"
# ---------------------------------------------------------------------------
cd "$IW"
./scripts/feeds update -a
./scripts/feeds install -a

# ---------------------------------------------------------------------------
say "5) config"
# ---------------------------------------------------------------------------
# Start from the ipq807x profile for this board and switch on the NSS bits.
cat > .config <<'EOF'
CONFIG_TARGET_qualcommax=y
CONFIG_TARGET_qualcommax_ipq807x=y
CONFIG_TARGET_qualcommax_ipq807x_DEVICE_redmi_ax6-stock=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_TARGET_PER_DEVICE_ROOTFS=y

# NSS / ECM offload
CONFIG_PACKAGE_kmod-qca-nss-dp=y
CONFIG_PACKAGE_kmod-qca-nss-drv=y
CONFIG_PACKAGE_kmod-qca-nss-ecm=y
CONFIG_PACKAGE_kmod-qca-nss-drv-bridge-mgr=y
CONFIG_PACKAGE_nss-firmware=y
CONFIG_PACKAGE_nss-firmware-ipq807x=y

# NSS firmware 12.5: the 11.4 choice is the default and its driver tree does
# not build on 6.12.x; qca-nss-ecm only adds -DNSS_FIRMWARE_VERSION_12_5 here.
CONFIG_NSS_FIRMWARE_VERSION_12_5=y

# tooling used to verify the result on the box
CONFIG_PACKAGE_ethtool-full=y
CONFIG_PACKAGE_iperf3=y
CONFIG_PACKAGE_htop=y
CONFIG_PACKAGE_curl=y
EOF

make defconfig
echo
echo "-- resulting selection:"
grep -E 'DEVICE_redmi_ax6-stock|NSS|nss' .config | sort

# ---------------------------------------------------------------------------
say "6) build"
# ---------------------------------------------------------------------------
make -j"$(nproc)" V=s 2>&1 | tee "$WORK/build.log"

# ---------------------------------------------------------------------------
say "7) result"
# ---------------------------------------------------------------------------
BIN="$IW/bin/targets/qualcommax/ipq807x"
ls -lh "$BIN"/*redmi*ax6*stock* 2>/dev/null || {
	echo "!! no ax6-stock image found; check $WORK/build.log" >&2
	exit 1
}

cat <<EOF

Built images are in $BIN

Flash with sysupgrade (settings are kept, and the upgrade path was patched for
this board's single-volume layout):

  scp $(ls "$BIN"/*redmi*ax6*stock*squashfs-sysupgrade.bin | head -1) root@192.168.10.1:/tmp/
  ssh root@192.168.10.1 'sysupgrade -v /tmp/$(basename "$(ls "$BIN"/*redmi*ax6*stock*squashfs-sysupgrade.bin | head -1)")'

Before you flash, take a backup and keep a way back:

  ssh root@192.168.10.1 'sysupgrade -b /tmp/backup-\$(date +%F).tar.gz'
  scp root@192.168.10.1:/tmp/backup-*.tar.gz .

If it does not come back: power-cycle while holding reset and use the U-Boot
HTTP recovery server at 192.168.1.1 (a third-party bootloader feature on this board, not a Xiaomi stock one).
EOF
