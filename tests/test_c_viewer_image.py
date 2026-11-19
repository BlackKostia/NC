#!/usr/bin/env python3
"""U3.2: src/ui/viewer_image.c versus frozen x86_64 assembly
(tests/harness/viewer_image_reference.s): ViewerDialog_set_mode,
ViewerDialog_render_image, viewer_mode_key, viewer_img_free.

VI1 differential (x86_64):
    - ViewerDialog_set_mode: PV_MODE_IMAGE (detect fail -> IMG_E_FORMAT, decode err,
      zero w/h/null px -> IMG_E_CORRUPT, ok -> state=1, cached state skip, app==NULL safe),
      PV_MODE_HEX (from text toggles hex, already hex no-op), PV_MODE_TEXT (no-op)
    - viewer_mode_key: i/I toggle image<->text (and disables hex), t/T -> text (clears hex),
      h/H in img_mode -> switches to hex, h/H outside img_mode -> 0, unknown -> 0
    - ViewerDialog_render_image: img_state==1 calls vim_draw_picture, else draws img_unsup;
      always draws frame, vw_img_hint, zoom badge, scrollbars
    - viewer_img_free: frees img, thumb, enc and zeroes pointers
VI2 qemu-aarch64 matches x86_64 byte for byte
VI3 mutation check across src/ui/viewer_image.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/viewer_image.c"
REF = "tests/harness/viewer_image_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
]


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "viewer_image_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "img_detect=fake_img_detect",
            "--redefine-sym", "img_decode=fake_img_decode",
            "--redefine-sym", "img_free=fake_img_free",
            "--redefine-sym", "ViewerDialog_on_btn0=fake_ViewerDialog_on_btn0",
            "--redefine-sym", "vim_draw_picture=fake_vim_draw_picture",
            "--redefine-sym", "vim_draw_zoom_badge=fake_vim_draw_zoom_badge",
            "--redefine-sym", "vw_draw_img_scrollbars=fake_vw_draw_img_scrollbars",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/viewer_image_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DVI_SRC="{full}"'])


def build_script() -> str:
    # V has_app hex_mode img_mode img_state
    # D detect_ret decode_ret w h px_ok
    return "\n".join([
        # 1. Detect fails -> IMG_E_FORMAT (-1), render shows unsupported
        "V 1 0 0 0",
        "D 0 0 0 0 0",
        "S 1",
        "R",
        # 2. Decode returns error (-2 IMG_E_UNSUP)
        "V 1 0 0 0",
        "D 1 -2 0 0 0",
        "S 1",
        # 3. Decode ok but w=0, h=0, px=NULL -> IMG_E_CORRUPT (-3)
        "V 1 0 0 0",
        "D 1 0 0 10 1",
        "S 1",
        "V 1 0 0 0",
        "D 1 0 10 0 1",
        "S 1",
        "V 1 0 0 0",
        "D 1 0 10 10 0",
        "S 1",
        # 4. Decode ok -> state=1, render calls vim_draw_picture, second S 1 skips decode
        "V 1 0 0 0",
        "D 1 0 32 24 1",
        "S 1",
        "R",
        "S 1",
        "F",                         # viewer_img_free
        # 5. app==NULL safe on set_mode(PV_MODE_IMAGE)
        "V 0 0 0 0",
        "D 1 0 16 16 1",
        "S 1",
        # 6. set_mode HEX (from text vs already hex) & TEXT (no-op)
        "V 1 0 0 0",
        "S 2",                       # text -> hex
        "S 2",                       # already hex -> no-op
        "S 3",                       # TEXT -> no-op
        # 7. viewer_mode_key: i/I/t/T/h/H/x
        "V 1 0 0 0",
        "D 1 0 16 16 1",
        f"K 0x{ord('h'):x} 0",       # not in img_mode -> 0
        f"K 0x{ord('x'):x} 0",       # unknown -> 0
        f"K 0x{ord('i'):x} 0",       # enters img_mode
        f"K 0x{ord('H'):x} 0",       # from img_mode -> switches to hex
        f"K 0x{ord('T'):x} 0",       # from hex -> switches to text
        f"K 0x{ord('I'):x} 0",       # enters img_mode
        f"K 0x{ord('i'):x} 0",       # already img_mode -> back to text
        "V 1 1 1 1",
        f"K 0x{ord('t'):x} 0",       # from img+hex -> clears both
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("st=-1", "st=-2", "st=-3", "st=1", "call vim_draw_picture st=1",
                   "call img_free w=32 h=24 px=1", "call ViewerDialog_on_btn0 hex=1",
                   "call ViewerDialog_on_btn0 hex=0", "K rc=0"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] VI1. viewer_image matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("sm-img", "if (mode == PV_MODE_IMAGE)", "if (0)"),
        ("sm-hex", "if (mode == PV_MODE_HEX && v->hex_mode == 0)", "if (mode == PV_MODE_HEX)"),
        ("ent-cache", "if (v->img_state == 0)", "if (1)"),
        ("ent-fmt", "int st = IMG_E_FORMAT;", "int st = IMG_E_CORRUPT;"),
        ("ent-bad", "if (im.w <= 0 || im.h <= 0 || !im.px) st = IMG_E_CORRUPT;",
         "if (im.w <= 0 || im.h <= 0) st = IMG_E_CORRUPT;"),
        ("key-case", "uint32_t k = e->lat | 0x20u;", "uint32_t k = e->lat;"),
        ("key-h", "if (v->img_mode == 0) return 0;", "if (0) return 0;"),
        ("key-i", "if (v->img_mode == 0)", "if (1)"),
        ("key-t", "if (v->hex_mode != 0) ViewerDialog_on_btn0(v);", "if (0) ViewerDialog_on_btn0(v);"),
        ("ren-st", "if (v->img_state == 1)", "if (v->img_state != 0)"),
        ("ren-hint", "v->base.base.h - 2", "v->base.base.h - 1"),
        ("free-th", "v->thumb = 0;", "v->thumb = 1;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "viewer_image.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] VI3. {len(muts)}/{len(muts)} mutants killed across viewer_image.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] VI2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
