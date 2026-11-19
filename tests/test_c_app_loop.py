#!/usr/bin/env python3
"""A3.3: src/app/app_loop.c versus frozen x86_64 assembly oracle.

ALP1 differential (x86_64):
    - Startup init, initial render, g_git_defer=0, git_refresh + conditional 2nd render
    - SIGTERM and stdin EOF (-2) clean exits calling App_task_shutdown + App_events_shutdown
    - Status message expiration check & EVT_RESIZE re-layout + preview sync
    - Burst event coalescing (16-event cap, stops on running==0 or timeout)
    - Mouse routing: active_dialog capture, left/right scrollbar drag, pane_mouse_ext,
      MACT_MOVE hover, status-bar click during task_active, hit-test chain (header/func/
      left/right dual vs preview)
    - Concurrent streaming: 0ms poll while loading, alternating stream_turn, 33ms
      progress throttle, error via task_status_errno, finish sync
ALP2 qemu-aarch64 matches x86_64 byte for byte
ALP3 mutation check (16 mutants)
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/app/app_loop.c"
REF = "tests/harness/app_loop_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c",
    "src/core/memory.c", "src/core/mem_prims.c",
]


def build(arch: str, t: Path, src_ovr: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "app_loop_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "pane_mouse_ext=fake_pane_mouse_ext",
            "--redefine-sym", "git_refresh=fake_git_refresh",
            "--redefine-sym", "input_next_event=fake_input_next_event",
            "--redefine-sym", "sys_clock_ms=fake_sys_clock_ms",
            "--redefine-sym", "sys_get_winsize=fake_sys_get_winsize",
            "--redefine-sym", "term_caps_refresh=fake_term_caps_refresh",
            "--redefine-sym", "DirModel_step_load=fake_DirModel_step_load",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    defs = [f'-DLOOP_SRC="{src_ovr or (ROOT / SRC)}"']
    return H.build(arch, t, ["tests/harness/app_loop_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


SCRIPT = "\n".join(str(i) for i in range(1, 12)) + "\n"


def test_differential(exe: Path) -> str:
    out = H.diff_impls(exe, stdin=SCRIPT.encode()).decode()
    for needle in ("call App_events_init 1", "call App_task_shutdown 1", "call App_events_shutdown 1",
                   "call App_layout 120x40", "call app_mouse_hover 1 3,4",
                   "vcall on_mouse id=99", "vcall on_mouse id=1", "vcall on_mouse id=2",
                   "vcall on_mouse id=10", "vcall on_mouse id=11", "vcall on_mouse id=12",
                   "call App_task_show 1", "call DirModel_step_load m=1",
                   "call DirModel_step_load m=2", "call task_status_errno 1 e=-5"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] ALP1. app_loop matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mid_burst_eof(exe: Path) -> None:
    r_ref = H.run_impl("x86_64", exe, "r", stdin=b"12\n").stdout.decode()
    r_c = H.run_impl("x86_64", exe, "c", stdin=b"12\n").stdout.decode()
    assert "call App_task_tick 1" in r_ref, f"expected asm to miss -2 in drain: {r_ref}"
    assert "call App_task_tick 1" not in r_c and "END run=0" in r_c, f"C must exit on mid-burst EOF: {r_c}"
    print("[PASS] ALP_EOF. mid-burst stdin EOF during drain exits cleanly in C (asm ran extra tick)")


def test_mutations(t: Path, baseline: str) -> None:
    src = (ROOT / SRC).read_text()
    muts = [
        ("git-def", "g_git_defer = 0;", "g_git_defer = 1;"),
        ("git-rnd", "if (lm->git_ctx || rm->git_ctx) App_render(app);", ""),
        ("sigterm", "while (app->running && !g_sigterm) {", "while (app->running) {"),
        ("load-to", "int to = (lm->is_loading || rm->is_loading) ? 0 : App_events_timeout(app);",
         "int to = App_events_timeout(app);"),
        ("msg-exp", "if (sb->msg_expire_ms && (uint64_t)sys_clock_ms() >= sb->msg_expire_ms) {",
         "if (sb->msg_expire_ms && (uint64_t)sys_clock_ms() > sb->msg_expire_ms) {"),
        ("eof-stop", "if (er < 0) { app->running = 0; }", "if (er < -99) { app->running = 0; }"),
        ("drain-cap", "for (int i = 0; i < 16 && app->running; i++) {",
         "for (int i = 0; i < 4 && app->running; i++) {"),
        ("dlg-m", "if (app->active_dialog) {", "if (0) {"),
        ("drag-l", "if (lp->dragging_scroll) {", "if (0) {"),
        ("drag-r", "if (rp->dragging_scroll) {", "if (0) {"),
        ("ext-m", "if (pane_mouse_ext(app, evt)) return;", "if (pane_mouse_ext(app, evt) > 9) return;"),
        ("hover-m", "if (evt->mouse_kind == MACT_MOVE) { app_mouse_hover(app, evt); return; }",
         "if (evt->mouse_kind == MACT_WHEEL) { app_mouse_hover(app, evt); return; }"),
        ("sb-task", "if (app->task_active && evt->mouse_kind == MACT_PRESS && sb->base.y == evt->mouse_y) {",
         "if (0 && app->task_active && evt->mouse_kind == MACT_PRESS && sb->base.y == evt->mouse_y) {"),
        ("prev-ht", "Widget *rw = (Widget *)(uintptr_t)(app->right_mode == RIGHT_MODE_PREVIEW ? app->preview_pane : app->right_pane);",
         "Widget *rw = (Widget *)(uintptr_t)app->right_pane;"),
        ("turn-alt", "app->stream_turn ^= 1;", "app->stream_turn = 0;"),
        ("thr-33", "if (now - *last_ms >= 33) {", "if (now - *last_ms >= 200) {"),
    ]
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src and old != new, name
        mp = t / f"m{idx}" / "app_loop.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=SCRIPT.encode())
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] ALP3. {len(muts)}/{len(muts)} mutants killed across app_loop.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_mid_burst_eof(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=SCRIPT.encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] ALP2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
