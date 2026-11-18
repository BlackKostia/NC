#!/usr/bin/env python3
"""src/fs/pkg_archive.c versus the frozen assembly (tests/harness/pkg_archive_reference.s): pkg_mkdir_p, pkg_write_file,
pkg_ensure_exec, pkg_parse_manifest, pkg_load_archive(_sha), pkg_extract_entry_to and pkg_free_archive.

PA1 differential (x86_64), each implementation in its own identical tree compared afterwards: nested / existing / trailing-slash /
    file-blocked directories; files of 0 B - 5 MiB, unwritable targets; exec bits on regular files, symlinks, directories, missing
    and read-only-directory files; manifests (quotes, blanks, CRLF, '==' values, repeated and unknown keys, values beyond their
    caps, no final newline, a negative / short length); .tar / .tar.gz / .tgz / .zip packages with and without the SHA-256,
    every entry extracted (stored, deflated, tar, a directory, a corrupt or cut-short deflate stream, a local extra field, 2 MiB
    and over-64-MiB entries, an unsupported method), unreadable and non-archive
    paths, allocation failures of the context and the 4 MiB buffer
PA2 defects of the asm, fixed:
    - pkg_load_archive_sha did not test the entries allocation, so a failed 288 KiB allocation made the parser write through NULL
    - pka_copy_val wrote the terminator at an index left over in r8 when the key or value was empty (the length of the previous
      copy): "name=" kept an earlier name, and an empty key after a long value wrote a NUL into the saved registers of the frame
      (the C writes an empty field; a Python model checks it)
    - pkg_mkdir_p of an empty path read an uninitialised stack byte as the path; a path of PATH_MAX bytes or more was truncated into
      a different one and created (the C creates nothing)
PA3 qemu-aarch64: the C module gives the x86_64 results; PA4 mutation check
"""

import gzip
import hashlib
import io
import os
import random
import shutil
import stat
import struct
import subprocess
import tarfile
import zipfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/pkg_archive.c"
REF = "tests/harness/pkg_archive_reference.s"
CORE = ["src/fs/archive_parse.c", "src/fs/inflate.c", "src/core/string.c", "src/core/string_path.c", "src/core/utf8.c", "src/core/memory.c",
        "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c", "src/core/hash.c", "src/fs/file_ops_read.c", "src/fs/file_ops.c",
        "src/fs/file_ops_copy.c", "src/fs/file_ops_delete.c", "src/fs/file_ops_overwrite.c", "src/fs/task.c", "src/fs/task_conflict.c",
        "build/i18n_en.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        o = t / "pkg_archive_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "mem_alloc=fake_mem_alloc", str(o)], check=True, capture_output=True)
        extra = [o]
    inc_a = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    uring = t / "pal_uring.o"
    subprocess.run([*H.ARCHS[arch]["as_"], *inc_a, str(ROOT / f"src/os/linux/{arch}/pal_uring.s"), "-o", str(uring)], check=True, capture_output=True)
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\n#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n'
                    'int g_task_parent_pid; TaskShared *g_task_shm;\n')
    return H.build(arch, t, ["tests/harness/pkg_archive_cli.c", str(stub), *CORE], [*extra, uring],
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DPKA_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, cwd: Path, arch: str = "x86_64") -> str:
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl], input=script.encode(), capture_output=True, cwd=cwd,
                         env={"PATH": "/usr/bin:/bin"}, timeout=60)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def snapshot(d: Path) -> list[tuple]:
    out = []
    for p in sorted(d.rglob("*")):
        st = p.lstat()
        kind = "l" if stat.S_ISLNK(st.st_mode) else "d" if stat.S_ISDIR(st.st_mode) else "f"
        data = hashlib.sha256(p.read_bytes()).hexdigest()[:16] if kind == "f" else os.readlink(p) if kind == "l" else ""
        out.append((str(p.relative_to(d)), kind, stat.S_IMODE(st.st_mode), data))
    return out


def tar_bytes(files: list[tuple[str, bytes | None]]) -> bytes:
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tf:
        for name, data in files:
            ti = tarfile.TarInfo(name)
            if data is None:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            else:
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return bio.getvalue()


def zip_bytes(files: list[tuple[str, bytes, int]]) -> bytes:
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, "w") as zf:
        for name, data, method in files:                    # a fixed timestamp: trees built at different instants are identical
            zf.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), data, compress_type=method)
    return bio.getvalue()


def central(z: bytearray, name: bytes) -> int:
    """Offset of the central-directory record of entry name."""
    i = z.index(b"PK\x01\x02")
    while z[i + 46: i + 46 + len(name)] != name:
        i = z.index(b"PK\x01\x02", i + 4)
    return i


def edge_zip() -> bytes:
    """A local header with an extra field, a 2 MiB deflated entry, one claiming 70 MB, one whose compressed size is cut short and
    one with an unsupported method (12, bzip2)."""
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, "w") as zf:
        zi = zipfile.ZipInfo("extra.txt", (2020, 1, 1, 0, 0, 0))
        zi.extra = b"\xfe\xca\x04\x00abcd"
        zf.writestr(zi, b"with an extra field " * 20, compress_type=zipfile.ZIP_STORED)
        for name, data in (("zeros", bytes(2 << 20)), ("huge", b"h" * 5000), ("short", bytes(range(256)) * 64), ("bz", b"bzip")):
            method = zipfile.ZIP_STORED if name == "bz" else zipfile.ZIP_DEFLATED
            zf.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), data, compress_type=method)
    z = bytearray(bio.getvalue())
    struct.pack_into("<I", z, central(z, b"huge") + 24, 70_000_000)
    c = central(z, b"short")
    struct.pack_into("<I", z, c + 20, struct.unpack_from("<I", z, c + 20)[0] // 2)
    struct.pack_into("<H", z, central(z, b"bz") + 10, 12)
    return bytes(z)


MANIFEST = "name = demo\nversion=\"1.2.3\"\r\nkind\t=\t'theme'\ndescription = \"A demo package\"  \n"


def populate(d: Path) -> None:
    rng = random.Random(0xA7C)
    (d / "blocker").write_text("x")
    (d / "exists").mkdir()
    (d / "ro").mkdir()
    (d / "ro" / "f").write_text("f")
    for name, mode in (("plain", 0o644), ("execd", 0o700), ("ux", 0o610)):
        (d / name).write_text("#!/bin/sh\n")
        os.chmod(d / name, mode)
    os.symlink("plain", d / "link")
    os.symlink("nowhere", d / "dangling")
    man = {
        "m_basic": MANIFEST,
        "m_caps": f"name={'n' * 100}\nversion={'v' * 50}\nkind={'k' * 30}\ndescription={'d' * 200}\n",
        "m_odd": "# comment\n  name  ==  \"quoted\"\nunknown=1\nversion=1\nversion=2\nnoequals\n\"kind\"=\"pl\"\ndescription",
        "m_noeol": "name=last",
        "m_keycase": "Name=up\nNAME=x\nname =ok\ndescription = é ü\t\n",
    }
    for k, v in man.items():
        (d / k).write_bytes(v.encode())
    big = bytes(rng.randrange(256) for _ in range(300000))
    files = [("manifest.txt", MANIFEST.encode()), ("bin/", None), ("bin/tool", b"#!/bin/sh\necho hi\n"), ("data/big.bin", big),
             ("empty", b"")]
    t = tar_bytes(files)
    (d / "p.tar").write_bytes(t)
    (d / "p.tar.gz").write_bytes(gzip.compress(t, mtime=0))
    (d / "p.tgz").write_bytes(gzip.compress(t, mtime=0))
    zf = [("manifest.txt", MANIFEST.encode(), zipfile.ZIP_DEFLATED), ("bin/tool", b"tool" * 1000, zipfile.ZIP_STORED),
          ("data/big.bin", big, zipfile.ZIP_DEFLATED), ("d/", b"", zipfile.ZIP_STORED), ("z0", b"", zipfile.ZIP_DEFLATED)]
    z = zip_bytes(zf)
    (d / "p.zip").write_bytes(z)
    bad = bytearray(z)
    i = bad.index(b"PK\x03\x04", bad.index(b"data/big.bin") - 40)
    bad[i + 30 + len("data/big.bin") + 10: i + 30 + len("data/big.bin") + 60] = b"\xff" * 50      # corrupt deflate stream
    (d / "bad.zip").write_bytes(bytes(bad))
    (d / "cut.zip").write_bytes(z[: len(z) // 2] + z[-200:])
    (d / "edge.zip").write_bytes(edge_zip())
    (d / "big.tar").write_bytes(tar_bytes([("huge", b"H" * (4 * 1024 * 1024 + 1000)), ("tiny", b"t")]))
    (d / "notgz.tar.gz").write_bytes(b"plain text")
    (d / "readme.txt").write_text("not an archive")


def script() -> str:
    s = "M a/b/c/d\nM exists\nM a/b/\nM blocker/sub\nM /\nM e//f\nM ./g/h\n"
    s += "".join(f"W {p} {n}\n" for p, n in (("w0", 0), ("w1", 1), ("w4k", 4096), ("w5m", 5 * 1024 * 1024), ("a/b/c/d/x", 10),
                                              ("nodir/x", 5), ("exists", 3), ("ro/f", 2), ("plain", 7)))
    s += "".join(f"X {p}\n" for p in ("plain", "execd", "ux", "link", "dangling", "exists", "missing", "w1"))
    s += "".join(f"F {m}\n" for m in ("m_basic", "m_caps", "m_odd", "m_noeol", "m_keycase", "missing"))
    s += "F m_basic -5\nF m_basic 0\nF m_basic 12\nF m_caps 7\n"
    for a in ("p.tar", "p.tar.gz", "p.tgz", "p.zip", "edge.zip", "bad.zip", "cut.zip", "big.tar", "notgz.tar.gz", "readme.txt", "missing.zip"):
        s += f"A {a} s 0\nA {a} - 0\n"
    s += "A p.zip s 1\nA p.zip s 3\nA p.tar.gz - 3\n"
    return s


def trees(t: Path, name: str) -> tuple[Path, Path]:
    a, b = t / name / "r", t / name / "c"
    for d in (a, b):
        shutil.rmtree(d, ignore_errors=True)
        d.mkdir(parents=True)
        populate(d)
        os.chmod(d / "ro", 0o555)
    return a, b


def unlock(*ds: Path) -> None:
    for d in ds:
        if (d / "ro").exists():
            os.chmod(d / "ro", 0o755)


def test_differential(exe: Path, t: Path) -> str:
    a, b = trees(t, "pa1")
    s = script()
    ra, rb = run(exe, "ref", s, a), run(exe, "c", s, b)
    unlock(a, b)
    assert ra == rb, "oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(ra.splitlines(), rb.splitlines()) if x != y)
    assert snapshot(a) == snapshot(b), "the trees differ"
    assert "W r=-1" in rb and "X r=-1" in rb and " r=-1 " in rb and "A null" in rb and "canary=0" in rb, "coverage"
    print(f"[PASS] PA1. identical to the asm on {len(rb.splitlines())} calls (directories, files, exec bits, manifests, "
          "tar / tgz / zip packages and every entry, OOM of the context and the buffer) and identical trees")
    return rb


def model_manifest(text: str) -> list[str]:
    out = {"name": "", "version": "", "kind": "", "description": ""}
    caps = {"name": 63, "version": 31, "kind": 15, "description": 111}

    def val(seg: str, cap: int) -> str:
        seg = seg.lstrip(" \t=\"").rstrip(" \t\r\"")
        return seg.encode()[:cap].decode(errors="ignore")
    for ln in text.split("\n"):
        if "=" in ln:
            k, v = ln.split("=", 1)
            k = val(k, 63)
            if k in out:
                out[k] = val(v, caps[k])
    return list(out.values())


def test_fixed(exe: Path, t: Path) -> None:
    d = t / "pa2"
    d.mkdir()
    cases = {"e1": "name=\nversion=1\n", "e2": "name=abc\nname=\n", "e3": "=x\nkind=k\n", "e4": "description=\"\"\nname=\" \"\n"}
    for k, v in cases.items():
        (d / k).write_text(v)
    c = run(exe, "c", "".join(f"F {k}\n" for k in cases) + "A p.zip s 2\nM \nM " + "q/" * 2100 + "\n", d)
    lines = c.splitlines()
    for (k, v), ln in zip(cases.items(), lines):
        assert ln == "F [" + "|".join(model_manifest(v)) + "] canary=0", (k, ln)
    (d / "p.zip").write_bytes(zip_bytes([("a", b"a", zipfile.ZIP_STORED)]))
    ref = run(exe, "ref", "A p.zip s 2\n", d)
    c2 = run(exe, "c", "A p.zip s 2\n", d)
    assert ref.startswith("A fault"), ref
    assert run(exe, "ref", "F e2\n", d) == "F [abc|||] canary=0\n", "the asm stale-index write is no longer visible"
    assert c2 == "A null\n", c2
    assert not (d / "q").exists(), "an overlong path created directories"
    print("[PASS] PA2. fixed: OOM of the entry table returns NULL (asm: write through NULL); empty manifest keys / values give empty "
          "fields (asm: NUL at a stale index, \"name=\" kept the old name); overlong mkdir paths create nothing")


MUTANTS = [
    ("mkdir prefixes", "        (void)os_mkdirat(AT_FDCWD, buf, 0755);\n        buf[i] = '/';", "        buf[i] = '/';"),
    ("mkdir start", "for (size_t i = 1; buf[0]", "for (size_t i = 2; buf[0]"),
    ("write trunc", "O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC", "O_WRONLY | O_CREAT | O_CLOEXEC"),
    ("write error", "return w < 0 ? -1 : 0;", "return 0;"),
    ("exec symlink", "os_statat(AT_FDCWD, path, &st, 0)", "os_statat(AT_FDCWD, path, &st, 1)"),
    ("exec keep bits", "if (st.mode & 0111) return 0;", ""),
    ("lead quote", "c == '=' || c == '\"'; }", "c == '='; }"),
    ("trail cr", "c == '\\t' || c == '\\r' || c == '\"'; }", "c == '\\t' || c == '\"'; }"),
    ("value cap", "n < cap - 1", "n < cap"),
    ("version cap", "offsetof(PkgEntry, version), 32}", "offsetof(PkgEntry, version), 31}"),
    ("first key only", "                    break;\n", "                    return;\n"),
    ("sha skipped", "        sha256_final_hex(&sha, out_sha_hex65);", ""),
    ("gunzip skipped", "    if (type == ARC_TGZ) {", "    if (false) {"),
    ("zip parse", "    if (type == ARC_ZIP) arc_parse_zip(ctx);", "    if (false) arc_parse_zip(ctx);"),
    ("local header", "        uint64_t hdr = 30 + (uint64_t)load_le16(p + 26) + load_le16(p + 28);", "        uint64_t hdr = 30 + (uint64_t)load_le16(p + 26);"),
    ("comp clamp", "comp = ent->comp_size < avail ? ent->comp_size : avail;", "comp = avail;"),
    ("inflate cap", "int64_t n = inflate_raw(p, comp, out, ent->size);", "int64_t n = inflate_raw(p, comp, out, ent->size / 2);"),
    ("stored size", "uint64_t len = ent->size < comp ? ent->size : comp;", "uint64_t len = comp;"),
    ("method check", "    if (ent->method) return -1;\n", ""),
    ("uncomp cap", "if (ent->size > ARC_MAX_UNCOMP) return -1;", "if (ent->size > 1000000) return -1;"),
]


def test_mutants(t: Path, expect: str) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            p = mt / "pkg_archive.c"
            p.write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(p))
                _, b = trees(mt, "tree")
                out = run(exe, "c", script(), b)
                unlock(b)
                noticed[name] = out != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] PA4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe, t)
        test_fixed(exe, t)
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            _, b = trees(t, "pa3")
            out = run(a64, "c", script(), b, "aarch64")
            unlock(b)
            assert out == expect, "qemu-aarch64 differs:\n" + "\n".join(f"  x86 {x}\n  a64 {y}" for x, y in zip(expect.splitlines(), out.splitlines()) if x != y)
            print("[PASS] PA3. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] PA3: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C PKG ARCHIVE TESTS PASSED.")


if __name__ == "__main__":
    main()
