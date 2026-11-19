#!/usr/bin/env python3
"""U2a: src/ui/dialog.c + src/ui/dialog_confirm.c versus frozen x86_64 assembly
(tests/harness/dialogs_reference.s + dialogs_confirm_reference.s): Dialog base class
(Dialog_vtbl, init, layout, render, draw_frame, on_key, on_mouse, on_confirm, on_cancel,
dlg_layout_center_buttons, dlg_layout_right_buttons) and ConfirmDialog.

DB1 differential (x86_64):
    - ConfirmDialog_new (normal + OOM), instanceof hierarchy (ConfirmDialog -> Dialog -> Widget -> Object)
    - ConfirmDialog_layout across wide (80x24), medium (46x15), narrow (30x12), short (50x6),
      and fallback (h<=0) container sizes
    - ConfirmDialog_render + Dialog_draw_frame (focused btn, hovered btn, normal btn, Unicode title)
    - Dialog_on_key: TAB/LEFT/RIGHT with 2 buttons & 1 button, ENTER (focus 0 -> DLG_OK, focus 1 -> DLG_CANCEL),
      ESC -> DLG_CANCEL, unhandled key swallowed without redraw
    - Dialog_on_mouse: hover enter/repeat/switch/leave, right-click ignored, left-click outside/btn0/btn1, release
    - dlg_layout_right_buttons (1-button and 2-button) + base Dialog_* defaults
DB2 qemu-aarch64: matches x86_64 byte for byte
DB3 mutation check across dialog.c and dialog_confirm.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = {
    "DLG_SRC": "src/ui/dialog.c",
    "CNF_SRC": "src/ui/dialog_confirm.c",
}
REFS = [
    "tests/harness/dialogs_reference.s",
    "tests/harness/dialogs_confirm_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
]

KEY_LEFT = 0x100003
KEY_RIGHT = 0x100004
KEY_TAB = 0x10000C
KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F


def build(arch: str, t: Path, overrides: dict[str, str] | None = None) -> Path:
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
        redefs = [
            "--redefine-sym", "App_close_dialog=fake_close_dialog",
            "--redefine-sym", "Object_alloc=fake_object_alloc",
        ]
        for o in objs:
            subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra += objs
    defs = []
    for k, v in SRCS.items():
        p = (overrides or {}).get(k, v)
        full = p if Path(p).is_absolute() else str(ROOT / p)
        defs.append(f'-D{k}="{full}"')
    return H.build(arch, t, ["tests/harness/dialog_base_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


def build_script() -> str:
    return "\n".join([
        # Base Dialog defaults
        "D",
        # OOM on ConfirmDialog_new
        "N 80 16 7 1",
        # Normal ConfirmDialog in 80x16 (dlg: w=64, h=9, x=8, y=3; btns at y=9)
        "N 80 16 42 0",
        "R",
        # Various layout container sizes + fallback h<=0
        "L 0 0 42 15",
        "L 0 0 30 12",
        "L 0 0 50 6",
        "L 60 14 0 0",
        "L 0 0 80 16",
        # Key navigation: unhandled, TAB, LEFT, RIGHT, ENTER(0), TAB, ENTER(1), ESC
        f"K 0x{ord('a'):x} 0",
        f"K 0x{KEY_TAB:x} 0",
        "R",                         # focus_btn == 1 rendered
        f"K 0x{KEY_LEFT:x} 0",
        f"K 0x{KEY_RIGHT:x} 0",
        f"K 0x{KEY_ENTER:x} 0",      # focus_btn == 1 -> on_cancel
        f"K 0x{KEY_TAB:x} 0",
        f"K 0x{KEY_ENTER:x} 0",      # focus_btn == 0 -> on_confirm
        f"K 0x{KEY_ESC:x} 0",        # on_cancel
        # Mouse hover & clicks on ConfirmDialog (80x16 -> x=8,y=3,w=64,h=9 -> btn_y=9, btns around x=30..50)
        "M 4 0 34 9",                # hover btn 0
        "M 4 0 34 9",                # repeat hover btn 0 (no redraw)
        "M 4 0 44 9",                # hover btn 1
        "R",                         # hovered_btn == 1 rendered
        "M 4 0 1 1",                 # hover leave -> hovered_btn=-1
        "M 4 0 39 9",                # exact exclusive right edge x2 of btn 0 -> miss (-1)
        "M 1 2 34 9",                # right click on btn 0 -> ignored
        "M 1 0 1 1",                 # left click outside -> ignored
        "M 1 0 34 9",                # left click btn 0 -> on_confirm
        "M 1 0 44 9",                # left click btn 1 -> on_cancel
        "M 2 0 34 9",                # release -> swallowed
        # dlg_layout_right_buttons (2 btns then 1 btn) + TAB with 1 button (no-op)
        "B 0",
        "B 1",
        f"K 0x{KEY_TAB:x} 0",        # btn_count == 1 -> focus_btn unchanged, no redraw
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=0\n", "N ok=1 is_cd=1 is_d=1 is_w=1 tag=42 hov=-1",
                   "call App_close_dialog 1 1", "call App_close_dialog 1 2",
                   "accent_fg/accent a=1", "badge_fg/badge_hover_bg a=1",
                   "badge_fg/badge_bg a=0", "Delete 3 items?"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] DB1. dialog + dialog_confirm match frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("DLG_SRC", "init-hov", "self->hovered_btn = (uint32_t)-1;", "self->hovered_btn = 0;"),
        ("DLG_SRC", "confirm-res", "self->result = DLG_OK;", "self->result = DLG_CANCEL;"),
        ("DLG_SRC", "cancel-res", "self->result = DLG_CANCEL;", "self->result = DLG_OK;"),
        ("DLG_SRC", "btn-focus", "(uint32_t)i == self->focus_btn", "0"),
        ("DLG_SRC", "btn-hover", "(uint32_t)i == self->hovered_btn", "0"),
        ("DLG_SRC", "key-tab-cnt", "(int32_t)d->btn_count > 1", "(int32_t)d->btn_count > 0"),
        ("DLG_SRC", "key-enter-fb", "d->focus_btn == 0", "d->focus_btn != 0"),
        ("DLG_SRC", "mouse-hit-x2", "e->mouse_x < (int16_t)z[i].x2", "e->mouse_x <= (int16_t)z[i].x2"),
        ("DLG_SRC", "mouse-hov-eq", "(uint32_t)hit != d->hovered_btn", "1"),
        ("DLG_SRC", "mouse-btn-l", "e->mouse_btn == MOUSE_LEFT", "1"),
        ("DLG_SRC", "center-gap", "w0 + 2 + w1", "w0 + 1 + w1"),
        ("DLG_SRC", "right-one", "if (btn1 != nullptr)", "if (0 && btn1 != nullptr)"),
        ("CNF_SRC", "lay-fallback", "if (h <= 0)", "if (h < 0)"),
        ("CNF_SRC", "lay-max64", "if (dw > 64) dw = 64;", "if (dw > 60) dw = 60;"),
        ("CNF_SRC", "lay-min34", "if (dw < 34) dw = w;", "if (dw < 40) dw = w;"),
        ("CNF_SRC", "lay-h9", "int dh = 9;", "int dh = 8;"),
    ]
    survivors: list[str] = []

    def check(idx: int, macro: str, name: str, old: str, new: str) -> None:
        src = ROOT / SRCS[macro]
        txt = src.read_text()
        assert old in txt and old != new, (name, src)
        mp = t / f"m{idx}" / src.name
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", {macro: str(mp)})
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] DB3. {len(muts)}/{len(muts)} mutants killed across dialog.c and dialog_confirm.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] DB2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
