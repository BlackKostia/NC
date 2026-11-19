#!/usr/bin/env python3
"""U3.3: src/ui/hex_edit.c versus frozen x86_64 assembly
(tests/harness/hex_edit_reference.s): hex_edit_free and hex_edit_on_key.

HE1 differential (x86_64):
    - inactive when hex_mode==0 or edit mode off (except 'e'/'E' without Ctrl/Alt)
    - 'e'/'E' allocates HexEditCtx, copies mmap -> heap + os_munmap, sets cursor=hex_row<<4;
      OOM on ctx alloc and OOM on writable-copy alloc return 0 cleanly
    - nibble entry (0-9, a-f, A-F): high nibble pushes undo ring + sets nibble=1 + dirty=1;
      low nibble writes low 4 bits + advances cursor (clamped at data_len-1); invalid char -> 0
    - navigation: KEY_LEFT (clamped at 0, resets nibble), KEY_RIGHT (clamped at data_len-1, resets nibble)
    - Ctrl+Z: pops undo ring, restores byte + cursor + nibble=0; empty undo ring still redraws
    - Ctrl+S: calls fs_write_file; ok clears dirty=0; err calls fs_errno_message(-EIO) + App_set_status
    - Ctrl+other -> 0; Alt+'e' does not toggle; hex_edit_free frees ctx & NULLs pointer (and NULL-safe)
HE2 qemu-aarch64 matches x86_64 byte for byte
HE3 mutation check across src/ui/hex_edit.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/hex_edit.c"
REF = "tests/harness/hex_edit_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
]

KEY_LEFT = 0x100003
KEY_RIGHT = 0x100004
MOD_ALT = 2
MOD_CTRL = 4


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "hex_edit_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "os_munmap=fake_os_munmap",
            "--redefine-sym", "fs_write_file=fake_fs_write_file",
            "--redefine-sym", "fs_errno_message=fake_fs_errno_message",
            "--redefine-sym", "mem_alloc=fake_mem_alloc",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/hex_edit_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DHE_SRC="{full}"'])


def build_script() -> str:
    # V hex_mode use_mmap data_len hex_row
    # E fail_alloc write_rc
    return "\n".join([
        # 1. hex_mode == 0 ignores everything; hex_edit_free on NULL is safe
        "V 0 1 4 0",
        "F",
        f"K 0x{ord('e'):x} 0",
        # 2. OOM on ctx alloc & OOM on mmap->heap copy
        "V 1 1 4 0",
        "E 1 0",
        f"K 0x{ord('e'):x} 0",
        "E 2 0",
        f"K 0x{ord('e'):x} 0",
        "E 0 0",
        # 3. Alt+e / Ctrl+e don't toggle when inactive
        "V 1 1 4 0",
        f"K 0x{ord('e'):x} {MOD_ALT}",
        f"K 0x{ord('e'):x} {MOD_CTRL}",
        f"K 0x{ord('a'):x} 0",       # inactive ignores nibbles
        # 4. Toggle on with 'e' (copies mmap -> heap + os_munmap), enter nibbles 0-9, a-f, A-F
        f"K 0x{ord('e'):x} 0",
        f"K 0x{KEY_LEFT:x} 0",       # clamped at 0
        f"K 0x{ord('9'):x} 0",       # high nibble of byte 0 -> 0x90
        f"K 0x{ord('a'):x} 0",       # low nibble of byte 0 -> 0x9a, cursor -> 1
        f"K 0x{ord('F'):x} 0",       # high nibble of byte 1 -> 0xf1
        f"K 0x{ord('0'):x} 0",       # low nibble of byte 1 -> 0xf0, cursor -> 2
        f"K 0x{ord('g'):x} 0",       # invalid nibble -> 0
        f"K 0x{ord('G'):x} 0",       # invalid nibble -> 0
        f"K 0x{ord('A'):x} 0",       # high nibble of byte 2 -> 0xa2, nibble=1
        f"K 0x{KEY_RIGHT:x} 0",      # moves to 3, resets nibble=0
        f"K 0x{KEY_RIGHT:x} 0",      # clamped at 3 (data_len-1)
        f"K 0x{ord('b'):x} 0",       # high nibble of byte 3
        f"K 0x{ord('c'):x} 0",       # low nibble of byte 3, cursor stays 3 (at end)
        f"K 0x{KEY_LEFT:x} 0",       # cursor -> 2
        f"K 0x{KEY_LEFT:x} 0",       # cursor -> 1
        f"K 0x{KEY_LEFT:x} 0",       # cursor -> 0
        # 5. Ctrl+Z undo x4 (including empty undo ring)
        f"K 0x{ord('z'):x} {MOD_CTRL}",
        f"K 0x{ord('z'):x} {MOD_CTRL}",
        f"K 0x{ord('z'):x} {MOD_CTRL}",
        f"K 0x{ord('z'):x} {MOD_CTRL}",
        f"K 0x{ord('z'):x} {MOD_CTRL}",  # undo_cnt == 0
        # 6. Ctrl+S save error & save ok, Ctrl+x unhandled
        f"K 0x{ord('x'):x} {MOD_CTRL}",
        "E 0 -1",
        f"K 0x{ord('s'):x} {MOD_CTRL}",
        "E 0 0",
        f"K 0x{ord('s'):x} {MOD_CTRL}",
        # 7. Toggle off with 'E', toggle on again with hex_row=1 -> cursor=16
        f"K 0x{ord('E'):x} 0",
        f"K 0x{ord('a'):x} 0",       # inactive again -> 0
        "V 1 0 20 1",
        f"K 0x{ord('E'):x} 0",       # heap data, hex_row=1 -> cursor=16
        "F",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("call os_munmap eq=1 len=4", "data=9af0a2bc", "data=10111213",
                   "call fs_write_file p=/tmp/edit.bin len=4", "call fs_errno_message -5",
                   "call App_set_status 1 k=3 |I/O error|", "cur=16", "ctx=NULL"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] HE1. hex_edit matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("mode-chk", "if (vd->hex_mode == 0) return 0;", "if (0) return 0;"),
        ("tog-mods", "if (!(mods & (MOD_CTRL | MOD_ALT)) && (key == 'e' || key == 'E'))",
         "if (key == 'e' || key == 'E')"),
        ("tog-cur", "ctx->cursor = vd->hex_row << 4;", "ctx->cursor = vd->hex_row;"),
        ("parse-af", "if (ch >= 'a' && ch <= 'f') return (int)(ch - 'a' + 10);",
         "if (ch >= 'a' && ch <= 'f') return (int)(ch - 'a' + 11);"),
        ("parse-AF", "if (ch >= 'A' && ch <= 'F') return (int)(ch - 'A' + 10);",
         "if (ch >= 'A' && ch <= 'F') return (int)(ch - 'A' + 11);"),
        ("undo-mask", "ctx->undo_ring[ctx->undo_cnt & 63u]", "ctx->undo_ring[0]"),
        ("save-ok", "ctx->dirty = 0;", "ctx->dirty = 1;"),
        ("nav-left", "if (ctx->cursor > 0) { ctx->cursor--; ctx->nibble = 0; }",
         "if (ctx->cursor > 1) { ctx->cursor--; ctx->nibble = 0; }"),
        ("nav-right", "if (ctx->cursor + 1 < vd->data_len)", "if (ctx->cursor + 2 < vd->data_len)"),
        ("nib-hi", "(cur & 0x0Fu) | ((uint32_t)nib << 4)", "(cur & 0xF0u) | ((uint32_t)nib << 4)"),
        ("nib-lo", "(cur & 0xF0u) | (uint32_t)nib", "(cur & 0x0Fu) | (uint32_t)nib"),
        ("mmap-clr", "vd->map_len = 0;", "vd->map_len = 1;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "hex_edit.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] HE3. {len(muts)}/{len(muts)} mutants killed across hex_edit.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] HE2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
