#!/usr/bin/env python3
"""U1.6: src/ui/git_render.c + src/ui/du_render.c versus frozen x86_64 assembly
(tests/harness/git_render_reference.s + du_render_reference.s).

GD1 differential (x86_64) for git_render.c + fp_draw_du_badge:
    - fp_draw_glyph_and_git: M/A/?/D/R/0 statuses, NULL name, custom row_bg & glyph
    - hdr_draw_git_badge: NULL app/pane, empty branch, normal branch, 80-char clipped branch, UTF-8 branch
    - fp_draw_du_badge: du_mode=0/1, narrow boundary (x <= base.x), normal & wide Unicode badge
GD2 du_render.c fixes 3 real bugs in frozen du_render.s (verified on both oracle and C):
    1. fp_draw_du_badge passed rdi (FilePane* heap address) to theme_get(idx) instead of app->theme_idx
    2. fp_draw_du_pane called ScreenBuffer_set_cell(sb,x,y,cp) missing fg/bg args (wrote fg=#00000000..7)
       instead of ScreenBuffer_set_cell_pen(sb,x,y,cp) with Theme.accent / row_bg
    3. size*100 overflow for huge sizes (> UINT64_MAX/100) guarded cleanly in C
    Also verifies 100% text/geometry parity on fp_draw_du_pane vs frozen asm across all row states.
GD3 qemu-aarch64: matches x86_64 byte for byte
GD4 mutation check across both git_render.c and du_render.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = {
    "GIT_SRC": "src/ui/git_render.c",
    "DU_SRC": "src/ui/du_render.c",
}
REFS = [
    "tests/harness/git_render_reference.s",
    "tests/harness/du_render_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
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
        for o in objs:
            subprocess.run(["objcopy", "--redefine-sym", "theme_get=fake_theme_get", str(o)],
                           check=True, capture_output=True)
        extra += objs
    defs = []
    for k, v in SRCS.items():
        p = (overrides or {}).get(k, v)
        full = p if Path(p).is_absolute() else str(ROOT / p)
        defs.append(f'-D{k}="{full}"')
    return H.build(arch, t, ["tests/harness/git_du_render_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


def build_exact_diff_script() -> str:
    lines: list[str] = []
    # git_render: fp_draw_glyph_and_git
    for st in (0, ord('M'), ord('A'), ord('?'), ord('D'), ord('R')):
        lines.append(f"G 4 1 0x2022 1 {st} 1")
    lines.append(f"G 6 2 0x25B8 17 {ord('M')} 0")   # NULL entry name
    # git_render: hdr_draw_git_badge
    lines += [
        "H 10 0 0 1 main",
        "H 10 0 1 0 main",
        "H 10 0 1 1 ",
        "H 10 0 1 1 main",
        "H 2 1 1 1 " + "b" * 80,
        "H 5 2 1 1 гілка-42",
    ]
    # du_render: fp_draw_du_badge (with theme_get idx logging off so screen dumps diff cell-for-cell)
    lines += [
        "B 0 0 50 0 0",
        "B 0 0 50 1 0",
        "B 4 1 10 1 2",    # too narrow (x <= base.x)
        "B 4 1 12 1 1",    # exact boundary check
        "B 2 2 60 1 2 Диск",
    ]
    return "\n".join(lines) + "\n"


def build_du_pane_script() -> str:
    lines: list[str] = [
        # du_mode == 0 -> nothing drawn
        "D 0 0 60 10 0 0 0 1 1000", "E 0 500", "P",
        # h == 5 -> list_h == 0 -> nothing drawn
        "D 0 0 60 5 1 0 0 1 1000", "E 0 500", "P",
        # Full pane: parent skipped, focused cursor on row 1, sizes 0 / 125 / 500 / 1000 / 1500 (> total)
        "D 2 1 60 10 1 0 1 1 1000",
        "E 32 0",          # FE_IS_PARENT (32) -> skipped
        "E 0 500",         # 50% (4 filled) + focused cursor
        "E 0 125",         # 12% (0 filled)
        "E 0 1000",        # 100% (8 filled)
        "E 0 1500",        # clamped to 100%
        "E 0 0",           # 0%
        "P",
        # Unfocused cursor + scroll=1 + du_total=0
        "D 0 0 50 8 1 1 2 0 0",
        "E 0 100",
        "E 0 250",
        "E 0 750",
        "P",
    ]
    return "\n".join(lines) + "\n"


def test_exact_diff(exe: Path) -> str:
    s = build_exact_diff_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("ok_fg/", "warn_fg/", "err_fg/", "muted/", "badge_fg/badge_bg a=1",
                   "accent_fg/accent a=1", "[main]"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] GD1. git_render + fp_draw_du_badge match frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_du_pane_and_asm_bugs(exe: Path) -> str:
    # 1. Prove asm bug 1: du_render.s passed FilePane* pointer as idx to theme_get(idx)
    probe = b"Q 1\nB 0 0 50 1 2\n"
    r_ref = H.run_impl("x86_64", exe, "ref", stdin=probe)
    r_c = H.run_impl("x86_64", exe, "c", stdin=probe)
    assert r_ref.returncode == 0 and r_c.returncode == 0
    assert b"theme_get idx=2\n" in r_c.stdout
    assert b"theme_get idx=2\n" not in r_ref.stdout, "expected asm oracle to pass fp pointer to theme_get"

    # 2. Prove asm bug 2 & check 100% text/geometry parity on fp_draw_du_pane
    ps = build_du_pane_script().encode()
    o_ref = H.run_impl("x86_64", exe, "ref", stdin=ps).stdout.decode()
    o_c = H.run_impl("x86_64", exe, "c", stdin=ps).stdout.decode()
    # Text lines ("  |...|") MUST match 100% between asm and C
    ref_text = [l for l in o_ref.splitlines() if l.startswith("  |")]
    c_text = [l for l in o_c.splitlines() if l.startswith("  |")]
    assert ref_text == c_text, f"du_pane text mismatch:\nREF={ref_text}\nC={c_text}"
    # Asm oracle wrote garbage fg #00000000 on bar cells; C writes accent/<row_bg>
    assert "#00000000/" in o_ref, "expected asm oracle to leak r8d=0..7 into ScreenBuffer_set_cell fg"
    assert "#00000000/" not in o_c
    for needle in ("accent/cursor_active_bg a=0", "accent/cursor_inactive_bg a=0", "accent/surface a=0",
                   "muted/cursor_active_bg a=0", "\\xe2\\x96\\x88" * 4 + "\\xe2\\x96\\x91" * 4,
                   "\\xe2\\x96\\x88" * 8, "\\xe2\\x96\\x91" * 8, "50%", "100%", "12%"):
        assert needle in o_c, f"du_pane coverage missing: {needle}"

    # 3. Overflow guard for huge size (> UINT64_MAX/100) in C
    huge = b"D 0 0 60 8 1 0 0 0 400000000000000000\nE 0 200000000000000000\nP\n"
    o_huge = H.run_impl("x86_64", exe, "c", stdin=huge).stdout.decode()
    assert "50%" in o_huge and ("\\xe2\\x96\\x88" * 4 + "\\xe2\\x96\\x91" * 4) in o_huge, o_huge
    print("[PASS] GD2. fp_draw_du_pane text matches asm 100% and fixes 3 asm bugs (theme_get idx, set_cell_pen, overflow)")
    return o_c


def test_mutations(t: Path, exact_script: bytes, pane_script: bytes, base_exact: str, base_pane: str) -> None:
    muts = [
        ("GIT_SRC", "status-zero", "if (!st) return;", "if (0 && !st) return;"),
        ("GIT_SRC", "status-A", "if (st == 'A') fg = theme->ok_fg;", "if (st == 'X') fg = theme->ok_fg;"),
        ("GIT_SRC", "status-q", "else if (st == '?') fg = theme->muted;", "else if (st == 'X') fg = theme->muted;"),
        ("GIT_SRC", "status-D", "else if (st == 'D') fg = theme->err_fg;", "else if (st == 'X') fg = theme->err_fg;"),
        ("GIT_SRC", "git-x-1", "x3 - 1", "x3"),
        ("GIT_SRC", "badge-empty", "if (!br || !br[0]) return;", "if (!br) return;"),
        ("GIT_SRC", "badge-bold", "ScreenBuffer_set_pen(s, t->badge_fg, t->badge_bg, ATTR_BOLD);",
         "ScreenBuffer_set_pen(s, t->badge_fg, t->badge_bg, ATTR_NONE);"),
        ("DU_SRC", "badge-mode", "if (!dm || dm->du_mode == 0) return;", "if (!dm) return;"),
        ("DU_SRC", "badge-fit", "if (x <= fp->base.x) return;", "if (x < fp->base.x - 20) return;"),
        ("DU_SRC", "pane-h", "int list_h = fp->base.h - 5;", "int list_h = fp->base.h - 4;"),
        ("DU_SRC", "skip-parent", "if (!e || (e->flags & FE_IS_PARENT)) continue;", "if (!e) continue;"),
        ("DU_SRC", "cursor-focus", "(fp->base.flags & WF_FOCUSED) ? th->cursor_active_bg : th->cursor_inactive_bg",
         "th->cursor_inactive_bg"),
        ("DU_SRC", "pct-cap", "if (size >= total) return 100;", "if (size >= total) return 99;"),
        ("DU_SRC", "bar-glyph", "i < filled ? 0x2588u : 0x2591u", "i <= filled ? 0x2588u : 0x2591u"),
        ("DU_SRC", "bar-pen", "ScreenBuffer_set_pen(sb, th->accent, bg, ATTR_NONE);",
         "ScreenBuffer_set_pen(sb, th->muted, bg, ATTR_NONE);"),
        ("DU_SRC", "pct-sfx", "tmp[n] = '%';", "tmp[n] = '!';"),
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
        r1 = H.run_impl("x86_64", exe, "c", stdin=exact_script)
        r2 = H.run_impl("x86_64", exe, "c", stdin=pane_script)
        if r1.returncode == 0 and r2.returncode == 0 and r1.stdout.decode() == base_exact and r2.stdout.decode() == base_pane:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] GD4. {len(muts)}/{len(muts)} mutants killed across git_render.c and du_render.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        s_exact = build_exact_diff_script().encode()
        s_pane = build_du_pane_script().encode()
        base_exact = test_exact_diff(exe)
        base_pane = test_du_pane_and_asm_bugs(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r1 = H.run_impl("aarch64", exe_arm, "c", stdin=s_exact)
            r2 = H.run_impl("aarch64", exe_arm, "c", stdin=s_pane)
            assert r1.returncode == 0 and r1.stdout.decode() == base_exact, "aarch64 exact differs"
            assert r2.returncode == 0 and r2.stdout.decode() == base_pane, "aarch64 pane differs"
            print("[PASS] GD3. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, s_exact, s_pane, base_exact, base_pane)


if __name__ == "__main__":
    main()
