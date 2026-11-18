#!/usr/bin/env python3
"""src/fs/pkg_vfs.c versus the frozen assembly (tests/harness/pkg_vfs_reference.s): pkg_vfs_list_stdout, the VFS-provider runner
behind `duop pkg vfs-list <uri>`.

PV1 differential (x86_64): providers found by scheme among packages of other kinds, other schemes, hidden directories, missing or
    unsafe executables (absolute, "../", a symlink), a non-executable script (made 0755 first), the argv / environment the helper
    gets, outputs of 0 B .. 300 KiB in bursts, URIs without "://", with a 62- / 63-character scheme, no root
PV2 defects of the asm, fixed:
    - a provider silent for a second ended the listing but was then waited for without limit: a hung helper hung duop (the C kills
      it and reports -1)
    - the provider's exit status was ignored: exit 3 or a failed exec (127) still reported success
    - a URI with an empty scheme ("://x") ran a vfs package that declares no vfs_scheme
PV3 qemu-aarch64: the C module gives the x86_64 results; PV4 mutation check
"""

import os
import shutil
import subprocess
import time
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/pkg_vfs.c"
REF = "tests/harness/pkg_vfs_reference.s"
CORE = ["src/fs/pkg_manager.c", "src/fs/pkg_archive.c", "src/fs/pkg_verify.c", "src/fs/archive_parse.c", "src/fs/inflate.c", "src/core/string.c",
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
        o = t / "pkg_vfs_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra.append(o)
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\n#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n'
                    'int g_task_parent_pid; TaskShared *g_task_shm;\nint pkg_fetch_url(char **e, const char *u, const char *d) '
                    '{ (void)e; (void)u; (void)d; return -1; }\n')
    return H.build(arch, t, ["tests/harness/pkg_vfs_cli.c", str(stub), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DPKV_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, tree: Path, env: dict[str, str | None] | None = None, arch: str = "x86_64",
        timeout: int = 60) -> str:
    e = {"PATH": "/usr/bin:/bin", "DUOP_PKG_DIR": str(tree / "pkgs"), "HELPER_VAR": "seen"}
    e.update(env or {})
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl], input=script.encode(), capture_output=True, cwd=tree,
                         env={k: v for k, v in e.items() if v is not None}, timeout=timeout)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace").replace(str(tree), "<T>")


SH = "#!/bin/sh\n"
PACKAGES = {                     # name: (manifest, {file: (text, mode)})
    "aa-theme": ("kind = theme\nvfs_scheme = mock\nexec = t.sh\n", {"t.sh": (SH + "echo wrong\n", 0o755)}),
    "solo-theme": ("kind = theme\nvfs_scheme = solo\nexec = t.sh\n", {"t.sh": (SH + "echo wrong\n", 0o755)}),
    "mock": ("name = mock\nkind = vfs\nvfs_scheme = mock\nexec = bin/list.sh\n",
             {"bin/list.sh": (SH + 'printf "%s|%s|%s|%s\\n" "$0" "$1" "$2" "$HELPER_VAR"\nprintf "a.txt\\t1\\t33188\\t0\\n"\n', 0o755)}),
    "zz-mock2": ("kind = vfs\nvfs_scheme = mock\nexec = list.sh\n",                 # a second provider: the first one listed wins
                 {"list.sh": (SH + 'printf "%s|%s|%s|%s\\n" "$0" "$1" "$2" "$HELPER_VAR"\n', 0o755)}),
    ".hidden": ("kind = vfs\nvfs_scheme = hid\nexec = h.sh\n", {"h.sh": (SH + "echo hidden\n", 0o755)}),
    "big": ("kind=vfs\r\nvfs_scheme=big\r\nexec=./b.sh\r\n", {"b.sh": (SH + "i=0; while [ $i -lt 3000 ]; do printf '%0100d\\n' $i; i=$((i+1)); done\n", 0o755)}),
    "burst": ("kind=vfs\nvfs_scheme=burst\nexec=b.sh\n", {"b.sh": (SH + "echo one; sleep 0.3; echo two; sleep 0.3; echo three\n", 0o755)}),
    "noexec": ("kind=vfs\nvfs_scheme=plain\nexec=p.sh\n", {"p.sh": (SH + "echo made-executable\n", 0o644)}),
    "abs": ("kind=vfs\nvfs_scheme=abs\nexec=/bin/echo\n", {}),
    "dotdot": ("kind=vfs\nvfs_scheme=up\nexec=../mock/bin/list.sh\n", {}),
    "missing": ("kind=vfs\nvfs_scheme=gone\nexec=nothere.sh\n", {}),
    "link": ("kind=vfs\nvfs_scheme=link\nexec=l.sh\n", {}),
    "dir": ("kind=vfs\nvfs_scheme=dir\nexec=sub\n", {"sub/x": ("x", 0o644)}),
    "empty": ("kind=vfs\nvfs_scheme=empty\nexec=e.sh\n", {"e.sh": (SH + "exit 0\n", 0o755)}),
    "long": (f"kind=vfs\nvfs_scheme={'s' * 62}\nexec=l.sh\n", {"l.sh": (SH + "echo long62\n", 0o755)}),
    "long63": (f"kind=vfs\nvfs_scheme={'t' * 63}\nexec=l.sh\n", {"l.sh": (SH + "echo long63\n", 0o755)}),
    "noscheme": ("kind=vfs\nexec=n.sh\n", {"n.sh": (SH + "echo noscheme\n", 0o755)}),
    "slow": ("kind=vfs\nvfs_scheme=slow\nexec=s.sh\n", {"s.sh": (SH + "echo start; exec sleep 6\n", 0o755)}),
    "fails": ("kind=vfs\nvfs_scheme=fails\nexec=f.sh\n", {"f.sh": (SH + "echo partial; exit 3\n", 0o755)}),
    "badexec": ("kind=vfs\nvfs_scheme=badexec\nexec=x.bin\n", {"x.bin": ("\x7fELFgarbage", 0o755)}),
}


def tree(t: Path) -> Path:
    shutil.rmtree(t, ignore_errors=True)
    for name, (man, files) in PACKAGES.items():
        d = t / "pkgs" / name
        d.mkdir(parents=True)
        (d / "manifest.ini").write_text(man)
        for f, (text, mode) in files.items():
            (d / f).parent.mkdir(parents=True, exist_ok=True)
            (d / f).write_text(text)
            os.chmod(d / f, mode)
    os.symlink("../mock/bin/list.sh", t / "pkgs" / "link" / "l.sh")
    (t / "pkgs" / "file").write_text("kind=vfs\n")
    return t


URIS = ["mock://root/dir", "solo://", "mock:x", "big://", "burst://a", "plain://", "abs://", "up://", "gone://", "link://", "dir://", "empty://",
        "s" * 62 + "://", "t" * 63 + "://", "hid://", "nothing://", "noscheme", "", "mock"]


def test_differential(exe: Path, t: Path) -> str:
    s = "\n".join(URIS) + "\n"
    a, b = tree(t / "pv1" / "r"), tree(t / "pv1" / "c")
    ra, rb = run(exe, "ref", s, a), run(exe, "c", s, b)
    ra += run(exe, "ref", "mock://\n", a, {"DUOP_PKG_DIR": None})
    rb += run(exe, "c", "mock://\n", b, {"DUOP_PKG_DIR": None})
    assert ra == rb, "oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(ra.splitlines(), rb.splitlines()) if x != y)
    assert "LIST|mock://root/dir|seen" in rb and "made-executable" in rb and "long62" in rb and "long63" not in rb, "coverage"
    assert rb.count("0000000002999") == 1 and "three" in rb and "hidden" not in rb and "wrong" not in rb, "coverage"
    assert os.stat(b / "pkgs" / "noexec" / "p.sh").st_mode & 0o777 == 0o755
    print(f"[PASS] PV1. identical to the asm on {len(URIS) + 1} URIs ({len(rb)} bytes of provider output)")
    return rb


def test_fixed(exe: Path, t: Path) -> None:
    res = {}
    for impl in ("ref", "c"):
        d = tree(t / "pv2" / impl[0])
        t0 = time.monotonic()
        out = run(exe, impl, "slow://\nfails://\nbadexec://\n://x\n", d)
        res[impl] = (out, time.monotonic() - t0)
    ref, c = res["ref"], res["c"]
    rl, cl = ref[0].splitlines(), c[0].splitlines()
    assert rl[1] == cl[1] == "start" and rl[2].startswith("= r=0 ms=") and int(rl[2].split("ms=")[1]) >= 5000, rl
    assert cl[2].startswith("= r=-1 ms=") and int(cl[2].split("ms=")[1]) <= 2000, cl
    assert "= r=0" in rl[5] and "= r=-1" in cl[5] and "= r=0" in rl[7] and "= r=-1" in cl[7], (rl, cl)
    assert "noscheme" in ref[0] and "noscheme" not in c[0] and cl[-1] == "= r=-1 ms=0", (rl[-3:], cl[-3:])
    assert c[1] < ref[1] - 3, (ref[1], c[1])
    print(f"[PASS] PV2. fixed: a silent provider is killed after 1 s (asm waited {ref[1]:.1f} s, C {c[1]:.1f} s); exit 3 / a failed "
          "exec report -1 (asm: 0); \"://x\" runs nothing (asm: the package without vfs_scheme)")


# Equivalent, not listed: dropping the "root[0] &&" test - opening "" as the root fails with ENOENT anyway.
MUTANTS = [
    ("trim cr", "e[-1] == '\\t' || e[-1] == '\\r'))", "e[-1] == '\\t'))"),
    ("kind cap", "pkv_trim_cp(eq + 1, eol, out->kind, sizeof out->kind)", "pkv_trim_cp(eq + 1, eol, out->kind, 3)"),
    ("kind checked", '!str_cmp(info.kind, "vfs") && ', ""),
    ("hidden skipped", "name[0] == '.' || ", ""),
    ("safe exec", "? pkm_safe_relpath(info.exec) : nullptr", "? info.exec : nullptr"),
    ("first match", "!found && (name =", "(name ="),
    ("scheme length", "n < PKV_SCHEME_MAX - 1 &&", "n < PKV_SCHEME_MAX &&"),
    ("colon required", "if (uri[n] != ':' || !n) return -1;", "if (!n) return -1;"),
    ("ensure exec", "if (pkg_ensure_exec(exe) < 0 || ", "if ("),
    ("argv list", '{exe, "LIST", uri, nullptr}', '{exe, "LS", uri, nullptr}'),
    ("eof ends", "if (n == 0) return true;", "if (n == 0) continue;"),
    ("silence", "#define PKV_SILENCE_MS 1000", "#define PKV_SILENCE_MS 200"),
    ("exit status", "status == 0 ? 0 : -1;", "1 ? 0 : -1;"),
]


def test_mutants(t: Path, expect: str) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}
    s = "\n".join(URIS) + "\n"

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "pkg_vfs.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "pkg_vfs.c"))
                d = tree(mt / "c")
                o = run(exe, "c", s, d, timeout=30) + run(exe, "c", "mock://\n", d, {"DUOP_PKG_DIR": "/nonexistent"}, timeout=30)
                noticed[name] = o + run(exe, "c", "fails://\n", d, timeout=30) != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] PV4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def c_expect(exe: Path, d: Path, arch: str = "x86_64") -> str:
    s = "\n".join(URIS) + "\n"
    o = run(exe, "c", s, d, arch=arch) + run(exe, "c", "mock://\n", d, {"DUOP_PKG_DIR": "/nonexistent"}, arch)
    return o + run(exe, "c", "fails://\n", d, arch=arch)


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        test_differential(exe, t)
        test_fixed(exe, t)
        expect = c_expect(exe, tree(t / "pv3" / "x"))
        if H.available("aarch64"):
            assert c_expect(build("aarch64", t / "a64"), tree(t / "pv3" / "a"), "aarch64") == expect, "qemu-aarch64 differs"
            print("[PASS] PV3. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] PV3: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C PKG VFS TESTS PASSED.")


if __name__ == "__main__":
    main()
