#!/usr/bin/env python3
"""U1.7b: src/ui/{img_preview,img_quad,img_braille}.c versus frozen x86_64 assembly
(tests/harness/img_{preview,quad,braille}_reference.s): img_blend, img_draw_rgba (half-block),
img_draw_quad (2x2 quadrant), and img_draw_braille (2x4 Braille).

IC1 differential (x86_64):
    - solid black (#000000 -> #01010101 clamp), low/medium contrast (Braille 15 vs 16 lum threshold),
      rich 2x2 & 2x4 multi-pattern (all 8 quadrant masks + Braille >4 bit inversion + alpha blend),
      semi-transparent alpha gradient, checkerboard, odd dimensions (1x1, 3x5, 7x11, 13x19, 32x24),
      and degenerate/varied boxes (0x0, 1x1, 5x3, 18x9, 40x16) across all 3 renderers
IC2 qemu-aarch64: matches x86_64 byte for byte (exact FNV-1a cell grid hashes)
IC3 mutation check across all 3 C files
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = {
    "IMG_PREV_SRC": "src/ui/img_preview.c",
    "IMG_QUAD_SRC": "src/ui/img_quad.c",
    "IMG_BR_SRC": "src/ui/img_braille.c",
}
REFS = [
    "tests/harness/img_preview_reference.s",
    "tests/harness/img_quad_reference.s",
    "tests/harness/img_braille_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/core/try_rt.c",
    "src/fs/img_core.c", "src/fs/img_bmp.c", "src/fs/img_tga.c", "src/fs/img_pnm.c",
    "src/fs/img_gif.c", "src/fs/img_png.c", "src/fs/img_jpeg.c", "src/fs/inflate.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
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
        extra += objs
    defs = []
    for k, v in SRCS.items():
        p = (overrides or {}).get(k, v)
        full = p if Path(p).is_absolute() else str(ROOT / p)
        defs.append(f'-D{k}="{full}"')
    return H.build(arch, t, ["tests/harness/img_cells_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


def build_script() -> str:
    lines: list[str] = []
    configs = [
        (0, 4, 4, 0x01000000),      # pure black over pure black -> 0x01010101
        (1, 8, 8, 0x011A1B26),      # Braille lum range 15 (< 16 -> uniform 0x2800)
        (2, 8, 8, 0x011A1B26),      # Braille lum range 16 (>= 16 -> non-zero mask)
        (3, 32, 24, 0x011A1B26),    # rich pattern: all 8 quad masks + Braille inversion + alpha
        (4, 13, 19, 0x01223344),    # odd dims + alpha gradient
        (5, 1, 1, 0x01102030),      # 1x1 tiny
        (5, 3, 5, 0x01000000),      # odd small over pure black bg (hits qd_color(0))
        (3, 7, 11, 0x01304050),     # odd medium
    ]
    for kind, iw, ih, bg in configs:
        lines.append(f"I {kind} {iw} {ih} 0x{bg:x}")
        for mode in (0, 1, 2):
            for bx, by, bw, bh in ((0, 0, 0, 0), (2, 1, 5, 3), (1, 1, 18, 9), (2, 2, 40, 16)):
                lines.append(f"R {mode} {bx} {by} {bw} {bh}")
    return "\n".join(lines) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("ch=9600", "ch=10240", "fg=16843009 bg=16843009"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] IC1. img_preview + img_quad + img_braille match frozen asm across {len(out.splitlines())} renders")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("IMG_PREV_SRC", "blend-round", "(mix * 257u + 257u) >> 16", "(mix * 257u) >> 16"),
        ("IMG_PREV_SRC", "blend-black", "if (out == 0) out = 0x010101u;", "if (0 && out == 0) out = 0x010101u;"),
        ("IMG_PREV_SRC", "rgba-rows", "(dh + 1u) >> 1", "dh >> 1"),
        ("IMG_PREV_SRC", "rgba-bot-bg", "py + 1 < dh ? idr_sample(v, dw, dh, (uint32_t)cx, py + 1) : v->bg",
         "idr_sample(v, dw, dh, (uint32_t)cx, py)"),
        ("IMG_PREV_SRC", "rgba-glyph", "0x2580u", "0x2584u"),
        ("IMG_QUAD_SRC", "quad-cols", "(dw + 1u) >> 1", "dw >> 1"),
        ("IMG_QUAD_SRC", "quad-oob", "px >= dw || py >= dh", "px > dw || py > dh"),
        ("IMG_QUAD_SRC", "quad-best", "if (err < best_err)", "if (err <= best_err)"),
        ("IMG_QUAD_SRC", "quad-masks", "for (uint32_t mask = 0; mask <= 7; mask++)",
         "for (uint32_t mask = 0; mask < 7; mask++)"),
        ("IMG_QUAD_SRC", "quad-black", "return (c ? c : 0x010101u) | 0x01000000u;",
         "return c | 0x01000000u;"),
        ("IMG_BR_SRC", "br-rows", "(dh + 3u) >> 2", "dh >> 2"),
        ("IMG_BR_SRC", "br-lum-r", "r * 77u", "r * 70u"),
        ("IMG_BR_SRC", "br-thresh", "if (hi - lo < 16) return 0;", "if (hi - lo < 17) return 0;"),
        ("IMG_BR_SRC", "br-inv", "if (cnt > 4) mask = (~mask) & 0xFFu;", "if (cnt > 5) mask = (~mask) & 0xFFu;"),
        ("IMG_BR_SRC", "br-base", "0x2800u + mask", "0x2801u + mask"),
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
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] IC3. {len(muts)}/{len(muts)} mutants killed across all 3 image cell renderers")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] IC2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
