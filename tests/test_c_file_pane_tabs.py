#!/usr/bin/env python3
"""U4.3: src/ui/file_pane_tabs.c versus frozen x86_64 assembly
(tests/harness/file_pane_tabs_reference.s): fp_get_active_tab, FilePane_nav_to,
FilePane_hist_back, FilePane_hist_fwd, FilePane_tab_new, FilePane_tab_switch,
FilePane_tab_close.

FPT1 differential (x86_64):
    - fp_get_active_tab: valid index, negative index, >= tab_count
    - FilePane_nav_to: normal chdir, DU mode triggers dir_du_populate, negative -errno
      propagated as full 64-bit intptr_t without mutating cursor/history/frecency
    - FilePane_hist_back / FilePane_hist_fwd: empty history, normal traversal, chdir error
    - FilePane_tab_new: saves active tab metadata, creates tabs up to NAV_TAB_MAX=8, 9th fails
    - FilePane_tab_switch: out-of-range (<0, >=cnt), same tab no-op, switch saves/restores
      cursor/scroll/sort_mode/sort_desc/show_hidden/path
    - FilePane_tab_close: last tab refused, out-of-range refused, close before active
      (decrements active_tab), close after active (keeps active_tab), close active in middle,
      close active at end (clamps to tab_count-1), idx=-1 closes active tab, frees history strings
FPT2 qemu-aarch64 matches x86_64 byte for byte
FPT3 mutation check across src/ui/file_pane_tabs.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/file_pane_tabs.c"
REF = "tests/harness/file_pane_tabs_reference.s"
CORE = [
    "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/fs/nav_state.c",
]


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "file_pane_tabs_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "DirModel_chdir=fake_DirModel_chdir",
            "--redefine-sym", "dir_du_populate=fake_dir_du_populate",
            "--redefine-sym", "FilePane_ensure_visible=fake_FilePane_ensure_visible",
            "--redefine-sym", "nav_frecency_record=fake_nav_frecency_record",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/file_pane_tabs_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DFPT_SRC="{full}"'])


def build_script() -> str:
    return "\n".join([
        # fp_get_active_tab bounds
        "G -1", "G 0", "G 1",
        # Empty history back/fwd
        "B", "F",
        # Close last tab -> refused
        "X -1", "X 0",
        # Nav error preserves cursor and returns full -errno
        "M 5 2 1 1 1",
        "E -13",
        "N /denied",
        "E 0",
        # Normal nav + DU mode nav
        "N /alpha",
        "D 1",
        "N /beta",
        "D 0",
        "M 9 3 2 1 1",
        # History back / fwd + error during back
        "B", "F",
        "E -2", "B", "E 0",
        "B",
        # Tab creation + metadata save/restore + switch
        "M 4 1 3 0 1",
        "+",             # tab 1 at /alpha
        "N /tab1_dir",
        "M 7 2 1 1 0",
        "+",             # tab 2 at /tab1_dir
        "N /tab2_dir",
        "M 11 5 2 0 0",
        "S -1", "S 3", "S 2",  # invalid, invalid, same
        "S 0",           # switch to tab 0 -> restores sm=3, sd=0, sh=1, cur=4, scr=1
        "S 1",           # switch to tab 1 -> restores /tab1_dir, cur=7, scr=2
        # Fill up to NAV_TAB_MAX=8, 9th fails
        "+", "+", "+", "+", "+", "+",
        # Close invalid idx
        "X 99",
        # Close tab after active (switch to 1, close 7)
        "S 1",
        "X 7",
        # Close tab before active (active=1 -> becomes 0)
        "X 0",
        # Switch to last tab and close active via -1 (clamps active_tab)
        "S 5",
        "X -1",
        # Switch to middle tab 2 and close active explicitly
        "S 2",
        "X 2",
        # Drain down to 1 tab
        "X -1", "X -1", "X -1", "X -1",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("G idx=null", "G idx=0", "N rc=-13", "call dir_du_populate 1",
                   "call nav_frecency_record |/beta|", "B rc=1", "F rc=1", "B rc=0",
                   "+ rc=0", "X 99 rc=0", "X -1 rc=0", "sm=3 sd=0 sh=1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] FPT1. file_pane_tabs matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("get-neg", "if (idx < 0 || idx >= (int32_t)self->tab_count) return nullptr;",
         "if (idx >= (int32_t)self->tab_count) return nullptr;"),
        ("nav-du", "if (m->du_mode) dir_du_populate(m);", "if (0) dir_du_populate(m);"),
        ("nav-err", "if (rc < 0) return rc;", "if (rc < 0) return 0;"),
        ("hist-b", "if (DirModel_chdir(m, p) < 0) return 0;",
         "if (DirModel_chdir(m, p) < 0) return 1;"),
        ("tab-max", "if ((int32_t)self->tab_count >= NAV_TAB_MAX || !self->tabs) return 0;",
         "if ((int32_t)self->tab_count >= NAV_TAB_MAX - 1 || !self->tabs) return 0;"),
        ("sw-same", "if (idx == (int32_t)self->active_tab) return 1;",
         "if (idx == (int32_t)self->active_tab) return 0;"),
        ("sw-sort", "m->sort_mode = t->sort_mode;", "m->sort_mode = 0;"),
        ("sw-cur", "self->cursor = (uint32_t)t->cursor;", "self->cursor = 0;"),
        ("cl-last", "if ((int32_t)self->tab_count <= 1) return 0;",
         "if ((int32_t)self->tab_count <= 2) return 0;"),
        ("cl-before", "if (act > idx) {", "if (act >= idx) {"),
        ("cl-clamp", "if (act >= (int32_t)self->tab_count) self->active_tab = self->tab_count - 1;",
         "if (act > (int32_t)self->tab_count) self->active_tab = self->tab_count - 1;"),
        ("cl-neg1", "if (idx < 0) idx = (int32_t)self->active_tab;", "if (idx < 0) idx = 0;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "file_pane_tabs.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] FPT3. {len(muts)}/{len(muts)} mutants killed across file_pane_tabs.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] FPT2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
