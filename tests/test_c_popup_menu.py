#!/usr/bin/env python3
"""U4.6: src/ui/popup_menu.c versus frozen x86_64 assembly
(tests/harness/popup_menu_reference.s): PopupMenuDialog_vtbl, PopupMenu_new,
PopupMenu_layout, PopupMenu_render, PopupMenu_on_key, PopupMenu_on_mouse,
pane_mouse_ext (right-click context menu & cross-pane drag-and-drop).

PM1 differential (x86_64):
    - PopupMenu_new & layout clamping: 0 pkg actions (w=24, h=7) vs 2 pkg actions (w=30, h=9),
      negative and past-edge x/y clamped into screen
    - PopupMenu_render: box, 5 built-in items + package items, cursor highlight
    - PopupMenu_on_key: Up/Down wrap modulo (5 + pkg_count), Esc cancels, Enter executes
      each of View/Copy/Move/CopyPath (OSC 52 + status)/Delete/PkgAction, unknown key -> 0
    - PopupMenu_on_mouse: inside left-click executes item, outside left-click cancels,
      non-left / non-press returns 1 without closing
    - pane_mouse_ext: right-click on left/right pane focuses, clamps cursor, opens popup;
      right-click in preview mode on right pane ignored; left-down + release on other pane
      focuses source pane and calls App_cmd_copy; release on same pane or outside ignored
PM2 C-only OOM guard (asm popup_menu.s did not check mem_alloc for NULL -> SIGSEGV)
PM3 qemu-aarch64 matches x86_64 byte for byte
PM4 mutation check across src/ui/popup_menu.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/popup_menu.c"
REF = "tests/harness/popup_menu_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c", "src/core/utf8.c",
    "src/core/memory.c", "src/core/syscall.c", "src/core/mem_prims.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "src/ui/dialog.c", "build/i18n_en.c",
]


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "popup_menu_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "osc52_copy_text=fake_osc52_copy_text",
            "--redefine-sym", "FilePane_get_selected_entry=fake_FilePane_get_selected_entry",
            "--redefine-sym", "DirModel_entry_name=fake_DirModel_entry_name",
            "--redefine-sym", "pkg_popup_refresh=fake_pkg_popup_refresh",
            "--redefine-sym", "pkg_popup_count=fake_pkg_popup_count",
            "--redefine-sym", "pkg_popup_label=fake_pkg_popup_label",
            "--redefine-sym", "pkg_popup_get=fake_pkg_popup_get",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/popup_menu_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DPM_SRC="{full}"'])


def build_script() -> str:
    # KEY_UP=0x100001 (1048577), KEY_DOWN=0x100002 (1048578), KEY_ENTER=0x10000E (1048590), KEY_ESC=0x10000F (1048591)
    # MACT_PRESS=1, MACT_RELEASE=2; MOUSE_LEFT=0, MOUSE_RIGHT=2
    UP, DN, ENT, ESC = 0x100001, 0x100002, 0x10000E, 0x10000F
    return "\n".join([
        # 0 pkg items -> w=24, h=7; clamp past bottom-right (60, 18)
        "S 0 0 0",
        "N 60 18",
        "R",
        # Unknown key -> 0; Up wraps 0 -> 4; render; Down wraps 4 -> 0; Esc closes
        f"K {ord('x')}",
        f"K {UP}",
        "R",
        f"K {DN}",
        "R",
        f"K {ESC}",
        # Negative coords clamped to (0, 0), 2 pkg items on dir entry (cursor=1 -> FE_IS_DIR) -> w=30, h=9
        "S 2 0 1",
        "N -5 -3",
        "R",
        # Non-left / non-press mouse on popup -> stays open
        "M 2 0 2 2",
        "M 1 2 2 2",
        # Click row 0 (View) -> executes App_cmd_view
        "M 1 0 2 1",
        # Execute Copy (1), Move (2), CopyPath (3), Delete (4), Pkg0 (5), Pkg1 (6)
        "S 2 0 0",
        "N 5 2", "M 1 0 7 4",       # item 1: Copy (y=2 -> row 0 at y=3, item 1 at y=4)
        "N 5 2", "M 1 0 7 5",       # item 2: Move
        "N 5 2", "M 1 0 7 6",       # item 3: CopyPath -> osc52 + status
        "N 5 2", "M 1 0 7 7",       # item 4: Delete
        "N 5 2", "M 1 0 7 8",       # item 5: Pkg0
        "N 5 2", f"K {UP}", f"K {ENT}",  # wrap to item 6 (Pkg1) + Enter
        # Click outside popup (on top border y=2, and past right edge x=35) -> cancels
        "N 5 2", "M 1 0 7 2",
        "N 5 2", "M 1 0 35 4",
        # pane_mouse_ext: right-click on left pane (x=10, y=5 -> row 1), then close
        "E 1 2 10 5",
        f"K {ESC}",
        # right-click on right pane at y=10 (clamps cursor to count-1=1)
        "E 1 2 45 10",
        f"K {ESC}",
        # right-click on right pane in preview mode -> ignored
        "S 0 1 0",
        "E 1 2 45 5",
        # Drag-and-drop: left-down on left pane, release on right pane (dual mode) -> App_cmd_copy
        "S 0 0 0",
        "E 1 0 10 5",
        "E 2 0 45 5",
        # Drag-and-drop release on same pane -> no copy
        "E 1 0 10 5",
        "E 2 0 12 6",
        # Release without active drag -> 0
        "E 2 0 45 5",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N xywh=46,13,24,7", "N xywh=0,0,30,9",
                   "call pkg_popup_refresh dir=1 name=|subdir| cnt=2",
                   "call App_cmd_view 1", "call App_cmd_copy 1", "call App_cmd_move 1",
                   "call osc52_copy_text |/work/left/alpha.txt|",
                   "call App_cmd_delete 1", "call App_run_pkg_action 1 idx=0",
                   "call App_run_pkg_action 1 idx=1", "Pkg: Checksum"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] PM1. popup_menu matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_oom(exe: Path) -> None:
    r = H.run_impl("x86_64", exe, "c", stdin=b"O\n")
    assert r.returncode == 0 and "OOM=1" in r.stdout.decode(), (r.returncode, r.stdout)
    print("[PASS] PM2. PopupMenu_new handles OOM cleanly (fixes asm NULL deref)")


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("w-30", "d->base.base.w = (n == 0) ? 24 : 30;", "d->base.base.w = 24;"),
        ("h-7", "d->base.base.h = n + 7;", "d->base.base.h = n + 6;"),
        ("clamp-x", "if (self->x > max_x) self->x = max_x;", "if (0) self->x = max_x;"),
        ("clamp-0", "if (self->x < 0) self->x = 0;", "if (0) self->x = 0;"),
        ("key-up", "d->cursor = (d->cursor + tot - 1u) % tot;", "d->cursor = (d->cursor + 1u) % tot;"),
        ("key-dn", "d->cursor = (d->cursor + 1u) % tot;", "d->cursor = (d->cursor + 2u) % tot;"),
        ("mouse-out", "mx >= self->x && mx < self->x + self->w", "mx >= self->x && mx <= self->x + self->w"),
        ("mouse-top", "my >= self->y + 1 && my < self->y + 1 + tot", "my >= self->y + 2 && my < self->y + 1 + tot"),
        ("pane-prev", "if (app->right_mode == RIGHT_MODE_PREVIEW) return nullptr;", "if (0) return nullptr;"),
        ("dnd-same", "if (!p || p == src) return 0;", "if (!p) return 0;"),
        ("dnd-clr", "g_dnd_active = 0;", "(void)0;"),
        ("cur-clamp", "if (idx > max) idx = max;", "if (0) idx = max;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "popup_menu.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] PM4. {len(muts)}/{len(muts)} mutants killed across popup_menu.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_oom(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] PM3. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
