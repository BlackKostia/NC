#!/usr/bin/env python3
"""U2b.11: src/ui/progress_dialog.c versus frozen x86_64 assembly
(tests/harness/progress_dialog{,_render,_input}_reference.s): ProgressDialog_vtbl,
ProgressDialog_new, ProgressDialog_layout, ProgressDialog_title_for,
ProgressDialog_format_summary, render, on_key, on_mouse, on_hide.

PD1 differential (x86_64):
    - ProgressDialog_new: fields, focus_btn=1, op_tag=OP_PROGRESS, instanceof, layout
    - ProgressDialog_layout: wide (100x30 -> 66x9), mid (56x20 -> 50x9), narrow (30x8 -> 30x8),
      very narrow (10x9 -> bar_w <= 0)
    - ProgressDialog_title_for: COPY, MOVE, DELETE, default
    - ProgressDialog_format_summary & pd_fmt_eta: unknown (-1), <10s, m:ss, h:0m:0s, h:mm:ss,
      COPY/MOVE/DELETE, SCAN, PAUSED, CANCELING (priority over paused)
    - ProgressDialog_render: progress bar (0%, 45%, 100%, 150% clamped), bytes w/ and w/o total,
      done_files > total_files clamped, DELETE hides bytes, paused/canceling warn_fg + [Resume],
      button focus/hover/idle styles, narrow window without bar
    - ProgressDialog_on_key: Alt+j/J/x, Ctrl+c, Esc, Tab, Right, BTab, Left, Enter, Space/p/P,
      b/B, c/C, unhandled swallowed
    - ProgressDialog_on_mouse: hover change/no-op/leave, left press on 0/1/2, exact x2 miss,
      wrong row miss, right click ignored, release ignored
    - on_confirm / on_cancel -> App_task_hide
PD2 OOM check (ProgressDialog_new returns NULL cleanly)
PD3 qemu-aarch64 matches x86_64 byte for byte + OOM
PD4 mutation check across src/ui/progress_dialog.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/progress_dialog.c"
REFS = [
    "tests/harness/progress_dialog_reference.s",
    "tests/harness/progress_dialog_render_reference.s",
    "tests/harness/progress_dialog_input_reference.s",
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
KEY_BTAB = 0x10000D
KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F
MOD_ALT = 2
MOD_CTRL = 4


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
    return H.build(arch, t, ["tests/harness/progress_dialog_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DPD_SRC="{full}"'])


def build_script() -> str:
    # S op phase paused canceling percent done_b total_b done_f total_f speed eta cur_name
    return "\n".join([
        "T 1", "T 2", "T 3", "T 99",
        "N 100 30",
        # Copy running: 45%, 512000/1048576, 3/10, 5242880 B/s, ETA 1:05
        "S 1 2 0 0 45 512000 1048576 3 10 5242880 65 archive.tar.gz",
        "R",
        # ETA edge cases: -1 (--:--), 5 (0:05), 3605 (1:00:05), 4320 (1:12:00), 39725 (11:02:05)
        "S 1 2 0 0 0 0 0 0 5 1024 -1 zero.bin",
        "R",
        "S 2 2 0 0 100 1000 1000 7 5 2048 5 clamped.bin",
        "R",
        "S 1 2 0 0 150 2048 4096 1 2 10000 3605 hours_pad.bin",
        "R",
        "S 1 2 0 0 50 100 200 1 2 500 4320 hours_nopad.bin",
        "S 1 2 0 0 50 100 200 1 2 500 39725 hours_big.bin",
        "S 1 2 0 0 99 999 1000 4 5 1024 0 almost_done.bin",
        # Delete op (hides byte counts & speed)
        "S 3 2 0 0 75 0 0 6 8 99999 12 old_dir",
        "R",
        # Scan phase
        "S 1 1 0 0 0 0 0 0 42 0 -1 scanning_dir",
        "R",
        # Paused (changes button 0 to Resume + warn_fg state)
        "S 1 2 1 0 60 600 1000 2 4 0 10 paused_file.txt",
        "R",
        # Canceling (priority over paused)
        "S 1 2 1 1 60 600 1000 2 4 0 10 cancel_file.txt",
        "R",
        # Layouts: mid, narrow, very narrow (bar_w <= 0), restore 80x24
        "L 0 0 56 20",
        "L 0 0 30 8",
        "L 0 0 10 9",
        "R",
        "N 80 24",
        "S 1 2 0 0 40 400 1000 2 5 1024 30 file.bin",
        "R",
        # Keys: Alt+j, Alt+J, Alt+x, Ctrl+c, Tab, Right, BTab, Left, Enter on each btn, hotkeys
        f"K 0x{ord('j'):x} {MOD_ALT}",
        f"K 0x{ord('J'):x} {MOD_ALT}",
        f"K 0x{ord('x'):x} {MOD_ALT}",
        f"K 0x{ord('c'):x} {MOD_CTRL}",
        f"K 0x{ord('x'):x} 0",
        f"K 0x{KEY_ENTER:x} 0",      # focus=1 -> hide
        f"K 0x{KEY_TAB:x} 0",        # 1 -> 2
        f"K 0x{KEY_ENTER:x} 0",      # focus=2 -> cancel
        f"K 0x{KEY_RIGHT:x} 0",      # 2 -> 0
        f"K 0x{KEY_ENTER:x} 0",      # focus=0 -> toggle_pause
        f"K 0x{KEY_BTAB:x} 0",       # 0 -> 2
        f"K 0x{KEY_LEFT:x} 0",       # 2 -> 1
        f"K 0x{KEY_ESC:x} 0",
        f"K 0x{ord(' '):x} 0",
        f"K 0x{ord('p'):x} 0",
        f"K 0x{ord('P'):x} 0",
        f"K 0x{ord('b'):x} 0",
        f"K 0x{ord('B'):x} 0",
        f"K 0x{ord('c'):x} 0",
        f"K 0x{ord('C'):x} 0",
        # 80x24 -> dw=66, dh=9, x=7, y=7, btn row y+h-2 = 14
        # Labels: " Pause "(7), " Background "(12), " Cancel "(8) -> tot=31 -> cx=7+(66-31)/2=24
        # z0=[24..31@14], z1=[33..45@14], z2=[47..55@14]
        "M 4 0 25 14",               # hover btn 0 (MACT_MOVE=4)
        "R",                         # render hovered btn 0 + focused btn 1
        "M 4 0 25 14",               # repeat hover -> need_redraw stays 0
        "M 4 0 10 14",               # leave hover -> -1, need_redraw=1
        "M 1 0 25 14",               # left press btn 0 -> pause
        "M 1 0 31 14",               # exact x2 of btn 0 -> miss
        "M 1 0 36 14",               # left press btn 1 -> hide
        "M 1 0 50 14",               # left press btn 2 -> cancel
        "M 1 0 25 13",               # wrong row -> miss
        "M 1 2 25 14",               # right press -> ignored
        "M 2 0 25 14",               # release -> ignored
        # on_confirm / on_cancel -> both call App_task_hide
        "C 0",
        "C 1",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=1 is_pd=1 is_d=1 tag=10 fb=1", "1:00:05", "1:12:00", "--:--",
                   "call App_task_toggle_pause 1 0", "call App_task_hide 1 0",
                   "call App_task_cancel 1 0", "badge_fg/badge_hover_bg a=1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] PD1. progress_dialog matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_oom(exe: Path, arch: str) -> None:
    r = H.run_impl(arch, exe, "oom")
    assert r.returncode == 0 and "OOM ok=1" in r.stdout.decode(), r.stdout.decode()


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("init-fb", "d->base.focus_btn = 1;", "d->base.focus_btn = 0;"),
        ("lay-max66", "if (dw > PD_W_MAX) dw = PD_W_MAX;", "if (dw > 60) dw = 60;"),
        ("lay-min44", "if (dw < PD_W_MIN) dw = w;", "if (dw < 52) dw = w;"),
        ("lay-h9", "int dh = PD_H;", "int dh = 8;"),
        ("eta-neg", "if (sec < 0)", "if (sec <= 0)"),
        ("eta-mpad", "if (m < 10) *p++ = '0';", "if (m < 1) *p++ = '0';"),
        ("eta-spad", "if (sec_r < 10) *p++ = '0';", "if (sec_r < 1) *p++ = '0';"),
        ("state-canc", "if (s->canceling)", "if (0)"),
        ("state-paus", "if (s->paused)", "if (0)"),
        ("state-del", "if (s->op != TASK_OP_DELETE)", "if (1)"),
        ("bar-clamp", "uint32_t pct = s->percent > 100u ? 100u : s->percent;", "uint32_t pct = s->percent;"),
        ("df-clamp", "uint64_t df = s->done_files > s->total_files ? s->total_files : s->done_files;",
         "uint64_t df = s->done_files;"),
        ("btn-gap", "cx += 2;", "cx += 1;"),
        ("key-alt", "if (mods & MOD_ALT)", "if (0)"),
        ("key-ctrl", "if (mods & MOD_CTRL) return 1;", "if (0) return 1;"),
        ("mouse-x2", "mx < (int16_t)z[i].x2", "mx <= (int16_t)z[i].x2"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "progress_dialog.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] PD4. {len(muts)}/{len(muts)} mutants killed across progress_dialog.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_oom(exe, "x86_64")
        print("[PASS] PD2. OOM in ProgressDialog_new returns NULL cleanly")
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            test_oom(exe_arm, "aarch64")
            print("[PASS] PD3. qemu-aarch64 matches x86_64 byte for byte + OOM check")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
