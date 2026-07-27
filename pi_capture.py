"""Capture a Raspberry Pi's device tree over SSH, the way perry was captured.

Pushes `scripts/10-capture-topology.sh` to the Pi, runs it, and pulls the
tarball back to `fixtures/`. From there `tools/dtb.py` turns it into a spec
that the same walkers already know how to read -- the point of doing this at
all is that a Pi Zero W is a completely different SoC from an MSM8937, and
nothing in `topology.jac` or `diagnose.jac` has to change.

Configuration is environment-driven. There is deliberately no default
password in this file: the repo is public, and a committed credential is one
`git add -A` away from being published.

    JACOS_PI_HOST    hostname or IP        (default raspberrypi.local)
    JACOS_PI_USER    login                 (default pi)
    JACOS_PI_KEY     path to a private key (preferred)
    JACOS_PI_PASS    password              (fallback; prompts if neither set)

Needs paramiko, which is not a project dependency:

    .demovenv/Scripts/python.exe -m pip install paramiko

NOTE (2026-07-26): this cannot reach the Pi on the venue network. The Pi is up
with sshd active on 10.104.9.37, but the laptop sits on 10.104.8.248 and the
two cannot route to each other -- client isolation. `raspberrypi.local` does
not resolve either, because mDNS is blocked the same way. The Pi's serial
console on COM6 at 115200 is currently the only channel that works; see
docs/HANDOFF.md section 10 for the base64-over-serial route.
"""

import getpass
import os
import socket
import sys
import time

import paramiko

HOST = os.environ.get("JACOS_PI_HOST", "raspberrypi.local")
USER = os.environ.get("JACOS_PI_USER", "pi")
KEY = os.environ.get("JACOS_PI_KEY", "")

SCRIPT_PATH = "scripts/10-capture-topology.sh"
REMOTE_SCRIPT = f"/home/{USER}/10-capture-topology.sh"
REMOTE_TARBALL = "/tmp/jacos-snapshot.tar.gz"
LOCAL_TARBALL = "fixtures/pizero-snapshot.tar.gz"


def wait_for_host(timeout: int = 180) -> None:
    """Block until the Pi answers on port 22, or give up.

    The original version looped forever. On a network that isolates clients
    that is indistinguishable from a hang, so it now has a deadline and says
    what it was waiting for.
    """
    print(f"Waiting up to {timeout}s for {HOST}:22 ...")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            socket.gethostbyname(HOST)
            with socket.create_connection((HOST, 22), timeout=2):
                print(f"{HOST} is up and sshd is listening.")
                time.sleep(2)  # let sshd finish coming up
                return
        except (socket.gaierror, socket.timeout, ConnectionRefusedError, OSError):
            time.sleep(2)
    sys.exit(
        f"{HOST} never answered on port 22.\n"
        "If the Pi is powered and sshd is active, the network is the problem "
        "(client isolation, or mDNS blocked). Use the serial route instead -- "
        "see docs/HANDOFF.md section 10."
    )


def connect() -> paramiko.SSHClient:
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    if KEY:
        print(f"Connecting to {USER}@{HOST} with key {KEY} ...")
        ssh.connect(HOST, username=USER, key_filename=KEY)
    else:
        password = os.environ.get("JACOS_PI_PASS") or getpass.getpass(
            f"password for {USER}@{HOST}: "
        )
        print(f"Connecting to {USER}@{HOST} ...")
        ssh.connect(HOST, username=USER, password=password)
    return ssh


def run_capture() -> None:
    wait_for_host()
    ssh = connect()
    try:
        sftp = ssh.open_sftp()
        print(f"Uploading {SCRIPT_PATH} ...")
        sftp.put(SCRIPT_PATH, REMOTE_SCRIPT)

        print("Running capture ...")
        _stdin, stdout, stderr = ssh.exec_command(f"sudo sh {REMOTE_SCRIPT}")
        status = stdout.channel.recv_exit_status()
        print(stdout.read().decode(errors="replace"))
        err = stderr.read().decode(errors="replace")
        if err.strip():
            print(err)

        if status != 0:
            sys.exit(f"capture script exited {status}")

        os.makedirs("fixtures", exist_ok=True)
        print("Downloading tarball ...")
        sftp.get(REMOTE_TARBALL, LOCAL_TARBALL)
        print(f"Saved {LOCAL_TARBALL}")
        sftp.close()
    finally:
        ssh.close()


if __name__ == "__main__":
    run_capture()
