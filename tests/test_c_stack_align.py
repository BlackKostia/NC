#!/usr/bin/env python3
"""C modules must not rely on a 16-byte aligned stack: many assembly callers reach C with rsp 8 bytes off the System V
alignment (audit_stack_abi.py --strict-align lists them), so an aligned SSE access to a stack slot (movaps/movdqa on
[rsp+..] / [rbp-..]) in any compiled object would fault when such a caller is the first to hit it. Fails the build instead."""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ALIGNED = re.compile(r"\b(movaps|movapd|movdqa|vmovaps|vmovapd|vmovdqa\w*)\b.*\[(rsp|rbp)")


def main() -> None:
    objs = sorted(p for p in (ROOT / "build").rglob("*.o"))
    assert objs, "build/ is empty: run make first"
    bad = []
    for o in objs:
        dis = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "-M", "intel", str(o)], capture_output=True, text=True).stdout
        bad += [f"{o.relative_to(ROOT)}: {line.strip()}" for line in dis.splitlines() if ALIGNED.search(line)]
    if bad:
        print("\n".join(bad[:20]))
        sys.exit("aligned SSE stack access found: C code may assume 16-byte stack alignment that assembly callers do not provide")
    print(f"[PASS] SA1. no aligned SSE access to the stack in {len(objs)} objects (asm callers may leave rsp 8 bytes off)")
    print("ALL C STACK ALIGNMENT TESTS PASSED.")


if __name__ == "__main__":
    main()
