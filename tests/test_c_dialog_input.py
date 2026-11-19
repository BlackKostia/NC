#!/usr/bin/env python3
"""U2b.1: src/ui/dialog_input.c versus frozen x86_64 assembly
(tests/harness/dialogs_input_reference.s): InputDialog_vtbl, InputDialog_new,
InputDialog_layout, InputDialog_render.

DI1 differential (x86_64):
    - InputDialog_new: OOM, NULL initial_text, short initial_text, long (72B) initial_text
    - InputDialog_layout: wide (80x24 -> dw=68), medium (50x16 -> dw=44),
      boundary (42x16 -> dw=36, 41x16 -> dw=41), narrow (30x12), short (60x6), offset (4,2,70,14)
    - InputDialog_render: prompt, empty input cursor cell, mid-text cursor cell,
      horizontal scroll right (cur >= scroll + field_w - 1) and scroll left (cur < scroll),
      exact boundary cur == scroll + field_w - 1
    - Virtual dispatch of InputDialog_on_key through InputDialog_vtbl
DI2 qemu-aarch64: matches x86_64 byte for byte
DI3 mutation check across src/ui/dialog_input.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/dialog_input.c"
REF = "tests/harness/dialogs_input_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
    "src/ui/dialogs_input_keys.c",
]

KEY_LEFT = 0x100003
KEY_ENTER = 0x10000E


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "dialogs_input_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "Object_alloc=fake_object_alloc", str(o)],
                       check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/dialog_input_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DDI_SRC="{full}"'])


def build_script() -> str:
    return "\n".join([
        # OOM
        "N 80 16 11 1 0",
        # Empty initial_text
        "N 80 16 12 0 0",
        "R",
        # Layout edge cases: wide, medium, exact 42 (dw=36), 41 (dw<36 -> dw=41), narrow, short, offset
        "L 0 0 80 24",
        "L 0 0 50 16",
        "L 0 0 42 16",
        "L 0 0 41 16",
        "L 0 0 30 12",
        "L 0 0 60 6",
        "L 4 2 70 14",
        # Short initial_text + render + key edit + mid-string cursor render
        "N 80 16 13 0 1",
        "R",
        f"K 0x{KEY_LEFT:x} 0",
        f"K 0x{KEY_LEFT:x} 0",
        f"K 0x{ord('!'):x} 0",
        "R",
        # Long initial_text (72B) in 50x16 (dw=44, field_w=38) -> triggers scroll right
        "N 50 16 14 0 2",
        "R",
        # Scroll left when cur < scroll
        "C 3 -1",
        "R",
        # Exact boundary cur == scroll + field_w - 1 (scroll=3, field_w=38 -> cur=40)
        "C 40 -1",
        "R",
        # Enter confirms through vtable
        f"K 0x{KEY_ENTER:x} 0",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=0\n", "N ok=1 is_id=1 is_d=1 tag=12", "New name:",
                   "hello.t!xt", "R scr=36 cur=72", "R scr=3 cur=3", "R scr=4 cur=40",
                   "accent_fg/accent a=1", "call App_close_dialog 1 1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] DI1. dialog_input matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("oom-null", "if (!id) return nullptr;", "if (0 && !id) return nullptr;"),
        ("init-len", "id->len = (uint32_t)n;", "id->len = 0;"),
        ("init-cur", "id->cursor = (uint32_t)n;", "id->cursor = 0;"),
        ("lay-max68", "if (dw > 68) dw = 68;", "if (dw > 64) dw = 64;"),
        ("lay-min36", "if (dw < 36) dw = w;", "if (dw < 40) dw = w;"),
        ("lay-h9", "int dh = 9;", "int dh = 8;"),
        ("lay-hoff", "int dy = y + ((h - dh) >> 1);", "int dy = y + 1 + ((h - dh) >> 1);"),
        ("scr-left", "if (cur < scroll)", "if (0 && cur < scroll)"),
        ("scr-right-ge", "else if (cur >= scroll + field_w - 1)", "else if (cur > scroll + field_w - 1)"),
        ("scr-right-off", "scroll = cur - field_w + 2;", "scroll = cur - field_w + 1;"),
        ("cur-space", "if (ch == 0) ch = ' ';", "if (ch == 0) ch = '_';"),
        ("cur-bold", "ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_BOLD);",
                     "ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_NONE);"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "dialog_input.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] DI3. {len(muts)}/{len(muts)} mutants killed across dialog_input.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] DI2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
