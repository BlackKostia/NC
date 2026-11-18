#!/usr/bin/env python3
"""src/fs/task_control.c versus the frozen assembly (tests/harness/task_control_reference.s): the UI side of the background task
(fs_task_poll, fs_task_snapshot, fs_task_toggle_pause, fs_task_cancel, fs_task_shutdown).

TC1 snapshots (x86_64, scripted clock): every phase and op, counters from 0 to 2^64 - 1 (percent, speed and ETA with their 128-bit
    products: overflow guards exactly at the boundary), done above total (clamped), active time below / at / above 500 ms, pauses
    (running and accumulated), cancel pending, an odd seqlock (the name is still copied after the bounded retries)
TC2 lifecycle with a forked fake worker: reaping a published result, a worker that dies without one (-EIO), cancel (flag, time
    stamp, SIGTERM re-sent while pending), pause / resume (SIGSTOP / SIGCONT seen in /proc, pause time accounted, no pause while
    cancelling), shutdown of a cooperative worker and of one that ignores the cancel (SIGKILL after the grace time), release of the
    wake fd and the page
TC3 qemu-aarch64: the C module gives the x86_64 snapshots; TC4 mutation check
"""

import random
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/task_control.c"
REF = "tests/harness/task_control_reference.s"
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
M64 = (1 << 64) - 1


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        o = t / "task_control_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        out = subprocess.run(["nm", str(o)], capture_output=True, text=True).stdout
        if " g_task_pause_at" in out or " b g_task_pause_at" in out:
            subprocess.run(["objcopy", "--globalize-symbol", "g_task_pause_at", str(o)], check=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "os_clock_ms=tc_clock", str(o)], check=True)
        extra = [o]
    return H.build(arch, t, ["tests/harness/task_control_cli.c", *CORE], extra, cflags=["-I", str(ROOT / "tests/harness"), f'-DTC_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=25)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def snapshot_script(rng: random.Random) -> str:
    s = ["T 100000\n"]
    vals = [0, 1, 2, 99, 100, 101, 999, 1000, 10 ** 6, 10 ** 12, 1 << 32, (1 << 63) - 1, 1 << 63, M64 // 1000, M64 // 1000 + 1, M64 // 100, M64 // 100 + 1, M64 - 1, M64]
    for op in (1, 2, 3):
        s.append(f"M {op}\n")
        for _ in range(60):
            tb, tf, db, df = (rng.choice(vals) for _ in range(4))
            start = 100000 - rng.choice([0, 1, 499, 500, 501, 1000, 7000, 10 ** 9, -5])
            paused, pms, pat = rng.choice([(0, 0, 0), (0, 200, 0), (1, 0, 99800), (1, 300, 100000), (1, 0, 99000), (0, 10 ** 10, 0)])
            s.append(f"S {rng.choice([1, 2, 3])} {tb} {tf} {db} {df} {rng.choice([0, 2, 7])} {rng.choice(['item.txt', '-', 'x' * 300])} "
                     f"{paused} {pms} {pat} {start} {rng.choice([0, 5])}\n")
    # the guards exactly at their boundaries: elapsed e, done_bytes * 1000 vs e * 2^64; remaining * e vs done * 2^64
    s += [f"S 2 {M64} 0 {M64} 0 0 b 0 0 0 {100000 - e} 0\n" for e in (500, 999, 1000, 1001)]
    s += [f"S 2 {M64} 0 {d} 0 0 b 0 0 0 {100000 - e} 0\n" for d, e in ((1 << 62, 4000), ((1 << 62) - 1, 250), (3, 501), (M64 // 2, 2))]
    s.append("S 2 0 0 0 0 1 odd 0 0 0 99000 0\n")
    return "".join(s)


LIFE = {
    "reap": "T 1000 1\nW r -2\nZ 50\nP\nP\n",
    "eio": "T 1000 1\nW n\nZ 50\nP\n",
    "cancel": "T 1000 1\nW d\nK\nK\nZ 100\nP\nP\n",
    "pause": "T 1000 100\nW d\nX\nX\nX\nK\nX\nZ 100\nP\n",
    "shutdown": "T 1000 1\nW d\nD\nP\n",
    "kill": "T 1000 1000\nW i\nX\nD\nP\n",
    "idle": "P\nK\nX\nD\n",
    "echild": "T 1000 1\nW r -7\nZ 30\nR\nP\n",
    "resend": "T 1000 1000\nW c\nK\nZ 50\nN\nP\nZ 50\nN\nP\nZ 50\nN\nD\n",
}


def test_snapshots(exe: Path, s: str) -> str:
    a, b = run(exe, "ref", s), run(exe, "c", s)
    if a != b:
        x, y = next((x, y) for x, y in zip(a.splitlines(), b.splitlines()) if x != y)
        raise AssertionError(f"snapshot: oracle and C differ:\n  ref {x}\n  c   {y}")
    ls = b.splitlines()
    assert any(" bps=0 " not in ln for ln in ls) and any(" eta=18446744073709551615 " not in ln for ln in ls) and any(" pct=100 " in ln for ln in ls)
    print(f"[PASS] TC1. fs_task_snapshot identical to the asm in {len(ls)} snapshots (percent / speed / ETA over the full 64-bit range, "
          "the 128-bit guards at their boundaries, pauses, cancel, seqlock)")
    return b


def test_life(exe: Path) -> dict[str, str]:
    outs = {}
    for tag, s in LIFE.items():
        a, b = run(exe, "ref", s), run(exe, "c", s)
        assert a == b, f"{tag}: oracle and C differ:\n{a}\n{b}"
        outs[tag] = b
    assert "P 1 res=-2 " in outs["reap"] and "P 1 res=-5 " in outs["eio"] and "P 1 res=-125 " in outs["cancel"], outs
    assert "X 1 state=stop" in outs["pause"] and "X 0 state=run" in outs["pause"] and "D pid=0" in outs["kill"], outs
    assert "X 0 state=" in outs["pause"].splitlines()[5] and "K cx=" in outs["pause"], "no pause while a cancel is pending"
    print(f"[PASS] TC2. lifecycle identical to the asm ({len(LIFE)} scenarios: reap, -EIO, cancel, pause / resume, shutdown, SIGKILL)")
    return outs


MUTANTS = [
    ("no -EIO", "== TASK_PHASE_DONE ? g_task_shm->result : -EIO", "== TASK_PHASE_DONE ? g_task_shm->result : 0"),
    ("ECHILD pending", "if (r > 0 || r == -ECHILD) {", "if (r > 0) {"),
    ("cancel not re-sent", "if (g_task_cancel_at) (void)os_kill(g_task_pid, SIGTERM);", ""),
    ("wake fd kept", "    g_task_wake_fd = -1;\n", ""),
    ("pauses counted", "el = now - g_task_start_ms - g_task_pause_ms;", "el = now - g_task_start_ms;"),
    ("running pause counted", "if (g_task_paused) el -= now - g_task_pause_at;", ""),
    ("entries for copy", "bool by_bytes = out->op != TASK_OP_DELETE && out->total_bytes;", "bool by_bytes = false;"),
    ("no clamp", "if (done > total) done = total;", ""),
    ("percent in scan", "total && out->phase != TASK_PHASE_SCAN ?", "total ?"),
    ("speed threshold", "if (elapsed < 500) return;", "if (elapsed < 499) return;"),
    ("speed guard", "if (tc_mulhi(out->done_bytes, 1000) < elapsed)", "if (true)"),
    ("eta guard", "if (tc_mulhi(total - done, elapsed) >= done) return;", ""),
    ("eta rounding", "(tc_muldiv(total - done, elapsed, done) + 999) / 1000", "tc_muldiv(total - done, elapsed, done) / 1000"),
    ("eta outside run", "if (out->phase != TASK_PHASE_RUN || !done) return;", "if (!done) return;"),
    ("name terminator", "out->cur_name[TASK_NAME_MAX - 1] = 0;", ""),
    ("pause while cancelling", "if (g_task_pid && !g_task_cancel_at) {", "if (g_task_pid) {"),
    ("pause time lost", "g_task_pause_ms += now - g_task_pause_at;", "(void)now;"),
    ("cancel time moves", "if (!g_task_cancel_at) g_task_cancel_at = now;", "g_task_cancel_at = now;"),
    ("paused cancel", "    task_resume(now);\n    (void)os_kill(g_task_pid, SIGTERM);", "    (void)os_kill(g_task_pid, SIGTERM);"),
    ("never killed", "(void)os_kill(g_task_pid, SIGKILL);", "(void)0;"),
]


# Not mutated: the length of the grace time (TASK_KILL_GRACE_MS): how many polls happen around the SIGKILL depends on the load
# (the scripted clock makes the deadline pass, the reaping is real).
def test_mutants(t: Path, scripts: dict[str, str], expect: dict[str, str]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "task_control.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "task_control.c"))
                noticed[name] = any(run(exe, "c", s) != expect[k] for k, s in scripts.items())
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] TC4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    snap = snapshot_script(random.Random(0x7C))
    with H.workdir() as d:
        t = Path(d)
        exe = build("x86_64", t / "x86")
        expect = {"snap": test_snapshots(exe, snap), **test_life(exe)}
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            assert run(a64, "c", snap, "aarch64") == expect["snap"], "qemu-aarch64 snapshots differ"
            print("[PASS] TC3. qemu-aarch64: the C module gives the x86_64 snapshots")
        else:
            print("[SKIP] TC3: aarch64 toolchain/qemu not installed")
        test_mutants(t, {"snap": snap, **LIFE}, expect)
    print("ALL C TASK CONTROL TESTS PASSED.")


if __name__ == "__main__":
    main()
