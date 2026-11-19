#!/usr/bin/env python3
"""U3.1: src/ui/viewer_pixels.c versus frozen x86_64 assembly
(tests/harness/viewer_pixels_reference.s): vim_draw_picture and vim_place.

VP1 differential (x86_64):
    - Quad / Half / Braille output: fit (zoom=0) and zoomed (centering smaller thumb box),
      thumb cache hit & cache miss on pan/zoom/size, OOM on thumb alloc, degenerate box
    - Sixel output: encode + cache hit + vim_place + img_overlay_show, OOM on enc alloc
    - Kitty output: known cell_px (cols=0), unknown cell_px (cols=ceil(tw*kc/bw), clamped 255),
      vim_kitty_pan short-circuit returning 1
    - vim_place direct: normal box and zero/negative box clamped to 1
VP2 qemu-aarch64 matches x86_64 byte for byte
VP3 mutation check across src/ui/viewer_pixels.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/viewer_pixels.c"
REF = "tests/harness/viewer_pixels_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/core/try_rt.c",
    "src/fs/img_core.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/viewer_zoom_rect.c",
]

BOX_PX_TRAMPOLINE_X86 = """\
.intel_syntax noprefix
.section .text
.global img_box_pixels
img_box_pixels:
    sub rsp, 24
    mov rcx, rsp
    call stub_box_px
    mov eax, [rsp]
    mov edx, [rsp + 4]
    mov ecx, [rsp + 8]
    add rsp, 24
    ret
"""


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        tr_s = t / "box_px_trampoline.s"
        tr_o = t / "box_px_trampoline.o"
        tr_s.write_text(BOX_PX_TRAMPOLINE_X86)
        subprocess.run(["as", str(tr_s), "-o", str(tr_o)], check=True, capture_output=True)
        extra.append(tr_o)

        o = t / "viewer_pixels_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "vim_kitty_pan=fake_vim_kitty_pan",
            "--redefine-sym", "img_overlay_show=fake_img_overlay_show",
            "--redefine-sym", "img_draw_rgba=fake_img_draw_rgba",
            "--redefine-sym", "img_draw_quad=fake_img_draw_quad",
            "--redefine-sym", "img_draw_braille=fake_img_draw_braille",
            "--redefine-sym", "img_scale_rect=fake_img_scale_rect",
            "--redefine-sym", "img_sixel_encode=fake_img_sixel_encode",
            "--redefine-sym", "img_kitty_encode=fake_img_kitty_encode",
            "--redefine-sym", "mem_alloc=fake_mem_alloc",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/viewer_pixels_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DVP_SRC="{full}"'])


def build_script() -> str:
    # V x y w h iw ih zoom braille pan_x pan_y
    # Z zoom braille pan_x pan_y
    # E proto cw ch kitty_pan_ret fail_alloc
    return "\n".join([
        # Quad fit + cache hit + pan cache miss
        "V 2 1 42 23 32 24 0 0 0 0",
        "E 0 0 0 0 0",
        "D",
        "D",                         # cache hit (no second img_scale_rect)
        "Z 100 0 3 4",               # zoomed small image -> centered in quad box
        "D",
        # Half-block fit & zoomed
        "E 1 0 0 0 0",
        "Z 0 0 0 0",
        "D",
        "Z 100 0 0 0",               # zoomed half-block (cw = thumb_w, no >>1)
        "D",
        # Braille (fit & zoomed)
        "E 0 0 0 0 0",
        "Z 0 1 0 0",
        "D",
        "Z 100 1 0 0",               # zoomed braille (ch = (thumb_h + 3) >> 2)
        "D",
        # Sixel encode + cache hit + OOM on enc
        "V 2 1 42 23 64 48 0 0 0 0",
        "E 2 8 16 0 0",
        "D",
        "D",                         # enc cache hit (no second img_sixel_encode)
        "V 2 1 42 23 64 48 0 0 0 0",
        "E 2 8 16 0 2",              # thumb alloc ok, enc alloc OOM
        "D",
        # Kitty: known cell_px (cols=0)
        "V 2 1 42 23 64 48 0 0 0 0",
        "E 3 10 20 0 0",
        "D",
        # Kitty: unknown cell_px (cw=0, ch=0 -> kc=cols, cols=ceil(tw*kc/bw))
        "V 2 1 42 23 64 48 0 0 0 0",
        "E 3 0 0 0 0",
        "D",
        # Kitty: very wide box (cols=280 -> kc clamped to 255)
        "V 0 0 282 23 64 48 0 0 0 0",
        "E 3 0 0 0 0",
        "D",
        # Kitty: vim_kitty_pan returns 1 -> short-circuit
        "E 3 10 20 1 0",
        "D",
        # OOM on thumb alloc
        "V 2 1 42 23 64 48 0 0 0 0",
        "E 0 0 0 0 1",
        "D",
        # Degenerate zero box (w=2 -> cols=0 -> bw=0, bh=0)
        "V 2 1 2 3 64 48 0 0 0 0",
        "E 0 0 0 0 0",
        "D",
        # Direct vim_place with valid & non-positive box
        "V 2 1 42 23 64 48 0 0 0 0",
        "E 2 8 16 0 0",
        "D",
        "P 320 320",
        "P 0 -5",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("call img_draw_quad", "call img_draw_rgba", "call img_draw_braille",
                   "call img_sixel_encode", "call img_kitty_encode 64x48 cols=0",
                   "call img_kitty_encode 64x48 cols=7", "call img_overlay_show len=42",
                   "call img_overlay_show len=77", "P rect="):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] VP1. viewer_pixels matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("braille-h", "bh = (int)((uint32_t)rows << 2);", "bh = (int)((uint32_t)rows << 1);"),
        ("kcols-cap", "kcols = cols > 255 ? 255 : cols;", "kcols = cols;"),
        ("kpan-ret", "if (vim_kitty_pan(v, proto, &buf.place)) return;", "if (0) return;"),
        ("upscale", "proto < IMG_PROTO_SIXEL ? 1 : 0", "0"),
        ("bb-half", "if (proto != IMG_PROTO_HALF) cw = (int)(((uint32_t)cw + 1u) >> 1);",
         "cw = (int)(((uint32_t)cw + 1u) >> 1);"),
        ("bb-braille", "if (v->img_braille) ch = (int)(((uint32_t)ch + 3u) >> 2);",
         "if (0) ch = (int)(((uint32_t)ch + 3u) >> 2);"),
        ("ft-cache", "key == v->img_cache_key", "0"),
        ("enc-cache", "v->enc && key == v->enc_key", "0"),
        ("enc-bg", "bg & 0xFFFFFFu", "bg ^ 1u"),
        ("enc-kcols", "if (kc != 0)", "if (0)"),
        ("place-bw", "int bw = box[0] > 0 ? box[0] : 1;", "int bw = box[0] > 0 ? box[0] : 2;"),
        ("place-bh", "int bh = box[1] > 0 ? box[1] : 1;", "int bh = box[1] > 0 ? box[1] : 2;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "viewer_pixels.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] VP3. {len(muts)}/{len(muts)} mutants killed across viewer_pixels.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] VP2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
