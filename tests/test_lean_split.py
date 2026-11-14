#!/usr/bin/env python3
"""Semantic tests for the duop-lean-modules mechanical splitters.

Each case assembles a tiny static x86-64 program, runs it, splits it with split_routine.py /
split_module.py, rebuilds and checks that the exit status (the program's computed result) is
unchanged and that the expected structure was produced.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / ".agents/skills/duop-lean-modules/scripts"
SPLIT_ROUTINE = SCRIPTS / "split_routine.py"
SPLIT_MODULE = SCRIPTS / "split_module.py"

HEAD = ".intel_syntax noprefix\n.section .text\n.global _start\n"
START = "_start:\n    call work\n    mov edi, eax\n    and edi, 255\n    mov eax, 60\n    syscall\n"


def build_run(tmp: Path, sources: list[Path]) -> int:
    objs = []
    for s in sources:
        o = s.with_suffix(".o")
        subprocess.run(["as", "-o", str(o), str(s)], check=True, capture_output=True)
        objs.append(str(o))
    exe = tmp / "prog"
    subprocess.run(["ld", "-o", str(exe), *objs], check=True, capture_output=True)
    return subprocess.run([str(exe)], check=False).returncode


def filler(n: int, reg: str = "eax") -> str:
    return "".join(f"    add {reg}, {k % 3}\n" for k in range(n))


def split(path: Path, *extra: str) -> str:
    r = subprocess.run([sys.executable, str(SPLIT_ROUTINE), *extra, str(path)],
                       check=True, capture_output=True, text=True)
    return r.stdout


def case_frame_offsets(tmp: Path) -> None:
    """Caller-frame slots shift by +16 inside a step, slots pushed inside the step do not."""
    src = tmp / "frame.s"
    body = (
        "work:\n    push rbx\n    sub rsp, 32\n"
        "    mov dword ptr [rsp], 7\n    mov dword ptr [rsp + 8], 11\n    xor eax, eax\n"
        "    # Step one: read caller slots\n" + filler(30) +
        "    add eax, [rsp]\n    add eax, [rsp + 8]\n"
        "    # Step two: pushed slot is local, frame slot is above it\n"
        "    push rax\n    mov ecx, [rsp]\n    add ecx, [rsp + 8]\n    pop rax\n    add eax, ecx\n"
        + filler(30) +
        "    # Step three: tail\n" + filler(30) +
        "    add rsp, 32\n    pop rbx\n    ret\n")
    src.write_text(HEAD + START + body)
    before = build_run(tmp, [src])
    out = split(src)
    text = src.read_text()
    assert "helpers" in out and "work__" in text, f"no steps extracted:\n{out}"
    assert "[rsp + 16]" in text or "[rsp + 8 + 16]" in text, "caller-frame operand not shifted"
    assert re.search(r"mov ecx, \[rsp\]\s*$", text, re.M), "block-local pushed slot was shifted"
    after = build_run(tmp, [src])
    assert before == after, f"result changed: {before} -> {after}"
    print(f"[PASS] S1. Step helpers keep caller-frame and pushed-slot offsets (exit {after})")


def case_fall_through(tmp: Path) -> None:
    """Helpers are never inserted between a routine and the label it falls through into."""
    src = tmp / "fall.s"
    body = (
        "work:\n    xor eax, eax\n    # Step one\n" + filler(45) + "    # Step two\n" + filler(45) +
        "    mov ecx, 3\n"
        "tail_part:\n    add eax, ecx\n    ret\n")
    src.write_text(HEAD + START + body)
    before = build_run(tmp, [src])
    split(src)
    text = src.read_text()
    i_tail = text.index("tail_part:")
    defs = [m.start() for m in re.finditer(r"^work__\w+:", text, re.M)]
    assert defs, "no steps extracted"
    assert min(defs) > i_tail, "helper placed inside a fall-through chain"
    after = build_run(tmp, [src])
    assert before == after, f"result changed: {before} -> {after}"
    print(f"[PASS] S2. Fall-through chains stay contiguous (exit {after})")


def case_stack_args(tmp: Path) -> None:
    """A block calling a routine that reads stack-passed arguments is never extracted."""
    src = tmp / "stk.s"
    callee = "argsum:\n    mov eax, [rsp + 8]\n    add eax, [rsp + 16]\n    ret\n"
    body = (
        "work:\n    sub rsp, 24\n    xor eax, eax\n"
        "    # Step one: stack arguments\n"
        "    mov dword ptr [rsp], 5\n    mov dword ptr [rsp + 8], 6\n    call argsum\n"
        + filler(70) + "    add rsp, 24\n    ret\n")
    src.write_text(HEAD + START + body + callee)
    before = build_run(tmp, [src])
    split(src)
    after = build_run(tmp, [src])
    assert before == after, f"result changed: {before} -> {after}"
    print(f"[PASS] S3. Stack-argument calls stay in the caller (exit {after})")


def case_module_split(tmp: Path) -> None:
    """split_module keeps .L-sharing code together, moves data with users, adds .global."""
    mod = tmp / "proj" / "src" / "m.s"
    mod.parent.mkdir(parents=True)
    (tmp / "proj" / "Makefile").write_text("SRCS := \\\n\tsrc/m.s \\\n\tsrc/main.s\n")
    parts = [".intel_syntax noprefix\n# m.s - test module\n", ".section .rodata\n",
             "tbl_a: .long 3\n", "tbl_b: .long 4\n", ".section .text\n.global work\n"]
    parts.append("work:\n    call fa\n    mov ecx, eax\n    call fb\n    add eax, ecx\n    ret\n")
    parts.append("fa:\n    mov eax, [rip + tbl_a]\n    jmp .Lshared\n" + filler(150, "eax"))
    parts.append("fa2:\n.Lshared:\n    add eax, 1\n    ret\n")
    parts.append("fb:\n    mov eax, [rip + tbl_b]\n" + filler(150, "eax") + "    ret\n")
    mod.write_text("".join(parts))
    main = mod.parent / "main.s"
    main.write_text(HEAD + START)
    before = build_run(tmp, [mod, main])
    subprocess.run([sys.executable, str(SPLIT_MODULE), "--max-lines", "200", "--names", "m_b",
                    str(mod)], check=True, capture_output=True, text=True)
    new = mod.parent / "m_b.s"
    assert new.is_file(), "second part not created"
    a, b = mod.read_text(), new.read_text()
    assert "fa2:" in a and "fa:" in a, ".L-sharing units were separated"
    assert "fb:" in b and "tbl_b:" in b and "tbl_a:" in a, "data did not follow its user"
    assert re.search(r"^\.global fb$", b, re.M), "cross-part routine not exported"
    assert "src/m_b.s" in (tmp / "proj" / "Makefile").read_text(), "part not registered"
    after = build_run(tmp, [mod, new, main])
    assert before == after, f"result changed: {before} -> {after}"
    print(f"[PASS] S4. Module split is link-safe and cohesive (exit {after})")


def main() -> int:
    if not (shutil.which("as") and shutil.which("ld")):
        print("[SKIP] binutils not available")
        return 0
    for case in (case_frame_offsets, case_fall_through, case_stack_args, case_module_split):
        with tempfile.TemporaryDirectory() as d:
            case(Path(d))
    print("ALL LEAN SPLIT TESTS PASSED.")
    return 0


if __name__ == "__main__":
    os.environ.pop("SPLIT_ONLY", None)
    sys.exit(main())
