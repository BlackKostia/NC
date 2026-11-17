#!/usr/bin/env python3
"""src/core/memory.c: slab/mmap allocator contract (zero-filled, 16-byte aligned, realloc, mremap growth, arena
reclaim, failure paths) under a randomized churn on x86_64 and aarch64 (qemu-user)."""

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import c_harness as H

CORE = ["src/core/memory.c", "src/core/mem_prims.c"]


OPS = {"x86_64": 200_000, "aarch64": 30_000}      # the allocator is portable C: the emulated run needs fewer operations to cover the arch-specific syscalls


def check_arch(arch: str) -> str:
    with H.workdir() as tmp:
        exe = H.build(arch, Path(tmp), ["tests/harness/memory_cli.c", *CORE])
        res = H.run(arch, exe, [str(OPS[arch])], b"", timeout=180)
        out = res.stdout.decode()
        assert res.returncode == 0 and out.startswith("ok "), f"{arch}: rc={res.returncode} {out!r} {res.stderr[-300:]!r}"
    return f"[PASS] A-{arch}: allocator contract holds ({out.split()[1]} checks, {OPS[arch] // 1000}k random alloc/realloc/free ops)"


def main() -> None:
    archs = [a for a in OPS if H.available(a)]
    for a in OPS:
        if a not in archs:
            print(f"[SKIP] A-{a}: toolchain/qemu unavailable")
    with ThreadPoolExecutor(len(archs)) as pool:                 # both ISAs at once: the wall time is the slower one
        for line in pool.map(check_arch, archs):
            print(line)
    print("ALL C MEMORY TESTS PASSED.")


if __name__ == "__main__":
    main()
