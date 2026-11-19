#!/usr/bin/env python3
"""U2b.6: src/ui/bookmark_dlg.c versus frozen x86_64 assembly
(tests/harness/bookmark_dlg{,_input}_reference.s): BookmarkDialog (Hotlist + Frecency).

BM1 differential (x86_64):
    - Mode 0 (Bookmarks): empty "(empty)" render, add ('a') from active pane DirModel.path,
      16 seeded items with scrolling past 13 visible rows, j/k/UP/DOWN, delete ('d') + cursor clamp,
      mouse click on row confirms selected item, non-press & out-of-range click ignored
    - Mode 1 (Frecency): 16 seeded paths, filter prompt "> ", typing ASCII filters via
      nav_frecency_match, Backspace deletes & refilters, scroll past 12 visible rows,
      mouse click shifted by +1 row for filter bar, ENTER/ESC
    - Layout clamping: wide (80x24 -> 68x18), medium (56x16 -> 52x14), narrow (34x24 -> 36x18)
BM2 C-only OOM regression: BookmarkDialog_new returns NULL cleanly on OOM
    (asm bookmark_dlg.s dereferenced NULL without checking NEW_OBJ)
BM3 qemu-aarch64: matches x86_64 byte for byte + OOM
BM4 mutation check across src/ui/bookmark_dlg.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/bookmark_dlg.c"
REFS = [
    "tests/harness/bookmark_dlg_reference.s",
    "tests/harness/bookmark_dlg_input_reference.s",
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
    return H.build(arch, t, ["tests/harness/bookmark_dlg_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DBM_SRC="{full}"'])


def build_script() -> str:
    # 80x24 -> 68x18 at x=6, y=3; mode 0 list starts y+2=5 (13 rows); mode 1 filter at 5, list at 6 (12 rows)
    return "\n".join([
        # Empty bookmarks + delete on empty + add from active pane
        "S 0 16",
        "N 80 24 0",
        "R",
        f"K 0x{ord('d'):x} 0",
        f"K 0x{ord('a'):x} 0",
        "R",
        # 16 bookmarks -> scroll past 13 rows, back up, delete last item to test cursor clamp
        "S 16 16",
        "N 80 24 0",
        "L 0 0 56 16",
        "L 0 0 34 24",
        "L 0 0 80 24",
        *[f"K 0x{KEY_DOWN:x} 0" for _ in range(13)],
        "R",                         # exact boundary cur==scroll+vis (13) -> scroll=1
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{KEY_DOWN:x} 0",
        "R",                         # scroll advances to 3
        f"K 0x{ord('d'):x} 0",       # delete index 15 -> cursor clamped to 14
        f"K 0x{ord('k'):x} 0",
        f"K 0x{ord('j'):x} 0",
        *[f"K 0x{KEY_UP:x} 0" for _ in range(15)],
        "R",                         # scroll returns to 0
        f"K 0x{ord('x'):x} 0",       # unhandled in mode 0
        "M 2 0 10 5",                # release -> ignored
        "M 1 0 10 4",                # above list -> ignored
        "M 1 0 10 7",                # row 2 -> idx 2 -> confirm
        f"K 0x{KEY_ESC:x} 0",
        # Mode 1: Frecency (16 items), scroll past 12 rows, filter "proj", BS, mouse click at row 6 (idx 0)
        "N 80 24 1",
        "R",
        *[f"K 0x{KEY_DOWN:x} 0" for _ in range(13)],
        "R",                         # scroll should advance to 2
        f"K 0x{KEY_BACKSPACE:x} 0",  # BS on empty filter -> ignored (rc=0)
        f"K 0x{ord('p'):x} 0",
        f"K 0x{ord('r'):x} 0",
        f"K 0x{ord('o'):x} 0",
        f"K 0x{ord('j'):x} 0",
        "R",
        f"K 0x{KEY_BACKSPACE:x} 0",
        "M 1 0 10 5",                # filter row (above list in mode 1) -> ignored
        "M 1 0 10 7",                # row 1 -> second match -> confirm
        "M 1 0 10 20",               # past match_cnt -> ignored
        f"K 0x{KEY_ENTER:x} 0",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("(empty)", "/added/from/pane", "scr=3", "scr=2", "flt=proj",
                   "sel=/home/user/projects/duop", "> ", "call App_close_dialog 1 1",
                   "call App_close_dialog 1 2"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] BM1. bookmark_dlg matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_oom(exe: Path, arch: str) -> None:
    r = H.run_impl(arch, exe, "oom")
    assert r.returncode == 0 and "OOM ok=1" in r.stdout.decode(), r.stdout.decode()


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("clamp-cur", "d->cursor = d->match_cnt - 1;", "d->cursor = d->match_cnt;"),
        ("lay-max68", "if (dw > 68) dw = 68;", "if (dw > 60) dw = 60;"),
        ("lay-min36", "if (dw < 36) dw = 36;", "if (dw < 40) dw = 40;"),
        ("lay-h18", "int dh = 18;", "int dh = 16;"),
        ("vis-13", "int vis = 13;", "int vis = 12;"),
        ("fre-y0", "y0++;\n        vis--;", "vis--;"),
        ("scr-up", "if ((int)d->cursor < (int)d->scroll) d->scroll = d->cursor;",
                   "if (0 && (int)d->cursor < (int)d->scroll) d->scroll = d->cursor;"),
        ("scr-dn", "if ((int)d->cursor >= (int)d->scroll + vis)",
                   "if ((int)d->cursor > (int)d->scroll + vis)"),
        ("sel-fre", "if (self->mode == 1) return nav_frecency_get",
                    "if (self->mode == 2) return nav_frecency_get"),
        ("key-fre-bs", "if (d->filter_len == 0) return 0;", "if (d->filter_len > 99) return 0;"),
        ("key-bm-add", "case 'a':", "case 'A':"),
        ("key-bm-del", "if ((int)d->match_cnt > 0)", "if ((int)d->match_cnt > 100)"),
        ("mouse-kind", "if (ev->mouse_kind != MACT_PRESS) return 0;", "if (0) return 0;"),
        ("mouse-m1", "int base_y = d->base.base.y + 2 + (d->mode == 1 ? 1 : 0);",
                     "int base_y = d->base.base.y + 2;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "bookmark_dlg.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] BM4. {len(muts)}/{len(muts)} mutants killed across bookmark_dlg.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_oom(exe, "x86_64")
        print("[PASS] BM2. OOM in BookmarkDialog_new returns NULL cleanly (fixes asm NULL deref)")
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            test_oom(exe_arm, "aarch64")
            print("[PASS] BM3. qemu-aarch64 matches x86_64 byte for byte + OOM check")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
