#!/usr/bin/env python3
"""U2b.3: src/ui/attr_dialogs.c versus frozen x86_64 assembly
(tests/harness/attr_dialogs{,_input}_reference.s): ChmodDialog.

AD1 differential (x86_64):
    - ChmodDialog_new: OOM, real file (chmod 0751), nonexistent file (default 0644), NULL app (80x24)
    - ChmodDialog_layout: wide (80x24 -> dw=56), medium (52x20 -> dw=48), narrow (36x18 -> dw=40)
    - ChmodDialog_on_key: LEFT/RIGHT clamp 0..8, SPACE toggles bit, '1'..'9' toggle & move cursor,
      'u'/'g' toggle edit_owner, edit_owner digits/':'/BS/30-char cap, ENTER confirms, ESC cancels
    - ChmodDialog_on_mouse: left-click on each of the 9 rwx bit positions, gap miss, wrong row/btn
    - Non-buggy render rows (title, basename, header, uid:gid) match frozen asm byte for byte
AD2 real asm bug fixes proven in C vs frozen asm:
    - Bug 1: ChmodDialog_layout in asm tail-jumped to dlg_layout_right_buttons with rsi=x, rdx=y
      (btn_count=1, zero-width button, Cancel missing). C passes OK/Cancel labels -> btn_count=2
      and clicking both OK and Cancel works!
    - Bug 2: cd_draw_bits in asm called ScreenBuffer_set_cell (6 args) with 4 args instead of
      ScreenBuffer_set_cell_pen, corrupting fg/bg of all 9 rwx bit cells. C renders exact
      text/cursor_active_bg a=1 and text/surface_alt a=0 cells + octal 0xxx.
AD3 qemu-aarch64: matches x86_64 byte for byte (both diff & fix scripts)
AD4 mutation check across src/ui/attr_dialogs.c
"""

import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/attr_dialogs.c"
REFS = [
    "tests/harness/attr_dialogs_reference.s",
    "tests/harness/attr_dialogs_input_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c", "src/core/utf8.c",
    "src/core/memory.c", "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
]

KEY_LEFT = 0x100003
KEY_RIGHT = 0x100004
KEY_BACKSPACE = 0x10000B
KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
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
        for o in objs:
            subprocess.run(["objcopy", "--redefine-sym", "Object_alloc=fake_object_alloc", str(o)],
                           check=True, capture_output=True)
        extra += objs
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/attr_dialogs_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DAD_SRC="{full}"'])


def build_diff_script(sample: Path, missing: Path) -> str:
    # 80x24 -> dw=56, h=10, x=12, y=7; rwx row = 11
    # bit x positions: 12 + 3 + i*2 + (i//3)*2 = 15,17,19, 23,25,27, 31,33,35
    return "\n".join([
        f"N 0 80 24 1 {sample}",           # OOM
        f"N 1 80 24 0 {missing}",          # NULL app, missing path -> default 0644, 80x24
        f"N 0 80 24 0 {sample}",           # real file (0751)
        "R",
        "L 0 0 52 20",                     # dw=48
        "L 0 0 36 18",                     # dw=40
        "L 0 0 80 24",                     # back to 80x24
        # Keys: LEFT clamp at 0, RIGHT x9 clamp at 8, SPACE toggle, digits 1 & 9
        f"K 0x{KEY_LEFT:x} 0",
        *[f"K 0x{KEY_RIGHT:x} 0" for _ in range(9)],
        f"K 0x{ord(' '):x} 0",
        f"K 0x{KEY_LEFT:x} 0",
        f"K 0x{ord('1'):x} 0",
        f"K 0x{ord('9'):x} 0",
        # Toggle edit_owner with 'u', backspace & type digits/':', verify digits don't toggle mode
        f"K 0x{ord('u'):x} 0",
        *[f"K 0x{KEY_BACKSPACE:x} 0" for _ in range(12)],
        f"K 0x{ord('5'):x} 0",
        f"K 0x{ord('0'):x} 0",
        f"K 0x{ord(':'):x} 0",
        f"K 0x{ord('9'):x} 0",
        f"K 0x{ord('x'):x} 0",             # non-digit ignored in edit_owner
        f"K 0x{ord('g'):x} 0",             # exit edit_owner
        "R",
        # Mouse: click bit 0 (x=15), bit 4 (x=25), bit 8 (x=35), gap (x=21), wrong row (y=10), right btn
        "M 1 0 15 11",
        "M 1 0 25 11",
        "M 1 0 35 11",
        "M 1 0 21 11",
        "M 1 0 15 10",
        "M 1 2 15 11",
        f"K 0x{KEY_ENTER:x} 0",
        f"K 0x{KEY_ESC:x} 0",
    ]) + "\n"


def build_fix_script(sample: Path) -> str:
    # Full render + clicking OK/Cancel buttons laid out by dlg_layout_right_buttons
    # 80x24 -> x=12, y=7, w=56, h=10 -> rx=66, by=15. "[ Cancel ]"(10) at [56..66), "[ OK ]"(6) at [48..54)
    return "\n".join([
        f"N 0 80 24 0 {sample}",
        "R",
        f"K 0x{KEY_RIGHT:x} 0",
        f"K 0x{ord(' '):x} 0",
        "R",
        "M 1 0 50 15",                     # click OK button
        "M 1 0 60 15",                     # click Cancel button
    ]) + "\n"


def test_differential(exe: Path, sample: Path, missing: Path) -> tuple[str, str]:
    s = build_diff_script(sample, missing).encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=0\n", "mode=420", "mode=489", "own=50:9 olen=4",
                   "Owner   Group   Other     Octal:", "uid:gid: ",
                   "call App_close_dialog 1 1", "call App_close_dialog 1 2"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] AD1. attr_dialogs state/layout/keys/mouse match frozen asm ({len(out.splitlines())} lines)")

    fs = build_fix_script(sample).encode()
    c_fix = H.run_impl("x86_64", exe, "fix_c", stdin=fs)
    ref_fix = H.run_impl("x86_64", exe, "fix_ref", stdin=fs)
    assert c_fix.returncode == 0 and ref_fix.returncode == 0
    co, ro = c_fix.stdout.decode(), ref_fix.stdout.decode()
    # Prove Bug 1 in asm (bc=1, zero-width [66..66@15]) vs C fix (bc=2, [48..54@15] [56..66@15] + clickable)
    assert "bc=1 [66..66@15]" in ro, "expected asm Bug 1 (zero-width button)"
    assert "bc=2 [50..56@15] [58..66@15]" in co, f"missing C button layout:\n{co}"
    assert "call App_close_dialog 1 1" in co and "call App_close_dialog 1 2" in co
    assert "call App_close_dialog" not in ro, "asm buttons unexpectedly worked"
    # Prove Bug 2 in asm (garbage colors) vs C fix (cursor_active_bg a=1 & surface_alt a=0 + octal 0751/0551)
    assert "text/cursor_active_bg a=1" in co and "text/surface_alt a=0" in co
    assert "text/cursor_active_bg a=1" not in ro, "expected asm Bug 2 (corrupt bit pen)"
    assert "0751" in co and "0551" in co and "  OK  " in co and " Cancel " in co
    print("[PASS] AD2. C fixes both asm defects (dlg_layout_right_buttons args & ScreenBuffer_set_cell_pen)")
    return out, co


def test_mutations(t: Path, sample: Path, missing: Path, base_diff: str, base_fix: str) -> None:
    ds = build_diff_script(sample, missing).encode()
    fs = build_fix_script(sample).encode()
    muts = [
        ("oom-null", "if (!d) return nullptr;", "if (0 && !d) return nullptr;", "c", ds, base_diff),
        ("def-mode", "d->mode = 0644U;", "d->mode = 0600U;", "c", ds, base_diff),
        ("lay-max56", "if (dw > 56) dw = 56;", "if (dw > 50) dw = 50;", "c", ds, base_diff),
        ("lay-min40", "if (dw < 40) dw = 40;", "if (dw < 44) dw = 44;", "c", ds, base_diff),
        ("lay-h10", "self->h = 10;", "self->h = 11;", "c", ds, base_diff),
        ("lay-btns", "dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);",
                     "dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], nullptr);", "fix_c", fs, base_fix),
        ("oct-hi", "out[1] = (char)('0' + ((mode >> 6) & 7));", "out[1] = (char)('0' + ((mode >> 3) & 7));", "fix_c", fs, base_fix),
        ("bit-pos", "int xpos = d->base.base.x + 3 + i * 2 + (i / 3) * 2;",
                    "int xpos = d->base.base.x + 3 + i * 2;", "fix_c", fs, base_fix),
        ("bit-cur", "if (i == (int)d->cursor)", "if (0 && i == (int)d->cursor)", "fix_c", fs, base_fix),
        ("key-r8", "if (d->cursor < 8)", "if (d->cursor < 7)", "c", ds, base_diff),
        ("key-19", "if (key >= '1' && key <= '9' && !d->edit_owner)", "if (0 && key >= '1' && key <= '9' && !d->edit_owner)", "c", ds, base_diff),
        ("key-own", "d->edit_owner ^= 1;", "d->edit_owner = 0;", "c", ds, base_diff),
        ("key-bs", "if (d->owner_len > 0)", "if (d->owner_len > 1)", "c", ds, base_diff),
        ("mouse-y4", "ev->mouse_y == d->base.base.y + 4", "ev->mouse_y == d->base.base.y + 3", "c", ds, base_diff),
        ("mouse-btn", "ev->mouse_btn == MOUSE_LEFT", "1", "c", ds, base_diff),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str, mode: str, inp: bytes, base: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "attr_dialogs.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, mode, stdin=inp)
        if r.returncode == 0 and r.stdout.decode() == base:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] AD4. {len(muts)}/{len(muts)} mutants killed across attr_dialogs.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        sample = t / "demo_file.sh"
        sample.write_text("#!/bin/sh\n")
        os.chmod(sample, 0o751)
        missing = t / "no_such_file"

        exe = build("x86_64", t / "x86")
        out, fix_out = test_differential(exe, sample, missing)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r1 = H.run_impl("aarch64", exe_arm, "c", stdin=build_diff_script(sample, missing).encode())
            r2 = H.run_impl("aarch64", exe_arm, "fix_c", stdin=build_fix_script(sample).encode())
            assert r1.returncode == 0 and r1.stdout.decode() == out, "aarch64 diff mismatch"
            assert r2.returncode == 0 and r2.stdout.decode() == fix_out, "aarch64 fix mismatch"
            print("[PASS] AD3. qemu-aarch64 matches x86_64 byte for byte (diff + fix)")
        test_mutations(t, sample, missing, out, fix_out)


if __name__ == "__main__":
    main()
