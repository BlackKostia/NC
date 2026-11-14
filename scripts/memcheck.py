#!/usr/bin/env python3
"""Service utility for checking Duop (pure x86-64 assembly) for memory leaks & bad frees."""
import argparse
import collections
import os
import re
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MC_BIN = os.path.join(ROOT, "duop_memcheck")
RE_SUMMARY = re.compile(
    r"MC_SUMMARY allocs=(\d+) frees=(\d+) live=(\d+) live_bytes=(\d+) peak_bytes=(\d+) bad_frees=(\d+)"
)
RE_LEAK = re.compile(r"MC_LEAK ptr=(0x[0-9a-fA-F]+) size=(\d+) caller=(0x[0-9a-fA-F]+) seq=(\d+)")
RE_BAD = re.compile(r"MC_BADFREE ptr=(0x[0-9a-fA-F]+) caller=(0x[0-9a-fA-F]+)")


def ensure_build():
    subprocess.run(["make", "-s", "MEMCHECK=1"], cwd=ROOT, check=True)


def resolve_callers(addrs):
    if not addrs or not os.path.exists(MC_BIN):
        return {}
    uniq = sorted(set(addrs))
    try:
        out = subprocess.check_output(
            ["addr2line", "-f", "-C", "-e", MC_BIN, *uniq],
            cwd=ROOT, text=True, stderr=subprocess.DEVNULL,
        ).splitlines()
    except (OSError, subprocess.CalledProcessError):
        return {}
    res = {}
    for i, a in enumerate(uniq):
        fn = out[2 * i] if 2 * i < len(out) else "?"
        loc = out[2 * i + 1] if 2 * i + 1 < len(out) else "?:0"
        if loc.startswith(ROOT + "/"):
            loc = loc[len(ROOT) + 1:]
        res[a] = f"{fn} ({loc})"
    return res


def parse_and_report(log_path):
    if not os.path.exists(log_path):
        print("MEMCHECK ERROR: log file not produced:", log_path, file=sys.stderr)
        return 2
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()

    leaks = []
    bads = []
    summaries = []
    for ln in lines:
        if m := RE_LEAK.match(ln):
            leaks.append((m.group(1), int(m.group(2)), m.group(3), int(m.group(4))))
        elif m := RE_BAD.match(ln):
            bads.append((m.group(1), m.group(2)))
        elif m := RE_SUMMARY.match(ln):
            summaries.append({k: int(v) for k, v in zip(
                ("allocs", "frees", "live", "live_bytes", "peak_bytes", "bad_frees"), m.groups()
            )})

    if not summaries:
        print("MEMCHECK ERROR: missing MC_SUMMARY in log", file=sys.stderr)
        return 2

    loc_map = resolve_callers([x[2] for x in leaks] + [x[1] for x in bads])
    s = summaries[-1]
    print(
        f"MEMCHECK allocs={s['allocs']} frees={s['frees']} live={s['live']} "
        f"live_bytes={s['live_bytes']} peak_bytes={s['peak_bytes']} bad_frees={s['bad_frees']}"
    )

    if bads:
        print(f"\nInvalid / Double frees ({len(bads)}):")
        for ptr, caller in bads[:20]:
            print(f"  ptr={ptr} at {loc_map.get(caller, caller)}")

    if leaks:
        grouped = collections.defaultdict(lambda: [0, 0])
        for _, sz, caller, _ in leaks:
            grouped[caller][0] += 1
            grouped[caller][1] += sz
        print(f"\nMemory leaks ({len(leaks)} blocks, {sum(x[1] for x in leaks)} bytes):")
        for caller, (cnt, tot) in sorted(grouped.items(), key=lambda kv: -kv[1][1])[:25]:
            print(f"  {tot:8d} B in {cnt:4d} block(s)  <-  {loc_map.get(caller, caller)}")

    return 1 if (s["live_bytes"] > 0 or s["bad_frees"] > 0 or leaks or bads) else 0


def run_smoke(log_path):
    sys.path.insert(0, os.path.join(ROOT, "tests"))
    from test_pty import PtySession
    with tempfile.TemporaryDirectory() as tmp:
        l = os.path.join(tmp, "left")
        r = os.path.join(tmp, "right")
        os.makedirs(l)
        os.makedirs(r)
        with open(os.path.join(l, "sample.txt"), "w") as f:
            f.write("hello memcheck\nline 2\n")
        sess = PtySession(
            MC_BIN, ["--lang", "en", l, r], cols=100, rows=30,
            extra_env={"DUOP_MEMCHECK_LOG": log_path},
        )
        try:
            sess.drain(0.30)
            sess.send(b"\x1b[B", wait=0.15)    # select sample.txt
            sess.send(b"\x1bOR", wait=0.25)    # F3 view
            sess.send(b"\x1b", wait=0.20)      # Esc close viewer
            sess.send(b"\x1b[21~", wait=0.15)  # F10 quit
            rc = sess.wait_exit(timeout=5.0)
            assert rc == 0, f"Unexpected exit: {rc}"
        except Exception:
            try:
                os.kill(sess.pid, 9)
                os.waitpid(sess.pid, 0)
            except OSError:
                pass
            raise


def main():
    ap = argparse.ArgumentParser(description="Duop pure-assembly memory leak checker")
    ap.add_argument("--no-build", action="store_true", help="Skip make MEMCHECK=1")
    ap.add_argument("--smoke", action="store_true", help="Run interactive PTY smoke check")
    ap.add_argument("--parse-log", metavar="FILE", help="Parse an existing memcheck log")
    ap.add_argument("cmd", nargs=argparse.REMAINDER, help="Command after -- to run under MEMCHECK")
    args = ap.parse_args()

    if args.parse_log:
        sys.exit(parse_and_report(args.parse_log))
    if not args.no_build:
        ensure_build()

    with tempfile.NamedTemporaryFile(prefix="duop_mc_", suffix=".log", delete=False) as tf:
        log_path = tf.name
    try:
        if args.smoke:
            run_smoke(log_path)
        elif args.cmd:
            cmd = args.cmd[1:] if args.cmd[0] == "--" else args.cmd
            env = os.environ.copy()
            env["DUOP_MEMCHECK_LOG"] = log_path
            subprocess.run(cmd, cwd=ROOT, env=env, check=True)
        else:
            ap.print_help()
            sys.exit(2)
        sys.exit(parse_and_report(log_path))
    finally:
        if os.path.exists(log_path):
            os.unlink(log_path)


if __name__ == "__main__":
    main()
