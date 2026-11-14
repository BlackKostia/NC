#!/usr/bin/env python3
"""Disk Usage (Alt+D) reports space actually used, like `du`: allocated blocks instead of the
apparent size (sparse files, /proc/kcore), directory blocks included, and it does not descend into
mount points of pseudo (proc, sysfs, ...), FUSE, squashfs, overlay or network filesystems, which
would only repeat data stored elsewhere. tmpfs is still counted."""

import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402
from du_util import du_text  # noqa: E402

BINARY = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "duop"))
MIB = 1 << 20


def wait_for(s, text, timeout=3.0):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        s.drain(0.08)
        if text in s.vt.full_text():
            return
    raise AssertionError(f"Timed out waiting for {text!r};\n{s.vt.full_text()}")


def row_after(s, name):
    """The size column of the left-pane row showing `name`."""
    for line in s.vt.full_text().splitlines():
        left = line.split("│")[1] if line.count("│") >= 2 else line
        pos = left.find(" " + name + " ")
        if pos >= 0:
            return left[pos + len(name) + 1:]
    return ""


def close(s):
    try:
        os.kill(s.pid, 9)
        os.waitpid(s.pid, 0)
    except OSError:
        pass


def test_allocated_sizes(tmp):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    sparse, data = os.path.join(left, "sparse_dir"), os.path.join(left, "data_dir")
    links = os.path.join(left, "links_dir")
    for d in (sparse, data, links, right):
        os.makedirs(d)
    with open(os.path.join(links, "a.bin"), "wb") as f:
        f.write(b"h" * 256 * 1024)
    for n in ("b.bin", "c.bin"):
        os.link(os.path.join(links, "a.bin"), os.path.join(links, n))   # 3 names, 1 inode
    with open(os.path.join(sparse, "huge.img"), "wb") as f:
        f.truncate(1 << 30)                          # 1 GiB apparent, nothing allocated
    with open(os.path.join(left, "top.sparse"), "wb") as f:
        f.truncate(512 * MIB)
    for i in range(3):
        with open(os.path.join(data, f"f{i}"), "wb") as f:
            f.write(b"d" * 1000)                     # 3 x 1000 B -> 3 allocated blocks
    s = PtySession(BINARY, ["--lang", "en", left, right], cols=120, rows=35)
    try:
        s.drain(0.4)
        s.send(b"\x1bd")
        wait_for(s, "Disk Usage")
        wait_for(s, du_text(data))
        txt = s.vt.full_text()
        assert "1.0 G" not in txt and "512 M" not in txt, f"apparent sizes of sparse files:\n{txt}"
        assert du_text(sparse) in row_after(s, "sparse_dir"), txt
        assert du_text(os.path.join(left, "top.sparse")) in row_after(s, "top.sparse"), txt
        assert du_text(links) in row_after(s, "links_dir"), f"hard links must count once:\n{txt}"
        assert du_text(links) != "772 K" and "772 K" not in txt, txt
        print("[PASS] DS1. Allocated blocks like `du`: sparse files, dir blocks, hard links once")
    finally:
        close(s)


MOUNT_SCRIPT = r'''
L="$1"; A="$2"
mount -t proc proc "$L/procfs" || exit 90
mount -t tmpfs tmpfs "$L/ram" || exit 91
head -c 1048576 /dev/zero > "$L/ram/blob"
mount -t overlay overlay -o "lowerdir=$A/lo,upperdir=$A/up,workdir=$A/wk" "$L/ovl" || exit 92
exec "$3" --lang en "$L" "$4"
'''


def test_mount_points(tmp):
    unshare = shutil.which("unshare")
    probe = subprocess.run([unshare or "unshare", "-rm", "true"], capture_output=True) if unshare else None
    if not probe or probe.returncode != 0:
        print("[SKIP] DS2. user + mount namespaces unavailable (unshare -rm)")
        return
    left, right, aux = (os.path.join(tmp, n) for n in ("l", "r", "aux"))
    for d in ("procfs", "ram", "ovl", "real"):
        os.makedirs(os.path.join(left, d))
    for d in ("lo", "up", "wk"):
        os.makedirs(os.path.join(aux, d))
    os.makedirs(right)
    with open(os.path.join(aux, "lo", "big.bin"), "wb") as f:
        f.write(b"o" * MIB)                          # visible through the overlay mount
    with open(os.path.join(left, "real", "data.bin"), "wb") as f:
        f.write(b"r" * 65536)
    s = PtySession(unshare, ["-rmpf", "--mount-proc", "sh", "-c", MOUNT_SCRIPT, "sh",
                             left, aux, BINARY, right], cols=120, rows=35)
    try:
        s.drain(0.6)
        s.send(b"\x1bd")
        wait_for(s, "Disk Usage")
        wait_for(s, du_text(os.path.join(left, "real")))
        txt = s.vt.full_text()
        assert "1.0 M" in row_after(s, "ram"), f"tmpfs must be counted:\n{txt}"
        assert "0 B" in row_after(s, "ovl"), f"overlay mount must not be walked:\n{txt}"
        assert "0 B" in row_after(s, "procfs"), f"proc mount must not be walked:\n{txt}"
        print("[PASS] DS2. proc / overlay mount points skipped, tmpfs counted")
    finally:
        close(s)


def main():
    for case in (test_allocated_sizes, test_mount_points):
        with tempfile.TemporaryDirectory() as tmp:
            case(tmp)
    print("ALL DISK USAGE SIZE TESTS PASSED.")


if __name__ == "__main__":
    main()
