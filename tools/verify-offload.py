"""Verify Qualcomm NSS/ECM hardware offload for a routed flow (wired or WiFi).

It keeps a bulk download running on the client and samples the router *while*
the traffic is in flight (accelerated_count is a current-connection count, so a
before/after snapshot only sees the closing flow).

Usage (PC side, router reachable over SSH with blank-password root as in rtr.py):

    set ROUTER_HOST=192.168.10.1
    set TEST_IP=101.6.15.130          # a CN mirror IP; literal IP avoids DNS hijack
    set TEST_HOST=mirrors.tuna.tsinghua.edu.cn
    set TEST_PATH=/ubuntu/ls-lR.gz
    rem optional: pin the test flow to a WiFi NIC
    set WLAN_IFACE_IP=192.168.10.108
    python verify-offload.py

The router's OpenClash must be stopped for the measurement window, otherwise
fake-IP DNS / tproxy sends the flow through userspace and it will never show up
as accelerated.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rtr as R

TEST_IP = os.environ.get("TEST_IP", "101.6.15.130")
TEST_HOST = os.environ.get("TEST_HOST", "mirrors.tuna.tsinghua.edu.cn")
TEST_PATH = os.environ.get("TEST_PATH", "/ubuntu/ls-lR.gz")
WLAN_IFACE_IP = os.environ.get("WLAN_IFACE_IP", "")


def bulk_loop():
    inner = ("1..8 | ForEach-Object { curl.exe --noproxy * -s -o NUL --max-time 20 "
             "-H 'Host: %s' 'http://%s%s' }" % (TEST_HOST, TEST_IP, TEST_PATH))
    if WLAN_IFACE_IP:
        inner = inner.replace("curl.exe --noproxy *",
                              "curl.exe --noproxy * --interface %s" % WLAN_IFACE_IP)
    return subprocess.Popen(["powershell", "-NoProfile", "-Command", inner],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    if os.name != "nt":
        sys.exit("run this on the Windows client (uses curl.exe)")
    c = R.connect(timeout=30)
    try:
        print(R.run("echo '--- flow offload (must be 0):'; "
                    "uci get firewall.@defaults[0].flow_offloading; "
                    "uci get firewall.@defaults[0].flow_offloading_hw; "
                    "echo '--- nss/wifi offload:'; "
                    "cat /sys/module/ath11k/parameters/nss_offload 2>/dev/null; "
                    "/etc/init.d/openclash stop >/dev/null 2>&1 && echo 'openclash stopped'",
                    client=c, timeout=180)[1])

        def snap(label):
            cmd = ("printf 'accelerated=%s ' $(cat /sys/kernel/debug/ecm/ecm_nss_ipv4/accelerated_count); "
                   "printf 'tcp_accel=%s ' $(cat /sys/kernel/debug/ecm/ecm_nss_ipv4/tcp_accelerated_count); "
                   "printf 'connections=%s ' $(cat /sys/kernel/debug/ecm/ecm_db/connection_count); "
                   "printf 'accel_mode2=%s ' $(ecm_dump.sh 2>/dev/null | grep -c 'accel_mode=2'); "
                   "printf 'slow_path=%s ' $(ecm_dump.sh 2>/dev/null | grep -c 'slow_path_packets=1'); "
                   "echo")
            out = R.run(cmd, client=c, timeout=120)[1].strip()
            print("[%s] %s" % (label, out))
            return out

        p = bulk_loop()
        time.sleep(10)
        snap("during")
        R.run("ecm_dump.sh > /tmp/ecm-during.txt 2>/dev/null", client=c, timeout=120)
        out = R.run("grep -B4 -A8 'nss_v4.ported.accel_mode=2' /tmp/ecm-during.txt | head -40",
                    client=c, timeout=60)[1]
        print(out)
        p.kill()
        time.sleep(2)
        snap("after")
        print("\nSuccessful offload: a flow in the dump shows "
              "nss_v4.ported.accel_mode=2 and accel_mode2 grows with the transfer.")
    finally:
        R.run("/etc/init.d/openclash start >/dev/null 2>&1; echo openclash restarted",
              client=c, timeout=240)
        c.close()


if __name__ == "__main__":
    main()
