#!/usr/bin/env python3
"""src/fs/inflate.c vs the frozen assembly decoder (differential, incl. corrupt/truncated/mutated streams) and vs zlib
(valid streams, x86_64 and aarch64 under qemu-user)."""

import random
import struct
import subprocess
import zlib
from pathlib import Path

import c_harness as H

ROOT = Path(__file__).resolve().parents[1]


def raw_deflate(data: bytes, level: int = 6, strategy: int = zlib.Z_DEFAULT_STRATEGY) -> bytes:
    c = zlib.compressobj(level, zlib.DEFLATED, -15, 8, strategy)
    return c.compress(data) + c.flush()


def sample_inputs(rnd: random.Random) -> list[bytes]:
    text = b"The quick brown fox jumps over the lazy dog. " * 40
    runs = bytes([7]) * 5000 + bytes(range(256)) * 20
    noise = rnd.randbytes(3000)
    mixed = b"".join(rnd.choice([text[:rnd.randrange(1, 400)], noise[:rnd.randrange(1, 300)], runs[:rnd.randrange(1, 900)]])
                     for _ in range(60))
    return [b"", b"a", b"ab" * 3, text, runs, noise, mixed, rnd.randbytes(70000)]


def valid_streams(rnd: random.Random) -> list[tuple[bytes, bytes, int]]:
    """(plain, stream, mode) with mode 0 = raw deflate, 1 = zlib."""
    out = []
    for plain in sample_inputs(rnd):
        for level in (0, 1, 6, 9):
            out.append((plain, raw_deflate(plain, level), 0))
            out.append((plain, zlib.compress(plain, level), 1))
        out.append((plain, raw_deflate(plain, 9, zlib.Z_FIXED), 0))
        out.append((plain, raw_deflate(plain, 6, zlib.Z_HUFFMAN_ONLY), 0))
        out.append((plain, raw_deflate(plain, 6, zlib.Z_RLE), 0))
    return out


def corpus(rnd: random.Random) -> bytes:
    recs = [s for _, s, _ in valid_streams(rnd)]
    for s in list(recs[:60]):
        for _ in range(12):
            b = bytearray(s)
            if b:
                for _ in range(rnd.randrange(1, 4)):
                    b[rnd.randrange(len(b))] ^= 1 << rnd.randrange(8)
            recs.append(bytes(b))
        recs.append(s[: rnd.randrange(len(s) + 1)])
    recs += [rnd.randbytes(rnd.randrange(1, 400)) for _ in range(1500)]
    return b"".join(struct.pack("<I", len(r)) + r for r in recs)


def test_differential_against_reference_asm() -> None:
    rnd = random.Random(0xF1A7)
    with H.workdir() as tmp:
        t = Path(tmp)
        for name in ("inflate_reference", "inflate_api_reference"):
            subprocess.run(["as", str(ROOT / f"tests/harness/{name}.s"), "-o", str(t / f"{name}.o")], check=True)
            subprocess.run(["objcopy", "--prefix-symbols=ref_", str(t / f"{name}.o")], check=True)
        cflags = [f for f in H.COMMON if f not in ("-ffreestanding",)] + ["-fno-stack-clash-protection"]
        subprocess.run(["gcc", *cflags, "-c", str(ROOT / "src/fs/inflate.c"), "-o", str(t / "c.o")], check=True)
        subprocess.run(["gcc", "-O2", "-no-pie", "-w", str(ROOT / "tests/harness/inflate_diff.c"), str(t / "c.o"),
                        str(t / "inflate_reference.o"), str(t / "inflate_api_reference.o"), "-o", str(t / "diff")], check=True)
        (t / "corpus.bin").write_bytes(corpus(rnd))
        res = subprocess.run([str(t / "diff"), str(t / "corpus.bin")], capture_output=True, text=True, timeout=300)
        assert res.returncode == 0, res.stdout + res.stderr
        print("[PASS] I1.", res.stdout.strip())


def test_valid_streams_on_all_targets() -> None:
    rnd = random.Random(0xBEEF)
    streams = [x for x in valid_streams(rnd) if len(x[0]) < 100000][:48]
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] I2-{arch}: toolchain/qemu unavailable")
            continue
        with H.workdir() as tmp:
            exe = H.build(arch, Path(tmp), ["tests/harness/inflate_cli.c", "src/fs/inflate.c", "src/core/mem_prims.c"])
            for plain, stream, mode in streams:
                res = H.run(arch, exe, [], struct.pack("<II", mode, max(len(plain), 1)) + stream)
                head, _, body = res.stdout.partition(b"\n")
                assert res.returncode == 0 and int(head) == len(plain) and body == plain, f"{arch}: mode={mode} len={len(plain)} -> {head!r}"
            small = H.run(arch, exe, [], struct.pack("<II", 0, 10) + raw_deflate(b"x" * 100))
            assert small.stdout.split(b"\n")[0] == b"-1", f"{arch}: output cap overflow must fail with -1"
        print(f"[PASS] I2-{arch}: {len(streams)} zlib/raw streams decode identically, cap overflow rejected")


def main() -> None:
    test_differential_against_reference_asm()
    test_valid_streams_on_all_targets()
    print("ALL C INFLATE TESTS PASSED.")


if __name__ == "__main__":
    main()
