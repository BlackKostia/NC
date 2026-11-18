#!/usr/bin/env python3
"""src/fs/pkg_manager.c versus the frozen assembly (tests/harness/pkg_manager_reference.s): pkg_get_root, pkg_list,
pkg_install_archive, pkg_remove, pkm_safe_name and pkm_safe_relpath.

PM1 differential (x86_64), each implementation in its own identical tree (compared afterwards, the tree path masked): roots from
    DUOP_PKG_DIR / XDG_CONFIG_HOME / HOME; installs of .tar / .tar.gz / .tgz / .zip packages from paths and http(s) URLs (with the
    SHA-256 right, upper-case, wrong, absent), the manifest at any depth, unsafe / empty / missing names, hostile entry paths
    ("../", absolute, "./", "a../b"), *.lang / *.layout activation, reinstalls; listings with max 0 / 1 / 3 / all; removals
    (activated files deleted, hostile files.list lines kept, unsafe names refused); name and relative-path checks
PM2 defects of the asm, fixed:
    - without DUOP_PKG_DIR / XDG_CONFIG_HOME / HOME the root was "", so an install wrote and deleted ./manifest.ini and unpacked the
      package into the working directory; a root too long for "<root>/<name>" unpacked it there too (the C refuses both)
    - pkg_list read every manifest into the directory block it was still iterating: with long manifests later packages vanished
      or were misread (the C is checked against the expected set of 120 packages)
    - a download always got a ".tar.gz" temp name, so a .zip or .tar URL could never be installed; a failed download left its
      temp file behind
    - a files.list line that did not fit 8 KiB was cut or left without its newline (the C records whole lines only)
    - a reinstall overwrote files.list, so the *.lang / *.layout files of the old version were never removed (the C deletes them
      before installing the new one); a sha256 / files.list / hashes.sha256 that could not be written still reported success
PM3 qemu-aarch64: the C module gives the x86_64 results; PM4 mutation check
"""

import gzip
import hashlib
import io
import os
import shutil
import stat
import subprocess
import tarfile
import zipfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/pkg_manager.c"
REF = "tests/harness/pkg_manager_reference.s"
CORE = ["src/fs/pkg_archive.c", "src/fs/pkg_verify.c", "src/fs/archive_parse.c", "src/fs/inflate.c", "src/core/string.c",
        "src/core/string_path.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c",
        "src/core/hash.c", "src/core/hash_file.c", "src/core/config.c", "src/core/tmpfile.c", "src/fs/file_ops_read.c", "src/fs/file_ops.c",
        "src/fs/file_ops_copy.c", "src/fs/file_ops_delete.c", "src/fs/file_ops_overwrite.c", "src/fs/task.c", "src/fs/task_conflict.c",
        "build/i18n_en.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    uring = t / "pal_uring.o"
    subprocess.run([*H.ARCHS[arch]["as_"], *inc, str(ROOT / f"src/os/linux/{arch}/pal_uring.s"), "-o", str(uring)], check=True, capture_output=True)
    extra = [uring]
    if arch == "x86_64":
        o = t / "pkg_manager_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra.append(o)
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\n#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n'
                    'int g_task_parent_pid; TaskShared *g_task_shm;\n')
    return H.build(arch, t, ["tests/harness/pkg_manager_cli.c", str(stub), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DPKM_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, tree: Path, env: dict[str, str] | None = None, arch: str = "x86_64", cwd: Path | None = None) -> str:
    e = {"PATH": "/usr/bin:/bin", "TREE": str(tree), "FETCH_DIR": str(tree / "arc"), "DUOP_PKG_DIR": str(tree / "pkgs")}
    e.update(env or {})
    e = {k: v for k, v in e.items() if v is not None}
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl], input=script.encode(), capture_output=True, cwd=cwd or tree / "cwd",
                         env=e, timeout=120)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def snapshot(d: Path) -> list[tuple]:
    out = []
    for p in sorted(d.rglob("*")):
        st = p.lstat()
        kind = "l" if stat.S_ISLNK(st.st_mode) else "d" if stat.S_ISDIR(st.st_mode) else "f"
        data = ""
        if kind == "f":
            data = hashlib.sha256(p.read_bytes().replace(str(d).encode(), b"<T>")).hexdigest()[:16]
        out.append((str(p.relative_to(d)), kind, stat.S_IMODE(st.st_mode), data))
    return out


def manifest(name: str, ver: str = "1.0.0", kind: str = "plugin", extra: str = "") -> bytes:
    return f"name = {name}\nversion = \"{ver}\"\nkind = {kind}\ndescription = The {name} package\n{extra}".encode()


def tar_bytes(files: list[tuple[str, bytes | None]], gz: bool = False) -> bytes:
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
    return gzip.compress(bio.getvalue(), mtime=0) if gz else bio.getvalue()


def zip_bytes(files: list[tuple[str, bytes]]) -> bytes:
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, "w") as zf:
        for name, data in files:
            zf.writestr(zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0)), data, compress_type=zipfile.ZIP_DEFLATED)
    return bio.getvalue()


def archives(arc: Path) -> dict[str, str]:
    """name -> sha256 of the packages used by the scripts"""
    pk = {
        "alpha.tar.gz": tar_bytes([("manifest.ini", manifest("alpha")), ("bin/", None), ("bin/tool", b"#!/bin/sh\necho alpha\n"),
                                   ("uk.lang", b"k = v\n"), ("lang/de.lang", b"d = e\n"), ("en.layout", b"layout\n"),
                                   ("./dot/x", b"dot"), ("../evil", b"evil"), ("/abs", b"abs"), ("a../b", b"ab"), ("deep/1/2/3/f", b"f"),
                                   ("..", b"dd")], gz=True),
        "beta.zip": zip_bytes([("beta-2.0/manifest.ini", manifest("beta", "2.0", "theme")), ("beta-2.0/theme.ini", b"[c]\n" * 50),
                               ("fr.lang", b"f = r\n")]),
        "gamma.tar": tar_bytes([("x/manifest.ini", manifest("gamma")), ("x/gamma.bin", bytes(range(256)) * 40)]),
        "delta.tgz": tar_bytes([("manifest.ini", manifest("delta", kind="lang")), ("pl.lang", b"p = l\n")], gz=True),
        "alpha2.tar.gz": tar_bytes([("manifest.ini", manifest("alpha", "1.1.0")), ("bin/tool", b"new\n")], gz=True),
        "eps.tar.gz": tar_bytes([("manifest.ini", manifest("eps", "0.1")), ("cs.lang", b"c = s\n")], gz=True),
        "longname.tar.gz": tar_bytes([("manifest.ini", manifest("longname-package-x")), ("lg.txt", b"lg")], gz=True),
        "noman.tar.gz": tar_bytes([("readme", b"no manifest")], gz=True),
        "unsafe.tar.gz": tar_bytes([("manifest.ini", manifest("../up"))], gz=True),
        "slash.tar.gz": tar_bytes([("manifest.ini", manifest("a/b"))], gz=True),
        "dot.tar.gz": tar_bytes([("manifest.ini", manifest("."))], gz=True),
        "noname.tar.gz": tar_bytes([("manifest.ini", b"version=1\n")], gz=True),
        "big.tar.gz": tar_bytes([("manifest.ini", b"# " + b"c" * 5000 + b"\nname=late\n")], gz=True),
        "corrupt.tar.gz": b"\x1f\x8b\x08\x00" + b"\0" * 40,
    }
    for name, data in pk.items():
        (arc / name).write_bytes(data)
    return {k: hashlib.sha256(v).hexdigest() for k, v in pk.items()}


def tree(t: Path) -> Path:
    shutil.rmtree(t, ignore_errors=True)
    for sub in ("arc", "pkgs", "cwd", "home", "xdg", "list"):
        (t / sub).mkdir(parents=True)
    (t / "cwd" / "manifest.ini").write_text("the user's own file\n")
    for i, (nm, man) in enumerate((("p1", "name=a\n"), ("p2", "name=b\nkind=k\n"), ("p3", "kind=x\n"), ("p4", None), ("p5", "name=c\n"),
                                   ("..x", "name=d\n"), ("p6", "name=e\n"))):
        (t / "list" / nm).mkdir()
        if man is not None:
            (t / "list" / nm / "manifest.ini").write_text(man)
    (t / "list" / "file").write_text("name=f\n")
    fl = t / "pkgs" / "hostile"
    fl.mkdir()
    (t / "lang").mkdir()
    for f in ("ok.lang", "keep.lang", "x"):
        (t / "lang" / f).write_text(f)
    pk = str(t / "pkgs")
    (t / "langfoo").write_text("not in lang/")
    (fl / "files.list").write_text(f"{pk}/../langfoo\n{pk}/../lang/ok.lang\n{pk}/../lang/sub/x\n/etc/hostname\n{pk}/../langx/x\n{pk}/../lang/../x\n"
                                   f"{pk}/../lang/keep.lang")
    archives(t / "arc")
    return t


def script(t: Path) -> str:
    sha = archives(t / "arc")
    a = t / "arc"
    s = "R\n"
    s += f"I {a}/alpha.tar.gz {sha['alpha.tar.gz']}\nI {a}/beta.zip {sha['beta.zip'].upper()}\nI {a}/gamma.tar -\nI {a}/delta.tgz {'0' * 64}\n"
    s += f"I {a}/delta.tgz -\nI https://host/x/eps.tar.gz {sha['eps.tar.gz']}\nI http://host/gamma.tar.gz -\n"
    s += "".join(f"I {a}/{n} -\n" for n in ("noman.tar.gz", "unsafe.tar.gz", "slash.tar.gz", "dot.tar.gz", "noname.tar.gz", "big.tar.gz",
                                             "corrupt.tar.gz", "missing.tar.gz", "readme"))
    s += "L 0\nL 1\n"                                       # full listings of this root: test_differential checks the C ones
    s += "D alpha\nD alpha\nD hostile\nD ..\nD a/b\nD\nD .\nD nope\n"
    s += "".join(f"S {x}\n" for x in ("abc", ".", "..", "...", "a/b", "./x", "././y", "./", "/abs", "a..", "a../b", "..a", "x/..",
                                      "x/../y", "x/..y", ".hidden", "a//b"))
    return s


def test_differential(exe: Path, t: Path) -> str:
    a, b = tree(t / "pm1" / "r"), tree(t / "pm1" / "c")
    outs = []
    for impl, d in (("ref", a), ("c", b)):
        o = run(exe, impl, script(d), d)
        o += run(exe, impl, "R\nI {0}/arc/delta.tgz -\nL\n".format(d), d, {"DUOP_PKG_DIR": None, "XDG_CONFIG_HOME": str(d / "xdg")})
        o += run(exe, impl, "R\nI {0}/arc/gamma.tar -\nL\nD gamma\n".format(d), d, {"DUOP_PKG_DIR": None, "HOME": str(d / "home")})
        o += run(exe, impl, "R\nL\nL 2\nL 5\n", d, {"DUOP_PKG_DIR": str(d / "list")})
        outs.append(o.replace(str(d), "<T>"))
    ra, rb = outs
    assert ra == rb, "oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(ra.splitlines(), rb.splitlines()) if x != y)
    assert snapshot(a) == snapshot(b), "the trees differ"
    assert "I r=0" in rb and "I r=-1" in rb and "D r=0" in rb and "D r=-1" in rb and "lang/uk.lang" not in "".join(map(str, snapshot(b))), "coverage"
    listed = run(exe, "c", "L\nL 2\n", b).splitlines()
    names = sorted(x.split("|")[0] for x in listed[0].split(" [")[1:])
    assert names == ["delta", "eps"]                       # beta / gamma keep their manifest in a sub-folder: not listed and listed[1].startswith("L n=2 "), listed
    assert (b / "langfoo").exists() and (b / "lang" / "x").exists() and not (b / "lang" / "ok.lang").exists() and (b / "lang" / "keep.lang").exists()
    print(f"[PASS] PM1. identical to the asm on {len(rb.splitlines())} steps (roots, installs from paths and URLs, listings, removals, "
          "name checks) and identical trees")
    return rb


def test_fixed(exe: Path, t: Path) -> None:
    res = {}
    for impl in ("ref", "c"):
        d = tree(t / "pm2" / impl[0])
        o = run(exe, impl, f"I {d}/arc/delta.tgz -\nR\n", d, {"DUOP_PKG_DIR": None})
        cwd_after = sorted(p.name for p in (d / "cwd").iterdir())
        long_root = str(d / "L") + "/" + "/".join(["d" * 200] * 21)
        long_root = long_root[:4080]                    # "<root>/manifest.ini" fits PATH_MAX, "<root>/longname-package-x" does not
        o2 = run(exe, impl, f"I {d}/arc/longname.tar.gz -\n", d, {"DUOP_PKG_DIR": long_root})
        cwd_long = sorted(p.name for p in (d / "cwd").iterdir())
        (d / "arc" / "z.zip").write_bytes((d / "arc" / "beta.zip").read_bytes())
        (d / "arc" / "t.tar").write_bytes((d / "arc" / "gamma.tar").read_bytes())
        o3 = run(exe, impl, "I http://h/z.zip -\nI https://h/t.tar -\nI http://h/fail.tar.gz -\nT\nL\n", d)
        res[impl] = (o, cwd_after, o2, cwd_long, o3)
        shutil.rmtree(d / "L", ignore_errors=True)
    ref, c = res["ref"], res["c"]
    assert ref[0].startswith("I r=0") and ref[1] == ["delta"], ref[:2]           # ./manifest.ini gone, ./delta/ installed
    assert c[0].startswith("I r=-1") and c[1] == ["manifest.ini"], c[:2]
    assert ref[2] == "I r=0\n" and {"lg.txt", "sha256", "files.list", "hashes.sha256"} <= set(ref[3]), ref[2:4]
    assert c[2] == "I r=-1\n" and c[3] == ["manifest.ini"], (ref[3], c[2:4])
    assert "I r=-1" in ref[4].splitlines()[1] and "T files=1" in ref[4], ref[4]
    lines = [ln for ln in c[4].splitlines() if not ln.startswith("  fetch")]
    assert lines[:4] == ["I r=0", "I r=0", "I r=-1", "T files=0"], c[4]
    assert all((t / "pm2" / "c" / "pkgs" / n / "sha256").is_file() for n in ("beta", "gamma")), "the .zip / .tar downloads were not installed"
    print("[PASS] PM2a. fixed: no root -> no install into the working directory (asm: ./manifest.ini replaced and deleted, the package "
          "unpacked in place; the same for a root too long for <root>/<name>); .zip / .tar URLs install; failed downloads leave no file")


def test_list_model(exe: Path, t: Path) -> None:
    d = t / "pm2" / "list"
    shutil.rmtree(d, ignore_errors=True)
    d.mkdir(parents=True)
    want = set()
    for i in range(120):
        p = d / f"package-{i:03d}"
        p.mkdir()
        (p / "manifest.ini").write_text(f"# {'x' * 900}\nname=pkg{i}\nversion={i}.0\n")
        want.add(f"pkg{i}|{i}.0||")
    outs = {impl: run(exe, impl, "L\n", d, {"DUOP_PKG_DIR": str(d)}, cwd=d) for impl in ("ref", "c")}
    got = outs["c"].split(" [")[1:]
    got = {g.split("]")[0] for g in got}
    assert got == want, (len(got), sorted(want - got)[:3])
    assert outs["ref"] != outs["c"], "the asm listing is no longer corrupted by its manifest reads"
    print(f"[PASS] PM2b. fixed: pkg_list of 120 packages with 1 KiB manifests lists every one (asm: {outs['ref'].count(' [')} entries, "
          "manifests read into the directory block being iterated)")


def test_files_list(exe: Path, t: Path) -> None:
    d = tree(t / "pm2" / "fl")
    files = [("manifest.ini", manifest("many"))] + [(f"{'l' * 88}{i:02d}.lang", b"x") for i in range(80)]   # tar names <= 100
    (d / "arc" / "many.tar").write_bytes(tar_bytes(files))
    assert run(exe, "c", f"I {d}/arc/many.tar -\n", d) == "I r=0\n"
    text = (d / "pkgs" / "many" / "files.list").read_text()
    lines = text.split("\n")
    assert text.endswith("\n") and len(text) < 8190 and all(ln.endswith(".lang") for ln in lines[:-1]), text[-300:]
    assert all(Path(ln).is_file() for ln in lines[:-1]) and 20 < len(lines) - 1 < 80
    r = tree(t / "pm2" / "fr")
    (r / "arc" / "many.tar").write_bytes(tar_bytes(files))
    assert run(exe, "ref", f"I {r}/arc/many.tar -\n", r) == "I r=0\n"
    cut = (r / "pkgs" / "many" / "files.list").read_text()
    assert not cut.endswith("\n") and not cut.endswith(".lang"), cut[-120:]              # the asm: a cut path, no newline
    print(f"[PASS] PM2c. fixed: files.list keeps whole lines only ({len(lines) - 1} of 80 activations fit 8 KiB)")


def test_reinstall(exe: Path, t: Path) -> None:
    res = {}
    for impl in ("ref", "c"):
        d = tree(t / "pm2" / f"re{impl[0]}")
        o = run(exe, impl, f"I {d}/arc/alpha.tar.gz -\nI {d}/arc/alpha2.tar.gz -\nD alpha\n", d)
        res[impl] = (o, sorted(p.name for p in (d / "lang").iterdir()), sorted(p.name for p in (d / "layouts").iterdir()))
    assert res["ref"][0] == res["c"][0] == "I r=0\nI r=0\nD r=0\n", res
    assert "uk.lang" in res["ref"][1] and "en.layout" in res["ref"][2], res["ref"]
    assert "uk.lang" not in res["c"][1] and "de.lang" not in res["c"][1] and res["c"][2] == [], res["c"]
    out = {}
    for impl in ("ref", "c"):
        d = tree(t / "pm2" / f"w{impl[0]}")
        (d / "pkgs" / "delta" / "sha256").mkdir(parents=True)         # the record cannot be written
        out[impl] = run(exe, impl, f"I {d}/arc/delta.tgz -\n", d)
    assert out == {"ref": "I r=0\n", "c": "I r=-1\n"}, out
    print("[PASS] PM2d. fixed: a reinstall first deletes the activations of the old version (asm: files.list overwritten, "
          "uk.lang / de.lang / en.layout orphaned for good); "
          "an unwritable sha256 record fails the install (asm: success)")


# Equivalent, not listed: extracting directory entries too ("e->is_dir ? nullptr :" dropped) - pkm_ensure_parent creates the
# directory and opening "<dir>/" for writing then fails, so nothing changes.
MUTANTS = [
    ("xdg sub", '"/duop/packages"', '"/duop/package"'),
    ("root fits", "str_len(v) + str_len(sub) >= (size_t)cap", "str_len(v) + str_len(sub) > (size_t)cap"),
    ("safe dot", '!str_cmp(s, ".") || ', ""),
    ("relpath dotslash", "while (p[0] == '.' && p[1] == '/') p += 2;", ""),
    ("relpath dotdot end", "(!q[2] || q[2] == '/')", "(q[2] == '/')"),
    ("list max", "n < max && (name", "(name"),
    ("list own buffer", "fs_read_file_head(path, man, PKM_MANIFEST_MAX, &len)", "fs_read_file_head(path, dents, PKM_MANIFEST_MAX, &len)"),
    ("list empty name", "if (out[n].name[0]) n++;", "n++;"),
    ("activate layout", '".layout") ? pkm_dir_lay', '".layoutx") ? pkm_dir_lay'),
    ("activate newline", "files[at + dl] = '\\n';", "files[at + dl] = ' ';"),
    ("parent dir", "    pkg_mkdir_p(buf);\n}", "}"),
    ("hashes", "        pkg_hashes_append(dst, lists + PKM_LIST_CAP, &lens[1]);\n", ""),
    ("manifest any depth", "path_basename(ctx->entries[i].name)", "ctx->entries[i].name"),
    ("manifest unlinked", "    (void)os_unlinkat(AT_FDCWD, tmp, 0);\n    if (r < 0)", "    if (r < 0)"),
    ("unsafe name", "return pkm_safe_name(pe->name) ? 0 : -1;", "return pe->name[0] ? 0 : -1;"),
    ("sha file", "pkg_write_file(path, sha_hex, 64)", "pkg_write_file(path, sha_hex, 63)"),
    ("sha compare", "!str_casecmp(sha, expected_sha256)", "!str_cmp(sha, expected_sha256)"),
    ("zip suffix", 'case ARC_ZIP: return ".zip";', 'case ARC_ZIP: return ".tar.gz";'),
    ("tmp unlink", "    if (dl) (void)os_unlinkat(AT_FDCWD, tmp, 0);\n", ""),
    ("unlink layouts", "else if (str_starts_with(p, pkm_dir_lay)) p += sizeof pkm_dir_lay - 1;", ""),
    ("unlink slash", "return *p == '/' && pkm_safe_name(p + 1);", "return pkm_safe_name(p + 1);"),
    ("complete lines", "if (nl == end) break;", ""),
    ("reinstall cleanup", "    pkm_unlink_listed(root, dir, path, lists);", ""),
    ("record failure", "pkg_write_file(path, sha_hex, 64) != 0) r = -1;", "pkg_write_file(path, sha_hex, 64) != 0) r = 0;"),
    ("remove dir", "r = fs_delete_recursive(dir) < 0 ? -1 : 0;", "r = 0;"),
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
            p = mt / "pkg_manager.c"
            p.write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(p))
                noticed[name] = c_reference(exe, mt / "c") != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] PM4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def c_reference(exe: Path, t: Path, arch: str = "x86_64") -> str:
    d = tree(t)
    o = run(exe, "c", script(d), d, arch=arch) + run(exe, "c", "L\nL 2\n", d, arch=arch)
    o += run(exe, "c", "R\nI {0}/arc/delta.tgz -\nL\n".format(d), d, {"DUOP_PKG_DIR": None, "XDG_CONFIG_HOME": str(d / "xdg")}, arch)
    o += run(exe, "c", "R\nI {0}/arc/gamma.tar -\nL\nD gamma\n".format(d), d, {"DUOP_PKG_DIR": None, "HOME": str(d / "home")}, arch)
    o += run(exe, "c", "R\nL\nL 2\nL 5\n", d, {"DUOP_PKG_DIR": str(d / "list")}, arch)
    o += run(exe, "c", "I http://h/beta.zip -\nI http://h/fail.tar.gz -\nT\n", d, arch=arch)
    o += run(exe, "c", "R\n", d, {"DUOP_PKG_DIR": "/" + "r" * 4095}, arch)
    o += run(exe, "c", f"I {d}/arc/alpha.tar.gz -\nI {d}/arc/alpha2.tar.gz -\n", d, arch=arch)
    (d / "pkgs" / "longname-package-x" / "sha256").mkdir(parents=True)
    o += run(exe, "c", f"I {d}/arc/longname.tar.gz -\n", d, arch=arch)
    return o.replace(str(d), "<T>") + "\n".join(map(str, snapshot(d)))


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        test_differential(exe, t)
        test_fixed(exe, t)
        test_list_model(exe, t)
        test_files_list(exe, t)
        test_reinstall(exe, t)
        expect = c_reference(exe, t / "c")
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            assert c_reference(a64, t / "c", "aarch64") == expect, "qemu-aarch64 differs"
            print("[PASS] PM3. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] PM3: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C PKG MANAGER TESTS PASSED.")


if __name__ == "__main__":
    main()
