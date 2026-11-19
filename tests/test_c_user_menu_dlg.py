#!/usr/bin/env python3
"""U2b.9: src/ui/user_menu_dlg.c versus frozen x86_64 assembly
(tests/harness/user_menu_dlg_reference.s): UserMenuDialog.

UM1 differential (x86_64):
    - UserMenuDialog_new (OOM + normal), layout (80x24 -> 68x16, 54x16 -> 50x12, 34x10 -> 36x10)
    - 10 config menu items + 4 pkg menu items (14 total > 11 visible rows):
      UP/DOWN/j/k scrolling across visible window (h-5 = 11 rows), clamping at 0 & 13,
      ENTER/ESC/q, unhandled key delegated to Dialog_on_key
    - Mouse click on item row selects & confirms; click outside list / right click / release
      delegates to Dialog_on_mouse
    - Non-buggy render rows match frozen asm byte for byte
UM2 real asm bug fix proven in C vs frozen asm:
    - UserMenuDialog_layout in asm tail-jumped to dlg_layout_right_buttons with rsi=x, rdx=y
      (zero-width button, Cancel missing). C passes OK/Cancel labels -> clickable OK & Cancel!
UM3 qemu-aarch64: matches x86_64 byte for byte (diff + fix)
UM4 mutation check across src/ui/user_menu_dlg.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/user_menu_dlg.c"
REF = "tests/harness/user_menu_dlg_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
]

KEY_UP = 0x100001
KEY_DOWN = 0x100002
KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "user_menu_dlg_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "Object_alloc=fake_object_alloc", str(o)],
                       check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/user_menu_dlg_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DUM_SRC="{full}"'])


def build_diff_script() -> str:
    # 80x24 -> 68x16 at x=6, y=4; list rows y+2=6..16 (11 visible rows)
    return "\n".join([
        "N 80 24 1",                 # OOM
        "N 80 24 0",
        "R",
        "L 0 0 54 16",               # 50x12
        "L 0 0 34 10",               # 36x10
        "L 0 0 80 24",               # back to 68x16
        f"K 0x{KEY_UP:x} 0",         # at 0 -> no redraw
        *[f"K 0x{KEY_DOWN:x} 0" for _ in range(11)],  # cur=11 -> scroll=1 (boundary!)
        "R",                         # shows Pkg: Format + Pkg: Lint
        f"K 0x{ord('j'):x} 0",       # cur=12 -> scroll=2
        f"K 0x{ord('j'):x} 0",       # cur=13 -> scroll=3
        f"K 0x{ord('j'):x} 0",       # clamped at 13
        "R",                         # shows Pkg: Deploy
        *[f"K 0x{ord('k'):x} 0" for _ in range(12)],  # cur=1 -> scroll=1
        f"K 0x{KEY_UP:x} 0",         # cur=0 -> scroll=0
        f"K 0x{KEY_ENTER:x} 0",
        f"K 0x{KEY_ESC:x} 0",
        f"K 0x{ord('q'):x} 0",
        # Mouse: click row y+2+3=9 -> cur=3 & confirm; above/below/right-click ignored
        "M 1 0 12 9",
        "M 1 0 12 5",
        "M 1 0 12 17",
        "M 1 2 12 9",
        "M 2 0 12 9",
    ]) + "\n"


def build_fix_script() -> str:
    # 80x24 -> 68x16 at x=6, y=4 -> rx=72, by=18; " Cancel "(8) at [64..72), "  OK  "(6) at [56..62)
    return "\n".join([
        "N 80 24 0",
        "R",
        "M 1 0 58 18",               # click OK
        "M 1 0 66 18",               # click Cancel
    ]) + "\n"


def test_differential(exe: Path) -> tuple[str, str]:
    s = build_diff_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=0\n", "Open terminal here", "Pkg: Format", "Pkg: Deploy",
                   "cur=11 scr=1", "cur=13 scr=3", "cur=3 scr=0",
                   "call App_close_dialog 1 1", "call App_close_dialog 1 2"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] UM1. user_menu_dlg matches frozen asm ({len(out.splitlines())} lines)")

    fs = build_fix_script().encode()
    c_fix = H.run_impl("x86_64", exe, "fix_c", stdin=fs)
    ref_fix = H.run_impl("x86_64", exe, "fix_ref", stdin=fs)
    assert c_fix.returncode == 0 and ref_fix.returncode == 0
    co, ro = c_fix.stdout.decode(), ref_fix.stdout.decode()
    assert "bc=1 [72..72@18]" in ro, f"expected asm Bug (zero-width button):\n{ro}"
    assert "bc=2 [56..62@18] [64..72@18]" in co, f"expected C OK/Cancel buttons:\n{co}"
    assert "call App_close_dialog 1 1" in co and "call App_close_dialog 1 2" in co
    assert "call App_close_dialog" not in ro
    assert "  OK  " in co and " Cancel " in co
    print("[PASS] UM2. C fixes asm dlg_layout_right_buttons defect (OK/Cancel buttons clickable)")
    return out, co


def test_mutations(t: Path, base_diff: str, base_fix: str) -> None:
    ds = build_diff_script().encode()
    fs = build_fix_script().encode()
    muts = [
        ("oom-null", "if (!d) return nullptr;", "if (0 && !d) return nullptr;", "c", ds, base_diff),
        ("lay-max68", "if (dw > 68) dw = 68;", "if (dw > 60) dw = 60;", "c", ds, base_diff),
        ("lay-min36", "if (dw < 36) dw = 36;", "if (dw < 40) dw = 40;", "c", ds, base_diff),
        ("lay-max16", "if (dh > 16) dh = 16;", "if (dh > 14) dh = 14;", "c", ds, base_diff),
        ("lay-min10", "if (dh < 10) dh = 10;", "if (dh < 12) dh = 12;", "c", ds, base_diff),
        ("lay-btns", "dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);",
                     "dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], nullptr);", "fix_c", fs, base_fix),
        ("pkg-idx", "PkgAction *a = pkg_menu_get(idx - cc);", "PkgAction *a = pkg_menu_get(idx);", "c", ds, base_diff),
        ("key-up-scr", "if (d->cursor < d->scroll) d->scroll = d->cursor;",
                       "if (0 && d->cursor < d->scroll) d->scroll = d->cursor;", "c", ds, base_diff),
        ("key-dn-scr", "if (d->cursor >= d->scroll + (uint32_t)vis)",
                       "if (d->cursor > d->scroll + (uint32_t)vis)", "c", ds, base_diff),
        ("key-q", "lat == KEY_ESC || lat == 'q'", "lat == KEY_ESC", "c", ds, base_diff),
        ("mouse-y-lo", "ev->mouse_y >= d->base.base.y + 2", "ev->mouse_y >= d->base.base.y + 1", "c", ds, base_diff),
        ("mouse-y-hi", "ev->mouse_y < d->base.base.y + d->base.base.h - 3",
                       "ev->mouse_y <= d->base.base.y + d->base.base.h - 3", "c", ds, base_diff),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str, mode: str, inp: bytes, base: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "user_menu_dlg.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, mode, stdin=inp)
        if r.returncode == 0 and r.stdout.decode() == base:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] UM4. {len(muts)}/{len(muts)} mutants killed across user_menu_dlg.c")


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
            print("[PASS] UM3. qemu-aarch64 matches x86_64 byte for byte (diff + fix)")
        test_mutations(t, out, fix_out)


if __name__ == "__main__":
    main()
