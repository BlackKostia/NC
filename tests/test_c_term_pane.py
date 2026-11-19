#!/usr/bin/env python3
"""U3.7: src/ui/term_pane.c versus frozen x86_64 assembly
(tests/harness/term_pane_reference.s): term_height, term_toggle, term_poll_read,
term_render, and globals g_term_visible / g_term_inited / g_term_fd.

TP1 differential (x86_64):
    - term_height: hidden -> 0, main_h < 9 -> 0, 9..17 -> 6, 24 -> 8
    - term_toggle: OOM on buffer alloc stays closed + sets ENOMEM status; first toggle spawns PTY,
      records cwd, registers aux fd 3; hide + change cwd (with single quotes!) + show sends
      escaped `cd '...'\\r` via os_pty_write; same cwd skips write
    - term_poll_read & term_put_byte: tabs, BS/DEL, CR, LF, CSI & OSC & non-CSI escapes,
      auto line-wrap at vis_w, 50-line scroll-up over TERM_ROWS=48
    - term_render: hidden/narrow/short no-op, box + title + visible rows + inverted cursor cell
TP2 qemu-aarch64 matches x86_64 byte for byte
TP3 mutation check across src/ui/term_pane.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/term_pane.c"
REF = "tests/harness/term_pane_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
]


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "term_pane_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "fs_errno_message=fake_fs_errno_message",
            "--redefine-sym", "input_set_aux_fd=fake_input_set_aux_fd",
            "--redefine-sym", "os_pty_spawn=fake_os_pty_spawn",
            "--redefine-sym", "os_pty_read=fake_os_pty_read",
            "--redefine-sym", "os_pty_write=fake_os_pty_write",
            "--redefine-sym", "mem_alloc=fake_mem_alloc",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/term_pane_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DTP_SRC="{full}"'])


def build_script() -> str:
    # E fail_alloc spawn_rc term_w term_h
    return "\n".join([
        # Hidden: height=0, poll no-op, render hidden
        "H 24",
        "P 0",
        "R",
        # OOM on buffer alloc -> stays closed + ENOMEM status
        "E 1 0 60 24",
        "T",
        # Normal toggle -> spawns PTY at /tmp/work (58x5)
        "E 0 0 60 24",
        "T",
        "H 8", "H 9", "H 17", "H 24",
        # Feed ANSI/CSI/OSC/tabs/BS + render
        "P 0",
        "R",
        # Feed wrap + control byte + render
        "P 1",
        "R",
        # Feed 50 newlines -> scroll_up + render with cursor
        "P 2",
        "R",
        # Narrow term_w=3 skips render; short term_h=10 skips render
        "E 0 0 3 24",
        "R",
        "E 0 0 60 24",
        # Toggle off, change cwd with single quote, toggle on -> cd '/tmp/a'\''b'\r
        "T",
        "C /tmp/a'b",
        "T",
        # Toggle off, same cwd, toggle on -> no cd write
        "T",
        "T",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("call fs_errno_message -12", "call os_pty_spawn cwd=/tmp/work sz=58x5",
                   "call input_set_aux_fd slot=3 fd=7", "H 8 -> 0", "H 9 -> 6", "H 24 -> 8",
                   "hi      worl!", "CSI OSC ok", "Prompt>",
                   "cd '/tmp/a'\\x5c''b'\\x0d"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] TP1. term_pane matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("ht-min9", "if (!g_term_visible || main_h < 9) return 0;", "if (!g_term_visible || main_h < 12) return 0;"),
        ("ht-min6", "return h >= 6 ? h : 6;", "return h >= 4 ? h : 4;"),
        ("esc-csi", "if (b == '[') g_term_esc = 2;", "if (0) g_term_esc = 2;"),
        ("esc-osc", "else if (b == ']') g_term_esc = 3;", "else if (0) g_term_esc = 3;"),
        ("tab-8", "g_term_cx = (g_term_cx + 8) & ~7;", "g_term_cx = (g_term_cx + 4) & ~3;"),
        ("bs-dec", "if (g_term_cx > 0) g_term_cx--;", "if (0) g_term_cx--;"),
        ("wrap-lf", "if (g_term_cx >= w) { g_term_cx = 0; term_lf(); }", "if (0) { g_term_cx = 0; term_lf(); }"),
        ("scroll-up", "mem_copy(g_term_buf, g_term_buf + TERM_COLS, TERM_COLS * (TERM_ROWS - 1));",
         "(void)0;"),
        ("cwd-quote", "if (ch == '\\'')", "if (0)"),
        ("tog-aux", "input_set_aux_fd(3, g_term_fd);", "input_set_aux_fd(2, g_term_fd);"),
        ("ren-y0", "int y0 = (int)app->term_h - 2 - th;", "int y0 = (int)app->term_h - 1 - th;"),
        ("cur-inv", "ScreenBuffer_set_cell(scr, col, y0 + rel + 1, cp, theme->surface, theme->text);",
         "ScreenBuffer_set_cell(scr, col, y0 + rel + 1, cp, theme->text, theme->surface);"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "term_pane.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] TP3. {len(muts)}/{len(muts)} mutants killed across term_pane.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] TP2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
