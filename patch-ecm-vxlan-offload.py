"""
patch-ecm-vxlan-offload.py -- stop qca-nss-ecm from compiling its VXLAN
interfacing layer, which needs a kernel patch this port does not ship.

Why:
    feeds/nss_packages/qca-nss-ecm/Makefile enables ECM_INTERFACE_VXLAN_ENABLE
    as soon as CONFIG_PACKAGE_kmod-vxlan is selected:

        ifeq ($(CONFIG_PACKAGE_kmod-vxlan),y)
        ECM_MAKE_OPTS+=ECM_INTERFACE_VXLAN_ENABLE=y
        endif

    With that flag on, ecm_interface.c calls vxlan_fdb_update_mac():

        ecm_interface.c:6766: error: implicit declaration of function
                                    'vxlan_fdb_update_mac'

    vxlan_fdb_update_mac() does not exist in mainline vxlan.c -- it is added by
    qosmio's 0603-5-qca-nss-clients-add-vxlan-support.patch, which this port
    deliberately does not carry (it does not apply cleanly to ImmortalWrt
    25.12).  Dropping kmod-vxlan instead would work, but it changes the kernel
    config and therefore forces a full kernel rebuild; and vxlan still works
    fine through the CPU slow path.

    So: keep the module, drop the offload.  VXLAN traffic is then not
    hardware-accelerated by NSS, everything else is unaffected.

Usage:
    python patch-ecm-vxlan-offload.py <tree>/feeds/nss_packages/qca-nss-ecm/Makefile

Idempotent: re-running prints "[--] already patched" and exits 0.
"""

import sys

MARKER = "NSS-VXLAN-OFFLOAD-DISABLED"

OLD = (
    "ifeq ($(CONFIG_PACKAGE_kmod-vxlan),y)\n"
    "ECM_MAKE_OPTS+=ECM_INTERFACE_VXLAN_ENABLE=y\n"
    "endif"
)

NEW = (
    "ifeq ($(CONFIG_PACKAGE_kmod-vxlan),y)\n"
    "# " + MARKER + ": ECM's VXLAN interfacing calls vxlan_fdb_update_mac(),\n"
    "# which is only supplied by 0603-5-qca-nss-clients-add-vxlan-support.patch.\n"
    "# That patch is not part of this port, so keep kmod-vxlan working through\n"
    "# the CPU slow path instead of failing to compile.  Upstream line was:\n"
    "#     ECM_MAKE_OPTS+=ECM_INTERFACE_VXLAN_ENABLE=y\n"
    "endif"
)


def main(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()

    if MARKER in text:
        print("[--] already patched")
        return 0

    count = text.count(OLD)
    if count != 1:
        print("[!!] expected exactly one vxlan enable block, found %d" % count)
        return 1

    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text.replace(OLD, NEW))
    print("[ok] qca-nss-ecm: VXLAN offload disabled (module stays usable)")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: %s <qca-nss-ecm/Makefile>" % sys.argv[0])
    sys.exit(main(sys.argv[1]))
