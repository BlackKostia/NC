#!/usr/bin/env python3
"""U4.7: src/ui/file_pane_render.c + src/ui/file_pane_rows.c versus frozen x86_64 assembly
(tests/harness/file_pane_render_reference.s): FilePane_render.

FPR1 differential (x86_64):
    - Too-small pane (w<6 or h<6) -> no-op
    - Adaptive widths: narrow (20: name only), small (32: name+size), medium (46: name+size+perms),
      wide (76: name+size+date), non-zero x/y
    - Focused vs unfocused border, title pill with left-ellipsis truncation for long paths,
      multi-tab strip (active focused, active unfocused, inactive, root "/" basename, HitZones)
    - Column headers: Name/Size/Modified/Perms, sort asc/desc arrows, unsorted, hovered underline
    - File rows: "..", dir, exec, symlink, dir-symlink, hidden, selected, cursor active/inactive,
      hovered row, long filename ellipsis, muted vs highlighted size/date/perms
    - Scrollbar thumb position & size when count > list_h
    - Footer: selected count+bytes summary vs dirs/files/bytes totals + loading / aborted / huge
      badges + active filter badge on bottom border
FPR2 hot-render perf gate (600 frames of 80x36 pane over 200 entries) vs frozen asm
FPR3 qemu-aarch64 matches x86_64 byte for byte
FPR4 mutation check across file_pane_render.c and file_pane_rows.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC_MAIN = "src/ui/file_pane_render.c"
SRC_ROWS = "src/ui/file_pane_rows.c"
REFS = ["tests/harness/file_pane_render_reference.s", "tests/harness/file_pane_cols_reference.s"]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c", "src/core/string_format.c",
    "src/core/string_datetime.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c",
    "src/core/mem_prims.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "src/ui/file_pane_layout.c", "src/ui/file_pane_tabs.c", "build/i18n_en.c",
]


def build(arch: str, t: Path, main_ovr: Path | None = None, rows_ovr: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        objs = []
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run(["as", *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            objs.append(o)
        H.rename_defined_globals(objs, "ref_")
        extra += objs
    mpath = str(main_ovr if main_ovr else (ROOT / SRC_MAIN))
    rpath = str(rows_ovr if rows_ovr else (ROOT / SRC_ROWS))
    # Stub symbols referenced only by file_pane_tabs.c (not called in render)
    stub = t / "tab_stubs.c"
    stub.write_text(
        '#include "duop_fs.h"\n#include "duop_ui.h"\n'
        'intptr_t DirModel_chdir(DirModel *m, const char *p){(void)m;(void)p;return 0;}\n'
        'int dir_du_populate(DirModel *m){(void)m;return 0;}\n'
        'void FilePane_ensure_visible(FilePane *fp){(void)fp;}\n'
        'void nav_hist_push(NavTab *t, const char *p){(void)t;(void)p;}\n'
        'const char *nav_hist_back(NavTab *t){(void)t;return nullptr;}\n'
        'const char *nav_hist_fwd(NavTab *t){(void)t;return nullptr;}\n'
        'void nav_frecency_record(const char *p){(void)p;}\n'
    )
    return H.build(arch, t, ["tests/harness/file_pane_render_cli.c", str(stub), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DFPR_SRC="{mpath}"', f'-DFPR_ROWS_SRC="{rpath}"'])


def build_script() -> str:
    return "\n".join([
        # Too small -> no-op
        "G 0 0 5 12", "R",
        "G 0 0 20 5", "R",
        # Wide focused pane (76x13 -> list_h=8 < count=12 -> scrollbar!) with selected item + filter
        "G 2 1 76 13",
        "F 1 1 2 3 0",
        "S 0 0 0 0 0 0",
        "L *.c",
        "R",
        # Unfocused + sort by size desc + hovered size col + no selection -> totals footer + loading
        "U 0",
        "F 0 6 0 2 1",
        "S 1 1 0 1 0 0",
        "L -",
        "R",
        # Medium width (46x12 -> perms extra col) + sort by ext + aborted badge + long path truncation
        "G 0 0 46 12",
        "P /very/deep/directory/hierarchy/with/long/segments/that/must/truncate/from/left",
        "F 1 2 0 -1 3",
        "S 3 0 0 0 1 0",
        "R",
        # Small width (32x12 -> size only) + huge unsorted badge
        "G 0 0 32 12",
        "S 2 1 1 0 0 1",
        "R",
        # Narrow width (20x10 -> name only)
        "G 0 0 20 10",
        "R",
        # Multi-tab strip: 4 tabs (active focused, then active unfocused, incl. "/" and empty path)
        "G 0 0 70 12",
        "P /home/dev/project/src/ui",
        "T 4 1",
        "F 1 0 0 -1 -1",
        "S 2 1 0 0 0 0",
        "R",
        "F 0 0 0 -1 -1",
        "R",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("TZ cnt=4", "[3:/]", "[4:/]", "drwxr-xr-x", "2023-11-14",
                   "selected", "filter:*.c", "scroll_thumb", "scroll_track",
                   "cursor_active_bg", "cursor_inactive_bg", "dir_fg", "exec_fg", "link_fg", "hidden_fg"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] FPR1. FilePane_render matches frozen asm cell by cell ({len(out.splitlines())} lines)")
    return out


def test_perf(exe: Path) -> None:
    ref_s, c_s = H.perf_gate(exe, "bench", max_ratio=1.15, repeats=3, retries=2)
    print(f"[PASS] FPR2. Hot-render perf gate: C {c_s * 1e3:.2f} ms vs asm {ref_s * 1e3:.2f} ms ({c_s / ref_s:.2f}x)")


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        # file_pane_render.c
        ("main", "min-w6", "if (fp->base.w < 6 || fp->base.h < 6) return;",
         "if (fp->base.w < 4 || fp->base.h < 6) return;"),
        ("main", "border-foc", "focused ? th->border_active : th->border_inactive", "th->border_inactive"),
        ("main", "path-ellip", "(void)str_cat(buf, \"\\xe2\\x80\\xa6\", 128);", "(void)0;"),
        ("main", "tab-root", "buf[3] = '/'; buf[4] = 0;", "buf[3] = '?'; buf[4] = 0;"),
        ("main", "hdr-arrow", "m->sort_desc ? \" \\xe2\\x96\\xbc\" : \" \\xe2\\x96\\xb2\"",
         "m->sort_desc ? \" \\xe2\\x96\\xb2\" : \" \\xe2\\x96\\xbc\""),
        ("main", "hdr-hov", "if ((int32_t)fp->hovered_col_hdr == sort_id)",
         "if ((int32_t)fp->hovered_col_hdr == -99)"),
        ("main", "sb-show", "if (m->count <= (uint64_t)(uint32_t)list_h) return;", "return;"),
        ("main", "foot-flt", "if (!m->filter[0]) return;", "return;"),
        # file_pane_rows.c
        ("rows", "cur-bg", "focused ? th->cursor_active_bg : th->cursor_inactive_bg", "th->cursor_inactive_bg"),
        ("rows", "hov-bg", "else if (r == (int32_t)fp->hovered_row) bg = th->surface_alt;", ""),
        ("rows", "sel-chk", "if (flags & FE_SELECTED) ScreenBuffer_set_cell_pen(scr, fp->base.x + 1, ry, CH_CHECK);", ""),
        ("rows", "glyph-dir", "else if (flags & FE_IS_DIR) glyph = CH_TRI_RIGHT;", ""),
        ("rows", "name-ell", "if ((int)e->disp_width > cols->name_w - 5)", "if (0)"),
        ("rows", "size-mut", "((flags & FE_SELECTED) || idx == (int32_t)fp->cursor) ? fg : th->muted",
         "((flags & FE_SELECTED) && idx == (int32_t)fp->cursor) ? fg : th->muted"),
        ("rows", "ex-par", "if (cols->extra_w <= 0 || (flags & FE_IS_PARENT)) return;",
         "if (cols->extra_w <= 0 || (flags & FE_IS_EXEC)) return;"),
        ("rows", "ex-date", "if (cols->extra_is_date) format_datetime(e->mtime, aux);",
         "if (0) format_datetime(e->mtime, aux);"),
    ]
    survivors: list[str] = []
    txt_main = (ROOT / SRC_MAIN).read_text()
    txt_rows = (ROOT / SRC_ROWS).read_text()

    def check(idx: int, which: str, name: str, old: str, new: str) -> None:
        base_txt = txt_main if which == "main" else txt_rows
        assert old in base_txt and old != new, name
        mp = t / f"m{idx}" / ("file_pane_render.c" if which == "main" else "file_pane_rows.c")
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(base_txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}",
                    main_ovr=mp if which == "main" else None,
                    rows_ovr=mp if which == "rows" else None)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] FPR4. {len(muts)}/{len(muts)} mutants killed across file_pane_render.c + file_pane_rows.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_perf(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] FPR3. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
