#!/usr/bin/env python3
"""U1.5: src/ui/dialogs_input_keys.c versus frozen x86_64 assembly
(tests/harness/dialogs_input_keys_reference.s): InputDialog_on_key line editing & UTF-8 cursor movement.

IK0 INPUT_MAX in include/duop_ui.h equals include/config.inc
IK1 differential (x86_64):
    - ASCII + 2/3/4-byte UTF-8 insertion at start, middle, end
    - KEY_LEFT / KEY_RIGHT stepping over UTF-8 continuation bytes, boundary no-ops (no dirty)
    - KEY_HOME / KEY_END
    - KEY_BACKSPACE / KEY_DELETE over ASCII & 2/3/4-byte UTF-8, boundary no-ops (no dirty)
    - Ctrl+U clears buffer; other Ctrl combos ignored without dirty
    - KEY_TAB toggles focus_btn; KEY_ENTER dispatches on_confirm (focus_btn==0) or on_cancel (focus_btn==1)
    - KEY_ESC dispatches on_cancel
    - INPUT_MAX - 1 capacity limit for 1-, 2-, and 4-byte UTF-8 characters
    - Out-of-range keys (< 0x20, > 0x10FFFF) ignored without dirty
IK2 qemu-aarch64: matches x86_64 byte for byte
IK3 mutation check across dialogs_input_keys.c
"""

import re
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/dialogs_input_keys.c"
REF = "tests/harness/dialogs_input_keys_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "build/i18n_en.c",
]

KEY_LEFT = 0x100003
KEY_RIGHT = 0x100004
KEY_HOME = 0x100005
KEY_END = 0x100006
KEY_DELETE = 0x10000A
KEY_BACKSPACE = 0x10000B
KEY_TAB = 0x10000C
KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F
MOD_CTRL = 4


def build(arch: str, t: Path, src_override: str | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "dialogs_input_keys_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra.append(o)
    full = src_override if src_override else str(ROOT / SRC)
    return H.build(arch, t, ["tests/harness/dialogs_input_keys_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DDIK_SRC="{full}"'])


def k(key: int, mods: int = 0) -> str:
    return f"K 0x{key:x} {mods}"


def build_script() -> str:
    lines: list[str] = []
    # Empty buffer boundary no-ops
    lines += [
        "R ",
        k(KEY_LEFT), k(KEY_RIGHT), k(KEY_BACKSPACE), k(KEY_DELETE),
        k(0x1F), k(0x110000),
        k(ord('a'), MOD_CTRL), k(KEY_ESC, MOD_CTRL),
    ]
    # Insert ASCII + 2-byte (П=0x041F) + 3-byte (日=0x65E5) + 4-byte (😀=0x1F600) + max Unicode (0x10FFFF)
    lines += [
        k(ord('A')), k(0x041F), k(0x65E5), k(0x1F600), k(0x10FFFF), k(ord('Z')),
        k(KEY_BACKSPACE), k(KEY_BACKSPACE), k(ord('Z')),
        # Step left across every multi-byte char down to 0, plus extra left at 0
        k(KEY_LEFT), k(KEY_LEFT), k(KEY_LEFT), k(KEY_LEFT), k(KEY_LEFT), k(KEY_LEFT),
        # Insert at start
        k(0x20),
        # Step right across every char up to end, plus extra right at end
        k(KEY_RIGHT), k(KEY_RIGHT), k(KEY_RIGHT), k(KEY_RIGHT), k(KEY_RIGHT), k(KEY_RIGHT), k(KEY_RIGHT),
        # Home, right 2, insert mid, backspace 3-byte/2-byte, delete 4-byte
        k(KEY_HOME), k(KEY_RIGHT), k(KEY_RIGHT), k(ord('!')),
        k(KEY_BACKSPACE), k(KEY_BACKSPACE),
        k(KEY_DELETE), k(KEY_DELETE),
        k(KEY_END), k(KEY_BACKSPACE),
    ]
    # Test backspace & delete on 2/3/4-byte UTF-8 directly
    lines += [
        "R aП日😀b",
        k(KEY_LEFT), k(KEY_BACKSPACE),   # delete 4-byte emoji via BS
        k(KEY_BACKSPACE),                # delete 3-byte CJK via BS
        k(KEY_HOME), k(KEY_RIGHT), k(KEY_DELETE),  # delete 2-byte Cyrillic via DEL
        k(KEY_END), k(KEY_DELETE),       # DEL at end (no-op)
    ]
    # Ctrl+U clear
    lines += [
        "R hello world",
        k(ord('u'), MOD_CTRL),
    ]
    # Tab + Enter + Esc virtual dispatch
    lines += [
        "R ok",
        k(KEY_ENTER),                    # focus_btn == 0 -> on_confirm
        k(KEY_TAB),                      # focus_btn -> 1
        k(KEY_ENTER),                    # focus_btn == 1 -> on_cancel
        k(KEY_TAB),                      # focus_btn -> 0
        k(KEY_ESC),                      # on_cancel
    ]
    # Capacity boundary: INPUT_MAX = 512, condition is len + n >= 511 -> reject (max len = 510)
    lines += [
        "F 509",
        k(0x041F),                       # 509 + 2 = 511 -> rejected
        k(ord('X')),                     # 509 + 1 = 510 -> accepted
        k(ord('Y')),                     # 510 + 1 = 511 -> rejected
        "F 507",
        k(0x1F600),                      # 507 + 4 = 511 -> rejected
        "F 506",
        k(0x1F600),                      # 506 + 4 = 510 -> accepted
    ]
    return "\n".join(lines) + "\n"


def test_constants() -> None:
    inc = (ROOT / "include/config.inc").read_text()
    hdr = (ROOT / "include/duop_ui.h").read_text()
    a = re.search(r"^\.equ INPUT_MAX,\s*(\d+)", inc, re.M)
    b = re.search(r"^#define INPUT_MAX (\d+)", hdr, re.M)
    assert a and b and a.group(1) == b.group(1), (a and a.group(1), b and b.group(1))
    print("[PASS] IK0. INPUT_MAX in duop_ui.h equals config.inc")


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("call on_confirm 1 0", "call on_cancel 1 0", "len=510 cur=510", "fb=1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] IK1. InputDialog_on_key matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("ctrl-u", "key == 'u'", "key == 'k'"),
        ("ctrl-mod", "mods & MOD_CTRL", "0 && (mods & MOD_CTRL)"),
        ("tab-xor", "dlg->base.focus_btn ^= 1;", "dlg->base.focus_btn = 0;"),
        ("enter-fb", "dlg->base.focus_btn == 0", "dlg->base.focus_btn != 0"),
        ("utf8-cont-l", "(dlg->buf[c] & 0xC0u) == 0x80u", "(dlg->buf[c] & 0xC0u) == 0xC0u"),
        ("utf8-cont-r", "(dlg->buf[c] & 0xC0u) == 0x80u", "0 && ((dlg->buf[c] & 0xC0u) == 0x80u)"),
        ("min-print", "key < 0x20u", "key <= 0x20u"),
        ("max-print", "key > 0x10FFFFu", "key >= 0x100000u"),
        ("cap-limit", "dlg->len + (uint32_t)n >= INPUT_MAX - 1", "dlg->len + (uint32_t)n > INPUT_MAX - 1"),
        ("nul-move-ins", "dlg->len - dlg->cursor + 1", "dlg->len - dlg->cursor"),
        ("bs-zero", "if (dlg->cursor == 0) return 0;", "if (dlg->cursor > 1000) return 0;"),
        ("del-end", "if (dlg->cursor >= dlg->len) return 0;", "if (dlg->cursor > dlg->len) return 0;"),
        ("dirty-flag", "app->need_redraw = 1;", "app->need_redraw = 0;"),
    ]
    src_txt = (ROOT / SRC).read_text()
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src_txt and old != new, name
        mp = t / f"m{idx}" / "dialogs_input_keys.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src_txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", str(mp))
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] IK3. {len(muts)}/{len(muts)} mutants killed")


def main() -> None:
    test_constants()
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] IK2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
