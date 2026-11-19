#!/usr/bin/env python3
"""U2b.5: src/ui/view_as_dialog.c versus frozen x86_64 assembly
(tests/harness/view_as_dialog_reference.s): ViewAsDialog.

VA1 differential (x86_64):
    - ViewAsDialog_new (OOM + normal), instanceof, layout (80x20 -> dw=60, 54x20 -> dw=50, 40x20 -> dw=44)
    - ViewAsDialog_render: basename, 3 buttons with focus highlight & HitZones, hint
    - ViewAsDialog_on_key: i/I/h/H/t/T (layout-independent lat), LEFT/RIGHT/TAB wrapping,
      ENTER confirms focus_btn+1, ESC cancels, unhandled -> 0
    - ViewAsDialog_on_mouse: non-press ignored, click on each button confirms i+1,
      exact x2 miss, wrong row miss
VA2 qemu-aarch64: matches x86_64 byte for byte
VA3 mutation check across src/ui/view_as_dialog.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/view_as_dialog.c"
REF = "tests/harness/view_as_dialog_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c", "src/core/utf8.c",
    "src/core/memory.c", "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
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
        o = t / "view_as_dialog_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "Object_alloc=fake_object_alloc", str(o)],
                       check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/view_as_dialog_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DVAS_SRC="{full}"'])


def build_script() -> str:
    # 80x20 -> dw=60, h=9, x=10, y=5; buttons on row y+4=9 starting at x+3=13:
    # "[I] Image"(9->11: [13..24)), "[H] Hex"(7->9: [26..35)), "[T] Text"(8->10: [37..47))
    return "\n".join([
        "N 80 20 3 1",               # OOM
        "N 80 20 3 0",               # normal (fmt=3)
        "R",
        "L 0 0 54 20",               # dw=50
        "L 0 0 40 20",               # dw=44
        "L 0 0 80 20",
        f"K 0x{ord('x'):x} 0",       # unhandled
        f"K 0x{KEY_LEFT:x} 0",       # 0 -> 2
        "R",
        f"K 0x{KEY_RIGHT:x} 0",      # 2 -> 0
        f"K 0x{KEY_TAB:x} 0",        # 0 -> 1
        f"K 0x{KEY_ENTER:x} 0",      # choice=2 (HEX)
        f"K 0x{ord('i'):x} 0",
        f"K 0x{ord('I'):x} 0",
        f"K 0x{ord('h'):x} 0",
        f"K 0x{ord('H'):x} 0",
        f"K 0x{ord('t'):x} 0",
        f"K 0x{ord('T'):x} 0",
        f"K 0x{KEY_ESC:x} 0",
        # Mouse: release ignored, each button ([13..20), [22..27), [29..35)), exact x2 miss, wrong row
        "M 2 0 15 9",
        "M 1 0 15 9",                # btn 0 -> choice=1
        "M 1 0 20 9",                # exact x2 of btn 0 -> miss
        "M 1 0 24 9",                # btn 1 -> choice=2
        "M 1 0 31 9",                # btn 2 -> choice=3
        "M 1 0 15 8",                # wrong row -> miss
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=0\n", "N ok=1 is_v=1 is_d=1 tag=22", "sunset.png",
                   "accent_fg/accent a=1", "call App_close_dialog 1 1", "call App_close_dialog 1 2"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] VA1. view_as_dialog matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("oom-null", "if (!d) return nullptr;", "if (0 && !d) return nullptr;"),
        ("init-ch", "d->choice = PV_MODE_IMAGE;", "d->choice = PV_MODE_HEX;"),
        ("lay-max60", "if (dw > 60) dw = 60;", "if (dw > 56) dw = 56;"),
        ("lay-min44", "if (dw < 44) dw = 44;", "if (dw < 48) dw = 48;"),
        ("lay-h9", "self->h = 9;", "self->h = 10;"),
        ("btn-focus", "i == (int)d->base.focus_btn", "0"),
        ("btn-gap", "bx += bw + 2;", "bx += bw + 1;"),
        ("key-case", "uint32_t low = ev->lat | 0x20U;", "uint32_t low = ev->lat;"),
        ("key-left", "d->base.focus_btn = (d->base.focus_btn + 2U) % 3U;",
                     "d->base.focus_btn = (d->base.focus_btn + 1U) % 3U;"),
        ("key-enter", "d->choice = d->base.focus_btn + 1U;", "d->choice = d->base.focus_btn;"),
        ("mouse-kind", "if (ev->mouse_kind != MACT_PRESS) return 0;", "if (0) return 0;"),
        ("mouse-x2", "ev->mouse_x < (int16_t)z[i].x2", "ev->mouse_x <= (int16_t)z[i].x2"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "view_as_dialog.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] VA3. {len(muts)}/{len(muts)} mutants killed across view_as_dialog.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] VA2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
