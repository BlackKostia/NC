#!/usr/bin/env python3
"""src/fs/archive_parse.c + archive_vfs.c versus the frozen assembly (tests/harness/archive_vfs_reference.s +
archive_extract_reference.s): the .tar / .tar.gz / .zip index and the archive as a virtual folder of a pane.

AR1 parsers, differential (x86_64): tar (files, directories, long names, sizes clamped to truncated data), zip (stored, deflated,
    directories, comments, ZIP64 records and extra fields), gzip (every header flag), and 600 random byte-flipped / truncated
    variants; the entries (name, offset, sizes, method, dir flag) or the gunzipped bytes
AR2 a defect of the asm, fixed: the ZIP central-directory bound "offset + 46 > length" wraps for a ZIP64 offset near 2^64, so a
    crafted archive made the parser read before its buffer (a crash when the buffer starts a mapping, as for the package manager, which parses without the fault
    guard); the C parser compares against the remaining length and returns no entries
AR3 the virtual folder: entering .tar / .tar.gz / .tgz / .zip files of a real directory, descending into folders synthesised from
    the paths, ".." up to the archive root and back out (the cursor on the archive), extracting stored, deflated and tar entries to
    temp files, an archive above 4 MiB (entered, flagged truncated), a corrupt one (not entered)
AR4 qemu-aarch64: the C modules give the x86_64 results; AR5 mutation check
"""

import gzip
import io
import random
import struct
import subprocess
import tarfile
import zipfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = ["src/fs/archive_parse.c", "src/fs/archive_vfs.c"]
REFS = ["tests/harness/archive_vfs_reference.s", "tests/harness/archive_extract_reference.s"]
MODS = ["src/fs/dir_model.c", "src/fs/dir_model_filter.c", "src/fs/dir_model_load.c", "src/fs/dir_model_stream.c", "src/fs/dir_model_stat.c",
        "src/fs/dir_model_select.c", "src/fs/dir_sort.c", "src/fs/dir_sort_radix.c", "src/fs/dir_cache.c", "src/fs/dir_search.c",
        "src/fs/dir_search_match.c", "src/fs/inflate.c", "src/fs/file_ops_delete.c", "src/fs/file_ops.c", "src/fs/file_ops_copy.c",
        "src/fs/file_ops_read.c", "src/fs/file_ops_overwrite.c", "src/fs/task.c", "src/fs/task_conflict.c", "src/core/oop_rt.c",
        "src/core/string_path.c", "src/core/tmpfile.c", "build/i18n_en.c"]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]


def build(arch: str, t: Path, srcs: list[str] | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    s1, s2 = [s if Path(s).is_absolute() else str(ROOT / s) for s in (srcs or SRCS)]
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    uring = t / "pal_uring.o"
    subprocess.run([*H.ARCHS[arch]["as_"], *inc, str(ROOT / f"src/os/linux/{arch}/pal_uring.s"), "-o", str(uring)], check=True, capture_output=True)
    extra = [uring]
    if arch == "x86_64":
        refs = []
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run(["as", *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            refs.append(o)
        H.rename_defined_globals(refs, "ref_")
        extra += refs
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\n#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n'
                    'int g_task_parent_pid; TaskShared *g_task_shm;\n')
    return H.build(arch, t, ["tests/harness/archive_cli.c", str(stub), *MODS, *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DAR_SRC1="{s1}"', f'-DAR_SRC2="{s2}"'])


def make_tar(rng: random.Random, gz: bool = False) -> bytes:
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode="w:gz" if gz else "w", format=tarfile.GNU_FORMAT) as tf:
        for i in range(rng.randrange(1, 12)):
            name = rng.choice(["a.txt", "dir/b.bin", "dir/sub/c", "x" * rng.randrange(90, 140), "ünï/é.txt", "deep/" * 5 + "f"]) + str(i)
            if rng.random() < 0.2:
                ti = tarfile.TarInfo(name + "_d")
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            data = bytes(rng.randrange(256) for _ in range(rng.choice([0, 1, 511, 512, 513, 3000])))
            ti = tarfile.TarInfo(name)
            ti.size = len(data)
            tf.addfile(ti, io.BytesIO(data))
    return bio.getvalue()


def make_zip(rng: random.Random, z64: bool = False) -> bytes:
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, "w") as zf:
        for i in range(rng.randrange(1, 10)):
            name = rng.choice(["a.txt", "d/b.bin", "d/e/", "long" * 20, "ü/x"]) + ("" if i == 0 else str(i))
            method = rng.choice([zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED])
            data = bytes(rng.randrange(4) for _ in range(rng.choice([0, 10, 5000])))
            if name.endswith("/"):
                zf.writestr(zipfile.ZipInfo(name), b"")
                continue
            zi = zipfile.ZipInfo(name)
            zi.compress_type = method
            with zf.open(zi, "w", force_zip64=z64) as w:
                w.write(data)
        if rng.random() < 0.3:
            zf.comment = b"c" * rng.randrange(0, 300)
    return bio.getvalue()


def crafted_zip64(cd_off: int) -> bytes:
    """An end-of-central-directory that defers to a ZIP64 record claiming the directory at cd_off."""
    z64 = struct.pack("<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0, 1, 1, 46, cd_off)
    loc = struct.pack("<IIQI", 0x07064B50, 0, 64, 1)
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
    return b"PK\x03\x04" + b"\0" * 60 + z64 + loc + eocd


def to_zip64(data: bytes, total: int) -> bytes:
    """The same zip with its end record deferring to a ZIP64 record that claims `total` entries."""
    e = data.rindex(b"PK\x05\x06")
    cd_size, cd_off = struct.unpack_from("<II", data, e + 12)
    z = len(data[:e])
    rec = struct.pack("<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0, total, total, cd_size, cd_off)
    loc = struct.pack("<IIQI", 0x07064B50, 0, z, 1)
    eocd = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 0xFFFF, 0xFFFF, cd_size, 0xFFFFFFFF, 0)
    return data[:e] + rec + loc + eocd


def crafted(d: Path) -> list[tuple[Path, str]]:
    """Inputs the random corpus rarely reaches: blank-padded tar sizes, 300-byte zip names, a stored entry whose central size exceeds
    its data, and a ZIP64 entry count above 2^32 (capped to ARC_MAX_ENTRIES before the 32-bit loop bound)."""
    out = []
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tf:
        for n in ("a", "b"):
            ti = tarfile.TarInfo(n)
            ti.size = 700
            tf.addfile(ti, io.BytesIO(b"x" * 700))
    tb = bytearray(bio.getvalue())
    tb[124:136] = b"   1274 \0\0\0\0"                              # " 1274" octal = 700
    (d / "blank.tar").write_bytes(bytes(tb))
    out.append((d / "blank.tar", "t"))
    zb = io.BytesIO()
    with zipfile.ZipFile(zb, "w") as zf:
        for i in range(10):
            zf.writestr(("n" * 300 if i == 0 else f"f{i}"), b"stored-bytes" * (i + 1), compress_type=zipfile.ZIP_STORED)
    z = zb.getvalue()
    (d / "longname.zip").write_bytes(z)
    out.append((d / "longname.zip", "z"))
    zz = bytearray(z)
    c = zz.index(b"PK\x01\x02", zz.index(b"PK\x01\x02") + 1)    # the second central record: claim a larger size
    struct.pack_into("<I", zz, c + 24, 99999)
    (d / "bigsize.zip").write_bytes(bytes(zz))
    out.append((d / "bigsize.zip", "z"))
    (d / "z64count.zip").write_bytes(to_zip64(z, (1 << 32) + 3))
    out.append((d / "z64count.zip", "z"))
    return out


def mutate(rng: random.Random, data: bytes) -> bytes:
    b = bytearray(data)
    if rng.random() < 0.3:
        b = b[: rng.randrange(len(b) + 1)]
    for _ in range(rng.randrange(1, 8)):
        if b:
            b[rng.randrange(len(b))] = rng.randrange(256)
    return bytes(b)


def corpus(t: Path) -> list[tuple[Path, str]]:
    rng = random.Random(0xA4C)
    d = t / "corpus"
    d.mkdir(parents=True)
    out = []
    for i in range(30):
        base = {"t": make_tar(rng), "z": make_zip(rng, i % 3 == 0), "g": gzip.compress(make_tar(rng), mtime=0)}
        for kind, data in base.items():
            for j in range(7):
                p = d / f"{i}_{kind}_{j}"
                p.write_bytes(data if j == 0 else mutate(rng, data))
                out.append((p, kind))
    for k, flg in enumerate((0, 2, 4, 8, 16, 30)):                       # gzip header flags
        body = gzip.compress(b"hello gzip " * 100, mtime=0)
        hdr = bytearray(body[:10])
        hdr[3] = flg
        extra = (b"\x04\x00abcd" if flg & 4 else b"") + (b"name\0" if flg & 8 else b"") + (b"comment\0" if flg & 16 else b"") + (b"\0\0" if flg & 2 else b"")
        p = d / f"gzflag{k}"
        p.write_bytes(bytes(hdr) + extra + body[10:])
        out.append((p, "g"))
    return out + crafted(d)


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=120)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def parse_script(items: list[tuple[Path, str]]) -> str:
    return "".join(f"P {p} {k}\n" for p, k in items)


def test_parsers(exe: Path, t: Path) -> str:
    items = corpus(t)
    s = parse_script(items)
    a, b = run(exe, "ref", s).splitlines(), run(exe, "c", s).splitlines()
    diffs = [(x, y) for x, y in zip(a, b) if x != y]
    assert all(x == "P fault" for x, _ in diffs), f"oracle and C differ beyond asm faults: {diffs[:2]}"
    assert len(a) == len(b) == len(items)
    print(f"[PASS] AR1. tar / zip / gzip parsers identical to the asm on {len(items)} inputs "
          f"({sum('n=0' not in ln for ln in b)} with entries, {len(diffs)} where only the asm faulted)")
    return "\n".join(b)


def test_zip64_wrap(exe: Path, t: Path) -> None:
    p = t / "evil.zip"
    p.write_bytes(crafted_zip64((1 << 64) - 0x10))
    q = t / "fine.zip"
    q.write_bytes(crafted_zip64(64))
    s = f"P {p} Z\nP {q} Z\n"
    ref, c = run(exe, "ref", s).splitlines(), run(exe, "c", s).splitlines()
    assert ref[0] == "P fault" and c[0] == "P n=0", (ref, c)
    assert ref[1] == c[1], (ref[1], c[1])
    print("[PASS] AR2. fixed: a ZIP64 directory offset near 2^64 no longer wraps the bound check (asm: read outside the buffer)")


def folder(t: Path) -> Path:
    d = t / "pane"
    (d / "plain").mkdir(parents=True)
    rng = random.Random(7)
    bio = io.BytesIO()
    with tarfile.open(fileobj=bio, mode="w") as tf:
        for name, data in (("top.txt", b"top"), ("dir/a.txt", b"A" * 100), ("dir/sub/b.bin", bytes(range(256)) * 9), ("dir2/c", b"c"), ("empty/", b"")):
            ti = tarfile.TarInfo(name.rstrip("/"))
            if name.endswith("/"):
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            else:
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    (d / "t.tar").write_bytes(bio.getvalue())
    (d / "t.tar.gz").write_bytes(gzip.compress(bio.getvalue(), mtime=0))
    (d / "t.tgz").write_bytes(gzip.compress(bio.getvalue(), mtime=0))
    zb = io.BytesIO()
    with zipfile.ZipFile(zb, "w") as zf:
        zf.writestr("z/stored.txt", b"stored data", compress_type=zipfile.ZIP_STORED)
        zf.writestr("z/deflated.txt", b"deflate me " * 500, compress_type=zipfile.ZIP_DEFLATED)
        zf.writestr("root.md", b"# root", compress_type=zipfile.ZIP_DEFLATED)
    (d / "t.zip").write_bytes(zb.getvalue())
    big = io.BytesIO()
    with zipfile.ZipFile(big, "w") as zf:
        zf.writestr("big.bin", bytes(rng.randrange(256) for _ in range(5 * 1024 * 1024)), compress_type=zipfile.ZIP_STORED)
    (d / "big.zip").write_bytes(big.getvalue())
    bt = io.BytesIO()                                       # > 4 MiB with entries: the listing overwrites the archive's own row
    with tarfile.open(fileobj=bt, mode="w") as tf:
        for name, size in (("a.txt", 10), ("b.txt", 20), ("c.txt", 30), ("huge.bin", 4 * 1024 * 1024 + 8192)):
            ti = tarfile.TarInfo(name)
            ti.size = size
            tf.addfile(ti, io.BytesIO(b"A" * size))
    (d / "big.tar").write_bytes(bt.getvalue())
    (d / "bad.tar.gz").write_bytes(b"not gzip at all")
    return d


def nav_script(d: Path) -> str:
    s = f"N {d}\nE t.tar\nE dir\nE sub\nX b.bin\nU\nX a.txt\nU\nX top.txt\nE dir2\nU\nU\nL\n"
    s += "E t.tar.gz\nE dir\nX a.txt\nU\nU\nE t.tgz\nU\nE t.zip\nE z\nX stored.txt\nX deflated.txt\nU\nX root.md\nU\n"
    s += "E big.zip\nU\nE big.tar\nX huge.bin\nU\nE bad.tar.gz\nE plain\nE nope\n"
    return s


def test_folder(exe: Path, t: Path) -> str:
    s = nav_script(folder(t))
    a, b = run(exe, "ref", s), run(exe, "c", s)
    assert a == b, "virtual folder: oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(a.splitlines(), b.splitlines()) if x != y)
    assert b.count("E r=3 ") == 2 and "X r=0 len=5500 " in b and " vm=2 " in b, "coverage"
    print(f"[PASS] AR3. virtual folder identical to the asm ({len(b.splitlines())} steps: .tar / .tar.gz / .tgz / .zip, folders, "
          "'..' and back out, extraction of stored / deflated / tar entries, > 4 MiB, corrupt)")
    return b


# Equivalent, not listed: dropping "if (size > comp) size = comp;" in arc_entry_data - the parser already clamps a stored entry's
# size to its compressed size and that to the data behind the local header, so extraction never sees size > comp.
MUTANTS = [
    ("src/fs/archive_parse.c", "tar name cap", "(const char *)raw + off, 100);", "(const char *)raw + off, 101);"),
    ("src/fs/archive_parse.c", "tar size clamp", "if (size > avail) size = avail;", ""),
    ("src/fs/archive_parse.c", "tar dir flag", "e->is_dir = raw[off + 156] == '5';", "e->is_dir = 0;"),
    ("src/fs/archive_parse.c", "tar block round", "((size + 511) & ~(uint64_t)511)", "size"),
    ("src/fs/archive_parse.c", "octal blank", "if (p[i] == ' ') continue;", "if (p[i] == ' ') break;"),
    ("src/fs/archive_parse.c", "eocd window", "steps + 1 >= 65536", "steps + 1 >= 256"),
    ("src/fs/archive_parse.c", "zip64 entries cap", "if (*total > ARC_MAX_ENTRIES) *total = ARC_MAX_ENTRIES;", ""),
    ("src/fs/archive_parse.c", "zip64 extra ignored", "        if (xlen <= len - cd - 46 - nlen) arc_zip64_extra(e, r + 46 + nlen, xlen);\n", ""),
    ("src/fs/archive_parse.c", "zip name cap", "(nlen > 255 ? 255 : nlen) + 1", "(nlen > 254 ? 254 : nlen) + 1"),
    ("src/fs/archive_parse.c", "zip dir flag", "e->is_dir = n && e->name[n - 1] == '/';", "e->is_dir = 0;"),
    ("src/fs/archive_parse.c", "zip comp clamp", "if (e->comp_size > avail) e->comp_size = avail;", ""),
    ("src/fs/archive_parse.c", "zip stored clamp", "if (!e->method && e->size > e->comp_size) e->size = e->comp_size;", ""),
    ("src/fs/archive_parse.c", "zip comment skipped", "cd += 46 + nlen + xlen + clen;", "cd += 46 + nlen + xlen;"),
    ("src/fs/archive_parse.c", "gzip fname", "for (int f = 8; f <= 16; f += 8)", "for (int f = 16; f <= 16; f += 8)"),
    ("src/fs/archive_parse.c", "gzip hcrc", "if (flg & 2) p += 2;", ""),
    ("src/fs/archive_parse.c", "gzip cap floor", "if (cap < 65536) cap = 65536;", ""),
    ("src/fs/archive_vfs.c", "dedupe", "if (!name[0] || DirModel_find_by_name(m, name) >= 0) continue;", "if (!name[0]) continue;"),
    ("src/fs/archive_vfs.c", "synthesised folder", "if (*p == '/') { *p = 0; dir = true; break; }", "if (*p == '/') { *p = 0; break; }"),
    ("src/fs/archive_vfs.c", "up one level", "while (i && ctx->sub[i - 1] != '/') i--;", "i = 0;"),
    ("src/fs/archive_vfs.c", "cursor on archive", "return (int32_t)cur >= 0 ? (int)cur : 0;", "return 0;"),
    ("src/fs/archive_vfs.c", "truncated flag", "return truncated ? 3 : 1;", "return 1;"),
    ("src/fs/archive_vfs.c", "sub slash", "if (n < PATH_MAX - 2) { ctx->sub[n] = '/'; ctx->sub[n + 1] = 0; }", ""),
    ("src/fs/archive_vfs.c", "gunzip skipped", "    if (ctx->type == ARC_TGZ) {", "    if (false) {"),
]


def test_mutants(t: Path, scripts: tuple[str, str], expect: tuple[str, str]) -> None:
    srcs = {s: (ROOT / s).read_text() for s in SRCS}
    for f, name, old, _ in MUTANTS:
        assert old in srcs[f], f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, f: str, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            paths = []
            for s in SRCS:
                p = mt / Path(s).name
                p.write_text(srcs[s].replace(old, new, 1) if s == f else srcs[s])
                paths.append(str(p))
            try:
                exe = build("x86_64", mt, paths)
                noticed[name] = any(run(exe, "c", sc).strip() != e.strip() for sc, e in zip(scripts, expect))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] AR5. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C modules are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        parsed = test_parsers(exe, t)
        test_zip64_wrap(exe, t)
        folder_out = test_folder(exe, t)
        scripts = (parse_script(corpus(t / "again")), nav_script(t / "pane"))
        expect = (run(exe, "c", scripts[0]), folder_out)
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            assert [run(a64, "c", sc, "aarch64") for sc in scripts] == list(expect), "qemu-aarch64 differs"
            print("[PASS] AR4. qemu-aarch64: the C modules give the x86_64 results")
        else:
            print("[SKIP] AR4: aarch64 toolchain/qemu not installed")
        test_mutants(t, scripts, expect)
    print("ALL C ARCHIVE TESTS PASSED.")


if __name__ == "__main__":
    main()
