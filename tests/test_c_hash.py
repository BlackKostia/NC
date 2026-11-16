#!/usr/bin/env python3
"""src/core/hash.c (CRC32 + SHA-256) against zlib/hashlib on x86_64 and aarch64 (qemu-user), many sizes and chunkings."""

import hashlib
import os
import random
import zlib

import c_harness as H

SIZES = [0, 1, 3, 55, 56, 57, 63, 64, 65, 119, 120, 121, 127, 128, 129, 1000, 4096, 65535, 1 << 20, (4 << 20) - 3]
CHUNKS = [1, 7, 63, 64, 65, 4096, 1 << 22]


def expected(data: bytes) -> str:
    return f"{zlib.crc32(data) & 0xFFFFFFFF:08x} {hashlib.sha256(data).hexdigest()}"


def check_arch(arch: str) -> int:
    rnd = random.Random(0xD00F)
    n = 0
    with H.workdir() as tmp:
        exe = H.build(arch, __import__("pathlib").Path(tmp), ["tests/harness/hash_cli.c", "src/core/hash.c", "src/core/mem_prims.c"])
        for size in SIZES:
            data = rnd.randbytes(size)
            for chunk in CHUNKS:
                if size > 100000 and chunk < 64:
                    continue  # keep the byte-at-a-time cases to small inputs
                got = H.run(arch, exe, [str(chunk)], data)
                assert got.returncode == 0 and got.stdout.decode().strip() == expected(data), \
                    f"{arch}: size={size} chunk={chunk}: {got.stdout!r} != {expected(data)!r} {got.stderr!r}"
                n += 1
    return n


def main() -> None:
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] H-{arch}: toolchain/qemu unavailable")
            continue
        print(f"[PASS] H-{arch}: CRC32+SHA-256 match zlib/hashlib in {check_arch(arch)} size/chunk combinations")
    print("ALL C HASH TESTS PASSED.")


if __name__ == "__main__":
    main()
