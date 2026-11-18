#!/usr/bin/env python3
"""src/fs/pkg_popup.c + pkg_preview.c versus the frozen assembly (tests/harness/pkg_popup_reference.s, pkg_preview_reference.s):
the popup-menu package actions (pkg_popup_refresh / count / label / get), pkg_action_has_marked, pkg_write_marked_list and the
external previewers (pkg_preview_try).

PM1 differential (x86_64), identical trees, real previewer scripts: menu actions filtered by scope (dir / file / any) and ext lists
    (commas, blanks, case, a value cut to its field, suffixes without a dot) for files, directories and no entry, more than 8 matches,
    labels and indexes -1 .. count; "{marked_file}" detection; marked lists (selections, none with and
    without a fallback, temp-name buffers too small); previewers chosen by preview_ext, their argv, outputs cut at max_len,
    0 / 1-byte buffers, output in bursts, unsafe and non-executable previewers, no root
PM2 defects of the asm, fixed:
    - a previewer that filled the buffer and then kept running was waited for without limit: the preview helper hung (the C kills
      it once the preview is full)
    - pkg_write_marked_list wrote a selected path that did not fit PATH_MAX as an empty line, so an action ran on a wrong file
      list; the C returns -1 and leaves no file (it also checks every write and the close, untested here)
PM3 qemu-aarch64: the C modules give the x86_64 results; PM4 mutation check
"""

import os
import shutil
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = ["src/fs/pkg_popup.c", "src/fs/pkg_preview.c"]
REFS = ["tests/harness/pkg_popup_reference.s", "tests/harness/pkg_preview_reference.s"]
MODS = ["src/fs/pkg_actions.c", "src/fs/dir_model.c", "src/fs/dir_model_filter.c", "src/fs/dir_model_load.c", "src/fs/dir_model_stream.c",
        "src/fs/dir_model_stat.c", "src/fs/dir_model_select.c", "src/fs/dir_sort.c", "src/fs/dir_sort_radix.c", "src/fs/dir_cache.c",
        "src/fs/dir_search.c", "src/fs/dir_search_match.c", "src/fs/archive_vfs.c", "src/core/oop_rt.c"]
CORE = ["src/fs/pkg_manager.c", "src/fs/pkg_archive.c", "src/fs/pkg_verify.c", "src/fs/archive_parse.c", "src/fs/inflate.c", "src/core/string.c",
        "src/core/string_path.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c",
        "src/core/hash.c", "src/core/hash_file.c", "src/core/config.c", "src/core/tmpfile.c", "src/fs/file_ops_read.c", "src/fs/file_ops.c",
        "src/fs/file_ops_copy.c", "src/fs/file_ops_delete.c", "src/fs/file_ops_overwrite.c", "src/fs/task.c", "src/fs/task_conflict.c",
        "build/i18n_en.c"]


def build(arch: str, t: Path, srcs: list[str] | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    s1, s2 = [s if Path(s).is_absolute() else str(ROOT / s) for s in (srcs or SRCS)]
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    uring = t / "pal_uring.o"
    subprocess.run([*H.ARCHS[arch]["as_"], *inc, str(ROOT / f"src/os/linux/{arch}/pal_uring.s"), "-o", str(uring)], check=True, capture_output=True)
    extra = [uring]
    if arch == "x86_64":
        objs = []
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run(["as", *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            objs.append(o)
        H.rename_defined_globals(objs, "ref_")
        extra += objs
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\n#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n'
                    'int g_task_parent_pid; TaskShared *g_task_shm;\nint pkg_fetch_url(char **e, const char *u, const char *d) '
                    '{ (void)e; (void)u; (void)d; return -1; }\n')
    return H.build(arch, t, ["tests/harness/pkg_menu_cli.c", str(stub), *MODS, *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DPKM1_SRC="{s1}"', f'-DPKM2_SRC="{s2}"'])


def run(exe: Path, impl: str, script: str, tree: Path, env: dict[str, str | None] | None = None, arch: str = "x86_64",
        timeout: int = 60) -> str:
    e = {"PATH": "/usr/bin:/bin", "TREE": str(tree), "DUOP_PKG_DIR": str(tree / "pkgs")}
    e.update(env or {})
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl], input=script.encode(), capture_output=True, cwd=tree,
                         env={k: v for k, v in e.items() if v is not None}, timeout=timeout)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


SH = "#!/bin/sh\n"
ACTIONS = {                                      # name: manifest
    "a-any": "name=Any\nexec=x\nmenu=Any entry\n",
    "b-dir": "name=Dir\nexec=x\nmenu=Dirs only\nscope=dir\n",
    "c-file": "name=File\nexec=x\nmenu=Files only\nscope = file\n",
    "d-md": "name=Md\nexec=x\nmenu=Markdown\next=.md, .MARKDOWN\n",
    "e-txt": "name=Txt\nexec=x\nmenu=Text\next=txt,log\n",
    "f-nomenu": "name=NoMenu\nexec=x\next=.md\n",
    "g-weird": "name=Weird\nexec=x\nmenu=Weird\nscope=other\next=" + "w" * 63 + "q" * 7 + "\n",      # cut to the 63-byte field
    "h-dirext": "name=DirExt\nexec=x\nmenu=Dir ext\nscope=dir\next=.md\n",
    **{f"m{i:02d}": f"name=M{i}\nexec=x\nmenu=Many {i}\next=.many\n" for i in range(7)},   # 15 actions: all scanned
}
PREVIEWERS = {                                   # name: (manifest, script, mode)
    "p-echo": ("preview_ext = .pv, .PVX\npreview_exec = bin/pv.sh\n", SH + 'printf "preview of %s|%s|" "$1" "$2"\nprintf "%s" "$#"\n', 0o755),
    "p-big": ("preview_ext=.big\npreview_exec=b.sh\n", SH + "i=0; while [ $i -lt 4000 ]; do echo line $i; i=$((i+1)); done\n", 0o755),
    "p-burst": ("preview_ext=.burst\npreview_exec=b.sh\n", SH + "echo one; sleep 0.1; echo two; sleep 0.1; echo three\n", 0o755),
    "p-silent": ("preview_ext=.silent\npreview_exec=s.sh\n", SH + "echo start; exec sleep 3\n", 0o755),
    "p-plain": ("preview_ext=.plain\npreview_exec=p.sh\n", SH + "echo plain\n", 0o644),
    "p-unsafe": ("preview_ext=.unsafe\npreview_exec=../p-echo/bin/pv.sh\n", "", 0o755),
    "p-fail": ("preview_ext=.fail\npreview_exec=f.sh\n", SH + "echo failing; exit 9\n", 0o755),
    "p-noext": ("preview_exec=n.sh\n", SH + "echo noext\n", 0o755),
    "p-fill": ("preview_ext=.fill\npreview_exec=f.sh\n", SH + "printf 'xxxxxxxxxx'; exec sleep 4\n", 0o755),
}


def tree(t: Path) -> Path:
    shutil.rmtree(t, ignore_errors=True)
    for name, man in ACTIONS.items():
        (t / "pkgs" / name).mkdir(parents=True)
        (t / "pkgs" / name / "manifest.ini").write_text(man)
    for name, (man, script, mode) in PREVIEWERS.items():
        d = t / "pkgs" / name
        d.mkdir(parents=True)
        (d / "manifest.ini").write_text(man)
        exe = man.split("preview_exec")[1].split("=")[1].split("\n")[0].strip()
        if script:
            (d / exe).parent.mkdir(parents=True, exist_ok=True)
            (d / exe).write_text(script)
            os.chmod(d / exe, mode)
    sel = t / "sel"
    (sel / "subdir").mkdir(parents=True)
    for f in ("one.txt", "two.md", "three"):
        (sel / f).write_text(f)
    ld = long_dir(t)                                       # about 4000 bytes: <dir>/<200-byte name> cannot fit
    ld.mkdir(parents=True)
    dfd = os.open(ld, os.O_RDONLY | os.O_DIRECTORY)                # the full path is too long for open()
    os.close(os.open("n" * 200, os.O_WRONLY | os.O_CREAT, 0o644, dir_fd=dfd))
    os.close(dfd)
    return t


def fixed_script(d: Path) -> str:
    """C-only expectations (PM2): the full previewer killed, the marked path that cannot fit"""
    return f"V 10 a.fill\nN {long_dir(d)}\nS {'n' * 200}\nW 4096 -\nT\n"


def long_dir(t: Path) -> Path:
    d = t / "L"
    while len(str(d)) + 251 < 4090:
        d = d / ("l" * 250)
    return d


def script(t: Path) -> str:
    s = "".join(f"R {d} {n}\n" for d, n in ((0, "a.md"), (0, "A.MARKDOWN"), (1, "dir.md"), (0, "x.txt"), (0, "notes.LOG"), (0, "a.many"),
                                           (1, "x"), (0, "-"), (1, "-"), (0, "plain"), (0, "a" + "w" * 63), (0, "qqqqqqq")))
    s += "".join(f"H {a}\n" for a in ("{marked_file}", "--list {marked_file} -v", "{marked_file", "{MARKED_FILE}", "", "{dir}"))
    s += f"N {t}/sel\nW 4096 -\nW 4096 {t}/fallback.txt\nS one.txt\nS subdir\nW 4096 {t}/fallback.txt\nW 40 -\nW 63 -\nT\n"
    s += "".join(f"V {m} {f}\n" for m, f in ((4096, "/x/a.pv"), (4096, "/X/B.PVX"), (10, "/x/a.pv"), (1, "a.pv"), (0, "a.pv"),
                                              (65536, "/y.big"), (100, "/y.big"), (4096, "z.burst"), (4096, "q.plain"), (4096, "q.unsafe"),
                                              (4096, "q.fail"), (4096, "q.none"), (4096, "q.noext")))
    return s


def test_differential(exe: Path, t: Path) -> str:
    a, b = tree(t / "pm1" / "r"), tree(t / "pm1" / "c")
    ra = run(exe, "ref", script(a), a) + run(exe, "ref", "V 4096 a.pv\nR 0 a.md\n", a, {"DUOP_PKG_DIR": None})
    rb = run(exe, "c", script(b), b) + run(exe, "c", "V 4096 a.pv\nR 0 a.md\n", b, {"DUOP_PKG_DIR": None})
    assert ra == rb, "oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(ra.splitlines(), rb.splitlines()) if x != y)
    for needle in ("R n=8 ", "Markdown", "Dirs only", "H 1", "H 0", "<T>/sel/one.txt", "fallback.txt", "preview of /x/a.pv||1", "plain", "failing"):
        assert needle in rb, f"coverage: {needle}"
    print(f"[PASS] PM1. identical to the asm on {len(rb.splitlines())} calls (popup filtering, marked lists, previewers)")
    return rb


def test_fixed(exe: Path, t: Path) -> None:
    res = {}
    for impl in ("ref", "c"):
        d = tree(t / "pm2" / impl[0])
        res[impl] = run(exe, impl, fixed_script(d), d).splitlines()
    ref, c = res["ref"], res["c"]
    assert ref[0].startswith("V r=10 ms=4000") and c[0].startswith("V r=10 ms=0"), (ref[0], c[0])
    assert ref[3] == 'W r=0 file="\\x0a"' and c[3] == "W r=-1 nofile" and c[4] == ref[4], (ref[3:], c[3:])
    print("[PASS] PM2. fixed: a previewer that fills the buffer and stays is killed (asm waited 4 s); a marked path that does not "
          "fit fails the list (asm: an empty line written)")


# Equivalent, not listed: the empty-list shortcut of pkp_match_ext (only reached with a non-empty ext) and the "pext[0] &&" test
# of pkg_preview (an empty preview_ext has no word to match); "got <= max_len" (the extra zero-byte read ends the loop like
# the full buffer does); the 63-byte word cap (an ext / preview_ext field holds 63 bytes, so no word is longer).
MUTANTS = [
    ("src/fs/pkg_popup.c", "ext case", "same = pkp_lower(name[nlen - n + i]) == pkp_lower(list[i]);", "same = name[nlen - n + i] == list[i];"),
    ("src/fs/pkg_popup.c", "ext blank", "if (*list == ',' || *list == ' ') { list++; continue; }", "if (*list == ',') { list++; continue; }"),
    ("src/fs/pkg_popup.c", "menu needed", "if (!a->menu[0]) return false;", ""),
    ("src/fs/pkg_popup.c", "scope dir", 'if (!str_cmp(a->scope, "dir") && !is_dir) return false;', ""),
    ("src/fs/pkg_popup.c", "scope file", 'if (!str_cmp(a->scope, "file") && is_dir) return false;', ""),
    ("src/fs/pkg_popup.c", "ext on dirs", "(!is_dir && pkp_match_ext(a->ext, name))", "pkp_match_ext(a->ext, name)"),
    ("src/fs/pkg_popup.c", "cache cap", "#define PKP_CACHE_MAX 8", "#define PKP_CACHE_MAX 7"),
    ("src/fs/pkg_popup.c", "get bound", "idx < pkp_cnt ?", "idx <= pkp_cnt ?"),
    ("src/fs/pkg_popup.c", "marked word", '"{marked_file}"', '"{marked_file"'),
    ("src/fs/pkg_popup.c", "fallback only unmarked", "if (ok && !marked && fallback_path", "if (ok && fallback_path"),
    ("src/fs/pkg_popup.c", "line newline", "line[n] = '\\n';", "line[n] = ' ';"),
    ("src/fs/pkg_popup.c", "fit refused", "if (n < 0) { ok = false; break; }", "if (n < 0) continue;"),
    ("src/fs/pkg_preview.c", "pext key", '"preview_ext"', '"preview_ex"'),
    ("src/fs/pkg_preview.c", "preview case", "same = pkpv_lower(path[plen - n + i]) == pkpv_lower(list[i]);", "same = path[plen - n + i] == list[i];"),
    ("src/fs/pkg_preview.c", "safe exec", "? pkm_safe_relpath(pexec) : nullptr", "? pexec : nullptr"),
    ("src/fs/pkg_preview.c", "silence", "#define PKPV_SILENCE_MS 350", "#define PKPV_SILENCE_MS 30"),
    ("src/fs/pkg_preview.c", "argv", "{exe, path, nullptr}", "{exe, nullptr, nullptr}"),
    ("src/fs/pkg_preview.c", "ensure exec", "if (pkg_ensure_exec(exe) < 0 || ", "if ("),
]


def c_expect(exe: Path, d: Path, arch: str = "x86_64") -> str:
    o = run(exe, "c", script(d), d, arch=arch) + run(exe, "c", "V 4096 a.pv\nR 0 a.md\n", d, {"DUOP_PKG_DIR": None}, arch)
    return o + run(exe, "c", fixed_script(d), d, arch=arch)


def test_mutants(t: Path, expect: str) -> None:
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
                noticed[name] = c_expect(build("x86_64", mt, paths), tree(mt / "c")) != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] PM4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C modules are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        test_differential(exe, t)
        test_fixed(exe, t)
        expect = c_expect(exe, tree(t / "pm3" / "x"))
        if H.available("aarch64"):
            assert c_expect(build("aarch64", t / "a64"), tree(t / "pm3" / "a"), "aarch64") == expect, "qemu-aarch64 differs"
            print("[PASS] PM3. qemu-aarch64: the C modules give the x86_64 results")
        else:
            print("[SKIP] PM3: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C PKG POPUP / PREVIEW TESTS PASSED.")


if __name__ == "__main__":
    main()
