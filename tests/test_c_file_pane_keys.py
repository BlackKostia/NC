#!/usr/bin/env python3
"""U4.4: src/ui/file_pane_keys.c versus frozen x86_64 assembly
(tests/harness/file_pane_keys_reference.s): FilePane_on_key and scrub_scrollbar.

FPK1 differential (x86_64):
    - FilePane_on_key: Ctrl+A (select all), other Ctrl+* ignored, Up/k, Down/j, PgUp/PgDn,
      Home/g, End/G, Space/Insert (toggle + advance), '*', Enter, Backspace, '~' (no HOME,
      chdir error, chdir ok, chdir ok + du_mode), unknown plain key -> 0
    - scrub_scrollbar: above top (clamped to 0), middle rows, at/below bottom (clamped to max),
      list_h < 2 -> 0, count <= list_h -> 0
FPK2 qemu-aarch64 matches x86_64 byte for byte
FPK3 mutation check across src/ui/file_pane_keys.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/file_pane_keys.c"
REF = "tests/harness/file_pane_keys_reference.s"
CORE = [
    "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c",
]


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "file_pane_keys_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "get_list_h=fake_get_list_h",
            "--redefine-sym", "FilePane_ensure_visible=fake_FilePane_ensure_visible",
            "--redefine-sym", "FilePane_enter_parent=fake_FilePane_enter_parent",
            "--redefine-sym", "DirModel_toggle_select=fake_DirModel_toggle_select",
            "--redefine-sym", "DirModel_select_all_toggle=fake_DirModel_select_all_toggle",
            "--redefine-sym", "DirModel_chdir=fake_DirModel_chdir",
            "--redefine-sym", "dir_du_populate=fake_dir_du_populate",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/file_pane_keys_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DFPK_SRC="{full}"'])


def build_script() -> str:
    # MOD_CTRL=4; KEY_UP=0x100001..KEY_BACKSPACE=0x10000B, KEY_ENTER=0x10000E
    return "\n".join([
        "C 10 2 50 10",
        # Ctrl+A vs Ctrl+B
        f"K 4 {ord('a')}",
        f"K 4 {ord('b')}",
        # Movement keys
        "K 0 0x100001",         # KEY_UP
        f"K 0 {ord('k')}",
        "K 0 0x100002",         # KEY_DOWN
        f"K 0 {ord('j')}",
        "K 0 0x100007",         # KEY_PGUP
        "K 0 0x100008",         # KEY_PGDN
        "K 0 0x100005",         # KEY_HOME
        "K 0 0x100006",         # KEY_END
        f"K 0 {ord('g')}",
        f"K 0 {ord('G')}",
        # Selection keys
        f"K 0 {ord(' ')}",
        "K 0 0x100009",         # KEY_INSERT
        f"K 0 {ord('*')}",
        # Enter / Backspace
        "K 0 0x10000E",         # KEY_ENTER
        "K 0 0x10000B",         # KEY_BACKSPACE
        # '~' home dir: no HOME, chdir error, chdir ok, chdir ok + du_mode
        "C 7 3 50 10",
        "H 0 0 0",
        f"K 0 {ord('~')}",
        "H 1 -13 0",
        f"K 0 {ord('~')}",
        "H 1 0 0",
        f"K 0 {ord('~')}",
        "C 7 3 50 10",
        "H 1 0 1",
        f"K 0 {ord('~')}",
        # Unknown plain key
        f"K 0 {ord('z')}",
        # scrub_scrollbar (base.y=2, so list starts at y=5)
        "C 0 5 50 10",
        "S 0", "S 4", "S 5", "S 7", "S 10", "S 14", "S 15", "S 20",
        # count <= list_h -> 0
        "C 0 5 8 10",
        "S 7",
        # list_h < 2 -> 0
        "C 0 5 50 1",
        "S 5",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("call select_all_toggle 1", "call toggle_select 1 idx=49",
                   "call open_selected 1 1", "call enter_parent 1",
                   "call chdir |/home/tester| err=-13", "call dir_du_populate 1",
                   "K rc=0 cur=0 scr=0 rd=0", "S my=14 scr=40", "S my=7 scr=0"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] FPK1. file_pane_keys matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("ctrl-a", "if (key == 'a') { DirModel_select_all_toggle(m); goto sync; }",
         "if (key == 'b') { DirModel_select_all_toggle(m); goto sync; }"),
        ("pgup", "fp->cursor -= (uint32_t)get_list_h(fp);", "fp->cursor -= 1;"),
        ("end-m1", "fp->cursor = (uint32_t)((int32_t)m->count - 1);",
         "fp->cursor = (uint32_t)((int32_t)m->count);"),
        ("sel-inc", "DirModel_toggle_select(m, (int32_t)fp->cursor); fp->cursor++;",
         "DirModel_toggle_select(m, (int32_t)fp->cursor);"),
        ("home-du", "if (m->du_mode) dir_du_populate(m);", "if (0) dir_du_populate(m);"),
        ("home-err", "if (DirModel_chdir(m, home) >= 0)", "if (DirModel_chdir(m, home) > 0)"),
        ("redraw", "app->need_redraw = 1;", "app->need_redraw = 0;"),
        ("scr-off3", "int rel = my - self->base.y - 3;", "int rel = my - self->base.y - 2;"),
        ("scr-neg", "if (rel < 0) rel = 0;", "if (rel < -1) rel = 0;"),
        ("scr-top", "if (rel >= lh) rel = lh - 1;", "if (rel > lh) rel = lh - 1;"),
        ("scr-lh2", "if (max_scroll <= 0 || lh < 2)", "if (max_scroll <= 0 || lh < 1)"),
        ("scr-div", "(uint32_t)(lh - 1)", "(uint32_t)lh"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "file_pane_keys.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] FPK3. {len(muts)}/{len(muts)} mutants killed across file_pane_keys.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] FPK2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
