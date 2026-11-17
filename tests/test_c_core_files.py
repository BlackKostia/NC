#!/usr/bin/env python3
"""src/core/oop_rt.c, hash_file.c and tmpfile.c on x86_64 and aarch64 (qemu-user) through a freestanding harness."""

import hashlib
import os
import re
import stat
import tempfile
import zlib
from pathlib import Path

import c_harness as H

MODULES = ["src/core/oop_rt.c", "src/core/hash_file.c", "src/core/hash.c", "src/core/tmpfile.c", "src/core/memory.c",
           "src/core/syscall.c", "src/core/try_rt.c", "src/core/string.c", "src/core/string_path.c", "src/core/mem_prims.c"]


def kv(out: bytes) -> dict[str, str]:
    return dict(re.findall(r"^(\w+)=(.*)$", out.decode(), re.M))


def run_all(arch: str) -> None:
    with H.workdir() as tmp:
        exe = H.build(arch, Path(tmp), ["tests/harness/core_files_cli.c", *MODULES])
        w = Path(tmp) / "work"
        w.mkdir()

        o = kv(H.run(arch, exe, ["oop"]).stdout)
        assert o["flags_after_init"] == "25" and o["class"] == "Child" and o["dtor_calls"] == "1", o
        for k in ("alloc_ok", "layout_dirty", "focused", "blurred", "hit_in", "hit_out", "hit_hidden", "is_widget",
                  "is_object", "is_child", "not_other", "null_name"):
            assert o[k] == "1", (k, o)

        data = os.urandom(70000)
        f = w / "data.bin"
        f.write_bytes(data)
        (w / "empty").write_bytes(b"")
        os.symlink(f, w / "link")
        (w / "dir").mkdir()
        for path, want in ((f, data), (w / "empty", b"")):
            h = kv(H.run(arch, exe, ["hash", str(path)]).stdout)
            assert h["rc"] == "0" and h["sha"] == hashlib.sha256(want).hexdigest() and h["crc"] == f"{zlib.crc32(want):08x}", (path, h)
        assert kv(H.run(arch, exe, ["hash", str(w / "link")]).stdout)["rc"] == "-40", "symlink must be refused (ELOOP)"
        assert kv(H.run(arch, exe, ["hash", str(w / "dir")]).stdout)["rc"] == "-1", "directories must be rejected"
        assert kv(H.run(arch, exe, ["hash", str(w / "missing")]).stdout)["rc"] == "-2", "missing file -> -ENOENT"

        final = w / "settings.conf"
        final.write_text("old")
        a = kv(H.run(arch, exe, ["atomic", str(final), "new contents", "ok"]).stdout)
        assert a["commit_rc"] == "0" and final.read_text() == "new contents", a
        assert not [p for p in w.iterdir() if ".tmp." in p.name], "temp file left behind after a successful commit"
        b = kv(H.run(arch, exe, ["atomic", str(final), "ignored", "-fail"]).stdout)
        assert b["commit_rc"] == "-5" and final.read_text() == "new contents", b
        assert not [p for p in w.iterdir() if ".tmp." in p.name], "temp file left behind after a failed write"
        long = w / ("x" * 4090)
        assert kv(H.run(arch, exe, ["atomic", str(long) + "/" + "y" * 20, "z", "ok"]).stdout)["open_rc"] == "-36"

        t = kv(H.run(arch, exe, ["tmp", "pre", ".sfx"]).stdout)
        uid = os.getuid()
        assert t["dir_rc"] == "0" and re.fullmatch(rf"/tmp/duop-{uid}-\d+(-\d+)?", t["dir"]), t
        d = Path(t["dir"])
        assert stat.S_IMODE(d.stat().st_mode) == 0o700 and d.stat().st_uid == uid
        assert t["open_ok"] == "1" and re.fullmatch(re.escape(t["dir"]) + r"/pre_[0-9a-f]{8}\.sfx", t["path"]), t
        assert Path(t["path"]).read_bytes() == b"x" and stat.S_IMODE(Path(t["path"]).stat().st_mode) == 0o600
        assert t["make_path"] == "0" and t["path2"] != t["path"] and Path(t["path2"]).exists()
        assert t["small_cap"] == "-1", "cap < 64 must be refused"
        for p in d.iterdir():
            p.unlink()
        d.rmdir()


def main() -> None:
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] F-{arch}: toolchain/qemu unavailable")
            continue
        run_all(arch)
        print(f"[PASS] F-{arch}: Object/Widget runtime, hash_file (symlink/dir/missing), private tmp dir, atomic replace")
    print("ALL C CORE FILE TESTS PASSED.")


if __name__ == "__main__":
    main()
