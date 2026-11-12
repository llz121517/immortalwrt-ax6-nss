"""Helper: talk to an OpenWrt router over SSH (dropbear, key or blank-password root).

Tries, in order: local SSH key (ROUTER_KEY, or ~/.ssh/id_ed25519_ayaka /
id_ed25519 / id_rsa), the "none" method, then a blank password. Set
ROUTER_HOST if the router is not at the default address:

    export ROUTER_HOST=192.168.10.1

dropbear has no SFTP, so file transfer goes through `cat >` / `base64`.
"""
import base64
import glob
import os

import paramiko

ROUTER = os.environ.get("ROUTER_HOST", "192.168.10.1")

_KEY_CANDIDATES = [
    os.environ.get("ROUTER_KEY", ""),
    os.path.expanduser("~/.ssh/id_ed25519_ayaka"),
    os.path.expanduser("~/.ssh/id_ed25519"),
    os.path.expanduser("~/.ssh/id_rsa"),
]


def _local_keys():
    for path in _KEY_CANDIDATES:
        for p in ([path] if path else []) + glob.glob(path.replace("~", os.path.expanduser("~"))):
            if p and os.path.isfile(p) and not p.endswith(".pub"):
                try:
                    yield paramiko.PKey.from_path(p)
                except Exception:
                    continue


def connect(timeout=20):
    t = paramiko.Transport((ROUTER, 22))
    t.start_client(timeout=timeout)
    for key in _local_keys():
        try:
            t.auth_publickey("root", key)
            return t
        except paramiko.AuthenticationException:
            continue
    try:
        t.auth_none("root")
    except paramiko.BadAuthenticationType:
        # Some dropbear builds/configs refuse the "none" method; root usually
        # has a blank password (passwordless-root profile), so try that.
        t.auth_password("root", os.environ.get("ROUTER_PASSWORD", ""))
    return t


def run(cmd, client=None, timeout=180):
    own = client is None
    if own:
        client = connect()
    ch = client.open_session()
    ch.settimeout(timeout)
    ch.exec_command(cmd)
    out = b""
    while True:
        d = ch.recv(65536)
        if not d:
            break
        out += d
    rc = ch.recv_exit_status()
    err = b""
    try:
        err = ch.recv_stderr(65536) or b""
    except Exception:
        pass
    ch.close()
    if own:
        client.close()
    return rc, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


def get_bytes(remote, client=None, timeout=300):
    """Read a remote file as bytes by base64-wrapping it; dropbear has no sftp."""
    rc, out, err = run("base64 -w0 %s" % remote, client=client, timeout=timeout)
    if rc != 0:
        raise RuntimeError("read %s failed rc=%s %s" % (remote, rc, err[:200]))
    return base64.b64decode("".join(out.split()))


def put_bytes(data, remote, client=None, chunk=60000, timeout=300):
    """Write bytes to a remote path using `cat >` over an exec channel."""
    own = client is None
    if own:
        client = connect()
    ch = client.open_session()
    ch.settimeout(timeout)
    ch.exec_command("cat > %s" % remote)
    for i in range(0, len(data), chunk):
        ch.sendall(data[i:i + chunk])
    ch.shutdown_write()
    ch.recv_exit_status()
    ch.close()
    if own:
        client.close()
