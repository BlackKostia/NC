#!/usr/bin/env python3
"""U2b.7: src/ui/search_dialog.c versus frozen x86_64 assembly
(tests/harness/search_dialog{,_input}_reference.s): SearchDialog + fp_exit_virtual + fp_draw_search_badge.

SD1 differential (x86_64):
    - SearchDialog_new (OOM, NULL app -> 80x24, normal), layout (80x24 -> dw=62, 50x24 -> dw=46, 36x24 -> dw=36)
    - SearchDialog_on_key: TAB/UP/DOWN field toggle, ASCII + 2-byte UTF-8 + 3-byte UTF-8 + >=0x10000 ignore,
      Ctrl/Alt mods ignored, BS & 0x08 multi-byte UTF-8 delete, 126B cap, ENTER/ESC
    - SearchDialog_on_mouse: click row y+3 -> field 0, row y+6 -> field 1, other rows/btns -> Dialog_on_mouse
    - fp_exit_virtual (virtual_mode 0 / 1 / 2) & fp_draw_search_badge (virtual_mode 0 -> du_badge, 1 -> badge)
    - Non-buggy render rows match frozen asm byte for byte
SD2 real asm bug fix proven in C vs frozen asm:
    - SearchDialog_layout in asm tail-jumped to dlg_layout_right_buttons with rsi=x, rdx=y
      (zero-width button, Cancel missing). C passes OK/Cancel labels -> both buttons rendered & clickable!
SD3 qemu-aarch64: matches x86_64 byte for byte (diff + fix)
SD4 mutation check across src/ui/search_dialog.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/search_dialog.c"
REFS = [
    "tests/harness/search_dialog_reference.s",
    "tests/harness/search_dialog_input_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
]

KEY_UP = 0x100001
KEY_DOWN = 0x100002
KEY_BACKSPACE = 0x10000B
KEY_TAB = 0x10000C
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
    return H.build(arch, t, ["tests/harness/search_dialog_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DSD_SRC="{full}"'])


def build_diff_script() -> str:
    # 80x24 -> dw=62, h=11, x=9, y=6; field 0 input at y+3=9, field 1 input at y+6=12
    return "\n".join([
        "N 0 80 24 1",               # OOM
        "N 1 80 24 0",               # NULL app -> 80x24
        "N 0 80 24 0",
        "L 0 0 50 24",               # dw=46
        "L 0 0 36 24",               # dw=36
        "L 0 0 80 24",
        # Type ASCII + 2B UTF-8 (U+041F) + 3B UTF-8 (U+25C6) + ignored 4B (U+1F600) + ignored Ctrl
        f"K 0x{ord('*'):x} 0",
        f"K 0x{ord('.'):x} 0",
        "K 0x041F 0",
        "K 0x25C6 0",
        "K 0x1F600 0",
        f"K 0x{ord('z'):x} 2",       # MOD_CTRL -> ignored
        f"K 0x{ord('z'):x} 4",       # MOD_ALT -> ignored
        "K 0x1B 0",                  # < 32 -> ignored
        "R",
        # Backspace 3B char via KEY_BACKSPACE, 2B char via 0x08
        f"K 0x{KEY_BACKSPACE:x} 0",
        "K 0x08 0",
        f"K 0x{ord('c'):x} 0",
        # Switch to grep field via TAB, type, switch via UP/DOWN, mouse click y+6 & y+3
        f"K 0x{KEY_TAB:x} 0",
        f"K 0x{ord('T'):x} 0",
        f"K 0x{ord('O'):x} 0",
        "R",
        f"K 0x{KEY_UP:x} 0",
        f"K 0x{KEY_DOWN:x} 0",
        "M 1 0 15 9",                # y+3 -> field 0
        "M 1 0 15 12",               # y+6 -> field 1
        "M 1 2 15 9",                # right click -> base
        "M 2 0 15 9",                # release -> base
        f"K 0x{KEY_ENTER:x} 0",
        f"K 0x{KEY_ESC:x} 0",
        # Virtual pane helpers: mode 0, 1, 2
        "V 0",
        "V 1",
        "V 2",
    ]) + "\n"


def build_fix_script() -> str:
    # 80x24 -> dw=62, h=11, x=9, y=6 -> rx=69, by=15; " Cancel "(8) at [61..69), "  OK  "(6) at [53..59)
    return "\n".join([
        "N 0 80 24 0",
        "R",
        "M 1 0 55 15",               # click OK
        "M 1 0 64 15",               # click Cancel
    ]) + "\n"


def test_differential(exe: Path) -> tuple[str, str]:
    s = build_diff_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=0\n", "n=*.c", "g=TO", "call fp_draw_du_badge 1 1",
                   "call DirModel_reload 1", "call FilePane_ensure_visible 1",
                   "call arc_nav_up 1", "V rc=7", "call App_close_dialog 1 1",
                   "call App_close_dialog 1 2"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] SD1. search_dialog + virtual helpers match frozen asm ({len(out.splitlines())} lines)")

    fs = build_fix_script().encode()
    c_fix = H.run_impl("x86_64", exe, "fix_c", stdin=fs)
    ref_fix = H.run_impl("x86_64", exe, "fix_ref", stdin=fs)
    assert c_fix.returncode == 0 and ref_fix.returncode == 0
    co, ro = c_fix.stdout.decode(), ref_fix.stdout.decode()
    assert "bc=1 [69..69@15]" in ro, f"expected asm Bug (zero-width button):\n{ro}"
    assert "bc=2 [53..59@15] [61..69@15]" in co, f"expected C OK/Cancel buttons:\n{co}"
    assert "call App_close_dialog 1 1" in co and "call App_close_dialog 1 2" in co
    assert "call App_close_dialog" not in ro
    assert "  OK  " in co and " Cancel " in co
    print("[PASS] SD2. C fixes asm dlg_layout_right_buttons defect (OK/Cancel buttons clickable)")
    return out, co


def test_mutations(t: Path, base_diff: str, base_fix: str) -> None:
    ds = build_diff_script().encode()
    fs = build_fix_script().encode()
    muts = [
        ("oom-null", "if (!d) return nullptr;", "if (0 && !d) return nullptr;", "c", ds, base_diff),
        ("lay-max62", "if (dw > 62) dw = 62;", "if (dw > 56) dw = 56;", "c", ds, base_diff),
        ("lay-min36", "if (dw < 36) dw = 36;", "if (dw < 40) dw = 40;", "c", ds, base_diff),
        ("lay-h11", "self->h = 11;", "self->h = 10;", "c", ds, base_diff),
        ("lay-btns", "dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);",
                     "dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], nullptr);", "fix_c", fs, base_fix),
        ("v-arc", "if (dm->virtual_mode == 2) return arc_nav_up(pane);",
                  "if (dm->virtual_mode == 9) return arc_nav_up(pane);", "c", ds, base_diff),
        ("v-zero", "if (dm->virtual_mode == 0) return 0;", "if (dm->virtual_mode == 9) return 0;", "c", ds, base_diff),
        ("badge-du", "if (dm->virtual_mode == 0) { fp_draw_du_badge(pane, scr); return; }",
                     "if (dm->virtual_mode == 9) { fp_draw_du_badge(pane, scr); return; }", "c", ds, base_diff),
        ("utf8-2b", "if (key < 0x800U)", "if (key < 0x80U)", "c", ds, base_diff),
        ("utf8-3b", "if (key < 0x10000U)", "if (key < 0x800U)", "c", ds, base_diff),
        ("bs-cont", "while (len > 0 && (buf[len] & 0xC0U) == 0x80U)",
                    "while (0 && len > 0 && (buf[len] & 0xC0U) == 0x80U)", "c", ds, base_diff),
        ("key-mods", "if ((ev->mods & (MOD_CTRL | MOD_ALT)) == 0 && (int)key >= 32)",
                     "if ((int)key >= 32)", "c", ds, base_diff),
        ("mouse-f0", "if (rel == 3)", "if (rel == 2)", "c", ds, base_diff),
        ("mouse-f1", "else if (rel == 6)", "else if (rel == 5)", "c", ds, base_diff),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str, mode: str, inp: bytes, base: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "search_dialog.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, mode, stdin=inp)
        if r.returncode == 0 and r.stdout.decode() == base:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] SD4. {len(muts)}/{len(muts)} mutants killed across search_dialog.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out, fix_out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r1 = H.run_impl("aarch64", exe_arm, "c", stdin=build_diff_script().encode())
            r2 = H.run_impl("aarch64", exe_arm, "fix_c", stdin=build_fix_script().encode())
            assert r1.returncode == 0 and r1.stdout.decode() == out, "aarch64 diff mismatch"
            assert r2.returncode == 0 and r2.stdout.decode() == fix_out, "aarch64 fix mismatch"
            print("[PASS] SD3. qemu-aarch64 matches x86_64 byte for byte (diff + fix)")
        test_mutations(t, out, fix_out)


if __name__ == "__main__":
    main()
