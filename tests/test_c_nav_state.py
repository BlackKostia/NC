#!/usr/bin/env python3
"""src/fs/nav_state.c and nav_persist.c versus the frozen assembly: per-tab history on random push / back / forward sequences
(duplicates, forward cut, 32-entry overflow), the case-insensitive substring test, and the persistent bookmark and frecency
lists -- loaded from odd files (blank lines, bad scores, missing newline, >64 / >128 lines, a file longer than the 16 KiB read
window), changed through add / remove / record / match and rewritten atomically. Each implementation runs in its own,
identically built data directory; results and the resulting files must be identical."""

import os
import random
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
REFS = ["nav_state", "nav_state_history", "nav_state_bookmarks", "nav_state_frecency"]
CLI_C = ["tests/harness/nav_cli.c", "src/fs/nav_state.c", "src/fs/nav_persist.c", "src/core/string.c", "src/core/string_path.c", "src/core/utf8.c",
         "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c", "src/core/tmpfile.c", "src/core/hash.c",
         "src/core/string_format.c"]
ENV = {"PATH": os.environ.get("PATH", "")}


def build(t: Path) -> Path:
    objs = []
    for m in REFS:
        o = t / f"{m}_ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
        objs.append(o)
    H.rename_defined_globals(objs, "ref_")
    return H.build("x86_64", t, CLI_C, objs)


def run(exe: Path, impl: str, script: str) -> list[str]:
    res = subprocess.run([str(exe), impl], input=script.encode(), capture_output=True, timeout=120, env=ENV)
    assert res.returncode == 0, res.stderr
    return res.stdout.decode("utf-8", "replace").splitlines()


def both(exe: Path, script: str) -> list[str]:
    ref, c = run(exe, "ref", script), run(exe, "c", script)
    assert ref == c, "results differ:\n" + "\n".join(f"{a!r:70} | {b!r}" for a, b in zip(ref, c) if a != b)[:2500]
    return c


def test_history(exe: Path) -> None:
    rng = random.Random(61)
    pool = [f"/p/{i}" for i in range(45)] + ["/", "/é ж", "/with space/x"]
    lines = ["TA\t/start"]
    for _ in range(4000):
        r = rng.random()
        tab = rng.randrange(0, 3)
        if r < 0.5:
            lines.append(f"HP\t{tab}\t{rng.choice(pool)}")
        elif r < 0.7:
            lines.append(f"HB\t{tab}")
        elif r < 0.85:
            lines.append(f"HF\t{tab}")
        else:
            lines.append(f"HD\t{tab}")
    lines += ["HP\t0\t", "HD\t0", "TF\t3"]
    out = both(exe, "\n".join(lines) + "\n")
    assert any(" len=32 " in o for o in out) and any(o.startswith("(null)") for o in out), "overflow and edge returns are exercised"
    both(exe, "TA\t-\nHD\t0\nHB\t0\nHF\t0\nHP\t0\t/a\nHD\t0\nTF\t8\nTF\t1\n")
    print("[PASS] NV1. tab history: 4000 random push / back / forward operations (cuts, repeats, 32-entry overflow) identical to the asm")


def test_contains(exe: Path) -> None:
    rng = random.Random(62)
    alpha = "abcABC xyZ/é.-_"
    lines = []
    for _ in range(20000):
        hay = "".join(rng.choice(alpha) for _ in range(rng.randrange(0, 14)))
        nd = "".join(rng.choice(alpha) for _ in range(rng.randrange(0, 5))) if rng.random() < 0.6 else hay[rng.randrange(0, len(hay) + 1):][:3].swapcase()
        lines.append(f"CI\t{hay}\t{nd}")
    out = both(exe, "\n".join(lines) + "\n")
    assert 3000 < out.count("1") < 18000, "matches and misses are both common"
    print("[PASS] NV2. nav_ci_contains identical to the asm on 20000 random pairs")


def snapshot(root: Path) -> dict[str, bytes]:
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


def persist(exe: Path, t: Path, name: str, files: dict[str, bytes], ops: list[str], env_style: str = "xdg") -> list[str]:
    res = []
    for impl in ("ref", "c"):
        root = t / f"{name}_{impl}"
        data = root / "xdg" / "duop"
        data.mkdir(parents=True)
        for fn, content in files.items():
            (data / fn).write_bytes(content)
        env = {"xdg": f"E\tXDG_DATA_HOME={root}/xdg", "home": f"E\tHOME={root}/home", "none": "E\tFOO=bar"}[env_style]
        script = "\n".join([env, "INIT", *ops, "CLEAN"]) + "\n"
        out = run(exe, impl, script.replace("@", str(root)))
        res.append((out, {k: v.replace(str(root).encode(), b"@") for k, v in snapshot(root).items()}))
    assert res[0][0] == res[1][0], f"{name}: results differ\n" + "\n".join(f"{a!r:70} | {b!r}" for a, b in zip(*[r[0] for r in res]) if a != b)[:2500]
    assert res[0][1] == res[1][1], f"{name}: files differ\n{[k for k in res[0][1] if res[0][1][k] != res[1][1].get(k)]}"
    return res[1][0]


def test_persistence(exe: Path, t: Path) -> None:
    rng = random.Random(63)
    bm_file = b"/home/a\n\n/home/b\n/home/a\n/x y/\xc3\xa9\n" + b"".join(f"/many/{i}\n".encode() for i in range(80))
    fre_file = b"5 /five\n0 /zero\nx /bad\n7/nospace\n12 /twelve\n3 \n 4 /lead\n99999999999 /huge\n3 /three" + b"".join(f"{i % 9 + 1} /f/{i}\n".encode() for i in range(150))
    big = b"".join(f"/path/number/{i:05d}/{'x' * 20}\n".encode() for i in range(900))       # longer than the 16383-byte window
    ops = []
    for _ in range(500):
        r = rng.random()
        p = f"/new/{rng.randrange(40)}"
        if r < 0.15: ops.append(f"BA\t{p}")
        elif r < 0.2: ops.append(f"BR\t{rng.randrange(-1, 70)}")
        elif r < 0.25: ops.append(f"BG\t{rng.randrange(-1, 70)}")
        elif r < 0.5: ops.append(f"FR\t{rng.choice([p, '/five', '/f/3', '/f/77'])}")
        elif r < 0.6: ops.append(f"FG\t{rng.randrange(-1, 140)}")
        elif r < 0.7: ops.append(f"FS\t{rng.randrange(-1, 140)}")
        elif r < 0.85: ops.append(f"FM\t{rng.choice(['', 'F', '/f/', 'NEW', 'zzz', 'e'])}\t{rng.choice([0, 1, 5, 200])}")
        else: ops.append("BC\nFC")
    wide = b"".join(f"/w/{i:03d}/{'y' * 270}\n".encode() for i in range(130))                 # the 16383-byte read window cuts the 59th line
    cases = {"wide": ({"bookmarks": wide, "frecency": b"".join(f"{i + 1} /w/{i:03d}/{'y' * 270}\n".encode() for i in range(130))}, ["BC", "FC", "BG\t57", "BG\t58", "FG\t57", "FG\t58"]),
             "empty": ({}, ops[:80]), "odd": ({"bookmarks": bm_file, "frecency": fre_file}, ops), "big": ({"bookmarks": big, "frecency": big}, ops[:120]),
             "nonl": ({"bookmarks": b"/only", "frecency": b"2 /only"}, ["BA\t/only", "BA\t/two", "FR\t/only", "FR\t/two", "BC", "FC", "FG\t0", "BG\t1"])}
    for name, (files, o) in cases.items():
        persist(exe, t, name, files, o)
    persist(exe, t, "home", {}, ["BA\t/a", "FR\t/b", "BC", "FC"], env_style="home")
    persist(exe, t, "noenv", {}, ["BA\t/a", "FR\t/b", "BC", "FC", "BG\t0"], env_style="none")      # no data directory: nothing is saved
    out = persist(exe, t, "full", {}, [f"BA\t/b{i}" for i in range(70)] + [f"FR\t/f{i}" for i in range(140)] + ["BC", "FC"])
    assert out[-3:] == ["64", "128", "clean"], out[-3:]
    print("[PASS] NV3. bookmarks and frecency: odd / oversized files, 500 random operations, HOME and missing environments, saved files identical to the asm")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        test_history(exe)
        test_contains(exe)
        test_persistence(exe, t)
    print("ALL C NAV STATE TESTS PASSED.")


if __name__ == "__main__":
    main()
