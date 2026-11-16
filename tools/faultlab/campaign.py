#!/usr/bin/env python3
"""Duop fault-injection campaigns.

  campaign.py baseline SCEN            syscall profile + oracle sanity of one clean run
  campaign.py sweep SCEN [--max-k N]   errno injection at every (sampled) syscall occurrence
  campaign.py short SCEN               short read()/write() counts (1 byte / odd sizes)
  campaign.py seu SCEN --runs N        single bit flips (registers, stack, .bss, heap, code)
  campaign.py one SCEN -r RULE         a single run, verbose (reproduce a finding)

SCEN: ui | copy | copy_x | tree | tree_x | move | move_x | delete   (_x = cross-device, read/write path)
Results: JSON lines in --out plus a summary grouped by class."""

from __future__ import annotations

import argparse
import json
import os
import random
import signal
import sys
import tempfile
import time
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import flab  # noqa: E402
from flab import K_DOWN, K_ESC, K_F3, K_F5, K_F6, K_F8, K_F10, SEV  # noqa: E402

E = dict(EPERM=1, ENOENT=2, ESRCH=3, EINTR=4, EIO=5, ECHILD=10, EAGAIN=11, ENOMEM=12, EACCES=13,
         EBUSY=16, ENFILE=23, EMFILE=24, ENOSPC=28, EROFS=30, ERANGE=34, ENOSYS=38)
SYS = {0: "read", 1: "write", 3: "close", 5: "fstat", 9: "mmap", 11: "munmap", 16: "ioctl", 25: "mremap",
       33: "dup2", 56: "clone", 57: "fork", 59: "execve", 61: "wait4", 62: "kill", 72: "fcntl",
       79: "getcwd", 80: "chdir", 202: "futex", 217: "getdents64", 254: "inotify_add_watch",
       257: "openat", 258: "mkdirat", 260: "fchownat", 262: "newfstatat", 263: "unlinkat",
       264: "renameat", 265: "linkat", 266: "symlinkat", 267: "readlinkat", 268: "fchmodat",
       271: "ppoll", 293: "pipe2", 294: "inotify_init1", 326: "copy_file_range", 332: "statx",
       425: "io_uring_setup", 426: "io_uring_enter"}
# syscall -> [(errno, fdsel)] realistic failure modes
PLAN = {0: [("EIO", "file"), ("EINTR", "any"), ("EAGAIN", "tty")], 1: [("ENOSPC", "file"), ("EIO", "any"), ("EINTR", "any"), ("EAGAIN", "tty")],
        3: [("EIO", "any")], 5: [("EIO", "any")], 9: [("ENOMEM", "any")], 16: [("EINTR", "any"), ("EIO", "any")],
        25: [("ENOMEM", "any")], 33: [("EBUSY", "any")], 56: [("EAGAIN", "any")], 57: [("EAGAIN", "any"), ("ENOMEM", "any")],
        59: [("ENOENT", "any"), ("ENOMEM", "any")], 61: [("EINTR", "any"), ("ECHILD", "any")], 62: [("ESRCH", "any")],
        72: [("EINTR", "any")], 79: [("ENOENT", "any"), ("ERANGE", "any")], 80: [("EACCES", "any"), ("EIO", "any")],
        202: [("EINTR", "any"), ("EAGAIN", "any")], 217: [("EIO", "any")], 254: [("ENOSPC", "any")],
        257: [("EMFILE", "any"), ("ENOMEM", "any"), ("EINTR", "any"), ("EIO", "any")], 258: [("ENOSPC", "any"), ("EIO", "any")],
        262: [("EIO", "any"), ("ENOMEM", "any")], 263: [("EIO", "any"), ("EBUSY", "any")], 264: [("EIO", "any")],
        266: [("ENOSPC", "any")], 267: [("EIO", "any")], 271: [("EINTR", "any"), ("ENOMEM", "any")],
        293: [("EMFILE", "any")], 294: [("EMFILE", "any")], 326: [("EIO", "any"), ("ENOSPC", "any"), ("EINTR", "any")],
        332: [("EIO", "any")], 425: [("ENOMEM", "any")], 426: [("EINTR", "any"), ("EIO", "any")]}

SCEN = {"ui": ("ui", False), "copy": ("copy", False), "copy_x": ("copy", True), "tree": ("tree", False),
        "tree_x": ("tree", True), "move": ("move", False), "move_x": ("move", True), "delete": ("delete", False)}
_TEMPLATE = None
_SYMS = None


def template():
    global _TEMPLATE
    if _TEMPLATE is None:
        _TEMPLATE = Path(tempfile.mkdtemp(prefix="flab.tpl.", dir="/dev/shm"))
        flab.build_template(_TEMPLATE)
    return _TEMPLATE


def drive(s: flab.Session, kind: str, notes: list):
    """Scenario keystrokes. Cursor order in the left pane: .., tree, a_note.txt, big.bin, pic.png."""
    if not s.wait_for(lambda: s.on_screen("a_note.txt") and s.on_screen("keep.txt"), 4.0):
        notes.append("no_initial_render")
        return
    done = lambda: bool(s.seen)                                    # noqa: E731
    if kind == "ui":
        s.send(K_DOWN * 2)
        s.send(K_F3, 0.15)                                          # viewer on a_note.txt
        s.wait_for(lambda: s.on_screen("line 3 of the note"), 2.0) or notes.append("viewer_missing")
        s.send(K_ESC, 0.1)
        s.send(b"\x1b[20~", 0.15)                                   # F9 live preview
        s.send(K_DOWN, 0.15)
        s.send(K_DOWN, 0.25)                                        # preview pic.png (decoder + TRY)
        s.send(b"\x1b[20~", 0.1)
        s.send(b"\t", 0.1)
        s.send(K_DOWN, 0.1)
        return
    target = {"copy": 3, "tree": 1, "move": 1, "delete": 1}[kind]
    s.send(K_DOWN * target, 0.08)
    if kind == "delete":
        s.send(K_F8, 0.05)
        s.wait_for(lambda: s.on_screen("Confirm Delete"), 2.0) or notes.append("no_dialog")
    else:
        s.send(K_F6 if kind == "move" else K_F5, 0.05)
        s.wait_for(lambda: s.on_screen("destination path"), 2.0) or notes.append("no_dialog")
    s.send(b"\r", 0.05)
    s.wait_for(done, 8.0) or notes.append("no_completion_message")
    s.drain(0.15)


def quit_app(s: flab.Session, notes: list):
    s.send(K_F10, 0.05)
    if s.wait_exit(2.5):
        return True
    notes.append("needed_extra_keys")                              # a dialog swallowed F10?
    for keys in (b"\r", K_ESC, K_ESC, K_F10, b"\r", K_ESC + K_F10, b"q", b"\x11"):
        s.send(keys, 0.2)
        if s.wait_exit(0.5):
            return True
    return False


def integrity(kind: str, fx: flab.Fixture, seen: set):
    """Data-integrity verdicts: [(class, detail)]."""
    out = []
    after_l, after_r = flab.snapshot(fx.left), flab.snapshot(fx.right)
    ok_seen, err_seen = any(m in seen for m in flab.OK_MARKS), any(m in seen for m in flab.ERR_MARKS)
    sub = "tree" if kind in ("tree", "move", "delete") else "big.bin"
    src = {k: v for k, v in fx.before_l.items() if k == sub or k.startswith(sub + "/")}
    others_l = {k: v for k, v in fx.before_l.items() if k not in src}
    if any(after_l.get(k) != v for k, v in others_l.items()) or any(after_r.get(k) != v for k, v in fx.before_r.items()):
        out.append(("WRONG_TARGET", "entries outside the operation changed"))
    if kind in ("copy", "tree", "move"):
        dst = {k: after_r.get(k) for k in src}
        bad = sorted(k for k, v in src.items() if dst[k] is not None and dst[k] != v)
        missing = sorted(k for k, v in src.items() if dst[k] is None)
        if kind == "move":
            lost = sorted(k for k, v in src.items() if v != "D" and dst[k] != v and after_l.get(k) != v)
            if lost:
                out.append(("DATA_LOSS", f"gone from source and not intact in destination: {lost[:4]}"))
            left_behind = sorted(k for k in src if k in after_l)
            if ok_seen and (bad or missing or left_behind):
                out.append(("SILENT_CORRUPTION", f"'Moved successfully' but bad={bad[:3]} missing={missing[:3]} left={left_behind[:3]}"))
        elif ok_seen and (bad or missing):
            out.append(("SILENT_CORRUPTION", f"'Copied successfully' but bad={bad[:3]} missing={missing[:3]}"))
        if bad and not ok_seen:
            out.append(("PARTIAL_LEFT", f"truncated/corrupt destination kept under its final name: {bad[:4]}"))
        if not ok_seen and not err_seen and (bad or missing):
            out.append(("SILENT_FAILURE", "incomplete result, neither success nor error shown"))
    if kind == "delete":
        left = sorted(k for k in src if k in after_l)
        if ok_seen and left:
            out.append(("SILENT_CORRUPTION", f"'Deleted successfully' but still present: {left[:4]}"))
        if left and not ok_seen and not err_seen:
            out.append(("SILENT_FAILURE", "items remain, neither success nor error shown"))
    return out


def run_one(job):
    """job = {scen, rules, tag}; returns a result dict."""
    kind, xdev = SCEN[job["scen"]]
    fx = flab.Fixture(Path(job["template"]), xdev)
    argv = [flab.FAULTLAB, "-o", str(fx.report)]
    for r in job.get("rules", []):
        argv += ["-r", r]
    argv += ["--", job.get("binary", flab.DUOP), str(fx.left), str(fx.right)]
    s = flab.Session(argv, str(fx.left), {"HOME": str(fx.home)})
    notes, res = [], {"tag": job.get("tag", ""), "scen": job["scen"], "rules": job.get("rules", [])}
    try:
        drive(s, kind, notes)
        exited = quit_app(s, notes)
        if not exited:
            os.kill(s.pid, signal.SIGTERM)                          # faultlab dumps blocked tasks
            s.wait_exit(2.0)
        s.drain(0.05)
        rep = flab.parse_report(fx.report)
        verdicts = []
        if not exited or rep.get("hang"):
            verdicts.append(("HANG", "; ".join(rep["blocked"])[:300]))
        elif "killed" in rep:
            verdicts.append(("CRASH_UI", f"UI killed by signal {rep['killed']}"))
        if exited and (dirty := s.tty_dirty()):
            verdicts.append(("TTY_DIRTY", ",".join(dirty)))
        if exited and "needed_extra_keys" in notes:
            verdicts.append(("UNRESPONSIVE", "F10 did not quit; extra keys were needed"))
        for f in rep["faults"]:
            if f["role"] == 1:
                verdicts.append(("WORKER_CRASH", f"signal {f['sig']} in a forked worker"))
            elif "killed" not in rep:
                verdicts.append(("RECOVERED_FAULT", f"signal {f['sig']} in the UI (TRY/CATCH or patched)"))
        verdicts += integrity(kind, fx, s.seen)
        if kind == "ui" and exited and rep.get("exit", 0) != 0:
            verdicts.append(("UNRESPONSIVE", f"exit code {rep.get('exit')}"))
        cls = max((v[0] for v in verdicts), key=SEV.index, default="OK")
        res.update(cls=cls, verdicts=verdicts, notes=notes, seen=sorted(s.seen), faults=rep["faults"],
                   hits=rep["hits"], rule_hits=rep.get("rule_hits", []), seu=rep["seu"],
                   exit=rep.get("exit"), killed=rep.get("killed"), counts=rep["counts"],
                   screen=s.vt.full_text() if job.get("verbose") else "")
    finally:
        s.close()
        fx.cleanup()
    return res


def sample_k(count, max_k):
    if count <= max_k:
        return list(range(1, count + 1))
    head = max_k * 2 // 3
    ks = set(range(1, head + 1)) | {count}
    step = (count - head) / (max_k - head)
    ks |= {int(head + step * i) for i in range(1, max_k - head)}
    return sorted(ks)


def plan_sweep(counts, max_k, persistent):
    jobs = []
    for role, scope in (("ui", "u"), ("child", "c")):
        for nr, cnt in sorted(counts[role].items()):
            for err, sel in PLAN.get(nr, []):
                if sel != "any" and nr in (0, 1) and role == "child" and sel == "tty":
                    continue
                for k in sample_k(cnt, max_k):
                    jobs.append((f"{role}:{SYS.get(nr, nr)}:{err}@{k}", [f"e:{scope}:{nr}:{k}:1:{E[err]}:{sel}"]))
                if persistent and err not in ("EINTR", "EAGAIN"):   # fault persists from occurrence k on
                    for k in sorted({1, max(1, cnt // 2)}):
                        jobs.append((f"{role}:{SYS.get(nr, nr)}:{err}@{k}+", [f"e:{scope}:{nr}:{k}:0:{E[err]}:{sel}"]))
    return jobs


def plan_short(counts):
    jobs = []
    for role, scope in (("ui", "u"), ("child", "c")):
        for nr in (0, 1):
            if counts[role].get(nr):
                for val in (1, 7, 4095):
                    jobs.append((f"{role}:{SYS[nr]}:short{val}", [f"s:{scope}:{nr}:1:0:{val}:any"]))
    return jobs


def plan_seu(counts, runs, seed, kind):
    rnd = random.Random(seed)
    jobs = []
    for i in range(runs):
        role, scope = ("child", "c") if kind != "ui" and rnd.random() < 0.6 and counts["child"] else ("ui", "u")
        pool = [nr for nr in counts[role] if counts[role][nr] >= 3 and nr in (0, 1, 271, 217, 262, 257, 326, 263)]
        if not pool:
            continue
        nr = rnd.choice(pool)
        k = rnd.randint(1, counts[role][nr])
        target = rnd.choice(["reg", "reg", "stack", "stack", "bss", "bss", "heap", "heap", "text"])
        jobs.append((f"seu:{role}:{target}:{SYS.get(nr, nr)}@{k}#{i}", [f"f:{scope}:{nr}:{k}:1:{rnd.randint(1, 1 << 30)}:{target}"]))
    return jobs


def summarize(results, syms):
    by = defaultdict(list)
    for r in results:
        by[r["cls"]].append(r)
    print(f"\n== {len(results)} runs: " + ", ".join(f"{c}={len(by[c])}" for c in reversed(SEV) if by[c]))
    for cls in reversed(SEV):
        if cls == "OK" or not by[cls]:
            continue
        groups = Counter()
        example = {}
        for r in by[cls]:
            where = ",".join(sorted({syms.name(f["rip"]).split("+")[0] for f in r["faults"]})) or "-"
            fam = r["tag"].split("@")[0].split("#")[0]
            key = (fam, where, (r["verdicts"][0][1] if cls not in ("CRASH_UI", "WORKER_CRASH") else "")[:110])
            groups[key] += 1
            example.setdefault(key, r["tag"])
        print(f"\n[{cls}] {len(by[cls])} runs")
        for (fam, where, detail), n in groups.most_common(40):
            print(f"  {n:4d}x {fam:34s} at {where:38s} {detail}  e.g. {example[(fam, where, detail)]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["baseline", "sweep", "short", "seu", "one"])
    ap.add_argument("scen", choices=sorted(SCEN))
    ap.add_argument("-r", "--rule", action="append", default=[])
    ap.add_argument("--max-k", type=int, default=18)
    ap.add_argument("--persistent", action="store_true")
    ap.add_argument("--runs", type=int, default=200)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=max(2, (os.cpu_count() or 4) - 2))
    ap.add_argument("--out", default="")
    ap.add_argument("--only", default="", help="substring filter on planned case tags")
    a = ap.parse_args()
    flab.ensure_faultlab()
    syms = flab.Symbols(flab.DUOP)
    tpl = str(template())
    base = run_one({"scen": a.scen, "template": tpl, "tag": "baseline", "verbose": a.mode in ("baseline", "one")})
    try:
        if a.mode == "baseline" or base["cls"] != "OK":
            print(json.dumps({k: v for k, v in base.items() if k not in ("screen",)}, indent=1))
            print(base["screen"])
            if base["cls"] != "OK":
                print("baseline run is not clean -- fix the scenario first")
                return 2
            return 0
        if a.mode == "one":
            r = run_one({"scen": a.scen, "template": tpl, "tag": "one", "rules": a.rule, "verbose": True})
            for f in r["faults"]:
                f["sym"] = syms.name(f["rip"])
            print(json.dumps({k: v for k, v in r.items() if k not in ("screen", "counts")}, indent=1))
            print(r["screen"])
            return 0
        plan = {"sweep": lambda: plan_sweep(base["counts"], a.max_k, a.persistent),
                "short": lambda: plan_short(base["counts"]),
                "seu": lambda: plan_seu(base["counts"], a.runs, a.seed, SCEN[a.scen][0])}[a.mode]()
        plan = [p for p in plan if a.only in p[0]]
        jobs = [{"scen": a.scen, "template": tpl, "tag": tag, "rules": rules} for tag, rules in plan]
        print(f"{a.mode} {a.scen}: {len(jobs)} runs on {a.jobs} workers", flush=True)
        t0, results = time.monotonic(), []
        with ProcessPoolExecutor(a.jobs) as ex:
            for i, r in enumerate(ex.map(run_one, jobs, chunksize=1)):
                r.pop("counts", None)
                results.append(r)
                if r["cls"] not in ("OK",) and SEV.index(r["cls"]) >= SEV.index("WORKER_CRASH"):
                    print(f"  {r['cls']:18s} {r['tag']:40s} {r['verdicts'][0][1][:90]}", flush=True)
        print(f"done in {time.monotonic() - t0:.0f}s")
        if a.out:
            with open(a.out, "w") as f:
                for r in results:
                    for flt in r["faults"]:
                        flt["sym"] = syms.name(flt["rip"])
                    f.write(json.dumps(r) + "\n")
        summarize(results, syms)
        return 0
    finally:
        import shutil
        shutil.rmtree(tpl, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
