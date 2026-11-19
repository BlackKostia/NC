#!/usr/bin/env python3
"""A2.6: src/app/app_layout.c versus frozen x86_64 assembly oracle.

ALY1 differential (x86_64):
    - App_layout: odd width split, terminal pane height subtraction, min main_h=6 clamp,
      with and without active_dialog
    - App_render: dual-pane vs preview mode, with and without active_dialog, clears
      need_redraw, calls pre/post flush hooks
    - App_set_status (3500ms ttl + need_redraw=1)
    - App_set_active_pane (same-pane no-op, switch to right pane with focus vcalls +
      sync preview in preview mode) & get_inactive_pane
    - App_sync_preview & App_preview_fire (non-preview early return, NULL entry,
      PreviewPane_load returning 0, async seq > 0, sync fallback seq <= 0)
ALY2 qemu-aarch64 matches x86_64 byte for byte
ALY3 mutation check (14 mutants)
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/app/app_layout.c"
REF = "tests/harness/app_layout_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c",
    "src/core/utf8.c", "src/core/memory.c", "src/core/mem_prims.c",
    "build/i18n_en.c",
]


def build(arch: str, t: Path, src_ovr: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "app_layout_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "ScreenBuffer_resize=fake_ScreenBuffer_resize",
            "--redefine-sym", "ScreenBuffer_clear=fake_ScreenBuffer_clear",
            "--redefine-sym", "ScreenBuffer_flush=fake_ScreenBuffer_flush",
            "--redefine-sym", "term_height=fake_term_height",
            "--redefine-sym", "term_render=fake_term_render",
            "--redefine-sym", "img_preview_pre_flush=fake_img_preview_pre_flush",
            "--redefine-sym", "img_preview_post_flush=fake_img_preview_post_flush",
            "--redefine-sym", "StatusBar_set_message=fake_StatusBar_set_message",
            "--redefine-sym", "sys_clock_ms=fake_sys_clock_ms",
            "--redefine-sym", "FilePane_get_selected_entry=fake_FilePane_get_selected_entry",
            "--redefine-sym", "DirModel_entry_name=fake_DirModel_entry_name",
            "--redefine-sym", "PreviewPane_load=fake_PreviewPane_load",
            "--redefine-sym", "PreviewPane_thumb_req=fake_PreviewPane_thumb_req",
            "--redefine-sym", "fs_preview_request=fake_fs_preview_request",
            "--redefine-sym", "PreviewPane_read_sync=fake_PreviewPane_read_sync",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    defs = [f'-DLAYOUT_SRC="{src_ovr or (ROOT / SRC)}"']
    return H.build(arch, t, ["tests/harness/app_layout_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


SCRIPT = "\n".join([
    # L <w> <h> <term_h> <has_dlg>
    "L 81 25 0 0",
    "L 80 24 6 1",
    "L 40 10 8 0",    # main_h = 10-3-8 = -1 -> clamps to 6
    # R <right_mode> <has_dlg>
    "R 0 0",
    "R 1 1",
    # S <kind>
    "S 2",
    # A <to_right> <right_mode>
    "A 0 0",          # already active -> no-op
    "A 1 0",          # switch to right, dual mode
    "A 1 1",          # switch to right, preview mode (schedules debounce)
    # P <right_mode> <has_fe> <pv_load_rc> <pv_req_rc>
    "P 0 1 1 7",      # non-preview -> clears due & returns
    "P 1 0 1 7",      # NULL entry -> PreviewPane_load(pv, NULL, NULL)
    "P 1 1 0 7",      # PreviewPane_load returns 0 -> no async request
    "P 1 1 1 9",      # async seq=9
    "P 1 1 1 0",      # seq == 0 -> PreviewPane_read_sync
    "P 1 1 1 -1",     # async failed -> PreviewPane_read_sync
]) + "\n"


def test_differential(exe: Path) -> str:
    out = H.diff_impls(exe, stdin=SCRIPT.encode()).decode()
    for needle in ("vcall layout t=2 0,1,40,22", "vcall layout t=3 40,1,41,22",
                   "vcall layout t=2 0,1,20,6", "vcall layout t=7 0,0,80,24",
                   "vcall render t=3", "vcall render t=4", "vcall render t=7",
                   "ttl=3500", "AP act=2 inact=1 due=5025 nr=1",
                   "PF due=0 seq=9 nr=1", "call PreviewPane_read_sync 1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] ALY1. app_layout matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    src = (ROOT / SRC).read_text()
    muts = [
        ("min-h", "if (main_h < 6) main_h = 6;", "if (main_h < 4) main_h = 4;"),
        ("term-sub", "int main_h = h - 3 - term_height(h - 3);", "int main_h = h - 3;"),
        ("sb-y", "WIDGET_CALL((Widget *)(uintptr_t)app->status_bar, layout, 0, h - 2, w, 1);",
         "WIDGET_CALL((Widget *)(uintptr_t)app->status_bar, layout, 0, h - 1, w, 1);"),
        ("dlg-lay", "if (app->active_dialog)\n        WIDGET_CALL((Widget *)(uintptr_t)app->active_dialog, layout, 0, 0, w, h);",
         ""),
        ("rnd-prev", "Widget *right = (Widget *)(uintptr_t)(app->right_mode == RIGHT_MODE_PREVIEW ? app->preview_pane : app->right_pane);",
         "Widget *right = (Widget *)(uintptr_t)app->right_pane;"),
        ("rnd-clr", "app->need_redraw = 0;", "app->need_redraw = 1;"),
        ("stat-ttl", "StatusBar_set_message((StatusBar *)(uintptr_t)app->status_bar, msg, kind, 3500);",
         "StatusBar_set_message((StatusBar *)(uintptr_t)app->status_bar, msg, kind, 1000);"),
        ("act-same", "if ((uint64_t)(uintptr_t)pane == app->active_pane) return;",
         "if ((uint64_t)(uintptr_t)pane == 0) return;"),
        ("inact-cmp", "if (app->left_pane != app->active_pane) return (FilePane *)(uintptr_t)app->left_pane;",
         "if (app->left_pane == app->active_pane) return (FilePane *)(uintptr_t)app->left_pane;"),
        ("sync-deb", "app->preview_due = (uint64_t)(sys_clock_ms() + PREVIEW_DEBOUNCE_MS);",
         "app->preview_due = (uint64_t)sys_clock_ms();"),
        ("pf-due", "app->preview_due = 0;", "app->preview_due = 1;"),
        ("pf-mode", "if (app->right_mode != RIGHT_MODE_PREVIEW) return;",
         "if (app->right_mode == 99) return;"),
        ("pf-seq", "if (seq > 0) app->preview_seq = (uint32_t)seq;",
         "if (seq >= 0) app->preview_seq = (uint32_t)seq;"),
        ("pf-sync", "else PreviewPane_read_sync(pv);", ""),
    ]
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src and old != new, name
        mp = t / f"m{idx}" / "app_layout.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=SCRIPT.encode())
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] ALY3. {len(muts)}/{len(muts)} mutants killed across app_layout.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=SCRIPT.encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] ALY2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
