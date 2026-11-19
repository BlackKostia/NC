#!/usr/bin/env python3
"""U4.2: src/ui/header_bar.c versus frozen x86_64 assembly
(tests/harness/header_bar_reference.s + header_bar_render_reference.s):
HeaderBar_vtbl, HeaderBar_new, HeaderBar_layout, HeaderBar_render, HeaderBar_on_mouse.

HB0 HDR_BTN_* constants in include/duop_ui.h match include/classes.inc
HB1 differential (x86_64):
    - HeaderBar_new: OOM returns NULL; normal sets id=100, hovered_id=-1, class="HeaderBar"
    - HeaderBar_layout: progressive pill fitting from w=10 (0 pills) through 30, 40, 50, 60,
      70, 80, 100, 120, 140 (all 6 pills: Quit, Help, Lang, Hidden, Preview, Theme) + non-zero x/y
    - HeaderBar_render: brand, dual/preview mode pill, hidden on/off labels, theme prefix+name,
      hovered vs normal pill styling
    - HeaderBar_on_mouse: hover enter/stay/switch/leave, left press on all 6 buttons, right press,
      wrong y, release no-op
HB2 qemu-aarch64 matches x86_64 byte for byte
HB3 mutation check across src/ui/header_bar.c
"""

import re
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/header_bar.c"
REFS = ["tests/harness/header_bar_reference.s", "tests/harness/header_bar_render_reference.s"]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "src/ui/header_bar_git.c", "build/i18n_en.c",
]


def test_constants() -> None:
    inc = (ROOT / "include/classes.inc").read_text()
    hdr = (ROOT / "include/duop_ui.h").read_text()
    names = ("HDR_BTN_THEME", "HDR_BTN_PREVIEW", "HDR_BTN_HIDDEN", "HDR_BTN_HELP", "HDR_BTN_QUIT", "HDR_BTN_LANG")
    for n in names:
        a = re.search(rf"^\.equ {n},\s*(\d+)", inc, re.M)
        b = re.search(rf"\b{n}\s*=\s*(\d+)", hdr)
        assert a and b and a.group(1) == b.group(1), (n, a and a.group(1), b and b.group(1))
    print(f"[PASS] HB0. {len(names)} HDR_BTN_* constants match include/classes.inc")


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
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
        for o in objs:
            subprocess.run(["objcopy", "--redefine-sym", "Object_alloc=fake_Object_alloc", str(o)],
                           check=True, capture_output=True)
        extra += objs
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/header_bar_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DHB_SRC="{full}"'])


def build_script() -> str:
    lines = ["S 0 0"]
    # Progressive widths to test each pill cutoff (0..6 pills) + offset x/y
    for x, y, w in ((0, 0, 10), (0, 0, 28), (0, 0, 36), (0, 0, 44), (0, 0, 56),
                    (0, 0, 68), (0, 0, 82), (2, 1, 100), (0, 2, 120)):
        lines.append(f"L {x} {y} {w} 1")
        lines.append("R")
    # Toggle right_mode=PREVIEW and show_hidden=1
    lines += ["S 1 1", "R"]
    # Hover each of the 6 zones and render, plus click each of the 6 buttons
    for idx in range(6):
        lines.append(f"C {idx} 4 0")   # MACT_MOVE
        lines.append("R")
        lines.append(f"C {idx} 4 0")   # same zone -> rd=0
        lines.append(f"C {idx} 1 0")   # MACT_PRESS MOUSE_LEFT
    # Edge cases: right click, release, exclusive x2 boundary, wrong y, outside x
    lines += [
        "C 0 1 2",       # right click on Quit -> rc=0
        "C 0 2 0",       # release on Quit -> rc=0
        "X 0 4 0",       # hover at x2 (exclusive) -> hover -1, rd=1
        "M 4 0 0 2",     # outside pills on same y -> stays -1, rd=0
        "C 1 4 0",       # hover zone 1
        "M 4 0 110 0",   # wrong y -> hover -1, rd=1
        "M 1 0 0 2",     # left press outside -> rc=0
    ]
    return "\n".join(lines) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("OOM=1", "NEW id=100 app=1 hov=-1 cls=HeaderBar",
                   "Z cnt=0", "Z cnt=6",
                   "call App_cmd_quit 1", "call App_cmd_help 1",
                   "call App_cmd_toggle_lang 1", "call App_cmd_toggle_hidden 1",
                   "call App_cmd_toggle_preview 1", "call App_cmd_cycle_theme 1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] HB1. HeaderBar matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("id-100", "Widget_init(&hb->base, app, 100);", "Widget_init(&hb->base, app, 101);"),
        ("init-hov", "hb->hovered_id = (uint32_t)-1;", "hb->hovered_id = 0;"),
        ("minx-pad", "int min_x = hb->base.x + bw + mw + 2;", "int min_x = hb->base.x + bw + mw + 6;"),
        ("pill-gap", "int nx = *right_x - pill_w - 1;", "int nx = *right_x - pill_w - 2;"),
        ("theme-12", "utf8_display_width(ls->s[LS_hdr_theme_pfx]) + 12",
         "utf8_display_width(ls->s[LS_hdr_theme_pfx]) + 10"),
        ("hid-on", "ls->s[LS_hdr_btn_hid_on] : ls->s[LS_hdr_btn_hid_off]",
         "ls->s[LS_hdr_btn_hid_off] : ls->s[LS_hdr_btn_hid_on]"),
        ("hov-bg", "hov ? th->accent : th->badge_bg", "th->badge_bg"),
        ("hov-bold", "hov ? ATTR_BOLD : ATTR_NONE", "ATTR_NONE"),
        ("hit-x2", "mx < (int16_t)zs[i].x2", "mx <= (int16_t)zs[i].x2"),
        ("hit-y", "my == (int16_t)zs[i].y", "my <= (int16_t)zs[i].y"),
        ("btn-left", "if (ev->mouse_btn != MOUSE_LEFT || hit == -1) return 0;",
         "if (hit == -1) return 0;"),
        ("cmd-quit", "case HDR_BTN_QUIT:    App_cmd_quit(app); break;",
         "case HDR_BTN_QUIT:    App_cmd_help(app); break;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "header_bar.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] HB3. {len(muts)}/{len(muts)} mutants killed across header_bar.c")


def main() -> None:
    test_constants()
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] HB2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
