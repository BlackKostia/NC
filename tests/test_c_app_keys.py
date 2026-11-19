#!/usr/bin/env python3
"""A3.1: src/app/app_keys.c versus frozen x86_64 assembly oracle.

AK1 differential (x86_64):
    - Modal dialog interception (WidgetVtbl.on_key)
    - duoprc configurable keybind dispatch (config_lookup_bind >= 0)
    - Terminal pane key interception (term_on_key == 2 -> App_layout, == 1 -> consumed)
    - app_handle_ext_key interception
    - All Ctrl+ combos (c/q/p/h/r/n/g/o/t/w OK & last-tab/d/other -> pane)
    - All Alt+ combos (t/T/l/j/u/other -> pane)
    - Function keys F1..F10 (App_dispatch_f_action 0..9)
    - Plain keys: Tab/BTab (dual vs preview), q/Q, /, ., z, Delete, Esc (cancel
      active/left/right streaming, clear active filter, no-op), fallback pane on_key
AK2 qemu-aarch64 matches x86_64 byte for byte
AK3 mutation check (16 mutants)
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/app/app_keys.c"
REF = "tests/harness/app_keys_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c",
    "src/core/memory.c", "src/core/mem_prims.c",
    "build/i18n_en.c",
]


def build(arch: str, t: Path, src_ovr: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "app_keys_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "config_lookup_bind=fake_config_lookup_bind",
            "--redefine-sym", "term_on_key=fake_term_on_key",
            "--redefine-sym", "FilePane_tab_new=fake_FilePane_tab_new",
            "--redefine-sym", "FilePane_tab_close=fake_FilePane_tab_close",
            "--redefine-sym", "FilePane_ensure_visible=fake_FilePane_ensure_visible",
            "--redefine-sym", "DirModel_apply_filter=fake_DirModel_apply_filter",
            "--redefine-sym", "DirModel_cancel_load=fake_DirModel_cancel_load",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    defs = [f'-DKEYS_SRC="{src_ovr or (ROOT / SRC)}"']
    return H.build(arch, t, ["tests/harness/app_keys_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


MOD_ALT, MOD_CTRL = 2, 4
KEY_DELETE, KEY_TAB, KEY_BTAB, KEY_ESC = 0x10000A, 0x10000C, 0x10000D, 0x10000F
KEY_F1, KEY_F10 = 0x100011, 0x10001A


def k(lat: int, mods: int = 0, dlg: int = 0, bind: int = -1, term: int = 0, ext: int = 0,
      rmode: int = 0, lmask: int = 0, flt: int = 0, tc: int = 1) -> str:
    return f"K {lat} {mods} {dlg} {bind} {term} {ext} {rmode} {lmask} {flt} {tc}"


SCRIPT = "\n".join([
    k(ord("a"), dlg=1),                          # modal dialog
    k(ord("a"), bind=7),                         # duoprc bind
    k(ord("a"), term=2),                         # term_on_key == 2 -> App_layout
    k(ord("a"), term=1),                         # term_on_key == 1 -> consumed
    k(ord("a"), ext=1),                          # app_handle_ext_key handled
    # Ctrl combos
    *[k(ord(c), MOD_CTRL) for c in "cqphrngotwdx"],
    k(ord("w"), MOD_CTRL, tc=0),                 # last tab warning
    # Alt combos
    *[k(ord(c), MOD_ALT) for c in "tTljuX"],
    # F1..F10
    k(KEY_F1), k(KEY_F1 + 4), k(KEY_F10),
    # Plain keys
    k(KEY_TAB, rmode=0), k(KEY_BTAB, rmode=0), k(KEY_TAB, rmode=1),
    k(ord("q")), k(ord("Q")), k(ord("/")), k(ord(".")), k(ord("z")), k(KEY_DELETE),
    # Esc variants
    k(KEY_ESC, lmask=1),                         # active/left loading
    k(KEY_ESC, lmask=2),                         # right loading
    k(KEY_ESC, flt=1),                           # clear filter
    k(KEY_ESC),                                  # no-op
    # Fallback to pane
    k(ord("j")),
]) + "\n"


def test_differential(exe: Path) -> str:
    out = H.diff_impls(exe, stdin=SCRIPT.encode()).decode()
    for needle in ("vcall on_key id=99", "call App_dispatch_action 1 a=7",
                   "call App_layout 1", "call FilePane_tab_close 1 i=-1",
                   "call App_dispatch_f_action 1 i=0", "call App_dispatch_f_action 1 i=9",
                   "call App_set_active_pane 1 p=2", "call BookmarkDialog_new 1 m=0",
                   "call BookmarkDialog_new 1 m=1", "call DirModel_cancel_load m=1",
                   "call DirModel_cancel_load m=2", "call DirModel_apply_filter f=||",
                   "vcall on_key id=1 k=106"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] AK1. app_keys matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    src = (ROOT / SRC).read_text()
    muts = [
        ("dlg-first", "if (app->active_dialog) {", "if (0) {"),
        ("bind-ge0", "if (act >= 0) { App_dispatch_action(app, act); return; }",
         "if (act > 99) { App_dispatch_action(app, act); return; }"),
        ("term-2", "if (tr == 2) { App_layout(app); return; }",
         "if (tr == 9) { App_layout(app); return; }"),
        ("term-nz", "if (tr != 0) return;", "if (tr > 9) return;"),
        ("ext-nz", "if (app_handle_ext_key(app, key, mods)) return;",
         "if (app_handle_ext_key(app, key, mods) > 9) return;"),
        ("ctrl-ref", "case 'r': reload_both_panes(app, nullptr);",
         "case 'r': App_cmd_quit(app);"),
        ("ctrl-tc", "if (!FilePane_tab_close(pane, -1)) {", "if (FilePane_tab_close(pane, -1)) {"),
        ("alt-case", "switch (key | 0x20) {", "switch (key) {"),
        ("alt-tasks", "case 'j': App_task_show(app); return 1;",
         "case 'j': App_cmd_usermenu(app); return 1;"),
        ("fkey-rng", "if (key >= KEY_F1 && key <= KEY_F10) {",
         "if (key >= KEY_F1 && key < KEY_F10) {"),
        ("tab-prev", "if (app->right_mode != RIGHT_MODE_PREVIEW)",
         "if (app->right_mode == RIGHT_MODE_PREVIEW)"),
        ("esc-rm", "if (rm->is_loading) { cancel_stream(app, rm); return; }",
         "if (0 && rm->is_loading) { cancel_stream(app, rm); return; }"),
        ("esc-flt", "if (am->filter[0] == '\\0') return;",
         "if (am->filter[0] != '\\0') return;"),
        ("frec-m1", "case 'z': open_bookmarks(app, 1); return 1;",
         "case 'z': open_bookmarks(app, 0); return 1;"),
        ("del-tr", "case KEY_DELETE: App_cmd_trash(app); return 1;",
         "case KEY_DELETE: App_cmd_quit(app); return 1;"),
        ("pane-fb", "(void)WIDGET_CALL((Widget *)(uintptr_t)app->active_pane, on_key, evt);", "(void)evt;"),
    ]
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src and old != new, name
        mp = t / f"m{idx}" / "app_keys.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=SCRIPT.encode())
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] AK3. {len(muts)}/{len(muts)} mutants killed across app_keys.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=SCRIPT.encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] AK2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
