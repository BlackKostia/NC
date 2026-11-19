#!/usr/bin/env python3
"""A3.2: src/app/app_events.c versus frozen x86_64 assembly oracle.

AEV1 differential (x86_64):
    - App_events_init (term_caps + dirwatch_init + aux fd 1)
    - App_events_shutdown (term_shutdown + fs_preview_stop)
    - App_events_timeout: truly idle (-1), task_active (100ms), nearest deadline across
      status/preview/watch0/watch1, past deadline clamped to 0, > INT32_MAX clamped
    - App_events_tick: debounced preview fire (before/at deadline), preview reply loop
      (stale seq skipped, pending==0 skipped, match calls PreviewPane_accept),
      dirwatch_poll scheduling (slot 0 & slot 1, WATCH_DEBOUNCE_MS vs WATCH_MIN_GAP_MS
      rate limit, already-pending ORs watch_kind), due refresh (is_loading defers,
      structural reload vs huge_mode / selected / content invalidate_stats, active pane
      triggers App_sync_preview), term_caps_changed -> App_sync_preview
AEV2 qemu-aarch64 matches x86_64 byte for byte
AEV3 mutation check (16 mutants)
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/app/app_events.c"
REF = "tests/harness/app_events_reference.s"
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
        o = t / "app_events_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "term_caps_init=fake_term_caps_init",
            "--redefine-sym", "term_caps_query=fake_term_caps_query",
            "--redefine-sym", "term_caps_refresh=fake_term_caps_refresh",
            "--redefine-sym", "term_caps_changed=fake_term_caps_changed",
            "--redefine-sym", "dirwatch_init=fake_dirwatch_init",
            "--redefine-sym", "dirwatch_fd=fake_dirwatch_fd",
            "--redefine-sym", "dirwatch_set=fake_dirwatch_set",
            "--redefine-sym", "dirwatch_poll=fake_dirwatch_poll",
            "--redefine-sym", "input_set_aux_fd=fake_input_set_aux_fd",
            "--redefine-sym", "term_shutdown=fake_term_shutdown",
            "--redefine-sym", "fs_preview_stop=fake_fs_preview_stop",
            "--redefine-sym", "sys_clock_ms=fake_sys_clock_ms",
            "--redefine-sym", "term_poll_read=fake_term_poll_read",
            "--redefine-sym", "fs_preview_fd=fake_fs_preview_fd",
            "--redefine-sym", "fs_preview_receive=fake_fs_preview_receive",
            "--redefine-sym", "fs_preview_shm_slot=fake_fs_preview_shm_slot",
            "--redefine-sym", "PreviewPane_accept=fake_PreviewPane_accept",
            "--redefine-sym", "DirModel_count_selected=fake_DirModel_count_selected",
            "--redefine-sym", "FilePane_reload_keep_cursor=fake_FilePane_reload_keep_cursor",
            "--redefine-sym", "DirModel_invalidate_stats=fake_DirModel_invalidate_stats",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    defs = [f'-DEVENTS_SRC="{src_ovr or (ROOT / SRC)}"']
    return H.build(arch, t, ["tests/harness/app_events_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


SCRIPT = "\n".join([
    "I",
    "S",
    # O <now> <task_act> <sb_exp> <pv_due> <w0_due> <w1_due>
    "O 1000 0 0 0 0 0",                        # idle -> -1
    "O 1000 1 0 0 0 0",                        # task active -> 100
    "O 1000 1 1500 1040 1200 1025",            # watch1 nearest -> 25
    "O 1000 0 900 1500 0 0",                   # expired status -> 0
    "O 1000 0 5000000000 0 0 0",               # > INT32_MAX -> 2147483647
    # T <now> <pv_due> <pv_seq> <pv_pend> <rep> <dw_ev> <w0_last> <w0_due> <w0_kind> <load> <huge> <sel> <caps>
    "T 1000 1001 5 1 1 0 0 0 0 0 0 0 0",       # pv_due not yet; reply seq=4 skipped, seq=5 accepted
    "T 1000 1000 5 0 1 0 0 0 0 0 0 0 1",       # pv_due fires; pending==0 skips accept; caps_changed -> sync
    "T 1000 0 0 0 0 9 0 0 0 0 0 0 0",          # dw_ev=1 (slot0 struct) + 8 (slot1 content) -> schedule both
    "T 1000 0 0 0 0 1 900 0 0 0 0 0 0",        # rate-limited: w0_last=900 + 500 = 1400 > 1150
    "T 1000 0 0 0 0 2 0 1200 1 0 0 0 0",       # already pending: ORs kind 1|2=3, keeps due=1200
    "T 1000 0 0 0 0 0 0 1000 1 1 0 0 0",       # due while loading -> defers to 1150
    "T 1000 0 0 0 0 0 0 1000 1 0 0 0 0",       # due structural -> reload_keep_cursor + sync_preview
    "T 1000 0 0 0 0 0 0 1000 1 0 1 0 0",       # due structural huge_mode -> invalidate_stats
    "T 1000 0 0 0 0 0 0 1000 1 0 0 2 0",       # due structural with selection -> invalidate_stats
    "T 1000 0 0 0 0 0 0 1000 2 0 0 0 0",       # due content-only -> invalidate_stats
]) + "\n"


def test_differential(exe: Path) -> str:
    out = H.diff_impls(exe, stdin=SCRIPT.encode()).decode()
    for needle in ("call input_set_aux_fd 1 17", "call fs_preview_stop",
                   "TO -1", "TO 100", "TO 25", "TO 0", "TO 2147483647",
                   "call PreviewPane_accept 1 l=200 tl=64 th=1",
                   "call App_preview_fire 1",
                   "TK wd0=1150 wd1=1150 wl0=0 wk0=1 wk1=2",
                   "TK wd0=1400 wd1=0",
                   "TK wd0=1200 wd1=0 wl0=0 wk0=3",
                   "call FilePane_reload_keep_cursor p=1 f=0",
                   "call DirModel_invalidate_stats m=1"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] AEV1. app_events matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    src = (ROOT / SRC).read_text()
    muts = [
        ("init-aux", "input_set_aux_fd(1, dirwatch_fd());", "input_set_aux_fd(0, dirwatch_fd());"),
        ("shut-pv", "fs_preview_stop();", ""),
        ("min-clamp0", "if (diff < 0) diff = 0;", "if (diff < -999) diff = 0;"),
        ("min-cap", "if (diff > 0x7FFFFFFFll) diff = 0x7FFFFFFFll;",
         "if (diff > 0x7FFFFFFFll) diff = 100;"),
        ("to-task", "int to = app->task_active ? TASK_TICK_MS : -1;",
         "int to = app->task_active ? 50 : -1;"),
        ("to-w1", "to = ev_min_deadline(to, watch_due(app)[1], now);", ""),
        ("sched-gap", "watch_due(app)[slot] = (d1 >= d2) ? d1 : d2;",
         "watch_due(app)[slot] = d1; (void)d2;"),
        ("sched-or", "watch_kind(app)[slot] |= kind;", "watch_kind(app)[slot] = kind;"),
        ("ref-load", "if (m->is_loading) { watch_due(app)[slot] = now + WATCH_DEBOUNCE_MS; return; }",
         "if (m->is_loading) { watch_due(app)[slot] = now; return; }"),
        ("ref-huge", "if ((kind & 1u) && !m->huge_mode && DirModel_count_selected(m, nullptr) == 0)",
         "if ((kind & 1u) && DirModel_count_selected(m, nullptr) == 0)"),
        ("ref-sel", "if ((kind & 1u) && !m->huge_mode && DirModel_count_selected(m, nullptr) == 0)",
         "if ((kind & 1u) && !m->huge_mode)"),
        ("pv-fire", "if (app->preview_due && now >= app->preview_due) App_preview_fire(app);",
         "if (app->preview_due && now > app->preview_due) App_preview_fire(app);"),
        ("pv-seq", "if (seq == app->preview_seq && pv->pending) {", "if (pv->pending) {"),
        ("pv-pend", "if (seq == app->preview_seq && pv->pending) {", "if (seq == app->preview_seq) {"),
        ("dw-s1", "if (ev & 12u) ev_schedule_watch(app, 1, (ev >> 2) & 3u, now);",
         "if (ev & 12u) ev_schedule_watch(app, 1, ev & 3u, now);"),
        ("caps-chg", "if (term_caps_changed()) App_sync_preview(app);", ""),
    ]
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src and old != new, name
        mp = t / f"m{idx}" / "app_events.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=SCRIPT.encode())
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] AEV3. {len(muts)}/{len(muts)} mutants killed across app_events.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=SCRIPT.encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] AEV2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
