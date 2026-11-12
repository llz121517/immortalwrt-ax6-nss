"""Helper: run commands on the build machine (Arch) over SSH.

Credentials are read from the environment so this file stays safe to publish:

    export ARCH_HOST=192.168.10.133
    export ARCH_USER=neko
    export ARCH_PASS=...          # optional; empty means key-based auth

The original workflow used password auth against a LAN host; anything you put
in the environment overrides the defaults below.
"""
import os
import sys

import paramiko

HOST = os.environ.get("ARCH_HOST", "")
USER = os.environ.get("ARCH_USER", "neko")
PASS = os.environ.get("ARCH_PASS", "")


def connect(host=None, user=None, password=None, timeout=15):
    host = host or HOST
    user = user or USER
    password = PASS if password is None else password
    if not host:
        raise SystemExit("ARCH_HOST is not set")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    kw = dict(port=22, username=user, timeout=timeout)
    if password:
        kw.update(password=password, allow_agent=False, look_for_keys=False)
    c.connect(host, **kw)
    return c


def run(cmd, timeout=300, client=None, sudo=False):
    """Run a command, return (rc, stdout, stderr)."""
    own = client is None
    c = client or connect()
    try:
        if sudo:
            cmd = f"sudo -S -p '' bash -lc {shell_quote(cmd)}"
            stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout)
            stdin.write(PASS + "\n")
            stdin.flush()
        else:
            stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout)
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        rc = stdout.channel.recv_exit_status()
        return rc, out, err
    finally:
        if own:
            c.close()


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def run_script(script, timeout=1800, client=None, sudo=False):
    """Upload a bash script via stdin and execute it."""
    own = client is None
    c = client or connect()
    try:
        cmd = "bash -s" if not sudo else "sudo -S -p '' bash -s"
        stdin, stdout, stderr = c.exec_command(cmd, timeout=timeout, get_pty=False)
        if sudo:
            stdin.write(PASS + "\n")
            stdin.flush()
        stdin.write(script)
        stdin.channel.shutdown_write()
        out = stdout.read().decode("utf-8", "replace")
        err = stderr.read().decode("utf-8", "replace")
        rc = stdout.channel.recv_exit_status()
        return rc, out, err
    finally:
        if own:
            c.close()


if __name__ == "__main__":
    rc, out, err = run(" ".join(sys.argv[1:]))
    print(out, end="")
    if err:
        print("STDERR:", err, file=sys.stderr)
    sys.exit(rc)
