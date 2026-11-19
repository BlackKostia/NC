#!/usr/bin/env python3
"""U2b.2: src/ui/conflict_dialog.c versus frozen x86_64 assembly
(tests/harness/conflict_dialog{,_input}_reference.s): ConflictDialog_vtbl,
ConflictDialog_new, layout, render, on_key, on_mouse.

CD1 differential (x86_64):
    - ConflictDialog_new: sizes, fields, instanceof, layout
    - ConflictDialog_layout: wide (80x20 -> dw=68), medium (56x20 -> dw=52), narrow (40x20 -> dw=44)
    - ConflictDialog_render: checkbox off/on, 3 buttons with focus highlight & HitZones, hint
    - ConflictDialog_on_key: a/A (for_all toggle), o/O/s/S/r/R, LEFT wrap (0->2->1),
      RIGHT/TAB wrap (1->2->0), ENTER confirms focus_btn+1, ESC cancels, unhandled -> 0
    - ConflictDialog_on_mouse: non-press ignored, row y+4 toggles for_all,
      click on each button [x1..x2) confirms id+1, click at exact x2 / outside ignored
CD2 C-only OOM regression: ConflictDialog_new returns NULL cleanly on OOM
    (asm conflict_dialog.s dereferenced NULL without checking NEW_OBJ)
CD3 qemu-aarch64: matches x86_64 byte for byte + OOM check
CD4 mutation check across src/ui/conflict_dialog.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/conflict_dialog.c"
REFS = [
    "tests/harness/conflict_dialog_reference.s",
    "tests/harness/conflict_dialog_input_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
]

KEY_LEFT = 0x100003
KEY_RIGHT = 0x100004
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
    return H.build(arch, t, ["tests/harness/conflict_dialog_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DCD_SRC="{full}"'])


def build_script() -> str:
    # 80x20 -> dw=68, h=11, x=6, y=4; checkbox row=8; btn row=10
    # Buttons at x=9: "[O] Overwrite"(len 13->15: [9..24)), "[S] Skip"(len 8->10: [26..36)), "[R] Rename"(len 10->12: [38..50))
    return "\n".join([
        "N 80 20 12345 67890",
        "R",
        "L 0 0 56 20",
        "L 0 0 40 20",
        "L 0 0 80 20",
        # Keys: toggle for_all via a and A, focus navigation, hotkeys, enter, esc, unhandled
        f"K 0x{ord('x'):x} 0",
        f"K 0x{ord('a'):x} 0",
        "R",
        f"K 0x{ord('A'):x} 0",
        f"K 0x{KEY_LEFT:x} 0",       # 0 -> 2
        "R",
        f"K 0x{KEY_LEFT:x} 0",       # 2 -> 1
        f"K 0x{KEY_RIGHT:x} 0",      # 1 -> 2
        f"K 0x{KEY_TAB:x} 0",        # 2 -> 0
        f"K 0x{KEY_RIGHT:x} 0",      # 0 -> 1
        f"K 0x{KEY_ENTER:x} 0",      # action = 2 (SKIP)
        f"K 0x{ord('o'):x} 0",
        f"K 0x{ord('O'):x} 0",
        f"K 0x{ord('s'):x} 0",
        f"K 0x{ord('S'):x} 0",
        f"K 0x{ord('r'):x} 0",
        f"K 0x{ord('R'):x} 0",
        f"K 0x{KEY_ESC:x} 0",
        # Mouse: release ignored, checkbox row toggles for_all, buttons + exact exclusive x2 miss
        "M 2 0 12 8",
        "M 1 0 12 8",
        "M 1 0 12 10",               # btn 0 (Overwrite)
        "M 1 0 24 10",               # exact x2 of btn 0 -> miss
        "M 1 0 28 10",               # btn 1 (Skip)
        "M 1 0 40 10",               # btn 2 (Rename)
        "M 1 0 60 10",               # past all btns -> miss
        "M 1 0 12 9",                # wrong row -> miss
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=1 is_cd=1 is_d=1 tag=15", "[ ] ", "[x] ",
                   "report_2026.tar.gz", "accent_fg/accent a=1",
                   "call App_close_dialog 1 1", "call App_close_dialog 1 2"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] CD1. conflict_dialog matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_oom(exe: Path, arch: str) -> None:
    r = H.run_impl(arch, exe, "oom")
    assert r.returncode == 0 and "OOM ok=1" in r.stdout.decode(), r.stdout.decode()


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("init-act", "cd->action = CONFLICT_ACT_OVERWRITE;", "cd->action = CONFLICT_ACT_SKIP;"),
        ("lay-max68", "if (dw > 68) dw = 68;", "if (dw > 60) dw = 60;"),
        ("lay-min44", "if (dw < 44) dw = 44;", "if (dw < 50) dw = 50;"),
        ("lay-h11", "self->h = 11;", "self->h = 10;"),
        ("chk-on", 'cd->for_all ? "[x] " : "[ ] "', 'cd->for_all ? "[ ] " : "[x] "'),
        ("btn-focus", "i == (int)cd->base.focus_btn", "0"),
        ("btn-gap", "bx += bw + 2;", "bx += bw + 1;"),
        ("key-esc", "case KEY_ESC:", "case 0x7FFFFF:"),
        ("key-all", "cd->for_all ^= 1;", "cd->for_all = 0;"),
        ("key-left-wrap", "if (fb < 0) fb = 2;", "if (fb < 0) fb = 0;"),
        ("key-right-wrap", "if (fb >= 3) fb = 0;", "if (fb >= 3) fb = 2;"),
        ("key-enter-inc", "cd->action = cd->base.focus_btn + 1;", "cd->action = cd->base.focus_btn;"),
        ("mouse-kind", "if (ev->mouse_kind != MACT_PRESS) return 0;", "if (0) return 0;"),
        ("mouse-chk-y", "if (ev->mouse_y == cd->base.base.y + 4)", "if (ev->mouse_y == cd->base.base.y + 3)"),
        ("mouse-x2", "ev->mouse_x < (int16_t)z[i].x2", "ev->mouse_x <= (int16_t)z[i].x2"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "conflict_dialog.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] CD4. {len(muts)}/{len(muts)} mutants killed across conflict_dialog.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_oom(exe, "x86_64")
        print("[PASS] CD2. OOM in ConflictDialog_new returns NULL cleanly (fixes asm NULL deref)")
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            test_oom(exe_arm, "aarch64")
            print("[PASS] CD3. qemu-aarch64 matches x86_64 byte for byte + OOM check")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
