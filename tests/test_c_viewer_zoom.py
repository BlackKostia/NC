#!/usr/bin/env python3
"""U1.8b: src/ui/{viewer_zoom,viewer_zoom_rect}.c versus frozen x86_64 assembly
(tests/harness/viewer_zoom{,_rect}_reference.s): vim_zoom_key, vim_zoom_mouse, vz_invalidate,
vim_zoom_rect, vim_draw_zoom_badge, and vim_kitty_pan.

VZ1 differential (x86_64):
    - vim_zoom_key: inactive guards, '+'/'=' stepping up to 800, '-'/'_' stepping down to 0,
      '1' (100% + center pan from Fit vs keeping pan), '0'/'f' (Fit), 'b'/'B' (Braille toggle),
      'o'/'O' (sys_open_external), arrows/PgUp/PgDn pan + clamping, Home/End, unknown key
    - vim_zoom_mouse: inactive guards, non-wheel -> vw_img_scrollbar_mouse, wheel zoom at Fit
      and with Ctrl, plain wheel vertical vs auto-horizontal vs Shift+wheel horizontal pan
    - vim_zoom_rect: Fit with upscale=0/1 (small & large image), zoomed crop & pan clamping
    - vim_draw_zoom_badge: inactive state, Fit, zoomed %, Braille ' B' suffix
    - vim_kitty_pan: non-Kitty, zoom==0 (clears mark), >16M pixels cap, first transmit+place,
      cached placement reuse (enc_key == 0x4B50414E), OOM on transmit & enc buffers
VZ2 qemu-aarch64: matches x86_64 byte for byte
VZ3 mutation check across viewer_zoom.c and viewer_zoom_rect.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = {
    "VZ_SRC": "src/ui/viewer_zoom.c",
    "VZR_SRC": "src/ui/viewer_zoom_rect.c",
}
REFS = [
    "tests/harness/viewer_zoom_reference.s",
    "tests/harness/viewer_zoom_rect_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/core/try_rt.c",
    "src/fs/img_core.c", "src/fs/img_bmp.c", "src/fs/img_tga.c", "src/fs/img_pnm.c",
    "src/fs/img_gif.c", "src/fs/img_png.c", "src/fs/img_jpeg.c", "src/fs/inflate.c",
    "src/fs/img_kitty.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
]

KEY_UP = 0x100001
KEY_DOWN = 0x100002
KEY_LEFT = 0x100003
KEY_RIGHT = 0x100004
KEY_HOME = 0x100005
KEY_END = 0x100006
KEY_PGUP = 0x100007
KEY_PGDN = 0x100008


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
        redefs = [
            "--redefine-sym", "sys_open_external=fake_open_external",
            "--redefine-sym", "vw_img_scrollbar_mouse=fake_sb_mouse",
            "--redefine-sym", "img_overlay_kitty_ready=fake_kitty_ready",
            "--redefine-sym", "img_overlay_kitty_mark=fake_kitty_mark",
            "--redefine-sym", "img_overlay_show=fake_overlay_show",
            "--redefine-sym", "vim_place=fake_vim_place",
            "--redefine-sym", "sys_write_all=fake_write_all",
            "--redefine-sym", "mem_alloc=fake_mem_alloc",
            "--redefine-sym", "img_kitty_encode=fake_kitty_encode",
        ]
        for o in objs:
            subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra += objs
    defs = []
    for k, v in SRCS.items():
        p = (overrides or {}).get(k, v)
        full = p if Path(p).is_absolute() else str(ROOT / p)
        defs.append(f'-D{k}="{full}"')
    return H.build(arch, t, ["tests/harness/viewer_zoom_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


def k(ch: int, mods: int = 0) -> str:
    return f"K 0x{ch:x} {mods} 0x{ch:x}"


def build_script() -> str:
    lines: list[str] = [
        # Inactive guards
        "S 0 1 800 600 200 100 0 0 0 0", k(ord('+')), "M 5 64 5 5 0",
        "S 1 0 800 600 200 100 0 0 0 0", k(ord('+')), "M 5 64 5 5 0",
        # Active image in Fit mode (zoom=0, box 200x100, img 800x600 => fit pct ~ 16%)
        "S 1 1 800 600 200 100 0 0 0 0",
        k(ord('x')),           # unknown -> 0
        k(ord('+')),           # step up from Fit (~16%) -> 25% + center pan
        k(ord('=')),           # -> 33%
        k(ord('-')),           # -> 25%
        k(ord('_')),           # -> 0 (Fit)
        k(ord('1')),           # -> 100% + center pan
        k(ord('1')),           # already zoomed -> keep pan
        k(ord('b')), k(ord('B')),
        k(ord('o')), k(ord('O')),
        k(KEY_RIGHT), k(KEY_LEFT), k(KEY_DOWN), k(KEY_UP), k(KEY_PGDN), k(KEY_PGUP),
        k(KEY_END), k(KEY_HOME),
        k(ord('f')),           # -> Fit
        # Step all the way past 800% cap & empty box fallback (cur_pct = 100)
        "S 1 1 800 600 0 0 0 0 0 0",
        k(ord('+')),           # cur_pct=100 -> 125
        "S 1 1 800 600 200 100 800 0 0 0",
        k(ord('+')),           # cap at 800
        # Tiny fit pct clamped to 10 (< 25)
        "S 1 1 10000 10000 200 100 0 0 0 0",
        k(ord('-')),           # cur_pct=10 -> Fit (0)
        # Mouse: non-wheel delegates to scrollbar, wheel zoom & pan (V, Shift-H, auto-H)
        "S 1 1 800 600 200 100 0 0 0 0",
        "M 1 0 10 5 0",        # non-wheel -> sb_mouse
        "M 5 64 10 5 0",       # wheel up in Fit -> zoom in (25%)
        "M 5 65 10 5 4",       # Ctrl+wheel down -> zoom out (Fit)
        "M 5 64 10 5 4",       # Ctrl+wheel up -> 25%
        "S 1 1 800 600 200 100 200 100 100 0",
        "M 5 65 10 5 0",       # wheel down -> vertical pan +1
        "M 5 64 10 5 0",       # wheel up -> vertical pan -1
        "M 5 65 10 5 1",       # Shift+wheel down -> horizontal pan +1
        "S 1 1 800 40 200 100 200 100 0 0",
        "M 5 65 10 5 0",       # box_h*100/zoom = 50 >= 40 -> auto-horizontal pan!
        # vim_zoom_rect: Fit (upscale=0 small, upscale=0 big, upscale=1 small) + zoomed crops
        "S 1 1 50 40 200 100 0 0 0 0",
        "R 200 100 0",         # native 50x40
        "R 200 100 1",         # upscaled via img_fit
        "S 1 1 800 600 200 100 0 0 0 0",
        "R 200 100 0",         # downscaled via img_fit
        "S 1 1 800 600 200 100 200 9999 -5 0",
        "R 200 100 0",         # zoomed 200%, pan_x clamped to max, pan_y clamped to 0
        "S 1 1 102 52 200 100 200 0 0 0",
        "R 200 100 0",         # t = 204 > 200 (and <= 210) -> clamped to 200
        "S 1 1 10 10 200 100 25 0 0 0",
        "R 200 100 0",         # 25% of 10 -> tw=2, sw=8
        # vim_draw_zoom_badge
        "S 1 0 800 600 200 100 0 0 0 0", "B 1 1 50 6",
        "S 1 1 800 600 200 100 0 0 0 0", "B 1 1 50 6",
        "S 1 1 800 600 200 100 200 0 0 0", "B 1 1 50 6",
        "S 1 1 800 600 200 100 200 0 0 1", "B 1 1 50 6",
        # vim_kitty_pan
        "S 1 1 8 8 200 100 200 0 0 0",
        "P 2 200 100 0 0",     # non-Kitty -> 0
        "S 1 1 8 8 200 100 0 0 0 0",
        "P 3 200 100 1 0",     # zoom==0 -> clears kitty_mark & returns 0
        "S 1 1 5000 5000 200 100 200 0 0 0",
        "P 3 200 100 0 0",     # > 16777216 pixels -> 0
        "S 1 1 8 8 200 100 200 1 2 0",
        "P 3 200 100 0 0",     # first transmit + alloc enc + place -> 1
        "P 3 200 100 1 1",     # cached transmit & enc reuse (no mem_alloc even if alloc fails!) -> 1
        "S 1 1 8 8 200 100 200 1 2 0",
        "P 3 200 100 0 1",     # OOM on transmit buffer -> 0
        "P 3 200 100 1 1",     # OOM on enc buffer -> 0
    ]
    return "\n".join(lines) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("call open_external path=/tmp/pic.png env_eq=1",
                   "call sb_mouse eq=1", "800x600 [200% B]", "800x600 [Fit]",
                   "call kitty_encode eq=1", "call overlay_show", "P rc=1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] VZ1. viewer_zoom + viewer_zoom_rect match frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("VZ_SRC", "key-state", "v->img_mode == 0 || v->img_state != 1", "v->img_mode == 0"),
        ("VZ_SRC", "braille-xor", "v->img_braille ^= 1;", "v->img_braille = 0;"),
        ("VZ_SRC", "wheel-ctrl", "v->img_zoom == 0 || (mods & MOD_CTRL)", "v->img_zoom == 0"),
        ("VZ_SRC", "wheel-shift", "(mods & MOD_SHIFT) != 0", "0"),
        ("VZ_SRC", "wheel-autoh", "(int)((v->img_box_h * 100u) / v->img_zoom) >= im->h", "(int)((v->img_box_h * 100u) / v->img_zoom) >= im->h + 10000"),
        ("VZ_SRC", "step-up", "if (zoom_steps[i] > cur)", "if (zoom_steps[i] >= cur)"),
        ("VZ_SRC", "step-dn", "if (zoom_steps[i] < cur)", "if (zoom_steps[i] <= cur)"),
        ("VZ_SRC", "pan-step", "int step = vis >> 4;", "int step = vis >> 3;"),
        ("VZ_SRC", "inv-key", "v->img_cache_key = (uint64_t)-1;", "v->img_cache_key = 0;"),
        ("VZR_SRC", "crop-clamp", "if (t > box_dim) t = box_dim;", "if (t > box_dim + 10) t = box_dim;"),
        ("VZR_SRC", "upscale-chk", "upscale != 0 || tw > (uint32_t)box_w || th > (uint32_t)box_h",
         "upscale == 999 || tw > (uint32_t)box_w || th > (uint32_t)box_h"),
        ("VZR_SRC", "badge-br", "if (v->img_braille != 0)", "if (0 && v->img_braille != 0)"),
        ("VZR_SRC", "kp-proto", "if (proto != IMG_PROTO_KITTY) return 0;", "if (proto == 0) return 0;"),
        ("VZR_SRC", "kp-pxcap", "px_cnt > 16777216u", "px_cnt > 99999999u"),
        ("VZR_SRC", "kp-enckey", "v->enc_key != kpan", "v->enc_key == kpan"),
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
    print(f"[PASS] VZ3. {len(muts)}/{len(muts)} mutants killed across viewer_zoom.c and viewer_zoom_rect.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] VZ2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
