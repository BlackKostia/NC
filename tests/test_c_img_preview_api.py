#!/usr/bin/env python3
"""U1.7c: src/ui/img_preview_api.c versus frozen x86_64 assembly
(tests/harness/img_preview_api_reference.s): img_preview_try_render placement & dispatch.

IPA1 differential (x86_64):
    - thumb_len < IMG_THUMB_HDR -> 0
    - tw == 0 -> draws LS_img_unsup warning, returns 1
    - IMG_PROTO_QUAD / IMG_PROTO_HALF -> dispatches img_draw_quad / img_draw_rgba with exact box & ImgView
    - IMG_PROTO_SIXEL / IMG_PROTO_KITTY with thumb_len == 31 (< 32) -> draws LS_img_unsup, returns 1
    - IMG_PROTO_SIXEL / IMG_PROTO_KITTY with thumb_len >= 32 -> computes centred ImgPlace and calls img_overlay_show
IPA2 C fixes div-by-zero in iptr_place when pv_box_pixels returns (0, 0) (narrow/short pane)
IPA3 qemu-aarch64: matches x86_64 byte for byte
IPA4 mutation check across img_preview_api.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/img_preview_api.c"
REF = "tests/harness/img_preview_api_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
]


def build(arch: str, t: Path, src_override: str | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "img_preview_api_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "pv_box_pixels=fake_pv_box_pixels",
            "--redefine-sym", "img_draw_quad=fake_img_draw_quad",
            "--redefine-sym", "img_draw_rgba=fake_img_draw_rgba",
            "--redefine-sym", "img_overlay_show=fake_img_overlay_show",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = src_override if src_override else str(ROOT / SRC)
    return H.build(arch, t, ["tests/harness/img_preview_api_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DIPA_SRC="{full}"'])


def build_script() -> str:
    return "\n".join([
        # Not ready (< 16 bytes) vs exact 16-byte header
        "T 2 1 42 15 0 0 1 10 10",
        "T 2 1 42 15 15 0 1 10 10",
        "T 2 1 42 15 16 0 2 0 0",
        # Unsupported (tw == 0)
        "T 2 1 42 15 64 0 2 0 10",
        # Quad mode (0) & Half mode (1)
        "T 2 1 42 15 64 0 3 80 40",
        "T 4 2 30 12 64 1 4 28 14",
        # Pixel modes with payload too short (31 < 32)
        "T 2 1 42 15 31 2 5 120 80",
        "T 2 1 42 15 31 3 6 120 80",
        # Sixel (2) & Kitty (3) placement calculations with varied box pixel sizes
        "B 240 180",
        "T 2 1 42 15 32 2 7 120 90",
        "T 2 1 42 15 100 3 8 240 180",
        "B 300 200",
        "T 5 2 32 15 88 2 9 101 55",
        "T 0 0 50 15 96 3 10 150 200",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("T rc=0\n", "call draw_quad", "call draw_rgba", "call overlay_show", "warn_fg/surface"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] IPA1. img_preview_try_render matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_divzero_fix(exe: Path) -> None:
    s = b"B 0 0\nT 0 0 2 5 64 2 1 100 50\n"
    r = H.run_impl("x86_64", exe, "c", stdin=s)
    assert r.returncode == 0 and b"T rc=1\n" in r.stdout and b"overlay_show" not in r.stdout, r
    print("[PASS] IPA2. C guards pv_box_pixels=(0,0) cleanly (fixes asm SIGFPE div-by-zero)")


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("hdr-len", "pv->thumb_len < IMG_THUMB_HDR", "pv->thumb_len <= IMG_THUMB_HDR"),
        ("tw-zero", "if (tw == 0)", "if (tw == 9999)"),
        ("proto-cmp", "mode >= IMG_PROTO_SIXEL", "mode > IMG_PROTO_SIXEL"),
        ("half-cmp", "mode == IMG_PROTO_HALF", "mode != IMG_PROTO_HALF"),
        ("px-min", "pv->thumb_len < IMG_THUMB_HDR + 16", "pv->thumb_len <= IMG_THUMB_HDR + 16"),
        ("ceil-w", "box_px_w - 1u", "box_px_w"),
        ("ceil-h", "box_px_h - 1u", "box_px_h"),
        ("center-x", "pv->base.x + 1 +", "pv->base.x + 2 +"),
        ("center-y", "pv->base.y + 3 +", "pv->base.y + 4 +"),
        ("box-w", "pv->base.w - 2", "pv->base.w - 3"),
        ("box-h", "pv->base.h - 5", "pv->base.h - 4"),
    ]
    src_txt = (ROOT / SRC).read_text()
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src_txt and old != new, name
        mp = t / f"m{idx}" / "img_preview_api.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src_txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", str(mp))
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] IPA4. {len(muts)}/{len(muts)} mutants killed")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_divzero_fix(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] IPA3. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
