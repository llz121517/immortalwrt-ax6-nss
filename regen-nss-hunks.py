#!/usr/bin/env python3
"""Make the NSS patch series apply to ImmortalWrt's backports-6.18.55.

Instead of hand-writing hunk context (fragile), this driver:

  1. rebuilds a scratch backports tree from a pristine copy,
  2. applies the IW patches and then the whole NSS series with `patch`,
  3. stops at the first hunk that does not apply,
  4. produces the intended post-patch file content for that hunk,
  5. runs `diff -u` between the current file and the edited file and splices
     the resulting canonical hunk back into the patch file,
  6. repeats until the series applies cleanly.

Run on the build host:

    python3 regen-nss-hunks.py <immortalwrt-tree> <scratch-dir>

<scratch-dir> must contain a `pristine` backports tree with all ImmortalWrt
patches already applied (see /tmp/p2_setup.sh).
"""
import os
import re
import shutil
import subprocess
import sys

SAT = {}


def sh(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


# ------------------------------------------------------------------ intents
# Each intent receives the current file text (state right before the patch is
# applied) and returns the wanted text, or None to mean "this hunk is obsolete".

DOC_ANCHOR = " * @NL80211_CMD_MAX: highest used command number\n"
DOC_ADD = (
    " * @NL80211_CMD_UPDATE_HE_MUEDCA_PARAMS: Updated MU-EDCA parameters from driver.\n"
    " *\tThis event is used to update dynamic MU-EDCA parameters in Beacon frame,\n"
    " *\tcoming from driver and now need to be reflected in Beacon frame.\n"
    " *\n"
)


def fix_203(text):
    if DOC_ADD in text:
        return text
    assert text.count(DOC_ANCHOR) == 1, "nl80211 doc anchor not unique"
    return text.replace(DOC_ANCHOR, DOC_ADD + DOC_ANCHOR)


TX_OLD = (
    "\t/* set this up so failure paths can clean up ack skb */\n"
    "\tinfo = IEEE80211_SKB_CB(skb);\n"
    "\tmemset(info, 0, sizeof(*info));\n"
    "\n"
    "\tinfo->flags = info_flags;\n"
)
TX_NEW = (
    "#ifdef CPTCFG_MAC80211_MESH\n"
    "nss_mesh:\n"
    "#endif\n"
    "\tinfo->flags |= info_flags;\n"
)


def fix_300(text):
    assert text.count(TX_OLD) == 1, "tx.c info block not found"
    return text.replace(TX_OLD, TX_NEW)


MPDU_PEER = "\t\tppdu_info->peer_id = ath11k_hal_rx_mpduinfo_get_peerid(ab, mpdu_info);\n"


def fix_068(text):
    add = (
        "\n"
        "\t\tppdu_info->mpdu_len += ab->hw_params.hw_ops->rx_desc_get_hal_mpdu_len(mpdu_info);\n"
        "\n"
    )
    assert text.count(MPDU_PEER) == 1, "hal_rx peer_id line not unique"
    return text.replace(MPDU_PEER, MPDU_PEER + add)


def fix_211(text):
    anchor = "\t[WMI_TAG_PDEV_CSA_SWITCH_COUNT_STATUS_EVENT] = {\n"
    add = (
        "\t[WMI_TAG_WDS_ADDR_EVENT] = {\n"
        "\t\t.min_len = sizeof(struct wmi_wds_addr_event) },\n"
    )
    assert text.count(anchor) == 1, "wmi policy anchor not unique"
    return text.replace(anchor, add + anchor)


def _block(text, start_marker, end_marker="\n}\n"):
    i = text.index(start_marker)
    j = text.index(end_marker, i) + len(end_marker)
    return i, j, text[i:j]


def fix_dp_rx(text):
    i, j, blk = _block(text, "static struct ath11k_peer *\nath11k_dp_rx_h_find_peer(")
    new = blk
    new = new.replace("ath11k_dp_rx_h_find_peer(struct ath11k_base *ab, struct sk_buff *msdu)",
                      "ath11k_dp_rx_h_find_peer(struct ath11k *ar, struct sk_buff *msdu)")
    new = new.replace("lockdep_assert_held(&ab->base_lock);", "lockdep_assert_held(&ar->ab->base_lock);")
    new = new.replace("ath11k_peer_find_by_id(ab, rxcb->peer_id);", "ath11k_peer_find_by_id(ar, rxcb->peer_id);")
    new = new.replace("ath11k_dp_rxdesc_mac_addr2_valid(ab, rx_desc)",
                      "ath11k_dp_rxdesc_mac_addr2_valid(ar->ab, rx_desc)")
    new = new.replace("ath11k_peer_find_by_addr(ab,\n\t\t\t\t\tath11k_dp_rxdesc_mpdu_start_addr2(ab, rx_desc));",
                      "ath11k_peer_find_by_addr(ar,\n\t\t\t\t\tath11k_dp_rxdesc_mpdu_start_addr2(ar->ab, rx_desc));")
    assert new != blk, "dp_rx find_peer block unchanged"
    assert "(ab," not in new, "leftover '(ab,' in find_peer:\n" + new
    return text[:i] + new + text[j:]


def fix_mac(text):
    i, j, blk = _block(text, "void ath11k_mac_peer_cleanup_all(struct ath11k *ar)\n")
    new = blk
    new = new.replace("&ab->tbl_mtx_lock", "&ar->tbl_mtx_lock")
    new = new.replace("&ab->peers", "&ar->peers")
    new = new.replace("ath11k_peer_rhash_delete(ab, peer);", "ath11k_peer_rhash_delete(ar, peer);")
    assert new != blk, "mac.c peer_cleanup block unchanged"
    return text[:i] + new + text[j:]


def fix_999_hal_rx(text):
    """If the enclosing function already has a valid `ab`, the conversion hunk
    is pure churn: drop it."""
    i, _, blk = _block(text, "static enum hal_rx_mon_status\nath11k_hal_rx_parse_mon_status_tlv(")
    if re.search(r"struct ath11k_base \*ab = ar->ab;", blk) or "ath11k *ar" in blk.split("\n")[0]:
        if re.search(r"struct ath11k_base \*ab = ar->ab;", blk):
            return None  # drop hunk
    # otherwise convert the two lines explicitly
    new = text
    new = new.replace("ath11k_hal_rx_mpduinfo_get_peerid(ab, mpdu_info);",
                      "ath11k_hal_rx_mpduinfo_get_peerid(ar->ab, mpdu_info);")
    new = new.replace("ppdu_info->mpdu_len += ab->hw_params",
                      "ppdu_info->mpdu_len += ar->ab->hw_params")
    if new == text:
        return None
    return new


INTENTS = {
    ("203-mac80211-ath11k-fw-dynamic-muedca", "include/uapi/linux/nl80211.h"): (fix_203, "+ * @NL80211_CMD_UPDATE_HE_MUEDCA_PARAMS"),
    ("300-ath11k-nss-mesh-offload-support", "net/mac80211/tx.c"): (fix_300, "+nss_mesh:"),
    ("068-ath11k-add-rx-histogram-stats", "drivers/net/wireless/ath/ath11k/hal_rx.c"): (fix_068, "+\t\tppdu_info->mpdu_len +="),
    ("211-002-ath11k-add-WDS-offload-support-on-NSS-offload-for-STA-mode", "drivers/net/wireless/ath/ath11k/wmi.c"): (fix_211, "+\t[WMI_TAG_WDS_ADDR_EVENT] = {"),
    ("999-900-bss-transition-handling", "drivers/net/wireless/ath/ath11k/dp_rx.c"): (fix_dp_rx, "-ath11k_dp_rx_h_find_peer(struct ath11k_base *ab"),
    ("999-900-bss-transition-handling", "drivers/net/wireless/ath/ath11k/mac.c"): (fix_mac, "-\tlist_for_each_entry_safe(peer, tmp, &ab->peers, list) {"),
    ("999-900-bss-transition-handling", "drivers/net/wireless/ath/ath11k/hal_rx.c"): (fix_999_hal_rx, "+\t\tpeer_id = ath11k_hal_rx_mpduinfo_get_peerid(ar->ab, mpdu_info);"),
}


# ------------------------------------------------------------------ patches
def patch_list(nss_dir):
    out = []
    for d in ("subsys", "ath10k", "ath11k"):
        src = os.path.join(nss_dir, d)
        if not os.path.isdir(src):
            continue
        for name in sorted(os.listdir(src)):
            if name.endswith(".patch"):
                out.append((d, name, os.path.join(src, name)))
    return out


def hunks(lines):
    """Return [(file, start, end)] where file is the +++ b/ path of the hunk."""
    res, cur, i = [], None, 0
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("+++ b/"):
            cur = ln[6:].strip()
        if ln.startswith("@@ "):
            s, j = i, i + 1
            while j < len(lines):
                if lines[j].startswith("@@ "):
                    break
                if lines[j].startswith("--- ") and j + 1 < len(lines) and lines[j + 1].startswith("+++ "):
                    break
                j += 1
            res.append((cur, s, j))
            i = j
        else:
            i += 1
    return res


def _find_hunk(patch_path, rel, marker):
    lines = open(patch_path, encoding="utf-8").readlines()
    hits = [(s, e) for f, s, e in hunks(lines) if f == rel and any(marker in l for l in lines[s:e])]
    if len(hits) != 1:
        sys.exit("%s[%s]: marker %r matched %d hunks" % (patch_path, rel, marker, len(hits)))
    return lines, hits[0]


def splice_hunk(patch_path, rel, marker, new_hunk_lines):
    lines, (s, e) = _find_hunk(patch_path, rel, marker)
    open(patch_path, "w", encoding="utf-8").writelines(lines[:s] + new_hunk_lines + lines[e:])


def drop_hunk(patch_path, rel, marker):
    lines, (s, e) = _find_hunk(patch_path, rel, marker)
    open(patch_path, "w", encoding="utf-8").writelines(lines[:s] + lines[e:])


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: %s <immortalwrt-tree> <scratch-dir>" % sys.argv[0])
    iw = os.path.abspath(sys.argv[1])
    scratch = os.path.abspath(sys.argv[2])
    nss_dir = os.path.join(iw, "package/kernel/mac80211/patches/nss")
    pristine = os.path.join(scratch, "pristine")
    work = os.path.join(scratch, "work")
    if not os.path.isdir(pristine):
        sys.exit("no pristine tree at " + pristine)

    plist = patch_list(nss_dir)
    print("%d NSS patches" % len(plist))

    for attempt in range(1, 15):
        shutil.rmtree(work, ignore_errors=True)
        shutil.copytree(pristine, work, symlinks=True)
        failed = None
        for d, name, path in plist:
            r = sh(["patch", "-p1", "-F2", "--forward", "-i", path], cwd=work)
            if r.returncode == 0:
                continue
            rej = []
            for root, _, files in os.walk(work):
                for f in files:
                    if f.endswith(".rej"):
                        rej.append(os.path.relpath(os.path.join(root, f), work))
            rels = [r[:-len(".rej")] for r in rej]
            for f in rej:
                os.remove(os.path.join(work, f))
            failed = (d, name, path, rels)
            break

        if failed is None:
            print("\nattempt %d: ALL PATCHES APPLY CLEANLY" % attempt)
            return 0

        d, name, path, rej = failed
        base = name[:-len(".patch")]
        print("\nattempt %d: %s/%s failed on %s" % (attempt, d, name, ", ".join(rej) or "?"))

        done = False
        for rel in rej:
            key = (base, rel)
            if key not in INTENTS:
                sys.exit("no intent for %r" % (key,))
            fn, marker = INTENTS[key]
            cur = open(os.path.join(work, rel), encoding="utf-8").read()
            wanted = fn(cur)
            if wanted is None:
                drop_hunk(path, rel, marker)
                print("  dropped obsolete hunk (%s)" % rel)
                done = True
                break
            tmp = os.path.join(scratch, "edited")
            with open(tmp, "w", encoding="utf-8", newline="") as fh:
                fh.write(wanted)
            r = sh(["diff", "-u", "--label", "a/" + rel, "--label", "b/" + rel, os.path.join(work, rel), tmp])
            lines = r.stdout.splitlines(True)
            start = next(i for i, l in enumerate(lines) if l.startswith("@@ "))
            new_hunk = lines[start:]
            if not new_hunk[-1].endswith("\n"):
                new_hunk[-1] += "\n"
            splice_hunk(path, rel, marker, new_hunk)
            print("  regenerated hunk for %s (%d lines)" % (rel, len(new_hunk)))
            done = True
            break
        if not done:
            sys.exit("nothing fixed")

    sys.exit("did not converge")


if __name__ == "__main__":
    sys.exit(main())
