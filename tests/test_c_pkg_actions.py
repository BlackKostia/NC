#!/usr/bin/env python3
"""src/fs/pkg_actions.c versus the frozen assembly (tests/harness/pkg_actions_reference.s): pkg_action_parse, pkg_action_find,
pkg_actions_scan, pkg_action_build_argv and the user-menu cache (pkg_menu_refresh / count / get).

PA1 differential (x86_64), each implementation in its own identical tree: manifests with blanks, CRLF, repeated / unknown keys,
    values beyond every field cap, no final newline; find of good / missing / unsafe names and unsafe executables; scans with max
    0 / 1 / 3 / all (packages without exec, unsafe directory names, files); the menu cache (more than 16 packages, menu-less ones
    dropped, indexes -1 .. count); argv building (placeholders set and unset, tabs, an executable path that just fits, buffers
    and argument arrays at their limits, unsafe executables, tiny buffers) with canaries after both
PA2 defects of the asm, fixed:
    - a package directory of 160 bytes or more was cut into the 160-byte slot by pkg_actions_scan, so the menu ran
      <cut dir>/<exec> - another program (the C skips such a package; pkg_action_find already refused it)
    - without DUOP_PKG_DIR / XDG_CONFIG_HOME / HOME pkg_action_find read ./<name>/manifest.ini and returned a relative directory
    - pkg_action_build_argv cut a word that did not fit the buffer and dropped the words beyond the argument array, so the action
      ran with other arguments than its manifest says (the C refuses: -1)
PA3 qemu-aarch64: the C module gives the x86_64 results; PA4 mutation check
"""

import shutil
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/pkg_actions.c"
REF = "tests/harness/pkg_actions_reference.s"
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
        o = t / "pkg_actions_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra.append(o)
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\n#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n'
                    'int g_task_parent_pid; TaskShared *g_task_shm;\nint pkg_fetch_url(char **e, const char *u, const char *d) '
                    '{ (void)e; (void)u; (void)d; return -1; }\n')
    return H.build(arch, t, ["tests/harness/pkg_actions_cli.c", str(stub), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DPKA_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, tree: Path, env: dict[str, str | None] | None = None, arch: str = "x86_64") -> str:
    e = {"PATH": "/usr/bin:/bin", "TREE": str(tree), "DUOP_PKG_DIR": str(tree / "pkgs")}
    e.update(env or {})
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl], input=script.encode(), capture_output=True, cwd=tree / "cwd",
                         env={k: v for k, v in e.items() if v is not None}, timeout=60)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


MANIFESTS = {
    "basic": "name = Basic\nexec = bin/run.sh\nmenu = Run basic\nargs = --dir {dir} {file}\nscope = file\nmode = bg\next = .txt,.md\n",
    "crlf": "name=Crlf\r\nexec=./tool\r\nargs=\t{path}\t-v \r\nmenu=\r\n",
    "caps": "".join(f"{k}={'x' * 300}\n" for k in ("name", "exec", "menu", "args", "scope", "mode", "ext")),
    "odd": "# c\n  name  =  spaced  \nunknown = 1\nexec=a\nexec=b\nnoeq\n=v\nmode=\"q\"\nargs",
    "noexec": "name=NoExec\nmenu=Has menu\n",
    "unsafe": "name=Unsafe\nexec=../../bin/sh\nmenu=Evil\n",
    "abs": "name=Abs\nexec=/bin/sh\nmenu=Abs\n",
    "plain": "name=Plain\nexec=p.sh\n",
}


def tree(t: Path) -> Path:
    shutil.rmtree(t, ignore_errors=True)
    for sub in ("pkgs", "cwd", "man"):
        (t / sub).mkdir(parents=True)
    for k, v in MANIFESTS.items():
        (t / "man" / k).write_text(v)
        (t / "pkgs" / k).mkdir()
        (t / "pkgs" / k / "manifest.ini").write_text(v)
    for i in range(14):
        (t / "pkgs" / f"m{i:02d}").mkdir()
        (t / "pkgs" / f"m{i:02d}" / "manifest.ini").write_text(f"name=M{i}\nexec=x\nmenu=Item {i}\n")
    (t / "pkgs" / "file").write_text("exec=x\n")
    (t / "pkgs" / "nomanifest").mkdir()
    (t / "man" / "empty").write_text("")
    (t / "manifest.ini").write_text("name=Parent\nexec=up\nmenu=Up\n")            # what ".." would reach
    (t / "pkgs2").mkdir()
    exact = "E" * (158 - len(str(t / "pkgs2")))                                   # "<root>/<name>" of exactly 159 / 160 bytes
    for name in (exact, exact + "F"):
        (t / "pkgs2" / name).mkdir()
        (t / "pkgs2" / name / "manifest.ini").write_text("name=Exact\nexec=x\n")
    for i in range(17):                                                         # one more menu action than the cache holds
        (t / "pkgs3" / f"q{i:02d}").mkdir(parents=True)
        (t / "pkgs3" / f"q{i:02d}" / "manifest.ini").write_text(f"name=Q{i}\nexec=q\nmenu=Q {i}\n")
    return t


BUILDS = [
    "run.sh|/pk/dir|1024|32|--dir {dir} {other_dir} {file} {path} {marked_file} literal",
    "run.sh|/pk/dir|1024|32|\t a\t\tb   c ",
    "run.sh|/pk/dir|1024|32|",
    "./run.sh|/pk/dir/|1024|32|x",
    "run.sh|/pk/dir|1024|2|",
    "run.sh|/pk/dir|1024|1|x",
    "run.sh|/pk/dir|1024|1|",
    "run.sh|/pk/dir|1|32|x",
    "run.sh|/pk/dir|0|32|x",
    "run.sh|/pk/dir|14|32|",
    "run.sh|/pk/dir|13|32|",
    "run.sh|/pk/dir|17|32|a",
    "run.sh|/pk/dir|21|32|{dir} a",
    "run.sh|/pk/dir|1024|4|a {dir}",
    "../x|/pk/dir|1024|32|a",
    "/bin/sh|/pk/dir|1024|32|a",
    "|/pk/dir|1024|32|a",
    "a..b|/pk/dir|1024|32|a",
    "run.sh|/pk/dir|1024|32|{DIR} {dir}x {} {path}",
]


def script(t: Path) -> str:
    s = "".join(f"P {t}/man/{k}\n" for k in (*MANIFESTS, "empty", "missing"))
    s += "".join(f"F {n}\n" for n in ("basic", "crlf", "unsafe", "abs", "noexec", "plain", "missing", "..", "a/b", "", "nomanifest", "file"))
    s += "S 0\nS 1\nS 3\nS 40\nM\n"
    s += "".join(f"B {b}\n" for b in BUILDS)
    return s


# argv cases the asm cut or truncated (PA2); part of the C expectation the mutants are compared with
C_ONLY = ["run.sh|/d|1024|4|a b c", "run.sh|/d|1024|4|a b", "run.sh|/pk/dir|17|32|ab", "run.sh|/pk/dir|16|32|a"]


def outputs(exe: Path, impl: str, d: Path, arch: str = "x86_64", c_only: bool = False) -> str:
    o = run(exe, impl, script(d), d, arch=arch)
    exact = sorted(p.name for p in (d / "pkgs2").iterdir())
    o += run(exe, impl, "".join(f"F {n}\n" for n in exact), d, {"DUOP_PKG_DIR": str(d / "pkgs2")}, arch)
    o += run(exe, impl, "M\n", d, {"DUOP_PKG_DIR": str(d / "pkgs3")}, arch)
    if c_only:
        o += run(exe, impl, "".join(f"B {b}\n" for b in C_ONLY), d, arch=arch)
    return o.replace(str(d), "<T>")


def test_differential(exe: Path, t: Path) -> str:
    a, b = tree(t / "pa1" / "r"), tree(t / "pa1" / "c")
    ra, rb = outputs(exe, "ref", a), outputs(exe, "c", b)
    assert ra == rb, "oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(ra.splitlines(), rb.splitlines()) if x != y)
    assert "F r=0" in rb and "F r=-1" in rb and "M n=" in rb and "ctx4" in rb and "<unset>" in rb and "B n=-1" in rb, "coverage"
    assert rb.splitlines()[-3].startswith("F r=0") and rb.splitlines()[-2] == "F r=-1" and "M n=16 count=16" in rb, rb.splitlines()[-3:-1]
    print(f"[PASS] PA1. identical to the asm on {len(rb.splitlines())} calls (parse, find, scan, menu cache, argv building)")
    return outputs(exe, "c", tree(t / "pa1" / "e"), c_only=True)


def test_fixed(exe: Path, t: Path) -> None:
    res = {}
    for impl in ("ref", "c"):
        d = tree(t / "pa2" / impl[0])
        longname = "L" * (170 - len(str(d / "pkgs")))
        (d / "pkgs" / longname).mkdir()
        (d / "pkgs" / longname / "manifest.ini").write_text("name=Long\nexec=run\nmenu=Long\n")
        scan = run(exe, impl, "S 40\n", d).replace(str(d), "<T>")
        (d / "cwd" / "rel").mkdir()
        (d / "cwd" / "rel" / "manifest.ini").write_text("name=Rel\nexec=r.sh\n")
        find = run(exe, impl, "F rel\n", d, {"DUOP_PKG_DIR": None})
        argv = run(exe, impl, "B run.sh|/d|1024|4|a b c d e\nB run.sh|/d|16|32|abcdefghij\nB run.sh|/d|1024|32|" + " ".join("w" * 3 for _ in range(31)) + "\n", d)
        res[impl] = (scan, find, argv)
    ref, c = res["ref"], res["c"]
    assert "|Long|" in ref[0].replace("[Long|", "|Long|") and "|Long|" not in c[0].replace("[Long|", "|Long|"), (ref[0][-200:], c[0][-200:])
    assert ref[1].startswith("F r=0") and "|rel]" in ref[1] and c[1] == "F r=-1\n", (ref[1], c[1])
    rl, cl = ref[2].splitlines(), c[2].splitlines()
    assert all(ln.startswith("B n=-1 ") for ln in cl[:2]) and not any(ln.startswith("B n=-1 ") for ln in rl[:2]), (rl, cl)
    assert cl[2].startswith("B n=-1 ") and not rl[2].startswith("B n=-1 "), (rl[2][:80], cl[2][:80])
    print("[PASS] PA2. fixed: a package dir of >= 160 bytes is skipped (asm: cut, another program run); no root -> no relative "
          "find (asm: ./rel/manifest.ini); argv that does not fit is refused (asm: words cut / dropped)")


# Equivalent, not listed: "buf_cap < 1" for "buf_cap < 2" - a one-byte buffer holds only "", and an empty executable is refused.
MUTANTS = [
    ("trim tab", "while (s < e && (*s == ' ' || *s == '\\t')) s++;", "while (s < e && *s == ' ') s++;"),
    ("trim cr", "e[-1] == '\\t' || e[-1] == '\\r'))", "e[-1] == '\\t'))"),
    ("trim cap", "while (n < cap - 1 && s < e)", "while (n < cap && s < e)"),
    ("args cap", '{"args", offsetof(PkgAction, args), 128}', '{"args", offsetof(PkgAction, args), 64}'),
    ("first key wins", "                    break;\n", "                    return;\n"),
    ("safe seg dotdot", '!str_cmp(s, "..")) return false;', '0) return false;'),
    ("find relpath", "if (pkm_safe_relpath(out->exec) && str_len(dir)", "if (str_len(dir)"),
    ("find dir cap", "str_len(dir) < sizeof out->dir) {", "str_len(dir) <= sizeof out->dir) {"),
    ("scan max", "n < max && (name", "(name"),
    ("scan exec", "if (!out[n].exec[0] || str_len(dir)", "if (str_len(dir)"),
    ("placeholder unset", 'return ctx[i] ? ctx[i] : "";', "return ctx[i];"),
    ("placeholder other", '"{other_dir}"', '"{other}"'),
    ("max min", "max_args < 2 ||", "max_args < 1 ||"),
    ("exec safe", "!pkm_safe_relpath(act->exec) ||", ""),
    ("word fit", "k >= cap) goto fail;", "k > cap) goto fail;"),
    ("array fit", "if (n >= max_args - 1 ||", "if (n >= max_args ||"),
    ("tab separator", "while (p[k] && p[k] != ' ' && p[k] != '\\t') k++;", "while (p[k] && p[k] != ' ') k++;"),
    ("literal advance", "if (!v) { buf += k + 1; cap -= k + 1; }", "if (!v) { buf += k; cap -= k; }"),
    ("argv end", "    argv_out[n] = nullptr;\n    return n;", "    return n;"),
    ("fail argv0", "    argv_out[0] = nullptr;\n    return -1;", "    return -1;"),
    ("menu filter", "if (pka_menu_cache[i].menu[0]) {", "if (1) {"),
    ("menu cap", "#define PKA_MENU_MAX 16", "#define PKA_MENU_MAX 15"),
    ("menu get bound", "idx < pka_menu_cnt ?", "idx <= pka_menu_cnt ?"),
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
            (mt / "pkg_actions.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "pkg_actions.c"))
                noticed[name] = outputs(exe, "c", tree(mt / "c"), c_only=True) != expect
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
            assert outputs(a64, "c", tree(t / "pa3" / "c"), "aarch64", c_only=True) == expect, "qemu-aarch64 differs"
            print("[PASS] PA3. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] PA3: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C PKG ACTIONS TESTS PASSED.")


if __name__ == "__main__":
    main()
