#!/usr/bin/env python3
"""src/fs/pkg_verify.c versus the frozen assembly (tests/harness/pkg_verify_reference.s): pkg_hashes_append, pkg_hashes_write and
pkg_verify of installed packages.

PV1 differential (x86_64): verification of an intact package, of tampered / missing / extra-byte files, of hash lists with upper-
    case hex, bad hex, a short line, a missing space, no trailing newline, no manifest entry, more than 8 KiB, an empty list, of a
    missing or short "sha256", of unsafe names; building lists file by file up to the 8 KiB limit (a line that does not fit is not
    recorded), with unreadable files skipped, and writing them; results, buffers and files
PV2 qemu-aarch64: the C module gives the x86_64 results; PV3 mutation check
"""

import hashlib
import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/pkg_verify.c"
REF = "tests/harness/pkg_verify_reference.s"
CORE = ["src/core/string.c", "src/core/string_path.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c",
        "src/core/mem_prims.c", "src/core/hash.c", "src/core/hash_file.c", "src/fs/file_ops_delete.c", "src/fs/file_ops.c", "src/fs/file_ops_copy.c",
        "src/fs/file_ops_read.c", "src/fs/file_ops_overwrite.c", "src/fs/task.c", "src/fs/task_conflict.c", "build/i18n_en.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        o = t / "pkg_verify_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra = [o]
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\n#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n'
                    'int g_task_parent_pid; TaskShared *g_task_shm;\n')
    return H.build(arch, t, ["tests/harness/pkg_verify_cli.c", str(stub), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DPKV_SRC="{path}"'])


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def package(root: Path, name: str, files: dict[str, bytes], lines=None, sha_text: str | None = None) -> Path:
    d = root / name
    d.mkdir(parents=True)
    for rel, data in files.items():
        (d / rel).parent.mkdir(parents=True, exist_ok=True)
        (d / rel).write_bytes(data)
    if lines is None:
        lines = [f"{sha(d / rel)} {d / rel}\n" for rel in files]
    (d / "hashes.sha256").write_text("".join(lines))
    (d / "sha256").write_text(sha_text if sha_text is not None else "ab" * 32 + "\n")
    return d


def tree(root: Path) -> tuple[Path, list[str]]:
    base = {"manifest.ini": b"[package]\nname=x\n", "bin/tool": b"#!/bin/sh\n", "doc/readme": b"hello"}
    package(root, "ok", base)
    d = package(root, "tampered", base)
    (d / "bin" / "tool").write_bytes(b"#!/bin/sh\nrm -rf /\n")
    d = package(root, "missing", base)
    (d / "doc" / "readme").unlink()
    d = package(root, "upper", base, lines=None)
    (d / "hashes.sha256").write_text("".join(f"{sha(d / r).upper()} {d / r}\n" for r in base))
    p = root / "ok"
    good = [f"{sha(p / r)} {p / r}\n" for r in base]
    for tag, lines in (("badhex", ["g" * 64 + f" {p / 'manifest.ini'}\n"]), ("short", ["ab" * 32 + " \n"]), ("nospace", [good[0].replace(" ", "_", 1)]),
                       ("nonl", ["".join(good)[:-1]]), ("nomanifest", good[1:]), ("empty", []), ("huge", good + [good[1]] * 120)):
        package(root, tag, {}, lines=lines)
    package(root, "nosha", {}, lines=good)
    (root / "nosha" / "sha256").unlink()
    package(root, "shortsha", {}, lines=good, sha_text="abcd")
    package(root, "badsha", {}, lines=good, sha_text="z" * 64)
    package(root, "sha63", {}, lines=good, sha_text="ab" * 31 + "ag")          # the 64th character is not hex
    files = []
    fdir = root / "files"
    fdir.mkdir()
    for i in range(80):
        f = fdir / (f"f{i:03d}_" + "n" * (i % 50))
        f.write_bytes(bytes([i]) * i)
        files.append(str(f))
    (fdir / "noread").write_text("x")
    (fdir / "noread").chmod(0)
    files.insert(5, str(fdir / "noread"))
    files.insert(6, str(fdir / "missing"))
    return root, files


def scripts(root: Path, files: list[str]) -> str:
    names = ["ok", "tampered", "missing", "upper", "badhex", "short", "nospace", "nonl", "nomanifest", "empty", "huge", "nosha", "shortsha",
             "badsha", "sha63", "", ".", "..", "a/b", "ok/.", "nope"]
    s = "".join(f"V {n}\n" for n in names)
    s += "A " + " ".join(files[:20]) + "\n"
    s += "A " + " ".join(files) + "\n"                                    # beyond 8 KiB: the rest is not recorded
    edge = 8192 - 66 - len(files[0])                                      # the line ends exactly at the cap / one byte before
    s += "A +8000 " + " ".join(files[:3]) + "\n" + "".join(f"A +{edge + k} {files[0]}\n" for k in (-1, 0, 1))
    s += f"H {root / 'out'} " + " ".join(files[:10]) + "\n"
    return s


def run(exe: Path, impl: str, root: Path, script: str, arch: str = "x86_64") -> str:
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl], input=script.encode(), capture_output=True,
                         env={"PATH": "/usr/bin:/bin", "PKG_ROOT": str(root)}, timeout=60)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def one(exe: Path, t: Path, impl: str, arch: str = "x86_64") -> tuple[str, bytes]:
    root, files = tree(t / f"{impl[0]}_{arch[:3]}")                     # equal path lengths: the root is masked afterwards
    (root / "out").mkdir()
    out = run(exe, impl, root, scripts(root, files), arch)
    written = (root / "out" / "hashes.sha256").read_bytes()
    (root / "files" / "noread").chmod(0o644)
    return out.replace(str(root), "@@"), written.replace(str(root).encode(), b"@@")


def test_differential(exe: Path, t: Path) -> tuple[str, bytes]:
    a, b = one(exe, t, "ref"), one(exe, t, "c")
    assert a[0] == b[0], "oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(a[0].splitlines(), b[0].splitlines()) if x != y)
    assert a[1] == b[1], "the written hash lists differ"
    vs = {ln.split()[1]: ln.split()[-1] for ln in b[0].splitlines() if ln.startswith("V ") and len(ln.split()) == 3}
    assert vs["ok"] == "=0" and vs["upper"] == "=0" and all(v == "=-1" for k, v in vs.items() if k not in ("ok", "upper")), vs
    lens = [ln.split()[1] for ln in b[0].splitlines() if ln.startswith("A ")]
    assert lens[-3] == "len=8191" and "len=8192" not in lens[-2:] and lens[-2] != lens[-1], ("a line fits up to 8191 bytes", lens[-3:])
    print(f"[PASS] PV1. pkg_verify / hashes identical to the asm ({len(b[0].splitlines())} calls: intact, tampered, malformed lists, "
          "8 KiB limit, sha256 file, unsafe names, appends near the limit, the written list)")
    return b


MUTANTS = [
    ("cap", "#define PKG_HASHES_CAP 8192", "#define PKG_HASHES_CAP 8193"),
    ("fit bound", "if (at + n + 66 >= PKG_HASHES_CAP) return;", "if (at + n + 66 > PKG_HASHES_CAP) return;"),
    ("unreadable recorded", "if (hash_file(file_path, &crc, hex) < 0) return;", "(void)hash_file(file_path, &crc, hex);"),
    ("hex upper rejected", "        c |= 0x20;\n", ""),
    ("hex length", "for (int i = 0; i < 64; i++) {", "for (int i = 0; i < 63; i++) {"),
    ("no newline accepted", "if (nl >= end) return -1;", "if (nl > end) return -1;"),
    ("space", " || p[64] != ' ') return -1;", ") return -1;"),
    ("manifest optional", "return manifest ? 0 : -1;", "return 0;"),
    ("case-sensitive hash", "str_casecmp(p, hex)", "str_cmp(p, hex)"),
    ("tamper ignored", "if (hash_file(p + 65, &crc, hex) < 0 || str_casecmp(p, hex)) return -1;", "if (hash_file(p + 65, &crc, hex) < 0) return -1;"),
    ("unsafe names", "if (!pkm_safe_name(name)) return -1;", ""),
    ("sha length", "(int64_t)got < 64", "(int64_t)got < 4"),
    ("sha hex", " || !pkv_is_hex64(sha)) goto out;", ") goto out;"),
]


# Not mutated (equivalent in pkg_verify): the empty-list check (an empty list has no manifest entry either) and the 66-byte
# minimum line (a shorter line has no path, so hash_file fails).
def test_mutants(t: Path, expect: tuple[str, bytes]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "pkg_verify.c").write_text(src.replace(old, new, 1))
            try:
                noticed[name] = one(build("x86_64", mt, str(mt / "pkg_verify.c")), mt.parent / f"x{i:02d}", "c") != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError, OSError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] PV3. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe, t / "x00")
        if H.available("aarch64"):
            assert one(build("aarch64", t / "a64"), t / "x99", "c", "aarch64") == expect, "qemu-aarch64 differs"
            print("[PASS] PV2. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] PV2: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C PKG VERIFY TESTS PASSED.")


if __name__ == "__main__":
    main()
