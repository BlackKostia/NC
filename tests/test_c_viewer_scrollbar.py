#!/usr/bin/env python3
"""U1.8a: src/ui/viewer_scrollbar.c versus frozen x86_64 assembly
(tests/harness/viewer_scrollbar_reference.s): vw_draw_img_scrollbars, vw_draw_text_scrollbar,
and vw_img_scrollbar_mouse.

VS1 differential (x86_64):
    - vw_draw_img_scrollbars: img_state!=1, img_zoom==0, both axes scrollable, single axis,
      tiny box*100/zoom==0 clamp to 1, pan=0/mid/max/beyond-max
    - vw_draw_text_scrollbar: data_len==0, vis_rows<=0, text mode (end_off<=top_off, total<=vis,
      normal scrolling) & hex mode ((data_len+15)>>4 rows)
    - vw_img_scrollbar_mouse: zoom==0, non-left btn, release clears drag, press outside/on V/on H,
      drag V/H inside & past both ends, drag with drag==0, non-scrollable axis (max_pan<=0)
VS2 qemu-aarch64: matches x86_64 byte for byte
VS3 mutation check across viewer_scrollbar.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/viewer_scrollbar.c"
REF = "tests/harness/viewer_scrollbar_reference.s"
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
        o = t / "viewer_scrollbar_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "vz_invalidate=fake_vz_invalidate", str(o)],
                       check=True, capture_output=True)
        extra.append(o)
    full = src_override if src_override else str(ROOT / SRC)
    return H.build(arch, t, ["tests/harness/viewer_scrollbar_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DVSB_SRC="{full}"'])


def build_script() -> str:
    return "\n".join([
        # Widget (x=2, y=1, w=20, h=12) => V track x=21 y=2..10 (len=9); H track y=12 x=3..20 (len=18)
        "W 2 1 20 12",
        # Image scrollbars: inactive states (0 and error -1)
        "I 0 200 1000 800 200 100 0 0",
        "I -1 200 1000 800 200 100 0 0",
        "I 1 0 1000 800 200 100 0 0",
        # Both axes scrollable, pan=0, mid, max, slightly beyond max (tpos == travel+1)
        "I 1 200 1000 800 200 100 0 0",
        "I 1 200 1000 800 200 100 450 375",
        "I 1 200 1000 800 200 100 900 750",
        "I 1 200 1000 800 200 100 1000 850",
        # Tiny vis (box*100/zoom == 0 -> clamped to 1) & single-axis (h fits)
        "I 1 800 1000 50 4 400 300 0",
        # Text & hex scrollbars
        "T 0 8 0 0 100",           # empty
        "T 1000 0 0 0 100",        # vis_rows == 0
        "T 1000 8 0 0 1000",       # total <= vis -> hidden
        "T 1000 8 0 0 200",        # top
        "T 1000 8 0 400 600",      # mid
        "T 1000 8 0 800 800",      # end_off == top_off -> vis clamped to 1
        "T 129 8 1 0 0",           # hex 129 bytes -> 9 rows > 8 (drawn iff +15)
        "T 1000 8 1 25 0",         # hex mid
        "T 1000 8 1 55 0",         # hex bottom
        # Mouse interactions on zoomed image (x=2,y=1,w=20,h=12, V at x=21 y=2..10, H at y=12 x=3..20)
        "I 1 0 1000 800 200 100 0 0",
        "M 1 0 21 5",              # zoom==0 -> ignored
        "I 1 200 1000 800 200 100 0 0",
        "M 1 2 21 5",              # right click -> ignored
        "M 4 0 21 5",              # move -> ignored
        "M 3 0 21 5",              # drag before press (drag==0) -> ignored
        "M 1 0 10 5",              # press outside tracks -> ignored
        "M 1 0 21 1",              # press above V track -> ignored
        "M 1 0 21 11",             # press below V track -> ignored
        "M 1 0 21 2",              # press top of V track -> drag=1
        "M 3 0 21 6",              # drag V mid
        "M 3 0 21 0",              # drag V above track -> clamped to 0
        "M 3 0 21 20",             # drag V below track -> clamped to max
        "M 2 0 21 6",              # release -> drag=0, rc=0
        "M 1 0 2 12",              # press left of H track -> ignored
        "M 1 0 21 12",             # press right of H track -> ignored
        "M 1 0 12 12",             # press mid of H track -> drag=2
        "M 3 0 0 12",              # drag H left of track -> clamped
        "M 3 0 30 12",             # drag H right of track -> clamped
        "M 2 0 12 12",             # release -> drag=0
        # Wide thumb (thumb_len == 9 => thumb_len >> 1 == 4) to test thumb-centering in scrub
        "I 1 100 200 200 100 100 0 0",
        "M 1 0 12 12",
        "M 1 0 21 6",
        # Non-scrollable image (fits inside box) -> scrub returns 0
        "I 1 100 50 40 200 100 10 10",
        "M 1 0 21 5",
        "M 1 0 10 12",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("scroll_thumb/dialog_bg a=0", "scroll_track/dialog_bg a=0",
                   "call vz_invalidate 1 0", "M rc=1 drag=1", "M rc=1 drag=2", "M rc=0 drag=0"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] VS1. viewer_scrollbar matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("bar-hide", "total <= vis", "total < vis"),
        ("bar-tlen1", "if (tlen == 0) tlen = 1;", "if (0 && tlen == 0) tlen = 1;"),
        ("bar-tpos-cap", "if (tpos > travel) tpos = travel;", "if (tpos > travel + 5) tpos = travel;"),
        ("bar-glyph", "CH_BLOCK_FULL", "CH_SHADE_LIGHT"),
        ("bar-horiz", "int cx = horiz ? x + i : x;", "int cx = x;"),
        ("img-state", "v->img_state != 1", "v->img_state == 0"),
        ("hex-rows", "(v->data_len + 15u) >> 4", "v->data_len >> 4"),
        ("text-vis1", "if (vis < 1) vis = 1;", "if (vis < 0) vis = 1;"),
        ("scrub-half", "rel - (thumb_len >> 1)", "rel"),
        ("mouse-rel", "e->mouse_kind == MACT_RELEASE", "0 && e->mouse_kind == MACT_RELEASE"),
        ("mouse-btn", "e->mouse_btn != MOUSE_LEFT", "0 && e->mouse_btn != MOUSE_LEFT"),
        ("drag-v-hit", "mx == vx && my >= vy && my < vy + vh", "mx == vx && my >= vy"),
        ("drag-h-hit", "my == hy && mx >= hx && mx < hx + hw", "my == hy && mx >= hx"),
        ("drag-inv", "vz_invalidate(v);", "(void)v;"),
    ]
    src_txt = (ROOT / SRC).read_text()
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src_txt and old != new, name
        mp = t / f"m{idx}" / "viewer_scrollbar.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src_txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", str(mp))
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] VS3. {len(muts)}/{len(muts)} mutants killed")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] VS2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
