#!/usr/bin/env python3
"""U2b.13: src/ui/dialog_help.c versus frozen x86_64 assembly
(tests/harness/dialogs_help{,_input}_reference.s): HelpDialog_vtbl, HelpDialog_new,
layout, render, on_key, on_mouse.

HD1 differential (x86_64):
    - HelpDialog_new: instanceof, layout, Close button + Overview/Instruction tab HitZones
    - HelpDialog_layout: wide (100x30 -> 78x26), mid (60x14 -> 54x14), narrow (36x10 -> 36x10),
      tiny (10x5 -> hint skipped, vis=1), resize clamps scroll to max_scroll
    - HelpDialog_render: both tabs (22 Overview lines, 36 Instruction lines), 0xE2 ('◆')
      heading accent+bold, scrolled window, active tab highlight, Close button & hint
    - HelpDialog_on_key: Esc/Enter/q/F1 close, Tab/BTab toggle tab + reset scroll,
      Left/'1' -> tab 0, Right/'2' -> tab 1, Up/Down/PgUp/PgDn/Home/End + clamping, unhandled
    - HelpDialog_on_mouse: left click on tab 0 & tab 1 + exact x2 miss -> delegates to Dialog_on_mouse,
      Close button click, wheel up/down (and wheel down at max_scroll does not redraw)
HD2 OOM check (HelpDialog_new returns NULL cleanly)
HD3 qemu-aarch64 matches x86_64 byte for byte + OOM
HD4 mutation check across src/ui/dialog_help.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/dialog_help.c"
REFS = [
    "tests/harness/dialogs_help_reference.s",
    "tests/harness/dialogs_help_input_reference.s",
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
KEY_LEFT = 0x100003
KEY_RIGHT = 0x100004
KEY_HOME = 0x100005
KEY_END = 0x100006
KEY_PGUP = 0x100007
KEY_PGDN = 0x100008
KEY_TAB = 0x10000C
KEY_BTAB = 0x10000D
KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F
KEY_F1 = 0x100011


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
    return H.build(arch, t, ["tests/harness/dialog_help_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DHD_SRC="{full}"'])


def build_script() -> str:
    return "\n".join([
        # Full-size 100x30 -> dw=78, dh=26, x=11, y=2
        "N 100 30",
        "R",
        # Switch to Instruction tab and render
        f"K 0x{KEY_TAB:x} 0",
        "R",
        # Shrink to 80x14 (vis=10 -> tab1 max_scroll=26)
        "L 0 0 80 14",
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{KEY_PGDN:x} 0",       # step = 14 - 5 = 9 -> scroll = 10
        "R",
        f"K 0x{KEY_END:x} 0",        # scroll = 26
        f"K 0x{KEY_DOWN:x} 0",       # clamped at 26
        f"K 0x{KEY_PGDN:x} 0",       # clamped at 26
        "R",
        # Resize taller to 100x30 -> clamps scroll from 26 down to 14 (36 - 22)
        "L 0 0 100 30",
        f"K 0x{KEY_UP:x} 0",
        f"K 0x{KEY_PGUP:x} 0",       # clamped to 0
        f"K 0x{KEY_UP:x} 0",         # stays 0
        f"K 0x{KEY_END:x} 0",
        f"K 0x{KEY_HOME:x} 0",
        # Tab switching keys: Left, Right, '1', '2', BTab, unhandled
        f"K 0x{KEY_LEFT:x} 0",
        f"K 0x{KEY_RIGHT:x} 0",
        f"K 0x{ord('1'):x} 0",
        f"K 0x{ord('2'):x} 0",
        f"K 0x{KEY_BTAB:x} 0",
        f"K 0x{ord('x'):x} 0",
        # Close keys: Esc, Enter, 'q', F1
        f"K 0x{KEY_ESC:x} 0",
        f"K 0x{KEY_ENTER:x} 0",
        f"K 0x{ord('q'):x} 0",
        f"K 0x{KEY_F1:x} 0",
        # Layout edge cases: mid (60x14), narrow (36x10), tiny (10x5 -> hint skipped, vis=1)
        "L 0 0 60 14",
        "L 0 0 36 10",
        "L 0 0 10 5",
        "R",
        f"K 0x{KEY_PGDN:x} 0",       # step clamped to 1
        f"K 0x{KEY_PGUP:x} 0",       # step clamped to 1
        # Back to 80x14 (dw=74, dh=14, x=3, y=0) for mouse tests:
        # tz[0] = [6..16@1], tz[1] = [18..31@1], Close button = [67..74@12]
        "L 0 0 80 14",
        "M 1 0 20 1",                # click tab 1 -> tab=1, scroll=0
        "M 1 0 16 1",                # exact x2 of tab 0 -> miss (delegates to Dialog_on_mouse)
        "M 1 0 10 1",                # click tab 0 -> tab=0, scroll=0
        "M 1 0 69 12",               # click Close button -> App_close_dialog
        "M 1 2 20 1",                # right press -> delegates to Dialog_on_mouse
        "M 5 64 20 5",               # wheel up at 0 -> stays 0, redraw=1
        "M 5 65 20 5",               # wheel down -> scroll=1, redraw=1
        "M 5 65 20 5",               # wheel down -> scroll=2
        "M 5 64 20 5",               # wheel up -> scroll=1
        f"K 0x{KEY_END:x} 0",        # scroll=12 (max)
        "M 5 65 20 5",               # wheel down at max -> redraw=0!
        "M 4 0 69 12",               # hover on Close -> delegates to Dialog_on_mouse
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=1 is_hd=1 is_d=1", "accent/dialog_bg a=1", "accent_fg/accent a=1",
                   "call App_close_dialog 1 2", "tab=1 sc=26"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] HD1. dialog_help matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_oom(exe: Path, arch: str) -> None:
    r = H.run_impl(arch, exe, "oom")
    assert r.returncode == 0 and "OOM ok=1" in r.stdout.decode(), r.stdout.decode()


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("cnt-tab", "return d->tab ? HELP_INSTR_COUNT : HELP_LINE_COUNT;",
         "return d->tab ? HELP_LINE_COUNT : HELP_LINE_COUNT;"),
        ("lay-max78", "if (dw > 78) dw = 78;", "if (dw > 70) dw = 70;"),
        ("lay-min40", "if (dw < 40) dw = w;", "if (dw < 56) dw = w;"),
        ("lay-clamp", "if ((int)d->scroll > ms) d->scroll = (uint32_t)ms;",
         "if ((int)d->scroll > ms + 20) d->scroll = (uint32_t)ms;"),
        ("tab-gap", "cx += w0 + 2;", "cx += w0 + 1;"),
        ("hint-room", "if (room > 0)", "if (room > 999)"),
        ("hdr-e2", "if ((unsigned char)line[0] == 0xE2)", "if (0)"),
        ("key-close", "case KEY_F1:", "case 0x7FFFFF:"),
        ("key-tab", "d->tab ^= 1;", "d->tab = 1;"),
        ("key-pgdn", "if (sc > ms) sc = ms;", "if (sc > ms + 20) sc = ms;"),
        ("mouse-x2", "mx < (int16_t)z->x2", "mx <= (int16_t)z->x2"),
        ("mouse-whl", "if ((int)d->scroll < ms)", "if ((int)d->scroll <= ms)"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "dialog_help.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] HD4. {len(muts)}/{len(muts)} mutants killed across dialog_help.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_oom(exe, "x86_64")
        print("[PASS] HD2. OOM in HelpDialog_new returns NULL cleanly")
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            test_oom(exe_arm, "aarch64")
            print("[PASS] HD3. qemu-aarch64 matches x86_64 byte for byte + OOM check")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
