#!/usr/bin/env python3
"""U0b (ui_event.h, ui_app_stub.h, perf_gate) + U1.1 leaf UI helpers versus frozen x86_64 assembly:
  src/ui/popup_osc52.c, term_keys.c, term_pane_input.c, preview_pane_mouse.c, header_bar_git.c.

UL0 constants (RIGHT_MODE_*) in include/duop_ui.h equal include/config.inc
UL1 differential (x86_64):
    - osc52_copy_text: nullptr, empty, len 1/2/3/4 (padding = / == / none), UTF-8, 300-byte string
    - term_key_encode: all 15 special keys KEY_UP..KEY_ESC, F1..F12 -> -1, out-of-range codepoints >= 0x110000 -> 0,
      Alt/Ctrl/Alt+Ctrl/Shift combinations around 0x1F/0x20/0x7E/0x7F and UTF-8
    - term_on_key & term_shutdown: invisible, Ctrl+` toggle vs Ctrl+Alt+`, negative fd, F-keys pass-through,
      swallowed codepoints, normal PTY write, shutdown when uninited / fd<0 / active fd
    - PreviewPane_on_mouse: non-wheel actions, wheel up clamping at 0, wheel down clamping in text and binary modes
    - hdr_draw_mode_and_git: widths 0/29/30/31/80, x/y offsets, dual vs preview mode, wide Unicode brand, git_badge args
UL2 OOM safety fix in popup_osc52.c (asm lacked NULL check on mem_alloc; C returns cleanly without crash)
UL3 qemu-aarch64: C modules match x86_64 byte for byte
UL4 mutation check across all 5 C modules
"""

import re
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = {
    "OSC52_SRC": "src/ui/popup_osc52.c",
    "TKEYS_SRC": "src/ui/term_keys.c",
    "TINPUT_SRC": "src/ui/term_pane_input.c",
    "PMOUSE_SRC": "src/ui/preview_pane_mouse.c",
    "HGIT_SRC": "src/ui/header_bar_git.c",
}
REFS = [
    "tests/harness/popup_osc52_reference.s",
    "tests/harness/term_keys_reference.s",
    "tests/harness/term_pane_input_reference.s",
    "tests/harness/preview_pane_mouse_reference.s",
    "tests/harness/header_bar_git_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
]


def build(arch: str, t: Path, overrides: dict[str, str] | None = None) -> Path:
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
        redefs = ["--redefine-sym", "sys_write_all=fake_write_all",
                  "--redefine-sym", "os_pty_write=fake_pty_write",
                  "--redefine-sym", "os_pty_close=fake_pty_close"]
        for o in objs:
            subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra += objs
    defs = []
    for k, v in SRCS.items():
        p = (overrides or {}).get(k, v)
        full = p if Path(p).is_absolute() else str(ROOT / p)
        defs.append(f'-D{k}="{full}"')
    return H.build(arch, t, ["tests/harness/ui_leaf1_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


def build_script() -> str:
    lines: list[str] = []
    # 1. OSC 52
    lines += ["O!", "O ", "O a", "O ab", "O abc", "O abcd", "O Hello, World! Привіт ✓", "O " + "0123456789abcdef" * 19]
    # 2. term_key_encode
    for key in range(0x100001, 0x100015):
        lines.append(f"E 0x{key:x} 0")
    for key in (0x100000, 0x10FFFF, 0x110000, 0x200000):
        lines.append(f"E 0x{key:x} 0")
    for key in (0x00, 0x1F, 0x20, 0x41, 0x61, 0x7E, 0x7F, 0x041F, 0x1F600):
        for mods in (0, 1, 2, 4, 6):
            lines.append(f"E 0x{key:x} {mods}")
    # 3. term_on_key & term_shutdown
    lines += [
        "T 0 0 -1", "K 0x61 0", "S",
        "T 0 1 7", "K 0x60 4", "S",
        "T 1 1 9", "K 0x60 4", "K 0x60 6", "K 0x60 0",
        "K 0x100011 0", "K 0x110000 0", "K 0x100001 0", "K 0x63 4", "K 0x41 2",
        "T 1 1 -1", "K 0x61 0", "S",
        "T 1 1 0", "K 0x61 0",
        "T 1 0 5", "S",
        "T 1 1 12", "S", "S",
    ]
    # 4. PreviewPane_on_mouse
    lines += [
        "P 5 20 0 0", "M 1 0 3 4", "M 2 0 3 4", "M 3 0 3 4", "M 4 0 3 4",
        "P 0 20 0 0", "M 5 64 1 1",
        "P 2 20 0 0", "M 5 64 1 1",
        "P 3 20 0 0", "M 5 64 1 1",
        "P 10 20 0 0", "M 5 64 1 1",
        "P 0 0 0 0", "M 5 65 1 1",
        "P 0 1 0 0", "M 5 65 1 1",
        "P 0 2 0 0", "M 5 65 1 1",
        "P 16 20 0 0", "M 5 65 1 1", "M 5 65 1 1",
        "P 0 99 1 0", "M 5 65 1 1",
        "P 0 99 1 7", "M 5 65 1 1",
        "P 0 99 1 8", "M 5 65 1 1",
        "P 0 99 1 32", "M 5 65 1 1", "M 5 65 1 1",
    ]
    # 5. hdr_draw_mode_and_git
    for w in (0, 29, 30, 31, 60, 100):
        for rm in (0, 1):
            lines.append(f"H 0 0 {w} {rm}")
    lines += ["H 4 2 80 0", "H 4 2 80 1", "B 日本Duop", "H 2 1 60 1"]
    return "\n".join(lines) + "\n"


def test_constants() -> None:
    inc = (ROOT / "include/config.inc").read_text()
    hdr = (ROOT / "include/duop_ui.h").read_text()
    for name in ("RIGHT_MODE_PANE", "RIGHT_MODE_PREVIEW"):
        a = re.search(rf"^\.equ {name},\s*(\d+)", inc, re.M)
        b = re.search(rf"^#define {name} (\d+)", hdr, re.M)
        assert a and b and a.group(1) == b.group(1), (name, a and a.group(1), b and b.group(1))
    print("[PASS] UL0. RIGHT_MODE_* constants in duop_ui.h equal config.inc")


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode(errors="backslashreplace")
    for needle in ("\\x1b]52;c;YQ==\\x07", "\\x1b]52;c;YWI=\\x07", "\\x1b]52;c;YWJj\\x07",
                   "call term_toggle 1 0", "call pty_write fd=9", "call pty_close 12 0",
                   "call git_badge eq=1", "scroll=19", "scroll=3"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] UL1. All 5 leaf UI modules match frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_oom(exe: Path) -> None:
    res = H.run_impl("x86_64", exe, "c", stdin=b"A 1\nO hello\n")
    assert res.returncode == 0 and b"O done\n" in res.stdout and b"write_all" not in res.stdout, res
    print("[PASS] UL2. osc52_copy_text handles mem_alloc OOM cleanly (fixes asm NULL deref)")


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("OSC52_SRC", "null-check", "if (!str) return;", "if (0 && !str) return;"),
        ("OSC52_SRC", "pad1", "n >= 2 ?", "n >= 3 ?"),
        ("OSC52_SRC", "pad2", "n >= 3 ?", "n >= 2 ?"),
        ("OSC52_SRC", "bel-byte", "buf[pos++] = 7;", "buf[pos++] = 8;"),
        ("TKEYS_SRC", "special-lo", "key >= KEY_UP", "key > KEY_UP"),
        ("TKEYS_SRC", "special-hi", "key > KEY_ESC", "key >= KEY_ESC"),
        ("TKEYS_SRC", "unicode-cap", "key >= 0x110000u", "key >= 0x100000u"),
        ("TKEYS_SRC", "alt-esc", "mods & MOD_ALT", "0 && (mods & MOD_ALT)"),
        ("TKEYS_SRC", "ctrl-lo", "key >= 0x20u", "key > 0x20u"),
        ("TKEYS_SRC", "ctrl-hi", "key <= 0x7Eu", "key < 0x7Eu"),
        ("TINPUT_SRC", "vis-guard", "if (!g_term_visible) return 0;", "if (0 && !g_term_visible) return 0;"),
        ("TINPUT_SRC", "toggle-mod", "e->mods == MOD_CTRL", "(e->mods & MOD_CTRL) != 0"),
        ("TINPUT_SRC", "fd-neg", "if (g_term_fd < 0) return 1;", "if (g_term_fd <= 0) return 1;"),
        ("TINPUT_SRC", "shut-inited", "if (!g_term_inited || g_term_fd < 0) return;", "if (g_term_fd < 0) return;"),
        ("TINPUT_SRC", "shut-reset", "g_term_fd = -1;", "g_term_fd = 0;"),
        ("PMOUSE_SRC", "wheel-kind", "e->mouse_kind != MACT_WHEEL", "e->mouse_kind == 0"),
        ("PMOUSE_SRC", "up-clamp", "if (scroll < 0) scroll = 0;", "if (scroll < -1) scroll = 0;"),
        ("PMOUSE_SRC", "bin-shift", "p->buf_len >> 3", "p->buf_len >> 4"),
        ("PMOUSE_SRC", "max-dec", "max--;", "max -= 2;"),
        ("HGIT_SRC", "min-w", "hb->base.w < 30", "hb->base.w <= 30"),
        ("HGIT_SRC", "mode-cmp", "app->right_mode == RIGHT_MODE_PREVIEW", "app->right_mode != RIGHT_MODE_PREVIEW"),
        ("HGIT_SRC", "badge-x", "x + mw + 1", "x + mw"),
    ]
    survivors: list[str] = []

    def check(idx: int, macro: str, name: str, old: str, new: str) -> None:
        src = ROOT / SRCS[macro]
        txt = src.read_text()
        assert old in txt and old != new, (name, src)
        mp = t / f"m{idx}" / src.name
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", {macro: str(mp)})
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode(errors="backslashreplace") == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] UL4. {len(muts)}/{len(muts)} mutants killed across all 5 leaf UI modules")


def main() -> None:
    test_constants()
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_oom(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode(errors="backslashreplace") == out, "aarch64 differs"
            print("[PASS] UL3. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
