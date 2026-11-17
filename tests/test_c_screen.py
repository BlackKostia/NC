#!/usr/bin/env python3
"""src/tui/screen*.c versus the frozen assembly (tests/harness/screen*_reference.s): random drawing sequences (cells,
pens, fills, boxes, UTF-8 text with wide / combining / control / malformed characters, resizes, rectangle
invalidation) followed by flushes; the ANSI byte stream and a hash of both cell buffers + geometry must match for
every iteration. Plus ABI facts (vtable, struct layout) and an aarch64 (qemu-user) run against the x86_64 stream."""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
REFS = ["screen", "screen_buffer", "screen_text", "screen_out"]
CLI_C = ["tests/harness/screen_cli.c", "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
         "src/core/string.c", "src/core/mem_prims.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/memory.c", "src/core/utf8.c",
         "src/core/oop_rt.c"]


def build(t: Path) -> Path:
    objs = []
    for m in REFS:
        o = t / f"{m}_ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
        objs.append(o)
    H.rename_defined_globals(objs, "ref_")
    return H.build("x86_64", t, CLI_C, objs)


def run(exe: Path, impl: str, seed: int, iters: int, runner: list[str] | None = None) -> tuple[bytes, bytes]:
    res = subprocess.run([*(runner or []), str(exe), impl, str(seed), str(iters)], capture_output=True, timeout=300)
    assert res.returncode == 0, (impl, seed, res.stderr[-300:])
    return res.stdout, res.stderr


def test_differential(exe: Path) -> None:
    total = 0
    for seed in range(1, 41):
        r, c = run(exe, "ref", seed, 120), run(exe, "c", seed, 120)
        assert r[1] == c[1], f"seed {seed}: cell buffers / geometry diverge (first differing state line)"
        assert r[0] == c[0], f"seed {seed}: flushed ANSI streams differ ({len(r[0])} vs {len(c[0])} bytes)"
        total += len(c[0])
    assert total > 500000, f"the scenario must emit a meaningful volume of output ({total})"
    print(f"[PASS] SC1. 40 seeds x 120 frames: {total} bytes of ANSI output and every buffer state identical to the asm")


def test_stream_shape(exe: Path) -> None:
    out, _ = run(exe, "c", 3, 60)
    assert out.startswith(b"\x1b[?2026h") and out.count(b"\x1b[?2026h") == out.count(b"\x1b[0m\x1b[?2026l"), "frames are synchronized updates"
    assert b"\x1b[38;2;" in out and b"\x1b[48;2;" in out and b"\x1b[1;1H" in out
    print("[PASS] SC2. frames are DEC 2026 synchronized updates with TrueColor SGR and absolute cursor moves")


def test_aarch64(exe: Path) -> None:
    if not H.available("aarch64"):
        print("[SKIP] SC3: aarch64 toolchain/qemu unavailable")
        return
    with H.workdir() as d:
        a64 = H.build("aarch64", Path(d), [c for c in CLI_C] + ["tests/harness/screen_ref_stubs.c"])
        for seed in (1, 2, 3):
            assert run(a64, "c", seed, 60, ["qemu-aarch64"]) == run(exe, "c", seed, 60), f"seed {seed}: aarch64 differs from x86_64"
    print("[PASS] SC3. aarch64 (qemu-user) produces the same ANSI stream and buffer states as x86_64")


def main() -> None:
    with H.workdir() as d:
        exe = build(Path(d))
        test_differential(exe)
        test_stream_shape(exe)
        test_aarch64(exe)
    print("ALL C SCREEN TESTS PASSED.")


if __name__ == "__main__":
    main()
