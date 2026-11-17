#!/usr/bin/env python3
"""src/fs/du_links.c and du_cache.c versus the frozen assembly: random operation sequences on the hard-link set (first sighting,
reset, probe-run overflow) and the subtree cache (hit, stale mtime signature, ino 0, eviction after 16 probes, cleanup / re-init),
with keys forged to share one hash slot, plus four threads sharing both tables (every key is a first sighting exactly once)."""

import os
import random
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
M64 = (1 << 64) - 1
REFS = ["du_links", "du_cache"]
CLI_C = ["tests/harness/du_tables_cli.c", "src/fs/du_links.c", "src/fs/du_cache.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
         "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
ENV = {"PATH": os.environ.get("PATH", "")}


def build(arch: str, t: Path, with_ref: bool) -> Path:
    objs = []
    if with_ref:
        for m in REFS:
            o = t / f"{m}_ref.o"
            subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                            str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
            objs.append(o)
        H.rename_defined_globals(objs, "ref_")
    thr = t / "pal_thread.o"
    subprocess.run([*H.ARCHS[arch]["as_"], "-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include"),
                    str(ROOT / f"src/os/linux/{arch}/pal_thread.s"), "-o", str(thr)], check=True)
    return H.build(arch, t, CLI_C, [*objs, thr], [] if with_ref else ["-DNO_REF"])


def run(exe: Path, *args: str, data: bytes = b"") -> str:
    res = subprocess.run([str(exe), *args], input=data, capture_output=True, env=ENV, timeout=300)
    assert res.returncode == 0, res.stderr
    return res.stdout.decode()


def same(o: str) -> bool:
    p = o.split()
    return p[0] == p[1] and (len(p) == 2 or p[2] == p[3])        # "ref c" or "ref c ref_size c_size"


def link_dev(ino: int, slot_hash: int) -> int:
    """a dev for which the link-set hash of (ino, dev) is slot_hash: h = ino * C ^ dev"""
    return ((ino * 0x9E3779B97F4A7C15) & M64) ^ slot_hash


def forged_keys(rng: random.Random, groups: int, per_group: int) -> list[tuple[int, int]]:
    keys = []
    for _ in range(groups):
        h = rng.getrandbits(64)
        for _ in range(per_group):
            ino = rng.randrange(1, 1 << 40)
            keys.append((ino, link_dev(ino, h)))
    return keys


def test_ops(exe: Path) -> None:
    rng = random.Random(21)
    plain = [(rng.randrange(0, 400), rng.randrange(0, 4)) for _ in range(300)]
    keys = plain + forged_keys(rng, 4, 90)                          # 90 keys per slot: more than the 64 / 16 probe windows
    lines = []
    last_sig: dict[tuple[int, int], int] = {}
    for i in range(40000):
        ino, dev = rng.choice(keys)
        r = rng.random()
        if r < 0.35:
            lines.append(f"L {dev} {ino}")
        elif r < 0.5:
            last_sig[(ino, dev)] = rng.choice([5, -5, 1 << 40])
            lines.append(f"P {ino} {dev} {last_sig[(ino, dev)]} {rng.getrandbits(64)}")
        elif r < 0.9:
            sig = last_sig.get((ino, dev), 7) if rng.random() < 0.7 else rng.choice([5, -5, 1 << 40, 7])
            lines.append(f"G {ino} {dev} {sig}")
        elif r < 0.903:
            lines.append("R")
        elif r < 0.91:
            lines.append("I")
        elif r < 0.9125:
            lines.append("C")
        elif r < 0.915:
            lines.append("X")
        else:
            lines.append(f"G {ino} {dev} {last_sig.get((ino, dev), 5)}")
    lines = ["I", "R"] + lines
    out = run(exe, "ops", data=("\n".join(lines) + "\n").encode()).splitlines()
    assert len(out) == len(lines)
    bad = [(l, o) for l, o in zip(lines, out) if not same(o)]
    assert not bad, bad[:3]
    firsts = [o for l, o in zip(lines, out) if l[0] == "L"]
    hits = [o for l, o in zip(lines, out) if l[0] == "G" and o.split()[0] == "1"]
    assert any(o == "1 1" for o in firsts) and any(o == "0 0" for o in firsts), "link set sees first and repeated sightings"
    assert len(hits) > 500, f"cache hits are exercised ({len(hits)} of {sum(l[0] == chr(71) for l in lines)} gets)"
    print(f"[PASS] DU1. {len(lines)} random link-set / cache operations (forged slot collisions, resets, cleanup) identical to the asm")


def test_edges(exe: Path) -> None:
    lines = ["L 1 5", "R", "L 1 5", "L 1 5", "L 2 5", "L 1 0", "L 1 0",             # ino 0 is never remembered: always first
             "G 5 1 9", "P 5 1 9 100", "G 5 1 9", "G 5 1 10", "G 0 0 0", "P 0 0 0 1", "G 0 0 0",
             "C", "L 1 5", "R", "L 1 5", "L 1 5", "R", "L 1 5", "X", "G 5 1 9", "P 5 1 9 100", "I", "G 5 1 9", "P 5 1 9 200", "G 5 1 9"]
    out = run(exe, "ops", data=("\n".join(lines) + "\n").encode()).splitlines()
    for l, o in zip(lines, out):
        assert same(o), (l, o)
    assert out[0] == "1 1" and out[2] == "1 1" and out[3] == "0 0" and out[4] == "1 1" and out[6] == "1 1", out[:7]   # no table yet: everything is new
    print("[PASS] DU2. edge cases (ino 0, uninitialised tables, reset, stale signature, overwrite) identical to the asm")


def test_probe_runs(exe: Path) -> None:
    """keys forged into one slot, inserted in order and then queried in order: the 64 (links) / 16 (cache) probe windows and the eviction"""
    rng = random.Random(22)
    group = forged_keys(rng, 1, 80)
    lines = ["I", "R"]
    for rep in range(2):
        lines += [f"L {dev} {ino}" for ino, dev in group]
    lines += ["R"] + [f"L {dev} {ino}" for ino, dev in group[:66]] + [f"L {dev} {ino}" for ino, dev in reversed(group[:66])]
    lines += [f"P {ino} {dev} 5 {i}" for i, (ino, dev) in enumerate(group[:24])]
    lines += [f"G {ino} {dev} 5" for ino, dev in group[:24]] + [f"G {ino} {dev} 6" for ino, dev in group[:24]]
    lines += [f"P {ino} {dev} 5 {i + 100}" for i, (ino, dev) in enumerate(group[:24])] + [f"G {ino} {dev} 5" for ino, dev in group[:24]]
    out = run(exe, "ops", data=("\n".join(lines) + "\n").encode()).splitlines()
    assert len(out) == len(lines) and all(same(o) for o in out), [(l, o) for l, o in zip(lines, out) if not same(o)][:3]
    g = [o for l, o in zip(lines, out) if l.startswith("G") and l.endswith(" 5")]
    assert g[:24].count("1 1 0 0") + sum(o.startswith("1 1") for o in g[:24]) >= 16 and any(o.startswith("0 0") for o in g[:24]), "the 16-slot window evicts"
    print("[PASS] DU5. probe-window limits (64 links / 16 cache) and slot eviction identical to the asm on forged same-slot keys")


def test_threads(exe: Path) -> None:
    for keys, forged, rounds, iters in ((6000, 0, 3, 150000), (48, 1, 400, 300), (60, 1, 300, 400)):
        out = run(exe, "threads", str(keys), str(forged), str(rounds), str(iters)).split()
        inline, bad_rounds, torn = (int(p.split("=")[1]) for p in out)
        assert inline == 0, "x86_64 must really run four threads"
        assert torn == 0, out
        assert bad_rounds == 0, f"each key must be a first sighting exactly once under contention: {out}"
    print("[PASS] DU3. four threads share the link set and the cache (600 contended rounds): one first sighting per key, no torn cache entries")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build("x86_64", t, True)
        test_ops(exe)
        test_edges(exe)
        test_probe_runs(exe)
        test_threads(exe)
    if H.available("aarch64"):
        with H.workdir() as d:
            exe = build("aarch64", Path(d), False)
            out = subprocess.run([*H.ARCHS["aarch64"]["run"], str(exe), "threads", "6000", "0", "2", "20000"], capture_output=True, timeout=300, text=True)
            inline, bad_rounds, torn = (int(p.split("=")[1]) for p in out.stdout.split())
            assert torn == 0 and bad_rounds == 0, out.stdout
            print(f"[PASS] DU4. aarch64 (qemu{', serial: clone needs CLONE_SYSVSEM there' if inline else ''}): link set and cache keep exact first-sighting counts")
    print("ALL C DISK USAGE TABLE TESTS PASSED.")


if __name__ == "__main__":
    main()
