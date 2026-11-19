#!/usr/bin/env python3
"""U4.1: src/ui/function_bar.c versus frozen x86_64 assembly
(tests/harness/function_bar_reference.s): FunctionBar_vtbl, FunctionBar_new,
FunctionBar_layout, FunctionBar_render, FunctionBar_on_mouse.

FB1 differential (x86_64):
    - FunctionBar_new: OOM returns NULL; normal sets id=101, hovered_id=-1, class="FunctionBar"
    - FunctionBar_layout: widths 0, 20 (btn_w=2), 30 (btn_w=3), 40 (btn_w=4), 50 (btn_w=5),
      80, 120, non-zero x/y offsets
    - FunctionBar_render: background fill, key badge digits "1".."0", label pills with and
      without 1-col breathing gap (btn_w 2, 3, 4, 5, 8, 12), hovered highlight vs normal
    - FunctionBar_on_mouse: MACT_MOVE hover transitions & redundant-move no-redraw, boundary
      x1/x2-1/x2 and wrong y, MACT_PRESS left/right/outside, MACT_RELEASE no-op
FB2 qemu-aarch64 matches x86_64 byte for byte
FB3 mutation check across src/ui/function_bar.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/function_bar.c"
REF = "tests/harness/function_bar_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
]


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "function_bar_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "Object_alloc=fake_Object_alloc", str(o)],
                       check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/function_bar_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DFB_SRC="{full}"'])


def build_script() -> str:
    # M kind btn x y  (MACT_PRESS=1, MACT_RELEASE=2, MACT_MOVE=4; MOUSE_LEFT=0, MOUSE_RIGHT=2)
    lines = []
    # Widths exercising every btn_w branch: 0, 2 (skip), 3 (badge only), 4 (no gap), 5 (gap), 8, 12
    for x, y, w in ((0, 0, 0), (0, 1, 20), (0, 1, 30), (0, 1, 40), (0, 1, 50), (2, 2, 80), (0, 3, 120)):
        lines.append(f"L {x} {y} {w} 1")
        lines.append("R")
    # Hover transitions on L 0 3 120 (each zone is 12 cols: [0,12), [12,24), ..., [108,120))
    lines += [
        "M 4 0 0 3",     # hover zone 0 (x1 boundary)
        "R",
        "M 4 0 11 3",    # still zone 0 (x2-1 boundary) -> no redraw
        "M 4 0 12 3",    # zone 1 (x2 of zone 0 = x1 of zone 1)
        "R",
        "M 4 0 119 3",   # zone 9 (digit "0")
        "R",
        "M 4 0 120 3",   # past last zone -> hover -1
        "R",
        "M 4 0 5 2",     # wrong y -> stays -1, no redraw
        "M 4 0 36 3",    # zone 3
        "M 4 0 36 2",    # wrong y -> leaves zone 3 -> hover -1, redraw
        # Press tests
        "M 1 0 0 3",     # left press zone 0 -> dispatch 0, rc=1
        "M 1 0 108 3",   # left press zone 9 -> dispatch 9, rc=1
        "M 1 2 12 3",    # right press zone 1 -> rc=0, no dispatch
        "M 1 0 5 0",     # left press wrong y -> rc=0, no dispatch
        "M 1 0 120 3",   # left press x out of bounds -> rc=0
        "M 2 0 12 3",    # release inside zone -> rc=0
    ]
    return "\n".join(lines) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("OOM=1", "NEW id=101 app=1 hov=-1 cls=FunctionBar",
                   "call App_dispatch_f_action 1 idx=0",
                   "call App_dispatch_f_action 1 idx=9",
                   "dir_fg", "badge_hover_bg", "M rc=1 hov=-1 rd=0"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] FB1. FunctionBar matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("id-101", "Widget_init(&fb->base, app, 101);", "Widget_init(&fb->base, app, 102);"),
        ("init-hov", "fb->hovered_id = (uint32_t)-1;", "fb->hovered_id = 0;"),
        ("div-10", "uint32_t x1 = (uint32_t)fb->base.x + (i * uw) / 10u;",
         "uint32_t x1 = (uint32_t)fb->base.x + (i * uw) / 9u;"),
        ("btnw-min3", "if (btn_w < 3) continue;", "if (btn_w < 4) continue;"),
        ("avail-le1", "if (avail <= 1) continue;", "if (avail <= 2) continue;"),
        ("gap-ge3", "int lbl_w = avail >= 3 ? avail - 1 : avail;",
         "int lbl_w = avail >= 4 ? avail - 1 : avail;"),
        ("hov-badge", "hov ? th->dir_fg : th->accent", "hov ? th->accent : th->dir_fg"),
        ("hov-lbl", "hov ? th->badge_hover_bg : th->badge_bg", "th->badge_bg"),
        ("hov-bold", "hov ? ATTR_BOLD : ATTR_NONE", "ATTR_NONE"),
        ("hit-x2", "mx < (int16_t)zs[i].x2", "mx <= (int16_t)zs[i].x2"),
        ("hit-y", "my == (int16_t)zs[i].y", "my <= (int16_t)zs[i].y"),
        ("btn-left", "if (ev->mouse_btn != MOUSE_LEFT || hit == -1) return 0;",
         "if (hit == -1) return 0;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "function_bar.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] FB3. {len(muts)}/{len(muts)} mutants killed across function_bar.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] FB2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
