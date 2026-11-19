#!/usr/bin/env python3
"""U4.8: src/ui/file_pane.c versus frozen x86_64 assembly
(tests/harness/file_pane_reference.s): FilePane_vtbl, FilePane_new, FilePane_dtor,
get_list_h, FilePane_ensure_visible, FilePane_get_selected_entry,
FilePane_reload_keep_cursor, FilePane_enter_parent.

FP1 differential (x86_64):
    - FilePane_new: OOM on object, OOM on DirModel (frees fp), normal init & vtable
    - FilePane_dtor: frees tabs and deletes DirModel
    - get_list_h: clamps h - 5 to >= 1
    - FilePane_ensure_visible: empty model, negative cursor, cursor >= count, cursor above/below
      viewport, scroll clamped to [0, max(0, count - lh)]
    - FilePane_get_selected_entry: stats valid entry, NULL out of range
    - FilePane_reload_keep_cursor: explicit focus_name (found/missing), NULL preserves active
      entry across order shift, NULL on empty model
    - FilePane_enter_parent: virtual mode exits, root "/" no-op, chdir error no-op, normal
      parent selects child basename (found + missing -> 0) + DU mode + hist/frecency
FP2 qemu-aarch64 matches x86_64 byte for byte
FP3 mutation check across src/ui/file_pane.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/file_pane.c"
REF = "tests/harness/file_pane_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c",
    "src/core/memory.c", "src/core/syscall.c", "src/core/mem_prims.c",
]


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "file_pane_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "Object_alloc=fake_Object_alloc",
            "--redefine-sym", "DirModel_new=fake_DirModel_new",
            "--redefine-sym", "nav_tabs_alloc=fake_nav_tabs_alloc",
            "--redefine-sym", "nav_tabs_free=fake_nav_tabs_free",
            "--redefine-sym", "DirModel_get_entry=fake_DirModel_get_entry",
            "--redefine-sym", "DirModel_ensure_entry_stat=fake_DirModel_ensure_entry_stat",
            "--redefine-sym", "DirModel_entry_name=fake_DirModel_entry_name",
            "--redefine-sym", "DirModel_reload=fake_DirModel_reload",
            "--redefine-sym", "DirModel_find_by_name=fake_DirModel_find_by_name",
            "--redefine-sym", "fp_exit_virtual=fake_fp_exit_virtual",
            "--redefine-sym", "DirModel_chdir=fake_DirModel_chdir",
            "--redefine-sym", "dir_du_populate=fake_dir_du_populate",
            "--redefine-sym", "fp_get_active_tab=fake_fp_get_active_tab",
            "--redefine-sym", "nav_hist_push=fake_nav_hist_push",
            "--redefine-sym", "nav_frecency_record=fake_nav_frecency_record",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/file_pane_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DFP_SRC="{full}"'])


def build_script() -> str:
    return "\n".join([
        # get_list_h
        "H 0", "H 5", "H 6", "H 15",
        # FilePane_ensure_visible: count, h, cursor, scroll
        "V 0 10 3 2",      # empty -> 0, 0
        "V 20 10 -3 5",    # neg cursor -> 0, scroll -> 0
        "V 20 10 20 0",    # cursor == count -> 19, scroll -> 15
        "V 20 10 99 0",    # cursor > count -> 19, scroll -> 15
        "V 20 10 2 10",    # cursor < scroll -> scroll=2
        "V 20 10 7 2",     # cursor == scroll+5 -> scroll=3
        "V 20 10 10 2",    # cursor > scroll+5 -> scroll=6
        "V 20 10 10 99",   # scroll > max_scroll -> clamped
        "V 3 10 1 -4",     # count < lh, neg scroll -> scroll=0
        # FilePane_get_selected_entry
        "V 4 10 1 0",
        "G 1",             # alpha
        "G 9",             # null
        # FilePane_reload_keep_cursor
        "V 4 10 1 0",
        "R 1 -",           # NULL focus_name: preserves "alpha" across shift (1 -> 2)
        "R 0 zebra",       # explicit focus_name -> 3
        "R 0 ..",          # explicit focus_name at idx=0
        "R 0 nonexistent", # missing -> keeps cursor
        "V 0 10 0 0",
        "R 0 -",           # empty model + NULL focus_name
        # FilePane_enter_parent: exit_virt, chdir_err, du_mode, path
        "P 1 0 0 /a/child",     # virtual mode -> early return
        "P 0 0 0 /",            # root "/" -> early return
        "P 0 -13 0 /a/child",   # chdir error -> early return
        "P 0 0 0 /a/child",     # normal -> parent "/a", selects "child" (idx 2)
        "P 0 0 1 /a/missing",   # DU mode + missing basename -> cur=0, dir_du_populate called
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("OOM_FP=1", "OOM_DM=1", "NEW id=7 lci=-1 hr=-1 hh=-1 tc=1 cls=FilePane",
                   "H 6 -> 1", "H 15 -> 10", "V cur=19 scr=15", "G ent=alpha", "G ent=null",
                   "R cur=2 scr=0", "R cur=3 scr=0", "P path=|/a| cur=2 scr=0",
                   "call dir_du_populate", "call nav_hist_push ok=1 |/a|",
                   "call nav_tabs_free ok=1 cnt=1", "call DirModel_dtor"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] FP1. FilePane matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("init-lci", "fp->last_click_idx = (uint32_t)-1;", "fp->last_click_idx = 0;"),
        ("init-tc", "fp->tab_count = 1;", "fp->tab_count = 0;"),
        ("lh-5", "int h = self->base.h - 5;", "int h = self->base.h - 4;"),
        ("ev-neg", "if (cur < 0) cur = 0;", "if (cur < -5) cur = 0;"),
        ("ev-max", "if ((uint64_t)(uint32_t)cur >= cnt) cur = (int32_t)cnt - 1;",
         "if ((uint64_t)(uint32_t)cur > cnt) cur = (int32_t)cnt - 1;"),
        ("ev-top", "if (cur < scr) scr = cur;", "if (0) scr = cur;"),
        ("ev-bot", "else if (cur >= scr + lh) scr = cur - lh + 1;",
         "else if (cur > scr + lh) scr = cur - lh + 1;"),
        ("sel-stat", "if (e) DirModel_ensure_entry_stat(m, e);", "if (0) DirModel_ensure_entry_stat(m, e);"),
        ("rel-find", "if (idx >= 0) self->cursor = (uint32_t)idx;", "if (idx > 0) self->cursor = (uint32_t)idx;"),
        ("par-virt", "if (fp_exit_virtual(self)) return;", "if (0) return;"),
        ("par-root", "if (m->path[0] == '/' && m->path[1] == 0) return;", "if (0) return;"),
        ("par-du", "if (m->du_mode) dir_du_populate(m);", "if (0) dir_du_populate(m);"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "file_pane.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] FP3. {len(muts)}/{len(muts)} mutants killed across file_pane.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] FP2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
