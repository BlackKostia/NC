#!/usr/bin/env python3
"""U3.5: src/ui/preview_mode.c versus frozen x86_64 assembly
(tests/harness/preview_mode_reference.s): img_box_pixels, pv_box_pixels,
PreviewPane_thumb_req, PreviewPane_cycle_mode, pv_mode_dispatch.

PM1 differential (x86_64):
    - img_box_pixels: non-positive cols/rows -> 0x0, QUAD (2x2), HALF (1x2),
      SIXEL known cell_px & unknown (6x12), KITTY known & unknown (10x20, cols clamped 255),
      IMG_PX_MAX (2048) cap on both dimensions
    - PreviewPane_thumb_req & pv_box_pixels: packs dims, proto|cols<<8, req_mode, bg&0xFFFFFF,
      zero box when narrow/short
    - PreviewPane_cycle_mode: image file (Image -> Hex -> Text -> Image), plain text
      (Text -> Hex -> Text), binary (Hex -> Text -> Hex), resets scroll=0 & sets need_redraw=1
    - pv_mode_dispatch: image mode draws bottom mode bar (" Alt+V  Image  Hex  Text ")
      and calls img_preview_try_render (-> 0), image in Hex/Text draws mode bar (-> 1/2),
      plain AUTO calls elf_preview_try_render (-> 0 if ELF, else 1/2), narrow bar clipping
PM2 qemu-aarch64 matches x86_64 byte for byte
PM3 mutation check across src/ui/preview_mode.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/preview_mode.c"
REF = "tests/harness/preview_mode_reference.s"
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
        o = t / "preview_mode_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "img_preview_try_render=fake_img_preview_try_render",
            "--redefine-sym", "elf_preview_try_render=fake_elf_preview_try_render",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/preview_mode_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DPM_SRC="{full}"'])


def build_script() -> str:
    # E proto cw ch elf_ret
    # B cols rows proto
    # P x y w h thumb_len view_mode is_binary
    return "\n".join([
        # 1. img_box_pixels across all protocols & caps
        "E 0 0 0 0",
        "B 0 10 0", "B 10 0 0", "B -5 10 0",
        "B 40 20 0",                 # QUAD: 80x40
        "B 40 20 1",                 # HALF: 40x40
        "B 40 20 2",                 # SIXEL unknown cell: 240x240
        "B 40 20 3",                 # KITTY unknown cell: 400x400
        "E 2 8 16 0",
        "B 40 20 2",                 # SIXEL known 8x16: 320x320
        "B 300 200 2",               # capped at 2048x2048
        # 2. PreviewPane_thumb_req: Kitty unknown (cols=38), wide (cols capped 255), short (dims=0)
        "E 3 0 0 0",
        "P 0 0 40 15 0 0 0",
        "Q",
        "P 0 0 300 15 0 0 0",
        "Q",
        "P 0 0 40 5 0 0 0",          # h-5 == 0 -> dims=0
        "Q",
        "E 3 10 20 0",
        "P 0 0 40 15 0 0 0",         # known cell_px -> cols=0
        "Q",
        # 3. PreviewPane_cycle_mode: image file (Auto->Image->Hex->Text->Image)
        "P 0 0 50 15 64 0 0",
        "D",                         # AUTO + thumb -> IMAGE (draws mode bar + img_preview_try_render)
        "C",                         # -> HEX (2)
        "D",                         # draws mode bar + returns 1
        "C",                         # -> TEXT (3)
        "D",                         # draws mode bar + returns 2
        "C",                         # -> IMAGE (1)
        "D",
        # Narrow pane clips mode bar cleanly
        "P 0 0 12 10 64 0 0",
        "D",
        # 4. Plain text file: AUTO -> TEXT, cycle -> HEX -> TEXT
        "E 0 0 0 0",
        "P 0 0 50 15 0 0 0",
        "D",                         # calls elf_preview_try_render (ret=0) -> returns 2
        "C",                         # -> HEX
        "D",                         # view_mode != AUTO -> skips elf, returns 1
        "C",                         # -> TEXT
        # 5. Binary file + ELF hit
        "E 0 0 0 1",
        "P 0 0 50 15 0 0 1",
        "D",                         # elf_preview_try_render returns 1 -> returns 0
        "E 0 0 0 0",
        "P 0 0 50 15 0 0 1",
        "D",                         # binary AUTO -> returns 1 (HEX)
        "C",                         # -> TEXT
        "D",                         # returns 2
        "P 0 0 50 15 0 1 1",         # view_mode=IMAGE without thumb -> falls back to binary HEX
        "D",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("B 80x40", "B 40x40", "B 240x240", "B 400x400", "B 2048x2048",
                   "pr=3 cols=38", "pr=3 cols=255", "dims=0 wh=0x0",
                   "call img_preview_try_render tlen=64", "call elf_preview_try_render ret=1",
                   " Alt+V ", "accent_fg/accent a=1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] PM1. preview_mode matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("half-w", "if (proto == IMG_PROTO_HALF) { *out_w = cols; *out_h = rows * 2; return; }",
         "if (proto == IMG_PROTO_HALF) { *out_w = cols * 2; *out_h = rows * 2; return; }"),
        ("sixel-g", "cw = 6; ch = 12;", "cw = 8; ch = 16;"),
        ("kitty-cap", "kc = cols > 255 ? 255u : (uint32_t)cols;", "kc = (uint32_t)cols;"),
        ("px-max", "if (w > IMG_PX_MAX) w = IMG_PX_MAX;", "if (w > 4096u) w = 4096u;"),
        ("pv-h5", "self->base.h - 5", "self->base.h - 4"),
        ("req-bg", "out->bg = th->surface & 0xFFFFFFu;", "out->bg = th->surface ^ 1u;"),
        ("eff-bin", "return self->is_binary ? PV_MODE_HEX : PV_MODE_TEXT;", "return PV_MODE_TEXT;"),
        ("cyc-img", "next = self->thumb_len >= IMG_THUMB_HDR ? PV_MODE_IMAGE : PV_MODE_HEX;",
         "next = PV_MODE_HEX;"),
        ("cyc-sc", "self->scroll = 0;", "self->scroll = 1;"),
        ("disp-elf", "if (elf_preview_try_render(self, scr, theme)) return 0;", "if (0) return 0;"),
        ("bar-act", "if (m == mode)", "if (m != mode)"),
        ("bar-clip", "if (room > 0)", "if (room > 99)"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "preview_mode.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] PM3. {len(muts)}/{len(muts)} mutants killed across preview_mode.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] PM2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
