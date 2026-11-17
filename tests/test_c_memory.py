#!/usr/bin/env python3
"""src/core/memory.c: slab/mmap allocator contract (zero-filled, 16-byte aligned, realloc, mremap growth, arena
reclaim, failure paths) under a randomized churn on x86_64 and aarch64 (qemu-user)."""

from pathlib import Path

import c_harness as H

CORE = ["src/core/memory.c", "src/core/mem_prims.c"]


def main() -> None:
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] A-{arch}: toolchain/qemu unavailable")
            continue
        with H.workdir() as tmp:
            exe = H.build(arch, Path(tmp), ["tests/harness/memory_cli.c", *CORE])
            res = H.run(arch, exe, [], b"", timeout=180)
            out = res.stdout.decode()
            assert res.returncode == 0 and out.startswith("ok "), f"{arch}: rc={res.returncode} {out!r} {res.stderr[-300:]!r}"
        print(f"[PASS] A-{arch}: allocator contract holds ({out.split()[1]} checks, 200k random alloc/realloc/free ops)")
    print("ALL C MEMORY TESTS PASSED.")


if __name__ == "__main__":
    main()
