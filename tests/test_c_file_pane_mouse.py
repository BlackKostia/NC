#!/usr/bin/env python3
"""U4.5: src/ui/file_pane_mouse.c versus frozen x86_64 assembly
(tests/harness/file_pane_mouse_reference.s): FilePane_on_mouse.

FPM0 DBLCLICK_MS in include/duop_ui.h matches include/config.inc
FPM1 differential (x86_64):
    - MACT_RELEASE clears dragging_scroll, returns 0
    - MACT_DRAG: no-op when not dragging; scrubs scrollbar + redraw + returns 1 when dragging
    - MACT_WHEEL: up/down by 3 clamped to [0, max(0, count - list_h)]
    - MACT_MOVE: column header hover (including x1/x2 boundary), list row hover (y+3..y+3+lh-1),
      redundant move suppresses redraw
    - MACT_PRESS: focuses pane; tab strip left switch / mid close / right ignore / single-tab ignore;
      column header click toggles sort_desc or switches mode (and handles is_unsorted);
      scrollbar press sets dragging_scroll + scrubs; list row right-click toggles selection;
      left single-click, double-click at dt==420 (opens!), too-slow click at dt==421 (single-click!),
      out-of-range row index ignored
FPM2 qemu-aarch64 matches x86_64 byte for byte
FPM3 mutation check across src/ui/file_pane_mouse.c
"""

import re
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/file_pane_mouse.c"
REF = "tests/harness/file_pane_mouse_reference.s"
CORE = ["src/core/string.c", "src/core/memory.c", "src/core/syscall.c", "src/core/mem_prims.c"]


def test_constants() -> None:
    inc = (ROOT / "include/config.inc").read_text()
    hdr = (ROOT / "include/duop_ui.h").read_text()
    a = re.search(r"^\.equ DBLCLICK_MS,\s*(\d+)", inc, re.M)
    b = re.search(r"^#define DBLCLICK_MS (\d+)", hdr, re.M)
    assert a and b and a.group(1) == b.group(1), (a and a.group(1), b and b.group(1))
    print(f"[PASS] FPM0. DBLCLICK_MS={b.group(1)} matches include/config.inc")


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "file_pane_mouse_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "sys_clock_ms=fake_clock",
            "--redefine-sym", "get_list_h=fake_get_list_h",
            "--redefine-sym", "scrub_scrollbar=fake_scrub_scrollbar",
            "--redefine-sym", "FilePane_ensure_visible=fake_FilePane_ensure_visible",
            "--redefine-sym", "FilePane_tab_switch=fake_FilePane_tab_switch",
            "--redefine-sym", "FilePane_tab_close=fake_FilePane_tab_close",
            "--redefine-sym", "DirModel_sort=fake_DirModel_sort",
            "--redefine-sym", "DirModel_toggle_select=fake_DirModel_toggle_select",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/file_pane_mouse_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DFPM_SRC="{full}"'])


def build_script() -> str:
    # M kind btn x y  (PRESS=1, RELEASE=2, DRAG=3, MOVE=4, WHEEL=5)
    # btn: LEFT=0, MID=1, RIGHT=2, WHEEL_UP=64, WHEEL_DOWN=65
    # Pane: x=5, y=2, w=40 (sb x=44), h=15 (list y=5..14), hdr y=3, tabs y=2
    return "\n".join([
        # Drag when not dragging -> rc=0
        "M 3 0 44 7",
        # Scrollbar press -> dragging_scroll=1, scrub
        "M 1 0 44 7",
        "M 3 0 44 10",    # drag while dragging -> scrub + rc=1
        "M 2 0 44 10",    # release -> dragging_scroll=0, rc=0
        # Wheel up/down & clamping (count=30, lh=10 -> max_scroll=20)
        "M 5 64 10 8",    # up from 0 -> stays 0
        "M 5 65 10 8",    # down -> 3
        "M 5 65 10 8",    # down -> 6
        "M 5 64 10 8",    # up -> 3
        "S 30 0 2 19",
        "M 5 65 10 8",    # down -> clamped to 20
        "S 5 0 2 0",      # count < lh -> max_scroll=0
        "M 5 65 10 8",
        "S 30 0 2 2",
        # Hover: header zone 0, boundary x2=25 (zone 1), outside header, list row 5, same row (no redraw), row 15 (past end)
        "M 4 0 10 3",
        "M 4 0 10 3",     # redundant -> rd=0
        "M 4 0 25 3",     # zone 1
        "M 4 0 44 3",     # past last hdr zone -> -1
        "M 4 0 10 5",     # row 0
        "M 4 0 10 14",    # row 9
        "M 4 0 10 15",    # past list -> -1
        # Tab strip clicks on y=2 (tab_count=2)
        "M 1 0 10 2",     # left on tab 0 -> tab_switch 0
        "M 1 1 20 2",     # mid on tab 1 -> tab_close 1
        "M 1 2 10 2",     # right on tab 0 -> ignored
        "M 1 0 16 2",     # at x2=16 (gap) -> not hit
        "S 30 0 1 2",     # tab_count=1 -> tab strip disabled
        "M 1 0 10 2",
        "S 30 0 2 2",
        # Column header clicks on y=3
        "M 1 0 10 3",     # sort_mode=0 (same as current 0) -> toggles sort_desc=1
        "M 1 0 10 3",     # toggles sort_desc=0
        "M 1 0 30 3",     # switches to sort_mode=1, desc=0
        "S 30 1 2 2",     # is_unsorted=1 -> clicking same mode 1 resets desc=0
        "M 1 0 30 3",
        "M 1 0 5 3",      # miss header zone on y=3 -> still handled
        "S 30 0 2 2",
        # List row clicks: right click selects, left single-click, double-click at +420, slow click at +421, out-of-range
        "M 1 2 10 6",     # right click row 1 (+scroll 2 = idx 3) -> toggle_select 3
        "T 1000",
        "M 1 0 10 7",     # left click idx 4 -> single click
        "T 1420",
        "M 1 0 10 7",     # dt=420 <= DBLCLICK_MS -> double click opens!
        "T 1500",
        "M 1 0 10 7",     # last_click_idx was reset to -1 -> single click again
        "T 1921",
        "M 1 0 10 7",     # dt=421 > DBLCLICK_MS -> single click!
        "T 2000",
        "M 1 0 10 8",     # different row idx 5 -> single click
        "M 1 1 10 8",     # middle click on row -> ignored (still handled)
        "S 3 0 2 2",
        "M 1 0 10 6",     # idx 3 == count 3 -> ignored
        "M 1 0 10 7",     # idx 4 > count 3 -> ignored
        "M 9 0 10 7",     # unknown mouse_kind -> rc=0
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("call scrub_scrollbar my=7", "call scrub_scrollbar my=10",
                   "call tab_switch idx=0", "call tab_close idx=1",
                   "call DirModel_sort sm=0 sd=1", "call DirModel_sort sm=1 sd=0",
                   "call toggle_select 1 idx=3", "call open_selected 1 cur=4",
                   "M rc=0 cur=5 scr=2 drg=0"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] FPM1. file_pane_mouse matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("rel-clr", "fp->dragging_scroll = 0;", "fp->dragging_scroll = 1;"),
        ("drag-chk", "if (!fp->dragging_scroll) return 0;", "if (0) return 0;"),
        ("wheel-3", "scr -= 3;", "scr -= 2;"),
        ("wheel-dn", "scr += 3;", "scr += 2;"),
        ("hov-x2", "mx < (int16_t)hz[i].x2", "mx <= (int16_t)hz[i].x2"),
        ("hov-dirty", "hov_hdr != (int32_t)fp->hovered_col_hdr || hov_row != (int32_t)fp->hovered_row", "1"),
        ("tab-cnt", "if (my != fp->base.y || (int32_t)fp->tab_count <= 1) return 0;",
         "if (my != fp->base.y || (int32_t)fp->tab_count <= 0) return 0;"),
        ("hdr-uns", "if (!m->is_unsorted && id == m->sort_mode)", "if (id == m->sort_mode)"),
        ("sb-col", "mx == fp->base.x + fp->base.w - 1", "mx == fp->base.x + fp->base.w"),
        ("dbl-ms", "now - (int64_t)fp->last_click_ms <= DBLCLICK_MS",
         "now - (int64_t)fp->last_click_ms < DBLCLICK_MS"),
        ("dbl-rst", "fp->last_click_idx = (uint32_t)-1;", "fp->last_click_idx = idx;"),
        ("row-cnt", "if ((uint64_t)idx >= m->count) return;", "if ((uint64_t)idx > m->count) return;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "file_pane_mouse.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] FPM3. {len(muts)}/{len(muts)} mutants killed across file_pane_mouse.c")


def main() -> None:
    test_constants()
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] FPM2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
