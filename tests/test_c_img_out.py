#!/usr/bin/env python3
"""src/fs/img_kitty.c, img_quant.c and img_sixel.c versus the frozen assembly: base64, Kitty transmission/placement,
palette quantization and Sixel bands on random pictures (alpha blends, few/many colors, runs, wide and tall sizes,
output buffers from too small to ample), compared byte for byte inside guarded buffers."""

import random
import struct
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
HOST_CFLAGS = [f for f in H.COMMON if f != "-ffreestanding"] + ["-fno-stack-clash-protection"]


def picture(rng: random.Random, w: int, h: int) -> bytes:
    kind = rng.randrange(5)
    pal = [bytes(rng.randrange(256) for _ in range(3)) for _ in range(rng.choice([1, 2, 5, 40, 300]))]
    out = bytearray()
    for i in range(w * h):
        if kind == 0:
            c = bytes(rng.randrange(256) for _ in range(3))
        elif kind == 1:
            c = pal[(i // rng.choice([1, 3])) % len(pal)] if rng.random() < 0.7 else rng.choice(pal)
        elif kind == 2:
            c = bytes([(i * 7) & 255, (i * 3 // max(w, 1)) & 255, 128])
        elif kind == 3:
            c = pal[0]
        else:
            c = bytes([rng.choice([0, 255]), rng.choice([0, 255]), rng.choice([0, 255])])
        a = rng.choice([255, 255, 255, 0, 128, rng.randrange(256)]) if rng.random() < 0.4 else 255
        out += c + bytes([a])
    return bytes(out)


def records(rng: random.Random, count: int) -> bytes:
    out = bytearray()

    def rec(kind: int, payload: bytes) -> None:
        out.extend(struct.pack("<BI", kind, len(payload)) + payload)
    for _ in range(count):
        w, h = rng.choice([(rng.randrange(1, 40), rng.randrange(1, 30)), (rng.randrange(1, 200), rng.randrange(1, 14)), (1, rng.randrange(1, 90)), (rng.randrange(1, 12), rng.randrange(1, 12))])
        px = picture(rng, w, h)
        r = rng.random()
        if r < 0.15:
            rec(0, bytes(rng.randrange(256) for _ in range(rng.randrange(0, 40))))
        elif r < 0.4:
            cap = rng.choice([w * h * 4 // 3 * 2 + 400, 4096 + 127, 4096 + 128, 20000, 300, 0, w * h * 6 + 9000])
            rec(1, struct.pack("<iiiI", w, h, rng.choice([0, 0, -1, 1, 5, 80]), cap) + px)
        elif r < 0.5:
            rec(2, struct.pack("<iiiiii", *[rng.randrange(0, 5000) for _ in range(4)], rng.randrange(0, 200), rng.randrange(0, 100)))
        elif r < 0.8:
            bg = rng.choice([0, 0xFFFFFF, 0x102030, rng.randrange(1 << 24)])
            cap = rng.choice([w * h * 8 + 20000, 70, 64, 130, w * 6 + 200, 4000, 600 + w * h])
            rec(3, struct.pack("<iiII", w, h, bg, cap) + px)
        else:
            rec(4, struct.pack("<I", rng.choice([0, 0xFFFFFF, 0x808080, rng.randrange(1 << 24)])) + px)
    return bytes(out)


def build(t: Path) -> Path:
    objs = []
    for m in ("kitty", "quant", "sixel"):
        o = t / f"img_{m}_ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / f"tests/harness/img_{m}_reference.s"), "-o", str(o)], check=True)
        objs.append(o)
    H.rename_defined_globals(objs, "ref_")
    for src in ("src/fs/img_kitty.c", "src/fs/img_quant.c", "src/fs/img_sixel.c", "src/core/string.c"):
        o = t / (Path(src).stem + ".o")
        subprocess.run(["gcc", *HOST_CFLAGS, "-c", str(ROOT / src), "-o", str(o)], check=True)
        objs.append(o)
    simd = t / "pal_simd.o"
    subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(ROOT / "src/os/linux/x86_64/pal_simd.s"), "-o", str(simd)], check=True)
    exe = t / "outdiff"
    link = subprocess.run(["gcc", "-O1", "-no-pie", "-w", "-I", str(ROOT / "include"), str(ROOT / "tests/harness/img_out_diff.c"), *map(str, objs), str(simd), "-o", str(exe)],
                          capture_output=True, text=True)
    assert link.returncode == 0, link.stderr[-1500:]
    return exe


def main() -> None:
    with H.workdir() as d:
        exe = build(Path(d))
        res = subprocess.run([str(exe)], input=records(random.Random(0x51A), 2500), capture_output=True, timeout=900)
        assert res.returncode == 0, res.stdout.decode() + res.stderr.decode()[-300:]
        line = res.stdout.decode().strip()
        produced = int(line.split("(")[1].split(" produced")[0])
        assert produced > 800, line
        print(f"[PASS] IMGO1. {line}")
    print("ALL C IMG OUTPUT ENCODER TESTS PASSED.")


if __name__ == "__main__":
    main()
