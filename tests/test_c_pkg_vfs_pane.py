#!/usr/bin/env python3
"""src/fs/pkg_vfs_pane.c versus the frozen assembly (tests/harness/pkg_vfs_pane_reference.s): pkg_vfs_find_by_uri,
pkg_vfs_load_dir, pkg_vfs_parent_uri and pkg_vfs_read_uri - a VFS provider package as a pane.

PP1 differential (x86_64), each implementation in its own identical tree, real shell providers: lookup by "<scheme>://" (other
    kinds, a prefix scheme, "scheme:" without "//", hidden package directories, unsafe execs), listings (sizes, mtimes, "d" dirs,
    CRLF, empty and nameless lines, names of 255+ bytes, missing fields, huge numbers) entered from a real directory and
    re-listed inside the VFS, parent URIs (root, trailing slash, no scheme, small buffers), READ into a temp file
PP2 defects of the asm, fixed:
    - a provider silent for 1.5 s was then waited for without limit: a hung provider froze the UI (the C kills it, -1)
    - the provider's exit status was ignored: a failing LIST showed an empty folder, a failing READ opened an empty file
    - a listing beyond 64 KiB was cut, its last line becoming a bogus entry (the C grows the buffer up to 8 MiB, beyond: -1)
    - READ stopped reading the provider's stdout after 200 bytes, so a chatty provider died of SIGPIPE mid-write and the cut file
      was opened; the C drains it
    - a failed READ left its temp file behind
PP3 qemu-aarch64: the C module gives the x86_64 results; PP4 mutation check
"""

import os
import shutil
import subprocess
import time
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/pkg_vfs_pane.c"
REF = "tests/harness/pkg_vfs_pane_reference.s"
MODS = ["src/fs/dir_model.c", "src/fs/dir_model_filter.c", "src/fs/dir_model_load.c", "src/fs/dir_model_stream.c", "src/fs/dir_model_stat.c",
        "src/fs/dir_model_select.c", "src/fs/dir_sort.c", "src/fs/dir_sort_radix.c", "src/fs/dir_cache.c", "src/fs/dir_search.c",
        "src/fs/dir_search_match.c", "src/fs/archive_vfs.c", "src/core/oop_rt.c"]
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
        o = t / "pkg_vfs_pane_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra.append(o)
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\n#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n'
                    'int g_task_parent_pid; TaskShared *g_task_shm;\nint pkg_fetch_url(char **e, const char *u, const char *d) '
                    '{ (void)e; (void)u; (void)d; return -1; }\n')
    return H.build(arch, t, ["tests/harness/pkg_vfs_pane_cli.c", str(stub), *MODS, *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DPKP_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, tree: Path, env: dict[str, str | None] | None = None, arch: str = "x86_64",
        timeout: int = 60) -> str:
    e = {"PATH": "/usr/bin:/bin", "TREE": str(tree), "DUOP_PKG_DIR": str(tree / "pkgs")}
    e.update(env or {})
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl], input=script.encode(), capture_output=True, cwd=tree,
                         env={k: v for k, v in e.items() if v is not None}, timeout=timeout)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


SH = "#!/bin/sh\n"
LISTING = ("a.txt\\t10\\t1700000000\\n" "cr\\rname\\t2\\t2\\n" "sub\\t0\\t1600000000\\td\\n" "crlf.txt\\t5\\t1\\r\\n" "\\n" "\\t7\\t7\\n" "nofields\\n"
           "onlysize\\t42\\n" "huge\\t99999999999999999999999\\t18446744073709551615\\n" + "L" * 300 + "\\t1\\t1\\n" "x\\t12abc\\t3\\n")
PROVIDER = SH + f'''case "$1" in
LIST) case "$2" in
  *empty*) ;;
  *) printf '{LISTING}' ;; esac ;;
READ) printf 'content of %s\\n' "$2" > "$3" ;;
esac
'''
PACKAGES = {
    "aa-theme": ("kind=theme\nvfs_scheme=mock\nexec=p.sh\n", {"p.sh": (SH + "echo wrong\n", 0o755)}),
    "solo-theme": ("kind=theme\nvfs_scheme=solo\nexec=p.sh\n", {"p.sh": (PROVIDER, 0o755)}),      # the only "solo" package
    "mock": ("kind = vfs\nvfs_scheme = mock\nexec = bin/p.sh\n", {"bin/p.sh": (PROVIDER, 0o755)}),
    "mo": ("kind=vfs\nvfs_scheme=mo\nexec=p.sh\n", {"p.sh": (PROVIDER.replace("content of", "mo content"), 0o644)}),
    ".hid": ("kind=vfs\nvfs_scheme=hid\nexec=p.sh\n", {"p.sh": (PROVIDER, 0o755)}),
    "unsafe": ("kind=vfs\nvfs_scheme=bad\nexec=../mock/bin/p.sh\n", {}),
    "noscheme": ("kind=vfs\nexec=p.sh\n", {"p.sh": (PROVIDER, 0o755)}),
    "slow": ("kind=vfs\nvfs_scheme=slow\nexec=s.sh\n", {"s.sh": (SH + "printf 'early\\t1\\t1\\n'; exec sleep 6\n", 0o755)}),
    "fails": ("kind=vfs\nvfs_scheme=fails\nexec=f.sh\n", {"f.sh": (SH + "printf 'x\\t1\\t1\\n'; [ \"$1\" = READ ] && echo half > \"$3\"; exit 4\n", 0o755)}),
    "crlf": ("kind=vfs\r\nvfs_scheme=crlf\r\nexec=p.sh\r\n", {"p.sh": (PROVIDER, 0o755)}),
    "burst": ("kind=vfs\nvfs_scheme=burst\nexec=b.sh\n", {"b.sh": (SH + "printf 'one\\t1\\t1\\n'; sleep 0.5; printf 'two\\t2\\t2\\n'\n", 0o755)}),
    "dirx": ("kind=vfs\nvfs_scheme=dirx\nexec=sub\n", {"sub/x": ("x", 0o644)}),
    "big": ("kind=vfs\nvfs_scheme=big\nexec=b.sh\n",
            {"b.sh": (SH + "i=0; while [ $i -lt 1500 ]; do printf 'file-%04d-%s\\t%d\\t1\\n' $i aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa $i; i=$((i+1)); done\n", 0o755)}),
    "chatty": ("kind=vfs\nvfs_scheme=chatty\nexec=c.sh\n",
               {"c.sh": (SH + "i=0; while [ $i -lt 2000 ]; do echo progress $i; i=$((i+1)); done; printf 'complete\\n' > \"$3\"\n", 0o755)}),
}


def tree(t: Path) -> Path:
    shutil.rmtree(t, ignore_errors=True)
    (t / "real" / "dir").mkdir(parents=True)
    (t / "real" / "f.txt").write_text("f")
    (t / "manifest.ini").write_text("kind=vfs\nvfs_scheme=dotdot\nexec=pkgs/mock/bin/p.sh\n")    # what ".." of the root would read
    (t / "pkgs").mkdir()
    (t / "pkgs" / "manifest.ini").write_text("kind=vfs\nvfs_scheme=dot\nexec=mock/bin/p.sh\n")       # and "."
    for name, (man, files) in PACKAGES.items():
        d = t / "pkgs" / name
        d.mkdir(parents=True, exist_ok=True)
        (d / "manifest.ini").write_text(man)
        for f, (text, mode) in files.items():
            (d / f).parent.mkdir(parents=True, exist_ok=True)
            (d / f).write_text(text)
            os.chmod(d / f, mode)
    return t


def script(t: Path) -> str:
    s = "".join(f"F {u}\n" for u in ("mock://", "mock://a/b", "mo://x", "mock:x", "mock:/x", "hid://", "bad://", "://", "nothing://",
                                      "MOCK://", "moc://", "theme://", "dot://", "dotdot://", "crlf://", "solo://"))
    s += f"N {t}/real\nL burst://\nL mock://root\nL mock://root/sub\nL mock://empty\nL mo://\nL nothing://\nL bad://x\n"
    s += "".join(f"U {cap} {u}\n" for cap, u in ((256, "mock://a/b/c"), (256, "mock://a/"), (256, "mock://a"), (256, "mock://"),
                                                  (256, "plain/path"), (256, "mock:///x"), (256, "s://a//b"), (8, "mock://abc/def"),
                                                  (11, "mock://a/bc"), (1, "mock://a")))
    s += "R mock://dir/file.txt\nR mo://f\nR nothing://f\nT\n"
    return s


def test_differential(exe: Path, t: Path) -> str:
    a, b = tree(t / "pp1" / "r"), tree(t / "pp1" / "c")
    ra, rb = run(exe, "ref", script(a), a), run(exe, "c", script(b), b)
    assert ra == rb, "oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(ra.splitlines(), rb.splitlines()) if x != y)
    assert "vm=3" in rb and "orig=<T>/real" in rb and "sub:1:" in rb and "R r=0 file len=" in rb and "U r=0" in rb, "coverage"
    print(f"[PASS] PP1. identical to the asm on {len(rb.splitlines())} calls (lookup, listings, parent URIs, READ)")
    return rb


def test_fixed(exe: Path, t: Path) -> None:
    res = {}
    for impl in ("ref", "c"):
        d = tree(t / "pp2" / impl[0])
        t0 = time.monotonic()
        o = run(exe, impl, f"N {d}/real\nL slow://\n", d)
        slow = time.monotonic() - t0
        o += run(exe, impl, f"N {d}/real\nL fails://\nR fails://f\nL big://\nR chatty://f\nR dirx://f\nT\n", d)
        res[impl] = (o.splitlines(), slow)
    (rl, rslow), (cl, cslow) = res["ref"], res["c"]
    assert rl[1].startswith("L r=0") and "early" in rl[1] and rslow > 5, (rl[1][:80], rslow)
    assert cl[1].startswith("L r=-1") and cslow < 4, (cl[1][:80], cslow)
    assert rl[3].startswith("L r=0") and " x:0:" in rl[3] and cl[3].startswith("L r=-1"), (rl[3][:80], cl[3][:80])
    assert rl[4].startswith("R r=0 file") and cl[4] == "R r=-1 none", (rl[4], cl[4])
    nref, nc = int(rl[5].split(" n=")[1].split()[0]), int(cl[5].split(" n=")[1].split()[0])
    assert cl[5].startswith("L r=0") and nc == 1501 and nref < nc, (nref, nc)
    assert rl[6] != cl[6] and cl[6].startswith("R r=0 file len=9 "), (rl[6], cl[6])
    assert rl[7] == "R r=-1 left" and cl[7] == "R r=-1 none" and cl[8] == "T files=0" and rl[8] == "T files=1", (rl[7:], cl[7:])
    print(f"[PASS] PP2. fixed: a hung provider is killed ({rslow:.1f} s -> {cslow:.1f} s); failing LIST / READ report -1 (asm: empty "
          f"folder, a half file); 1500 entries listed in full (asm: {nref - 1}, cut at 64 KiB); a chatty READ is drained; no stale temp file")


MUTANTS = [
    ("trim cr", "e[-1] == '\\t' || e[-1] == '\\r'))", "e[-1] == '\\t'))"),
    ("kind", 'if (str_cmp(in.kind, "vfs") || ', "if ("),
    ("scheme set", "!in.scheme[0] || ", ""),
    ("slashes", "uri[sl] == ':' && uri[sl + 1] == '/' && uri[sl + 2] == '/'", "uri[sl] == ':'"),
    ("safe exec", "? pkm_safe_relpath(in.exec) : nullptr", "? in.exec : nullptr"),
    ("dot entries", 'found = str_cmp(nm, ".") && str_cmp(nm, "..") && ', "found = "),
    ("silence", "#define PKVP_SILENCE_MS 1500", "#define PKVP_SILENCE_MS 100"),
    ("exit status", "status == 0 ? 0 : -1;", "1 ? 0 : -1;"),
    ("grow", "size_t nc = o->cap * 2 > o->max ? o->max : o->cap * 2;", "size_t nc = o->cap;"),
    ("name cr", "if (*p != '\\r' && n < 255) name[n++] = *p;", "if (n < 255) name[n++] = *p;"),
    ("name cap", "n < 255) name[n++]", "n < 254) name[n++]"),
    ("nameless", "    if (!n) return 0;\n", ""),
    ("dir flag", "st.mode = S_IFDIR | 0755;", "st.mode = S_IFREG | 0755;"),
    ("mtime", "st.mtime = pkvp_dec(&p, eol);", "(void)pkvp_dec(&p, eol);"),
    ("orig kept", "if (model->virtual_mode != 3) {", "if (1) {"),
    ("parent entry", "if (ds_append_parent(model) < 0) goto out;", ""),
    ("sorted", "    DirModel_sort(model);\n", ""),
    ("parent root", "    out[s] = 0;\n    return 1;", "    return 0;"),
    ("parent slash", "if (out[e] == '/') { out[e] = 0; return 1; }", "if (out[e] == '/') { out[e + 1] = 0; return 1; }"),
    ("read arg", '"READ", uri, out_tmp_path, envp', '"READ", uri, nullptr, envp'),
    ("read unlink", "    (void)os_unlinkat(AT_FDCWD, out_tmp_path, 0);", ""),
]


def c_expect(exe: Path, d: Path, arch: str = "x86_64") -> str:
    return run(exe, "c", script(d), d, arch=arch) + run(exe, "c", f"N {d}/real\nL fails://\nR fails://f\nL big://\nR chatty://f\nR dirx://f\nT\n", d, arch=arch)


def test_mutants(t: Path, expect: str) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "pkg_vfs_pane.c").write_text(src.replace(old, new, 1))
            try:
                noticed[name] = c_expect(build("x86_64", mt, str(mt / "pkg_vfs_pane.c")), tree(mt / "c")) != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] PP4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        test_differential(exe, t)
        test_fixed(exe, t)
        expect = c_expect(exe, tree(t / "pp3" / "x"))
        if H.available("aarch64"):
            assert c_expect(build("aarch64", t / "a64"), tree(t / "pp3" / "a"), "aarch64") == expect, "qemu-aarch64 differs"
            print("[PASS] PP3. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] PP3: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C PKG VFS PANE TESTS PASSED.")


if __name__ == "__main__":
    main()
