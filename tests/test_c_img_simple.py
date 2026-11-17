#!/usr/bin/env python3
"""src/fs/img_bmp.c, img_tga.c and img_pnm.c (PNM + QOI) versus the frozen assembly: structured random files (every
header variant, palettes, bit masks, RLE packets, comments, truncations) and byte-flipped mutations are decoded by both,
inside guarded mappings so any out-of-bounds read or write faults; return code, size and every pixel must match."""

import random
import struct
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
HOST_CFLAGS = [f for f in H.COMMON if f != "-ffreestanding"] + ["-fno-stack-clash-protection"]
FMT = {"bmp": 4, "pnm": 5, "tga": 6, "qoi": 7}


def rb(rng: random.Random, n: int) -> bytes:
    return bytes(rng.randrange(256) for _ in range(n))


def bmp(rng: random.Random) -> bytes:
    w, h = rng.randrange(0, 40), rng.randrange(0, 12)
    bpp = rng.choice([1, 4, 8, 16, 24, 32, 32, 24, 8, 2, 0, 15, 64])
    hsz = rng.choice([12, 40, 40, 40, 52, 56, 108, 124, 20, 64])
    comp = rng.choice([0, 0, 0, 3, 3, 1, 2, 4])
    neg = rng.random() < 0.3
    stride = ((w * bpp + 31) // 32) * 4
    if hsz == 12:
        dib = struct.pack("<IHHHH", 12, w, h, 1, bpp)
    else:
        dib = struct.pack("<IiiHHIIiiII", hsz, w, -h if neg else h, 1, bpp, comp, stride * h, 2835, 2835, rng.choice([0, 0, 2, 16, 256, 1000]), 0)
        dib += rb(rng, max(0, hsz - 40))
    masks = b""
    if hsz == 40 and comp == 3:
        masks = struct.pack("<III", *rng.choice([(0xF800, 0x7E0, 0x1F), (0x7C00, 0x3E0, 0x1F), (0xFF0000, 0xFF00, 0xFF), (0xF, 0xF0, 0xF00), (0, 0, 0), (0xFFFFFFFF, 0, 0)]))
    elif hsz >= 56 and comp == 3 and len(dib) >= 56:
        m = rng.choice([(0xF800, 0x7E0, 0x1F, 0), (0xFF0000, 0xFF00, 0xFF, 0xFF000000), (0x0F00, 0x00F0, 0x000F, 0xF000), (0xFF, 0xFF00, 0xFF0000, 0), (0xFFFFFFFF, 1, 0x80000000, 0x7FFFFFFE)])
        dib = dib[:40] + struct.pack("<IIII", *m) + dib[56:]
    pal = rb(rng, rng.choice([0, 12, 16, 64, 256 * (3 if hsz == 12 else 4)])) if bpp <= 8 else b""
    off = 14 + len(dib) + len(masks) + len(pal)
    if rng.random() < 0.1:
        off = rng.randrange(0, 200)
    data = rb(rng, stride * h + rng.choice([0, 0, 0, 5]))
    if rng.random() < 0.3:
        data = data[:rng.randrange(0, len(data) + 1)]
    out = b"BM" + struct.pack("<IHHI", off + len(data), 0, 0, off) + dib + masks + pal + data
    return out


def tga(rng: random.Random) -> bytes:
    typ = rng.choice([1, 2, 3, 9, 10, 11, 0, 4, 32, 2, 10])
    cm = rng.choice([0, 1, 1]) if typ & 7 == 1 or rng.random() < 0.2 else 0
    cmn, cme = rng.choice([0, 1, 4, 16, 256, 300]), rng.choice([8, 15, 16, 24, 32, 0, 40])
    w, h = rng.randrange(0, 20), rng.randrange(0, 12)
    bpp = rng.choice([8, 15, 16, 24, 32, 8, 24, 0, 40])
    idlen = rng.choice([0, 0, 0, 3, 20])
    hdr = bytes([idlen, cm, typ]) + struct.pack("<HHBHHHHBB", 0, cmn, cme, 0, 0, w, h, bpp, 0)[0:0]
    hdr = bytes([idlen, cm, typ]) + struct.pack("<HHB", 0, cmn, cme) + struct.pack("<HHHH", 0, 0, w, h) + bytes([bpp, rng.choice([0, 0x20, 0x08, 0x28])])
    body = rb(rng, idlen)
    if cm:
        body += rb(rng, cmn * ((cme + 7) // 8) + rng.choice([0, 0, -3, 5]))
    n = w * h * max(1, (bpp + 7) // 8)
    if typ & 8:
        px = b""
        while len(px) < n * rng.choice([1, 1, 1, 2]) and len(px) < 4000:
            cnt = rng.randrange(0, 128)
            px += bytes([cnt | (0x80 if rng.random() < 0.5 else 0)]) + rb(rng, (1 if px and rng.random() < 0 else (bpp + 7) // 8) * (1 if px[-1:] >= b"\x80" or rng.random() < 0.5 else cnt + 1))
        body += px
    else:
        body += rb(rng, n + rng.choice([0, 0, 0, 7, -5]))
    out = hdr + body
    return out[:rng.randrange(18, len(out) + 1)] if rng.random() < 0.2 else out


def pnm(rng: random.Random) -> bytes:
    ws = lambda: rng.choice([b" ", b"\n", b"\r\n", b"\t", b"  ", b" # comment\n", b"#x\n#y\n", b"\x00"])
    magic = rng.choice([b"P5", b"P6", b"P6", b"P5", b"P3"])
    w, h = rng.randrange(0, 20), rng.randrange(0, 10)
    maxv = rng.choice([1, 15, 100, 255, 255, 256, 1000, 65535, 0, 70000, 2**31, 2**31 - 1])
    num = lambda v: rng.choice([str(v), "%0*d" % (6, v), str(v) + "x"]).encode() if rng.random() < 0.1 else str(v).encode()
    head = magic + ws() + num(w) + ws() + num(h) + ws() + num(maxv)
    head += rng.choice([b" ", b"\n", b"", b"  "])
    ch = 3 if magic == b"P6" else 1
    bps = 2 if maxv > 255 else 1
    body = rb(rng, w * h * ch * bps + rng.choice([0, 0, 0, 4, -3]))
    out = head + body
    return out[:rng.randrange(2, len(out) + 1)] if rng.random() < 0.2 else out


def qoi(rng: random.Random) -> bytes:
    w, h = rng.randrange(0, 24), rng.randrange(0, 12)
    stream = bytearray()
    for _ in range(rng.randrange(0, w * h + 10)):
        r = rng.random()
        if r < 0.1:
            stream += bytes([0xFE]) + rb(rng, 3)
        elif r < 0.2:
            stream += bytes([0xFF]) + rb(rng, 4)
        elif r < 0.45:
            stream += bytes([0x40 | rng.randrange(64)])
        elif r < 0.65:
            stream += bytes([0x80 | rng.randrange(64)]) + rb(rng, 1)
        elif r < 0.85:
            stream += bytes([0xC0 | rng.randrange(62)])
        else:
            stream += bytes([rng.randrange(64)])
    stream += bytes([0] * 7 + [1])
    out = b"qoif" + struct.pack(">IIBB", w, h, rng.choice([3, 4]), 0) + bytes(stream)
    return out[:rng.randrange(0, len(out) + 1)] if rng.random() < 0.25 else out


def mutate(rng: random.Random, d: bytes) -> bytes:
    b = bytearray(d)
    for _ in range(rng.randrange(1, 4)):
        if b:
            b[rng.randrange(min(len(b), 64) if rng.random() < 0.7 else len(b))] = rng.randrange(256)
    return bytes(b)


GEN = {"bmp": bmp, "tga": tga, "pnm": pnm, "qoi": qoi}
MIN = {"bmp": 0, "tga": 18, "pnm": 2, "qoi": 0}     # callers (img_detect) guarantee these minimum lengths for the decoders


def records(rng: random.Random, name: str, count: int) -> bytes:
    out = bytearray()
    for i in range(count):
        d = GEN[name](rng)
        if i % 3 == 2:
            d = mutate(rng, d)
        if len(d) < MIN[name]:
            d += bytes(MIN[name] - len(d))
        out += struct.pack("<IB", len(d), FMT[name]) + d
    return bytes(out)


def build(t: Path) -> Path:
    objs = []
    for m in ("bmp", "tga", "pnm"):
        o = t / f"img_{m}_ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / f"tests/harness/img_{m}_reference.s"), "-o", str(o)], check=True)
        objs.append(o)
    H.rename_defined_globals(objs, "ref_")
    for m in ("bmp", "tga", "pnm"):
        o = t / f"img_{m}.o"
        subprocess.run(["gcc", *HOST_CFLAGS, "-c", str(ROOT / f"src/fs/img_{m}.c"), "-o", str(o)], check=True)
        objs.append(o)
    exe = t / "imgdiff"
    link = subprocess.run(["gcc", "-O1", "-no-pie", "-w", "-I", str(ROOT / "include"), str(ROOT / "tests/harness/img_diff.c"), *map(str, objs), "-o", str(exe)],
                          capture_output=True, text=True)
    assert link.returncode == 0, link.stderr[-1500:]
    return exe


def test_differential(exe: Path) -> None:
    rng = random.Random(0x1CE)
    for name in ("bmp", "tga", "pnm", "qoi"):
        data = records(rng, name, 6000)
        res = subprocess.run([str(exe)], input=data, capture_output=True, timeout=300)
        assert res.returncode == 0, f"{name}: {res.stdout.decode()} {res.stderr.decode()[-300:]}"
        line = res.stdout.decode().strip()
        decoded = int(line.split("(")[1].split(" decoded")[0])
        assert decoded > 600, f"{name}: the generator must produce many decodable files ({line})"
        print(f"[PASS] IMG-{name}. {line}")


def main() -> None:
    with H.workdir() as d:
        exe = build(Path(d))
        test_differential(exe)
    print("ALL C IMG (BMP/TGA/PNM/QOI) TESTS PASSED.")


if __name__ == "__main__":
    main()
