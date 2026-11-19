#!/usr/bin/env python3
"""U2b.8: src/ui/fuzzy_dialog.c versus frozen x86_64 assembly
(tests/harness/fuzzy_dialog_reference.s): FuzzyDialog (Command Palette & Fuzzy Finder).

FZ1 differential (x86_64):
    - Mode 0 (Command Palette): 19 built-in commands + 2 pkg actions (payload 0x1000+i),
      fuzzy filtering, insertion sort by descending score, scrolling past 14 visible rows,
      UP/DOWN, Backspace, ENTER/ESC, unhandled key delegation
    - Mode 1 (Fuzzy Finder): dir_fuzzy_collect on temp tree, filtering, empty match -> NULL,
      selected relative path
FZ2 real asm bug fixes proven in C:
    - OOM on struct / items_ptr / matches_ptr returns NULL with 0 leaked blocks
      (asm dereferenced NULL items_ptr)
    - Render uses Dialog_draw_frame(d, scr, th, nullptr, nullptr), theme argument, and
      ScreenBuffer_set_cell_pen -> highlights selected row (accent_fg/cursor_active_bg) and
      matched query characters (accent/... a=1)
FZ3 qemu-aarch64: matches x86_64 byte for byte (diff + render + OOM)
FZ4 mutation check across src/ui/fuzzy_dialog.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/fuzzy_dialog.c"
REF = "tests/harness/fuzzy_dialog_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c", "src/core/utf8.c",
    "src/core/memory.c", "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "src/fs/dir_fuzzy.c", "src/fs/dir_fuzzy_walk.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
]

KEY_UP = 0x100001
KEY_DOWN = 0x100002
KEY_BACKSPACE = 0x10000B
KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "fuzzy_dialog_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "Object_alloc=fake_object_alloc", str(o)],
                       check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/fuzzy_dialog_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DFZ_SRC="{full}"'])


def build_script(tree: Path) -> str:
    return "\n".join([
        # Mode 0: Command Palette (21 items: 19 built-in + 2 pkg)
        "N 0",
        "R",
        # Scroll down 16 times -> scroll advances past FUZ_VIS_ROWS (14) to 2, then back up to 0
        *[f"K 0x{KEY_DOWN:x} 0" for _ in range(16)],
        "R",
        *[f"K 0x{KEY_UP:x} 0" for _ in range(16)],
        # Type "pl" -> matches Plugin actions (payload 0x1000/0x1001), renders accent highlight
        f"K 0x{ord('p'):x} 0",
        f"K 0x{ord('l'):x} 0",
        "R",
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{KEY_BACKSPACE:x} 0",
        f"K 0x{KEY_BACKSPACE:x} 0",
        f"K 0x{KEY_BACKSPACE:x} 0",  # BS on empty
        # Type "zzz" -> 0 matches -> get_selected == 0
        f"K 0x{ord('z'):x} 0",
        f"K 0x{ord('z'):x} 0",
        f"K 0x{ord('z'):x} 0",
        f"K 0x{KEY_ENTER:x} 0",
        f"K 0x{KEY_ESC:x} 0",
        # Mode 1: Fuzzy Finder on temp tree
        f"N 1 {tree}",
        "R",
        f"K 0x{ord('m'):x} 0",
        f"K 0x{ord('a'):x} 0",
        f"K 0x{ord('i'):x} 0",
        f"K 0x{ord('n'):x} 0",
        "R",
        f"K 0x{KEY_ENTER:x} 0",
    ]) + "\n"


def test_differential(exe: Path, tree: Path) -> tuple[str, str]:
    s = build_script(tree).encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("tot=21 mc=21", "scr=2", "sel=4096", "sel=4097",
                   "q=zzz sel=0", "sel=src/main.c",
                   "call App_close_dialog 1 1", "call App_close_dialog 1 2"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] FZ1. fuzzy_dialog state/sort/keys/selection match frozen asm ({len(out.splitlines())} lines)")

    r_oom = H.run_impl("x86_64", exe, "oom")
    assert r_oom.returncode == 0 and "OOM k=3 null=1 live=0" in r_oom.stdout.decode(), r_oom.stdout.decode()
    r_ren = H.run_impl("x86_64", exe, "R", stdin=s)
    assert r_ren.returncode == 0
    ro = r_ren.stdout.decode()
    for needle in ("> pl", "Plugin: Format Code", "accent_fg/cursor_active_bg",
                   "accent/cursor_active_bg a=1", "accent/dialog_bg a=1", "text/dialog_bg a=0"):
        assert needle in ro, f"render coverage missing: {needle}"
    print("[PASS] FZ2. C fixes OOM crash/leaks and renders matched chars & selection via ScreenBuffer_set_cell_pen")
    return out, ro


def test_mutations(t: Path, tree: Path, base_diff: str, base_ren: str) -> None:
    s = build_script(tree).encode()
    muts = [
        ("pkg-base", "items[d->total_cnt].pad = (int32_t)(0x1000 + i);",
                     "items[d->total_cnt].pad = (int32_t)(0x2000 + i);", "c", base_diff),
        ("sort-skip", "if (d->query_buf[0] == '\\0') return;",
                      "if (1 || d->query_buf[0] == '\\0') return;", "c", base_diff),
        ("sort-dir", "while (j >= 0 && matches[j].score < key.score)",
                     "while (j >= 0 && matches[j].score > key.score)", "c", base_diff),
        ("score-neg", "if (sc < 0) continue;", "if (sc <= 0) continue;", "c", base_diff),
        ("row-mask", "if (ch_idx < 64 && (mask & (1ULL << ch_idx)))",
                     "if (0 && ch_idx < 64 && (mask & (1ULL << ch_idx)))", "R", base_ren),
        ("row-sel", "if (selected) {", "if (0 && selected) {", "R", base_ren),
        ("key-dn-scr", "if (c >= (int)d->scroll + FUZ_VIS_ROWS)",
                       "if (c > (int)d->scroll + FUZ_VIS_ROWS)", "c", base_diff),
        ("key-up-scr", "if (c < (int)d->scroll) d->scroll = (uint32_t)c;",
                       "if (0 && c < (int)d->scroll) d->scroll = (uint32_t)c;", "c", base_diff),
        ("key-bs", "if (d->query_len > 0) {", "if (d->query_len > 1) {", "c", base_diff),
        ("key-esc", "if (key == KEY_ESC) { Dialog_on_cancel(&d->base); return 1; }",
                    "if (key == KEY_ESC) { Dialog_on_confirm(&d->base); return 1; }", "c", base_diff),
        ("sel-mode0", "if (self->mode == 0) return (uintptr_t)(uint32_t)it->pad;",
                      "if (self->mode == 9) return (uintptr_t)(uint32_t)it->pad;", "c", base_diff),
        ("sel-empty", "if ((int)self->match_cnt <= 0 || self->cursor >= self->match_cnt) return 0;",
                      "if (0 && ((int)self->match_cnt <= 0 || self->cursor >= self->match_cnt)) return 0;", "c", base_diff),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str, mode: str, base: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "fuzzy_dialog.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, mode, stdin=s)
        if r.returncode == 0 and r.stdout.decode() == base:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] FZ4. {len(muts)}/{len(muts)} mutants killed across fuzzy_dialog.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        tree = t / "proj"
        (tree / "src").mkdir(parents=True)
        (tree / "src" / "main.c").write_text("int main(){}\n")
        (tree / "src" / "domain.c").write_text("int x;\n")
        (tree / "README.md").write_text("# readme\n")

        exe = build("x86_64", t / "x86")
        out, ren = test_differential(exe, tree)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            s = build_script(tree).encode()
            r1 = H.run_impl("aarch64", exe_arm, "c", stdin=s)
            r2 = H.run_impl("aarch64", exe_arm, "R", stdin=s)
            r3 = H.run_impl("aarch64", exe_arm, "oom")
            assert r1.returncode == 0 and r1.stdout.decode() == out, "aarch64 diff mismatch"
            assert r2.returncode == 0 and r2.stdout.decode() == ren, "aarch64 render mismatch"
            assert r3.returncode == 0 and "OOM k=3 null=1 live=0" in r3.stdout.decode(), "aarch64 oom mismatch"
            print("[PASS] FZ3. qemu-aarch64 matches x86_64 byte for byte (diff + render + OOM)")
        test_mutations(t, tree, out, ren)


if __name__ == "__main__":
    main()
