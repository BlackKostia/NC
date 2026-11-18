#!/usr/bin/env python3
"""src/ui/status_bar.c versus the frozen assembly (tests/harness/status_bar_reference.s + status_bar_render_reference.s): the
StatusBar widget, rendered through its vtable and compared cell by cell (text, colours, attributes; tests/harness/ui_render.h).

SB1 differential (x86_64): construction (id, class, app), StatusBar_set_message (kinds 0..3 and an unknown one, Unicode, 600-byte
    text, negative and zero TTLs) and expiry by the scripted clock; the background-task summary and its hint; entry lines for
    files of 0 B .. 5 GiB, directories, "..", executables, symlinks (to a file, dangling, to a directory), wide and combining
    names, 255-byte names; the filter of an empty listing; no active pane; bar widths 0 .. 200 around the 95-column hint
    threshold, at x offsets
SB0 the MSG_* kinds and STATUS_MAX of include/duop_ui.h equal include/classes.inc / config.inc
SB2 qemu-aarch64: the C module gives the x86_64 results; SB3 mutation check
"""

import os
import re
import shutil
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/status_bar.c"
REFS = ["tests/harness/status_bar_reference.s", "tests/harness/status_bar_render_reference.s"]
MODS = ["src/fs/dir_model.c", "src/fs/dir_model_filter.c", "src/fs/dir_model_load.c", "src/fs/dir_model_stream.c", "src/fs/dir_model_stat.c",
        "src/fs/dir_model_select.c", "src/fs/dir_sort.c", "src/fs/dir_sort_radix.c", "src/fs/dir_cache.c", "src/fs/archive_vfs.c",
        "src/fs/archive_parse.c", "src/fs/inflate.c", "src/core/oop_rt.c", "src/tui/screen.c", "src/tui/screen_buffer.c",
        "src/tui/screen_text.c", "src/tui/screen_rect.c", "src/core/string_format.c", "src/core/string_datetime.c", "src/core/tmpfile.c"]
CORE = ["src/core/string.c", "src/core/string_path.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c",
        "src/core/mem_prims.c", "src/fs/file_ops_read.c", "src/fs/file_ops.c", "src/fs/file_ops_copy.c", "src/fs/file_ops_delete.c",
        "src/fs/file_ops_overwrite.c", "src/fs/task.c", "src/fs/task_conflict.c", "src/fs/dir_search.c", "src/fs/dir_search_match.c",
        "build/i18n_en.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
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
        for o in objs:
            subprocess.run(["objcopy", "--redefine-sym", "sys_clock_ms=fake_clock", str(o)], check=True, capture_output=True)
        extra += objs
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\nint g_task_parent_pid; TaskShared *g_task_shm;\n')
    return H.build(arch, t, ["tests/harness/status_bar_cli.c", str(stub), *MODS, *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DSB_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=60, env={"TZ": "UTC"})
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def tree(t: Path) -> Path:
    shutil.rmtree(t, ignore_errors=True)
    d = t / "dir"
    (d / "subdir").mkdir(parents=True)
    files = {"empty": 0, "small.txt": 1023, "mid.bin": 1536 * 1024, "日本語の名前.txt": 7, "été.md": 3, "f" * 255: 1}
    for name, size in files.items():
        with open(d / name, "wb") as f:
            f.truncate(size)
    with open(d / "huge.img", "wb") as f:
        f.truncate(5 << 30)
    (d / "run.sh").write_text("#!/bin/sh\n")
    os.chmod(d / "run.sh", 0o755)
    os.symlink("small.txt", d / "link")
    os.symlink("nowhere/at/all", d / "dangling")
    os.symlink("subdir", d / "dirlink")
    for p in d.rglob("*"):
        os.utime(p, (1_700_000_000, 1_700_000_000), follow_symlinks=False)
    os.utime(d, (1_600_000_000, 1_600_000_000))
    (t / "emptydir").mkdir()
    return t


def script(t: Path) -> str:
    s = f"D {t}/dir\nP 1\nT 1000\n"
    for w in (0, 1, 10, 40, 94, 95, 96, 120, 200):
        s += f"L 0 {w}\n" + "".join(f"C {c}\nR\n" for c in range(15))
    s += "L 7 120\nC 3\nR\n"
    s += "L 0 120\nM 0 500 plain info\nR\nM 1 500 ok ✓ done\nR\nM 2 500 warning\nR\nM 3 500 error message\nR\nM 9 500 unknown kind\nR\n"
    s += "M 1 500 " + "x" * 600 + "\nR\nM 2 0 zero ttl\nR\nM 2 -5 negative\nR\nM 1 100 ages\nT 1099\nR\nT 1100\nR\nR\n"
    s += "K 1 7\nR\nL 0 40\nR\nL 0 200\nR\nK 0 0\nR\n"
    for hint in ("x" * 72, "y" * 73, "z" * 74):                              # the 20-column room for the entry line
        s += f"H {hint}\nC 2\nL 0 95\nR\nL 0 96\nR\n"
    s += "H Alt+1 left  F1 help\n"
    s += f"D {t}/emptydir\nC 1\nR\nF *.zzz\nR\nL 0 94\nF -\nR\nL 0 120\nR\nF only filter\nR\nP 0\nR\nK 1 a\nR\n"
    return s


def test_constants() -> None:
    inc = (ROOT / "include/classes.inc").read_text() + (ROOT / "include/config.inc").read_text()
    hdr = (ROOT / "include/duop_ui.h").read_text()
    names = ("MSG_INFO", "MSG_OK", "MSG_WARN", "MSG_ERR", "STATUS_MAX")
    for n in names:
        a = re.search(rf"^\.equ {n},\s*(\d+)", inc, re.M)
        b = re.search(rf"^#define {n} (\d+)", hdr, re.M)
        assert a and b and a.group(1) == b.group(1), (n, a and a.group(1), b and b.group(1))
    print(f"[PASS] SB0. {len(names)} StatusBar constants of duop_ui.h equal the assembler's")


def test_differential(exe: Path, t: Path) -> str:
    s = script(tree(t / "sb1"))
    a, b = run(exe, "ref", s), run(exe, "c", s)
    assert a == b, "oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(a.splitlines(), b.splitlines()) if x != y)
    arrow, kanji = "\\xe2\\x86\\x92", "\\xe6\\x97\\xa5"                           # the dump escapes non-ASCII bytes
    for needle in ("2023-11-14", "drwx", f"{arrow} small.txt", f"{arrow} nowhere/at/all", kanji, "Copying 42%", "ok_fg", "err_fg",
                   "warn_fg", "muted"):
        assert needle in b, f"coverage: {needle}"
    print(f"[PASS] SB1. StatusBar identical to the asm cell by cell ({b.count('R exp=')} renders, {len(b.splitlines())} lines of dump)")
    return b


MUTANTS = [
    ("hint threshold", "#define SB_HINT_MIN_W 95", "#define SB_HINT_MIN_W 96"),
    ("hint room", "w->w - hw - 3 < 20", "w->w - hw - 3 < 19"),
    ("info room", "if (room >= 20) max = room;", "if (room > 20) max = room;"),
    ("msg bold", "ScreenBuffer_set_pen(scr, fg, t->bg, ATTR_BOLD);", "ScreenBuffer_set_pen(scr, fg, t->bg, ATTR_NONE);"),
    ("msg kinds", "k == MSG_WARN ? t->warn_fg", "k == MSG_WARN ? t->err_fg"),
    ("unknown kind", "pfx[k <= MSG_ERR ? k : MSG_INFO]", "pfx[k & 3]"),
    ("expiry", "if ((uint64_t)sys_clock_ms() < self->msg_expire_ms)", "if ((uint64_t)sys_clock_ms() <= self->msg_expire_ms)"),
    ("expiry cleared", "        self->msg_expire_ms = 0;\n", ""),
    ("ttl", "(uint64_t)(sys_clock_ms() + ttl_ms)", "(uint64_t)(sys_clock_ms() + ttl_ms + 1)"),
    ("task width", "sb_text(scr, w, line, w->w - hw - 2);", "sb_text(scr, w, line, w->w - hw - 1);"),
    ("dir tag", "if (e->flags & FE_IS_DIR) (void)str_cat", "if (0) (void)str_cat"),
    ("parent no date", "if (e->flags & FE_IS_PARENT) return;", ""),
    ("link target", "if (e->flags & FE_IS_LINK) sb_link_target(m, e, line);", ""),
    ("filter shown", "if (m->filter[0]) { sb_filter(w, scr, t, m, line); return; }", ""),
    ("no pane", "if (!fp) return;", "if (!fp) { sb_hint(w, scr, t); return; }"),
    ("fill", "ScreenBuffer_fill_rect(scr, w->x, w->y, w->w, 1, ' ');", ""),
    ("hint pos", "w->x + w->w - hw - 1, w->y, hint, hw + 1);\n}\n\n/* the filter", "w->x + w->w - hw, w->y, hint, hw + 1);\n}\n\n/* the filter"),
    ("widget id", "Widget_init(&sb->base, app, 102);", "Widget_init(&sb->base, app, 101);"),
]


def test_mutants(t: Path, expect: str) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}
    s = script(tree(t / "mtree"))

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "status_bar.c").write_text(src.replace(old, new, 1))
            try:
                noticed[name] = run(build("x86_64", mt, str(mt / "status_bar.c")), "c", s) != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] SB3. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        test_constants()
        exe = build("x86_64", t / "x86")
        test_differential(exe, t)
        expect = run(exe, "c", script(tree(t / "mtree")))
        if H.available("aarch64"):
            assert run(build("aarch64", t / "a64"), "c", script(tree(t / "mtree")), "aarch64") == expect, "qemu-aarch64 differs"
            print("[PASS] SB2. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] SB2: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C STATUS BAR TESTS PASSED.")


if __name__ == "__main__":
    main()
