"""
patch-platform-sh.py -- replace ImmortalWrt's A/B upgrade arm for the
`redmi,ax6-stock` board with a single-volume sequence.

Why:
    ImmortalWrt's ipq807x/platform.sh handles redmi,ax6-stock together with
    xiaomi,ax3600-stock / ax9000-stock, using Xiaomi's A/B U-Boot layout:
    it reads flag_boot_rootfs, picks rootfs vs rootfs_1, and toggles the
    flag_try_sysN_failed counters.

    The AX6 on the bench does not have that bootloader behaviour. Measured:

        $ fw_printenv -n flag_boot_rootfs
        rc=1  value=[]
        $ [ "" -eq "1" ]
        ash: out of range
        $ grep -c rootfs_1 /proc/mtd
        0

    So the arm would abort the upgrade. Its actual layout is one UBI
    partition holding all three volumes:

        /proc/mtd        mtd9 "rootfs"                (1015 MiB)
        ubi0 volumes     0 kernel / 1 rootfs / 2 rootfs_data
        /dev/ubiblock0_1 the only ubiblock -> root= must be ubiblock0_1

    With CI_UBIPART="rootfs" nand_do_upgrade keeps those volume IDs
    (nand_upgrade_prepare_ubi: "rootfs volumes keep their IDs"), which is
    exactly what the bootloader's root= expects.

Usage:
    python patch-platform-sh.py <tree>/target/linux/qualcommax/ipq807x/base-files/lib/upgrade/platform.sh
"""

import sys

MARKER = "NSS-STOCK-SINGLE-VOLUME"

NEW_ARM = """redmi,ax6-stock|\\
\txiaomi,ax3600-stock|\\
\txiaomi,ax9000-stock)
\t\t# {marker}: this board has a single UBI partition and a bootloader
\t\t# that supplies the NAND table via SMEM. There is no rootfs_1 and no
\t\t# flag_boot_rootfs, so ImmortalWrt's A/B arm cannot run here -- it
\t\t# would abort on `[ "" -eq "1" ]` ("out of range"). Keep the existing
\t\t# volume IDs (0 kernel, 1 rootfs, 2 rootfs_data) and write in place;
\t\t# bootargs already points at /dev/ubiblock0_1.
\t\tCI_UBIPART="rootfs"
\t\tnand_do_upgrade "$1"
\t\t;;""".format(marker=MARKER)


def main(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    if MARKER in text:
        print("[--] already patched")
        return 0

    start = text.find("redmi,ax6-stock|")
    if start < 0:
        print("[!!] no redmi,ax6-stock arm found", file=sys.stderr)
        return 1

    # The arm body ends at the ";;" that closes it. Inside the body there are
    # no stray ";;" tokens, so the first one after `start` is the arm terminator.
    end = text.find(";;", start)
    if end < 0:
        print("[!!] cannot find the end of the arm", file=sys.stderr)
        return 1
    end += 2

    old_arm = text[start:end]
    if "flag_boot_rootfs" not in old_arm:
        print("[!!] the arm does not look like the A/B version; refusing to touch it",
              file=sys.stderr)
        return 1

    text = text[:start] + NEW_ARM + text[end:]

    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)

    print("[ok] platform.sh: A/B arm replaced with the single-volume sequence")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: patch-platform-sh.py <platform.sh>")
    sys.exit(main(sys.argv[1]))
