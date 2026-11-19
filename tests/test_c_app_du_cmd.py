#!/usr/bin/env python3
"""A1.2: src/app/{app_du,app_cmdline}.c versus frozen x86_64 assembly oracles.

AD1 differential (x86_64):
    - app_du: App_du_init (default 300ms, empty env, custom DUOP_DU_PROGRESS_MS=50),
      progress callback (elapsed < delay, another active_dialog blocks popup,
      DuProgressDialog_new OOM, dialog open + reuse, EVT_RESIZE re-layout,
      ignored non-Esc keys, EVT_KEY KEY_ESC cancel with status, DU_PHASE_DONE
      close + idempotent second close), du_toggle (du_mode 0 vs 1)
    - app_cmdline: App_run_expanded_cmd (single cur_name fallback, NULL cur_name,
      multi-selection with space quoting, selection list > 60000B -ENAMETOOLONG,
      command expansion > 120000B -ENAMETOOLONG, chdir failure -ENOENT,
      OOM on 1st and 2nd mem_alloc)
AD2 qemu-aarch64 matches x86_64 byte for byte
AD3 mutation check across both C modules
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = {
    "du": "src/app/app_du.c",
    "cmd": "src/app/app_cmdline.c",
}
REFS = [
    "tests/harness/app_du_reference.s",
    "tests/harness/app_cmdline_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/mem_prims.c", "src/core/config_expand.c",
    "build/i18n_en.c",
]


def build(arch: str, t: Path, ovr: dict[str, Path] | None = None) -> Path:
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
        redefs = [
            "--redefine-sym", "cfg_getenv=fake_cfg_getenv",
            "--redefine-sym", "du_set_progress=fake_du_set_progress",
            "--redefine-sym", "input_poll_event=fake_input_poll_event",
            "--redefine-sym", "os_clock_ms=fake_os_clock_ms",
            "--redefine-sym", "os_poll_in=fake_os_poll_in",
            "--redefine-sym", "sys_get_winsize=fake_sys_get_winsize",
            "--redefine-sym", "term_caps_refresh=fake_term_caps_refresh",
            "--redefine-sym", "mem_alloc=fake_mem_alloc",
            "--redefine-sym", "DirModel_get_entry=fake_DirModel_get_entry",
            "--redefine-sym", "DirModel_entry_name=fake_DirModel_entry_name",
            "--redefine-sym", "sys_exec_sh_arg=fake_sys_exec_sh_arg",
        ]
        for o in objs:
            subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra += objs
    ovr = ovr or {}
    defs = [
        f'-DDU_SRC="{ovr.get("du", ROOT / SRCS["du"])}"',
        f'-DCMD_SRC="{ovr.get("cmd", ROOT / SRCS["cmd"])}"',
    ]
    return H.build(arch, t, ["tests/harness/app_du_cmd_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


def build_script(work: Path) -> str:
    d_act = work / "act"
    d_inact = work / "inact"
    d_act.mkdir(exist_ok=True)
    d_inact.mkdir(exist_ok=True)
    missing = work / "no_such_dir_xyz"
    return "\n".join([
        # app_du: init defaults & empty env (delay=300)
        "D 0 0",
        "D 1 0 1000 1299 0 0 0",   # elapsed 299 < 300 -> quiet
        "D 0 1",
        "D 1 0 1000 1299 0 0 0",   # empty env keeps 300
        # custom delay=50
        "D 0 2 50",
        "D 1 0 1000 1049 0 0 0",   # 49 < 50 -> quiet
        "D 1 0 1000 1050 1 0 0",   # another active_dialog -> stay quiet
        "D 1 0 1000 1050 0 1 0",   # DuProgressDialog_new OOM -> quiet
        "D 1 0 1000 1050 0 0 3",   # non-Esc events ignored, opens dialog + renders
        "D 1 0 1000 1100 0 0 0",   # reuses open dialog + renders
        "D 1 0 1000 1150 0 0 1",   # EVT_RESIZE re-lays out app + dialog
        "D 1 0 1000 1200 0 0 2",   # EVT_KEY KEY_ESC cancels with MSG_INFO
        "D 1 1 1000 1250 0 0 0",   # DU_PHASE_DONE closes dialog + need_redraw
        "D 1 1 1000 1260 0 0 0",   # second DU_PHASE_DONE is no-op
        # du_toggle
        "D 2 0",
        "D 2 1",
        # app_cmdline
        f"C 0 0 {d_act} {d_inact} foo.txt {d_act}/foo.txt run:%f:%p:%d:%D:%F",
        f"C 0 0 {d_act} {d_inact} - - run:%f:%F:%d",
        f"C 1 0 {d_act} {d_inact} ignored.txt {d_act}/ignored.txt run:%F:%D",
        f"C 2 0 {d_act} {d_inact} foo.txt {d_act}/foo.txt run:%F",         # sel > 60000B -> -ENAMETOOLONG
        f"C 4 0 {d_act} {d_inact} foo.txt {d_act}/foo.txt run:%f",         # sel == 60000B exact boundary (i == max)
        f"C 3 0 {d_act} {d_inact} foo.txt {d_act}/foo.txt %F:%F:%F",       # cmd > 120000B -> -ENAMETOOLONG
        f"C 0 0 {missing} {d_inact} foo.txt {missing}/foo.txt run:%f",     # chdir -> -ENOENT
        f"C 0 1 {d_act} {d_inact} foo.txt {d_act}/foo.txt run:%f",         # OOM on sel
        f"C 0 2 {d_act} {d_inact} foo.txt {d_act}/foo.txt run:%f",         # OOM on cmd
    ]) + "\n"


def test_differential(exe: Path, t: Path) -> str:
    s = build_script(t / "w").encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("call DuProgressDialog_new 1 oom=0",
                   "call DuProgressDialog_layout 1 0,0,100,30",
                   "DP rc=1 ad=1 rd=0 w=100",
                   "call fake_dlg_dtor 1",
                   "call dir_du_populate 1", "call du_leave 1",
                   "in_active=1", "AC ff=1 cwd_restored=1",
                   "alpha.txt", "beta space.c",
                   "ERR_NOENT", "ERR_NOMEM"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] AD1. app_du & app_cmdline match frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script(t / "w").encode()
    muts = [
        ("du", "delay-env", "if (v && v[0] != '\\0') g_du_delay = parse_uint(v);",
         "if (v && v[0] == '\\0') g_du_delay = parse_uint(v);"),
        ("du", "delay-cmp", "if (elapsed < (int64_t)g_du_delay) return;",
         "if (elapsed <= (int64_t)g_du_delay) return;"),
        ("du", "other-dlg", "if (app->active_dialog) return;", "if (app->active_dialog == 999) return;"),
        ("du", "esc-key", "if (evt->key == KEY_ESC) *canceled = 1;",
         "if (evt->key == KEY_ENTER) *canceled = 1;"),
        ("du", "resize-dlg", "if (g_du_dlg) DuProgressDialog_layout", "if (!g_du_dlg) DuProgressDialog_layout"),
        ("du", "poll-ms", "(void)os_poll_in(STDIN_FD, 100);", "(void)os_poll_in(STDIN_FD, 50);"),
        ("du", "cancel-rc", "return 1;", "return 0;"),
        ("du", "toggle-dir", "if (m->du_mode == 0)", "if (m->du_mode != 0)"),
        ("cmd", "sel-flag", "if (!fe || !(fe->flags & FE_SELECTED)) continue;",
         "if (!fe) continue;"),
        ("cmd", "sel-fallback", "if (added == 0 && cur_name) {", "if (added != 0 && cur_name) {"),
        ("cmd", "sel-bound", "if (i >= max) return -1;", "if (i > max) return -1;"),
        ("cmd", "chdir-err", "if (rc < 0) return (int)rc;", "if (rc > 0) return (int)rc;"),
        ("cmd", "force-full", "scr->force_full = 1;", "scr->force_full = 0;"),
        ("cmd", "err-long", "if (neg_errno == -ENAMETOOLONG)", "if (neg_errno == -ENOENT)"),
    ]
    survivors: list[str] = []
    txts = {k: (ROOT / v).read_text() for k, v in SRCS.items()}

    def check(idx: int, key: str, name: str, old: str, new: str) -> None:
        assert old in txts[key] and old != new, name
        mp = t / f"m{idx}" / Path(SRCS[key]).name
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txts[key].replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", {key: mp})
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] AD3. {len(muts)}/{len(muts)} mutants killed across app_du & app_cmdline")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        (t / "w").mkdir()
        exe = build("x86_64", t / "x86")
        out = test_differential(exe, t)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script(t / "w").encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] AD2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
