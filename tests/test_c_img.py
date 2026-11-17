#!/usr/bin/env python3
"""src/fs/img_bmp.c, img_tga.c and img_pnm.c (PNM + QOI) versus the frozen assembly: structured random files (every
header variant, palettes, bit masks, RLE packets, comments, truncations) and byte-flipped mutations are decoded by both,
inside guarded mappings so any out-of-bounds read or write faults; return code, size and every pixel must match."""

import random
import struct
import subprocess
import zlib
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
HOST_CFLAGS = [f for f in H.COMMON if f != "-ffreestanding"] + ["-fno-stack-clash-protection"]
FMT = {"bmp": 4, "pnm": 5, "tga": 6, "qoi": 7, "gif": 3, "png": 1, "jpeg": 2}


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


def lzw_encode(rng: random.Random, pixels: list[int], mcs: int) -> bytes:
    """GIF LZW as an encoder produces it (code size grows when an entry equals 1 << size; clear before the table is full)."""
    clear, eoi = 1 << mcs, (1 << mcs) + 1
    bits = bytearray()
    acc = nb = 0

    def emit(code: int, size: int) -> None:
        nonlocal acc, nb
        acc |= code << nb
        nb += size
        while nb >= 8:
            bits.append(acc & 255)
            acc >>= 8
            nb -= 8
    size, nxt, table = mcs + 1, eoi + 1, {}
    emit(clear, size)
    cur = None
    for p in pixels:
        if cur is None:
            cur = p
            continue
        if (cur, p) in table:
            cur = table[(cur, p)]
            continue
        emit(cur, size)
        table[(cur, p)] = nxt
        if nxt == (1 << size) and size < 12:
            size += 1
        nxt += 1
        if nxt >= 4094 or rng.random() < 0.002:                  # table (nearly) full or an early clear
            emit(clear, size)
            size, nxt, table = mcs + 1, eoi + 1, {}
        cur = p
    if cur is not None:
        emit(cur, size)
    emit(eoi, size)
    if nb:
        bits.append(acc & 255)
    return bytes(bits)


def subblocks(rng: random.Random, data: bytes) -> bytes:
    out = bytearray()
    i = 0
    while i < len(data):
        n = min(rng.choice([255, 255, 1, 7, 100]), len(data) - i)
        out += bytes([n]) + data[i:i + n]
        i += n
    return bytes(out) + b"\x00"


def gif(rng: random.Random) -> bytes:
    cw, ch = rng.randrange(0, 40), rng.randrange(0, 30)
    gbits = rng.randrange(0, 8)
    use_gpal = rng.random() < 0.7
    out = bytearray(rng.choice([b"GIF89a", b"GIF87a"]) + struct.pack("<HHBBB", cw, ch, (0x80 | gbits) if use_gpal else gbits, 0, 0))
    if use_gpal:
        out += rb(rng, 3 * (2 << gbits))
    for _ in range(rng.randrange(0, 3)):                           # extensions before the image
        k = rng.random()
        if k < 0.5:
            out += bytes([0x21, 0xF9, 4, rng.choice([0, 1, 1, 5]), 10, 0, rng.randrange(0, 20), 0])
        elif k < 0.8:
            out += bytes([0x21, 0xFE]) + subblocks(rng, rb(rng, rng.randrange(0, 40)))
        else:
            out += bytes([0x21, 0xFF, 11]) + b"NETSCAPE2.0" + subblocks(rng, rb(rng, 3))
    if rng.random() < 0.05:
        out += bytes([0x3B])
    big = rng.random() < 0.08                                       # large noisy frames fill the 4096-entry dictionary (12-bit codes)
    iw, ih = (rng.randrange(60, 140), rng.randrange(60, 140)) if big else (rng.randrange(0, 30), rng.randrange(0, 30))
    ix, iy = rng.randrange(0, 12), rng.randrange(0, 12)
    lbits = rng.randrange(0, 8)
    lpal = rng.random() < 0.3
    flags = (0x80 | lbits if lpal else 0) | (0x40 if rng.random() < 0.4 else 0)
    out += bytes([0x2C]) + struct.pack("<HHHHB", ix, iy, iw, ih, flags)
    if lpal:
        out += rb(rng, 3 * (2 << lbits))
    mcs = rng.choice([4, 6, 8]) if big else rng.choice([2, 3, 4, 5, 6, 7, 8, 8, 1, 9, 11, 12, 0])
    top = 1 << min(mcs, 8) if mcs else 2
    pixels = [rng.choice([rng.randrange(top), rng.randrange(top)] if big else [rng.randrange(top), rng.randrange(min(top, 3)), 0]) for _ in range(max(iw * ih + rng.choice([0, 0, 5, -3]), 0))]
    if rng.random() < 0.15:
        stream = rb(rng, rng.randrange(0, 60))
    else:
        stream = lzw_encode(rng, pixels, max(mcs, 2) if mcs < 12 else 11)
    out += bytes([mcs]) + subblocks(rng, stream)
    if rng.random() < 0.8:
        out += bytes([0x3B])
    return bytes(out)[:len(out) - rng.randrange(1, 4)] if rng.random() < 0.15 else bytes(out)


def png_chunk(typ: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + typ + data + struct.pack(">I", zlib.crc32(typ + data))


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def png(rng: random.Random) -> bytes:
    ctype = rng.choice([0, 2, 3, 4, 6, 3, 2, 6, 1, 5, 7])
    depth = rng.choice({0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]}.get(ctype, [8, 3, 0, 32]))
    ilace = rng.choice([0, 0, 1, 1, 2])
    w, h = rng.randrange(0 if rng.random() < 0.02 else 1, 36), rng.randrange(1, 14)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(ctype, 1)
    bits = ch * depth
    passes = [(0, 0, 1, 1)] if not ilace else ADAM7
    raw = bytearray()
    for x0, y0, dx, dy in passes:
        pw = max(0, (w - x0 + dx - 1) // dx) if w > x0 else 0
        ph = max(0, (h - y0 + dy - 1) // dy) if h > y0 else 0
        if not pw:
            continue
        for _ in range(ph):
            raw += bytes([rng.choice([0, 1, 2, 3, 4, 4, 0, 7])]) + rb(rng, (pw * bits + 7) // 8)
    if rng.random() < 0.15:
        raw = raw[:rng.randrange(0, len(raw) + 1)]                      # short data: the remaining rows decode as zeros
    ihdr = struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, ilace)
    out = b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", ihdr)
    if rng.random() < 0.8 and ctype in (3, 2, 6, 0, 4):
        out += png_chunk(b"PLTE", rb(rng, rng.choice([3, 6, 12, 48, 768, 10, 0]) if ctype == 3 else rng.choice([3, 30])))
    if rng.random() < 0.6:
        trns = {3: rb(rng, rng.choice([1, 2, 5, 16, 300])), 0: rb(rng, rng.choice([2, 2, 1])), 2: rb(rng, rng.choice([6, 6, 5, 2]))}.get(ctype, rb(rng, 2))
        if ctype in (0, 2) and rng.random() < 0.7:                      # a key that really occurs: first pixel sample
            trns = bytes(raw[1:1 + len(trns)]) if len(raw) > len(trns) else trns
        out += png_chunk(b"tRNS", trns)
    comp = zlib.compress(bytes(raw), rng.choice([0, 1, 6, 9]))
    if rng.random() < 0.1:
        comp = comp[:rng.randrange(0, len(comp) + 1)]
    cuts = sorted(rng.sample(range(len(comp) + 1), min(len(comp) + 1, rng.choice([1, 1, 2, 3]))))
    pieces, last = [], 0
    for c in cuts + [len(comp)]:
        pieces.append(comp[last:c])
        last = c
    for piece in pieces:
        if piece or rng.random() < 0.1:
            out += png_chunk(b"IDAT", piece)
        if rng.random() < 0.1:
            out += png_chunk(b"tEXt", b"k\x00v")
    if rng.random() < 0.85:
        out += png_chunk(b"IEND", b"")
    if rng.random() < 0.12:                                                  # cut inside the last chunk, 1..3 bytes short
        return out[:len(out) - rng.randrange(1, 4)]
    return out[:rng.randrange(0, len(out) + 1)] if rng.random() < 0.1 else out


def jpeg(rng: random.Random) -> bytes:
    """Real encoder output (Pillow/libjpeg): every subsampling, gray, restart intervals, optimized tables, progressive
    (rejected as unsupported), 16-bit quantizers, then optional truncation / byte flips."""
    from PIL import Image
    import io
    w, h = rng.randrange(1, 80), rng.randrange(1, 60)
    mode = rng.choice(["RGB", "RGB", "RGB", "L"])
    kind = rng.random()
    if kind < 0.4:                                              # noise: long AC runs, big magnitudes, 16-bit Huffman codes
        px = rb(rng, w * h * (3 if mode == "RGB" else 1))
    elif kind < 0.7:                                            # gradients: few coefficients, long zero runs, EOB
        px = bytes(((x * 255 // max(w, 1)) ^ (y * rng.randrange(1, 9))) & 255 for y in range(h) for x in range(w) for _ in range(3 if mode == "RGB" else 1))
    else:
        px = bytes(rng.choice([0, 255, 128]) for _ in range(w * h * (3 if mode == "RGB" else 1)))
    im = Image.frombytes(mode, (w, h), px)
    kw = {"quality": rng.choice([1, 20, 50, 75, 95, 100]), "optimize": rng.random() < 0.4, "progressive": rng.random() < 0.08}
    if mode == "RGB":
        kw["subsampling"] = rng.choice([0, 1, 2, 2, 1])
    if rng.random() < 0.3:
        kw["restart_marker_blocks"] = rng.randrange(1, 9)
    if rng.random() < 0.2:
        kw["qtables"] = [[rng.choice([1, 2, 16, 300, 1000, 255]) for _ in range(64)] for _ in range(2 if mode == "RGB" else 1)]
    buf = io.BytesIO()
    try:
        im.save(buf, "JPEG", **kw)
    except (ValueError, OSError, TypeError):
        kw.pop("subsampling", None)
        kw.pop("qtables", None)
        buf = io.BytesIO()
        im.save(buf, "JPEG", **kw)
    out = buf.getvalue()
    r = rng.random()
    if r < 0.15:
        out = out[:rng.randrange(2, len(out) + 1)]
    elif r < 0.3:
        out = out[:len(out) - rng.randrange(1, 4)]
    return out


GEN = {"bmp": bmp, "tga": tga, "pnm": pnm, "qoi": qoi, "gif": gif, "png": png, "jpeg": jpeg}
MIN = {"bmp": 0, "tga": 18, "pnm": 2, "qoi": 0, "gif": 0, "png": 0, "jpeg": 0}     # callers (img_detect) guarantee these minimum lengths for the decoders


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


def build(t: Path, refs: tuple[str, ...] = ("bmp", "tga", "pnm", "gif", "gif_lzw", "png", "png_px", "jpeg", "jpeg_frame", "jpeg_bits", "jpeg_scan", "jpeg_idct"), mods: tuple[str, ...] = ("bmp", "tga", "pnm", "gif", "png", "jpeg")) -> Path:
    objs = []
    for m in refs:
        o = t / f"img_{m}_ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), "-I", str(ROOT / "tests/harness"),
                        str(ROOT / f"tests/harness/img_{m}_reference.s"), "-o", str(o)], check=True)
        objs.append(o)
    H.rename_defined_globals(objs, "ref_")
    for m in mods:
        o = t / f"img_{m}.o"
        subprocess.run(["gcc", *HOST_CFLAGS, "-c", str(ROOT / f"src/fs/img_{m}.c"), "-o", str(o)], check=True)
        objs.append(o)
    inf = t / "inflate.o"                                                          # shared by both PNG decoders
    subprocess.run(["gcc", *HOST_CFLAGS, "-c", str(ROOT / "src/fs/inflate.c"), "-o", str(inf)], check=True)
    objs.append(inf)
    exe = t / "imgdiff"
    link = subprocess.run(["gcc", "-O1", "-no-pie", "-w", "-I", str(ROOT / "include"), str(ROOT / "tests/harness/img_diff.c"), *map(str, objs), "-o", str(exe)],
                          capture_output=True, text=True)
    assert link.returncode == 0, link.stderr[-1500:]
    return exe


def test_differential(exe: Path) -> None:
    rng = random.Random(0x1CE)
    for name in ("bmp", "tga", "pnm", "qoi", "gif", "png", "jpeg"):
        data = records(rng, name, 1500 if name == "jpeg" else 6000)
        res = subprocess.run([str(exe)], input=data, capture_output=True, timeout=300)
        assert res.returncode == 0, f"{name}: {res.stdout.decode()} {res.stderr.decode()[-300:]}"
        line = res.stdout.decode().strip()
        decoded = int(line.split("(")[1].split(" decoded")[0])
        assert decoded > 300, f"{name}: the generator must produce many decodable files ({line})"
        print(f"[PASS] IMG-{name}. {line}")


def main() -> None:
    with H.workdir() as d:
        exe = build(Path(d))
        test_differential(exe)
    print("ALL C IMG (BMP/TGA/PNM/QOI/GIF/PNG/JPEG) TESTS PASSED.")


if __name__ == "__main__":
    main()
