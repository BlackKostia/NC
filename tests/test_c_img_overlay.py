#!/usr/bin/env python3
"""U1.7a: src/ui/img_overlay.c versus frozen x86_64 assembly (tests/harness/img_overlay_reference.s):
pixel-protocol (Sixel / Kitty) overlay state machine, emitted escape bytes, and rect invalidation.

OV1 differential (x86_64):
    - Kitty mark/ready tracking & reset on hide/remove
    - Sixel initial show, steady-state keep (rect_changed=0 vs rect_changed=1 resend),
      same-rect replacement (new key / new data), moved-rect invalidation, hide via absent show,
      hide via foreign active_dialog vs visible when active_dialog == owner
    - Kitty initial show, steady-state keep (no rect_changed check!), same-rect replacement,
      moved-rect deferred delete (d=A when tx_img==0 vs d=a when tx_img!=0), hide emits d=A,
      sync update markers ESC[?2026h / ESC[?2026l, cursor positioning ESC[row;colH
OV2 qemu-aarch64: matches x86_64 byte for byte
OV3 mutation check across img_overlay.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/img_overlay.c"
REF = "tests/harness/img_overlay_reference.s"
CORE = [
    "src/core/string.c", "src/core/memory.c", "src/core/syscall.c",
    "src/core/mem_prims.c", "src/core/string_format.c",
    "build/i18n_en.c",
]


def build(arch: str, t: Path, src_override: str | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "img_overlay_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "sys_write_all=fake_write_all",
            "--redefine-sym", "term_img_proto=fake_term_img_proto",
            "--redefine-sym", "ScreenBuffer_rect_changed=fake_rect_changed",
            "--redefine-sym", "ScreenBuffer_rect_invalidate=fake_rect_invalidate",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = src_override if src_override else str(ROOT / SRC)
    return H.build(arch, t, ["tests/harness/img_overlay_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DOV_SRC="{full}"'])


def build_script() -> str:
    return "\n".join([
        # Idle flush (nothing shown)
        "F",
        # Kitty mark / ready checks
        "R 1", "K 1", "R 1", "R 2", "K 0", "R 1",
        # Sixel lifecycle
        "P 2",
        "S 1 0 100 5 3 20 10", "F",        # initial Sixel emit at (6;4 -> ESC[4;6H)
        "C 0", "S 1 0 100 5 3 20 10", "F", # same Sixel, cells unchanged -> no emit
        "C 1", "S 1 0 100 5 3 20 10", "F", # same Sixel, cells changed -> resend!
        "S 1 1 100 5 3 20 10", "F",        # same rect, different data ptr -> replace without invalidate
        "S 1 1 101 5 3 20 10", "F",        # same rect, different key -> replace without invalidate
        "S 1 1 101 6 3 20 10", "F",        # moved x -> invalidate old rect + emit new
        "S 1 1 101 6 3 22 10", "F",        # resized w -> invalidate old rect + emit new
        # Dialog covers Sixel (owner=1, active_dialog=2 -> hidden + invalidate)
        "D 2", "S 1 1 101 6 3 22 10", "F",
        # Dialog owns Sixel (owner=2, active_dialog=2 -> visible)
        "S 2 0 200 1 2 10 8", "F",
        # Absent show -> hides Sixel + invalidates
        "D 0", "F",
        # Kitty lifecycle
        "P 3",
        "S 1 2 300 4 2 30 15", "F",        # initial Kitty emit
        "C 1", "S 1 2 300 4 2 30 15", "F", # same Kitty: no rect_changed check, no resend!
        "S 1 3 301 4 2 30 15", "F",        # same rect, new key -> direct replace (no del_on_emit)
        "S 1 3 301 8 2 30 15", "F",        # moved rect, tx_img==0 -> del_on_emit with d=A!
        "K 2", "R 2",
        "S 1 3 301 8 4 30 15", "F",        # moved rect, tx_img!=0 -> del_on_emit with d=a!
        "R 2",                             # tx_img preserved across placement move
        "F",                               # hide Kitty -> ov_remove emits d=A & clears tx_img!
        "R 2",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("\\x1b[?2026h", "\\x1b[?2026l", "\\x1b[4;6H", "SIXEL_A", "KITTY_PAYLOAD_1",
                   "\\x1b_Ga=d,d=A,q=2\\x1b\\", "\\x1b_Ga=d,d=a,q=2\\x1b\\",
                   "call rect_changed eq=1", "call rect_invalidate eq=1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] OV1. img_overlay matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("kitty-ready", "pixels == ov_kitty_tx_img", "pixels != ov_kitty_tx_img"),
        ("dlg-owner", "app->active_dialog == ov_cur.owner", "app->active_dialog != ov_cur.owner"),
        ("same-key", "ov_cur.key == ov_last.key", "1"),
        ("same-data", "ov_cur.data == ov_last.data", "1"),
        ("same-rect-x", "ov_cur.x == ov_last.x", "1"),
        ("same-rect-y", "ov_cur.y == ov_last.y", "1"),
        ("same-rect-w", "ov_cur.w == ov_last.w", "1"),
        ("sixel-keep", "ov_last_proto == IMG_PROTO_SIXEL", "ov_last_proto == IMG_PROTO_KITTY"),
        ("kitty-del-def", "ov_last_proto == IMG_PROTO_KITTY", "ov_last_proto == IMG_PROTO_SIXEL"),
        ("tx-clear", "ov_kitty_tx_img = nullptr;", "(void)app;"),
        ("del-kind", "ov_kitty_tx_img ? seq_kitty_del_p : seq_kitty_del", "seq_kitty_del"),
        ("row-1based", "ov_cur.y + 1u", "ov_cur.y"),
        ("col-1based", "ov_cur.x + 1u", "ov_cur.x"),
        ("reset-emit", "ov_emit = 0;", "ov_emit = 1;"),
    ]
    src_txt = (ROOT / SRC).read_text()
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src_txt and old != new, name
        mp = t / f"m{idx}" / "img_overlay.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src_txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", str(mp))
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] OV3. {len(muts)}/{len(muts)} mutants killed")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] OV2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
