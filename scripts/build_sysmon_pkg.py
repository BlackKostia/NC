#!/usr/bin/env python3
"""Package builder for duop-sysmon (.tar.gz + .sha256)."""

from __future__ import annotations

import hashlib
import os
import tarfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG_DIR = os.path.join(ROOT, "packages", "duop-sysmon")
DIST_DIR = os.path.join(ROOT, "dist")
ARCHIVE_NAME = "duop-sysmon-1.0.0.tar.gz"
FILES = (
    ("manifest.ini", 0o644),
    ("duop_tui_kit.py", 0o644),
    ("sys_telemetry.py", 0o644),
    ("duop-sysmon", 0o755),
)


def main() -> int:
    os.makedirs(DIST_DIR, exist_ok=True)
    archive_path = os.path.join(DIST_DIR, ARCHIVE_NAME)
    sha_path = archive_path + ".sha256"

    with tarfile.open(archive_path, "w:gz", format=tarfile.USTAR_FORMAT) as tf:
        for fname, mode in FILES:
            src = os.path.join(PKG_DIR, fname)
            ti = tf.gettarinfo(src, arcname=fname)
            ti.mode = mode
            ti.uid = 0
            ti.gid = 0
            ti.uname = "root"
            ti.gname = "root"
            with open(src, "rb") as f:
                tf.addfile(ti, f)

    digest = hashlib.sha256()
    with open(archive_path, "rb") as f:
        while chunk := f.read(65536):
            digest.update(chunk)
    hex_digest = digest.hexdigest()

    with open(sha_path, "w", encoding="utf-8") as f:
        f.write(f"{hex_digest}  {ARCHIVE_NAME}\n")

    print(f"Built {archive_path}")
    print(f"SHA256 {hex_digest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
