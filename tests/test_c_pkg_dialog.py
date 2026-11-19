#!/usr/bin/env python3
"""U2b.14: src/ui/pkg_dialog.c versus frozen x86_64 assembly
(tests/harness/pkg_dialog_reference.s): PkgDialog_vtbl, PkgDialog_new,
App_cmd_packages, App_pkg_install_confirm, layout, render, on_key, on_mouse.

PKD1 differential (x86_64):
    - PkgDialog_new, App_cmd_packages, App_pkg_install_confirm (empty/ok/err)
    - PkgDialog_layout: wide (90x26 -> 70x18), mid (56x14 -> 50x10), narrow (28x10 -> 30x8)
    - PkgDialog_render: empty installed/available tabs + header pills + hint
    - PkgDialog_handle_key: Esc/q, Up/k, Down/j, Tab (refresh installed<->available),
      v (verify ok/err), Enter (fallback verify ok/err in installed; install in available ok/err),
      r (run action ok/err), u (upgrade in installed / update in available, ok/err),
      d/Delete (remove ok/err + cursor clamp), i (opens InputDialog), unhandled -> 0
    - PkgDialog_handle_mouse: right click closes, left click ignored
PKD2 C-only regression tests for 3 real asm defects fixed:
    1) Selected row fill_rect now calls ScreenBuffer_set_pen(selected_fg, selected_bg) BEFORE
       fill_rect and passes ' ' as the 6th argument (asm passed uninitialized r9d & stale pen).
    2) KEY_ENTER on an installed package with an action no longer dereferences freed PkgDialog
       after App_close_dialog (real UAF in pkg_dialog.s:311-312).
    3) OOM safety on PkgDialog_new and entries allocation failure.
PKD3 qemu-aarch64 matches x86_64 byte for byte + regression & OOM tests
PKD4 mutation check across src/ui/pkg_dialog.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/pkg_dialog.c"
REF = "tests/harness/pkg_dialog_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
    "src/ui/dialog_input.c",
    "src/ui/dialogs_input_keys.c",
]

KEY_UP = 0x100001
KEY_DOWN = 0x100002
KEY_DELETE = 0x10000A
KEY_TAB = 0x10000C
KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "pkg_dialog_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        for sym in ("mem_alloc=fake_mem_alloc", "Object_alloc=fake_object_alloc"):
            subprocess.run(["objcopy", "--redefine-sym", sym, str(o)], check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/pkg_dialog_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DPKD_SRC="{full}"'])


def build_script() -> str:
    # F inst avail act_ok ver_rc rem_rc inst_rc regfind_rc upg_rc upd_rc
    return "\n".join([
        "F 0 0 0 0 0 0 0 0 0",
        "N 90 26",
        "R",                         # empty installed tab
        f"K 0x{KEY_TAB:x} 0",
        "R",                         # empty available tab
        f"K 0x{KEY_TAB:x} 0",        # toggle back 1 -> 0
        "L 0 0 56 14",
        "L 0 0 28 10",
        "L 0 0 90 26",
        # Empty list ignores v/Enter/r/d
        f"K 0x{ord('v'):x} 0",
        f"K 0x{KEY_ENTER:x} 0",
        f"K 0x{ord('r'):x} 0",
        f"K 0x{ord('d'):x} 0",
        # Populated installed (2) + available (2)
        "F 2 2 0 0 0 0 0 0 0",
        "N 90 26",
        "A",                         # App_cmd_packages
        # Navigation: Up at 0, Down, j, Down at max, k, Up
        f"K 0x{KEY_UP:x} 0",
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{ord('j'):x} 0",
        f"K 0x{ord('k'):x} 0",
        f"K 0x{ord('x'):x} 0",       # unhandled -> 0
        # Verify ok & err
        f"K 0x{ord('v'):x} 0",
        "F 2 2 0 -1 0 0 0 0 0",
        f"K 0x{ord('v'):x} 0",
        # Enter on installed w/o action -> fallback verify ok & err
        "F 2 2 0 0 0 0 0 0 0",
        f"K 0x{KEY_ENTER:x} 0",
        "F 2 2 0 -1 0 0 0 0 0",
        f"K 0x{KEY_ENTER:x} 0",
        # Run ('r') err & ok
        f"K 0x{ord('r'):x} 0",
        "F 2 2 1 0 0 0 0 0 0",
        f"K 0x{ord('r'):x} 0",
        # Upgrade ('u') on installed tab ok & err
        f"K 0x{ord('u'):x} 0",
        "F 2 2 0 0 0 0 0 -1 0",
        f"K 0x{ord('u'):x} 0",
        # Tab -> available tab, Update ('u') ok & err
        "F 2 2 0 0 0 0 0 0 0",
        f"K 0x{KEY_TAB:x} 0",
        f"K 0x{ord('u'):x} 0",
        "F 2 2 0 0 0 0 0 0 -1",
        f"K 0x{ord('u'):x} 0",
        # Available tab Enter -> install err (regfind fail), install err (archive fail), install ok -> switches to tab 0
        "F 2 2 0 0 0 0 -1 0 0",
        f"K 0x{KEY_ENTER:x} 0",
        "F 2 2 0 0 0 -1 0 0 0",
        f"K 0x{KEY_ENTER:x} 0",
        "F 2 2 0 0 0 0 0 0 0",
        f"K 0x{KEY_ENTER:x} 0",
        # Remove ('d' and KEY_DELETE): err, then remove last item -> cursor clamps down, remove remaining -> count=0
        "F 2 2 0 0 -1 0 0 0 0",
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{ord('d'):x} 0",
        "F 2 2 0 0 0 0 0 0 0",
        f"K 0x{ord('d'):x} 0",
        f"K 0x{KEY_DELETE:x} 0",
        # 'i' install prompt, Esc, 'q', mouse right & left
        f"K 0x{ord('i'):x} 0",
        f"K 0x{KEY_ESC:x} 0",
        f"K 0x{ord('q'):x} 0",
        "M 1 0 10 10",
        "M 1 2 10 10",
        # App_pkg_install_confirm: empty, ok, err
        "I ",
        "F 2 2 0 0 0 0 0 0 0",
        "I /tmp/foo.tgz",
        "F 2 2 0 0 0 -1 0 0 0",
        "I /tmp/bad.tgz",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=1 is_pkd=1 is_d=1", "A rc=1 ad=1 rd=1",
                   "call App_run_pkg_action 1 name=alpha-pkg exec=run.sh",
                   "call pkg_registry_upgrade", "call pkg_registry_update",
                   "call pkg_install_archive /tmp/foo.tgz sha=NULL",
                   "call pkg_remove beta-pkg", "K rc=0 ad=0"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] PKD1. pkg_dialog matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_fixes_and_oom(exe: Path, arch: str) -> str:
    rf = H.run_impl(arch, exe, "fix")
    assert rf.returncode == 0, rf.stderr.decode()
    fout = rf.stdout.decode()
    assert "selected_fg/selected_bg a=0" in fout, "selected row fill missing selected_fg/selected_bg"
    assert "alpha-pkg  1.2.3  tool  Alpha helper" in fout
    assert "beta-pkg  2.0.0  theme  Beta colors" in fout
    assert "FIX_UAF rc=1 app_poisoned=1" in fout
    assert "call App_run_pkg_action 1 name=beta-pkg exec=run.sh" in fout

    ro = H.run_impl(arch, exe, "oom")
    assert ro.returncode == 0 and "OOM1 ok=1" in ro.stdout.decode() and "OOM2 ok=1" in ro.stdout.decode()
    return fout


def test_mutations(t: Path, baseline: str, fix_base: str) -> None:
    s = build_script().encode()
    muts = [
        ("lay-max70", "if (dw > 70) dw = 70;", "if (dw > 60) dw = 60;"),
        ("lay-min30", "if (dw < 30) dw = 30;", "if (dw < 40) dw = 40;"),
        ("lay-max18", "if (dh > 18) dh = 18;", "if (dh > 14) dh = 14;"),
        ("lay-min8", "if (dh < 8) dh = 8;", "if (dh < 12) dh = 12;"),
        ("row-sel", "if (idx == d->cursor)", "if (0)"),
        ("key-down", "if (d->cursor + 1 < d->count)", "if (d->cursor < d->count)"),
        ("key-tab", "d->tab ^= 1;", "d->tab = 1;"),
        ("key-upg", "return d->tab == 0 ? pkg_registry_upgrade(envp) : pkg_registry_update(envp);",
         "return d->tab == 0 ? pkg_registry_update(envp) : pkg_registry_upgrade(envp);"),
        ("key-enter-uaf", "if (r == 1) return 1;", "if (0) return 1;"),
        ("mouse-rt", "if (ev->mouse_btn == MOUSE_RIGHT)", "if (ev->mouse_btn == MOUSE_LEFT)"),
        ("inst-empty", "if (!dlg->buf[0]) return;", "if (0) return;"),
        ("cmd-ad", "app->active_dialog = (uint64_t)(uintptr_t)d;", "app->active_dialog = 0;"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "pkg_dialog.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r1 = H.run_impl("x86_64", exe, "c", stdin=s)
        r2 = H.run_impl("x86_64", exe, "fix")
        if r1.returncode == 0 and r1.stdout.decode() == baseline and r2.returncode == 0 and r2.stdout.decode() == fix_base:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] PKD4. {len(muts)}/{len(muts)} mutants killed across pkg_dialog.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        fout = test_fixes_and_oom(exe, "x86_64")
        print("[PASS] PKD2. C-only regression checks pass (selected-row fill_rect, Enter UAF fix, OOM safety)")
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            fout_arm = test_fixes_and_oom(exe_arm, "aarch64")
            assert fout_arm == fout, "aarch64 fix output differs"
            print("[PASS] PKD3. qemu-aarch64 matches x86_64 byte for byte + fixes + OOM")
        test_mutations(t, out, fout)


if __name__ == "__main__":
    main()
