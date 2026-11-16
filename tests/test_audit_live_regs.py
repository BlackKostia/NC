#!/usr/bin/env python3
"""audit_live_regs.py: a caller-saved register that is live across a clobbering call is reported (audit 2026-11-16).

LR1 a tiny assembled program whose caller keeps r10d across `call callee` while callee overwrites r10 is reported
LR2 the same program with a callee that saves/restores r10, or that never touches it, is clean; so is an indirect
    (vtable-style) call with the value reloaded from memory afterwards
LR3 an indirect call keeps r8d/r9d live (the handle_mouse__part2 bug class): reported, and the reload fixes it
LR4 baseline discipline: new findings, stale entries and UNREVIEWED reasons all fail the gate
LR5 the real binary has no unreviewed live-register clobbers
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AUDIT = os.path.join(REPO_ROOT, ".agents/skills/duop-reliability-audit/scripts/audit_live_regs.py")
PAD = "    nop\n" * 8

HEADER = ".intel_syntax noprefix\n.section .text\n.global _start\n_start:\n    call caller\n    mov eax, 60\n    xor edi, edi\n    syscall\n"
BUGGY = HEADER + f"caller:\n    mov r10d, 5\n{PAD}    call callee\n{PAD}    add eax, r10d\n    ret\ncallee:\n    xor r10d, r10d\n    ret\n"
SAVES = HEADER + f"caller:\n    mov r10d, 5\n{PAD}    call callee\n{PAD}    add eax, r10d\n    ret\ncallee:\n    push r10\n    xor r10d, r10d\n    pop r10\n    ret\n"
UNTOUCHED = HEADER + f"caller:\n    mov r10d, 5\n{PAD}    call callee\n{PAD}    add eax, r10d\n    ret\ncallee:\n    xor eax, eax\n    ret\n"
INDIRECT_BUG = HEADER + (f"caller:\n    mov r8d, [rsp + 8]\n    mov r9d, [rsp + 16]\n{PAD}    lea rax, [rip + callee]\n    call rax\n"
                         f"{PAD}    mov esi, r8d\n    mov edx, r9d\n    ret\ncallee:\n    ret\n")
INDIRECT_FIXED = HEADER + (f"caller:\n    mov r8d, [rsp + 8]\n    mov r9d, [rsp + 16]\n{PAD}    lea rax, [rip + callee]\n    call rax\n"
                           f"{PAD}    mov esi, [rsp + 8]\n    mov edx, [rsp + 16]\n    ret\ncallee:\n    ret\n")


def build(tmp: str, name: str, source: str) -> str:
    src, obj, elf = (os.path.join(tmp, name + ext) for ext in (".s", ".o", ""))
    with open(src, "w") as fh:
        fh.write(source)
    subprocess.run(["as", src, "-o", obj], check=True)
    subprocess.run(["ld", obj, "-o", elf], check=True)
    return elf


def run(elf: str, baseline: str, *extra: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, AUDIT, elf, "--baseline", baseline, *extra], capture_output=True, text=True)


def write_baseline(path: str, accepted: dict) -> None:
    with open(path, "w") as fh:
        json.dump({"accepted": accepted}, fh)


def test_clobbered_register_is_reported(tmp: str) -> None:
    empty = os.path.join(tmp, "empty.json")
    write_baseline(empty, {})
    res = run(build(tmp, "buggy", BUGGY), empty)
    assert res.returncode == 1 and "LIVEREG: caller -> callee r10" in res.stdout, res.stdout + res.stderr
    print("[PASS] LR1. A live r10 across a call that overwrites it is reported")


def test_safe_variants_are_clean(tmp: str) -> None:
    empty = os.path.join(tmp, "empty.json")
    write_baseline(empty, {})
    for name, source in (("saves", SAVES), ("untouched", UNTOUCHED), ("indirect_fixed", INDIRECT_FIXED)):
        res = run(build(tmp, name, source), empty)
        assert res.returncode == 0, f"{name}: false positive\n{res.stdout}{res.stderr}"
    print("[PASS] LR2. Saved/restored, untouched and reloaded registers are not reported")


def test_indirect_call_clobbers_everything(tmp: str) -> None:
    empty = os.path.join(tmp, "empty.json")
    write_baseline(empty, {})
    res = run(build(tmp, "indirect", INDIRECT_BUG), empty)
    assert res.returncode == 1, res.stdout
    for reg in ("r8", "r9"):
        assert f"LIVEREG: caller -> ? {reg}" in res.stdout, f"{reg} live across a vtable call not reported:\n{res.stdout}"
    print("[PASS] LR3. r8d/r9d kept across an indirect call are reported (handle_mouse__part2 class)")


def test_baseline_discipline(tmp: str) -> None:
    elf = build(tmp, "buggy2", BUGGY)
    path = os.path.join(tmp, "base.json")
    write_baseline(path, {"caller -> callee r10": "returns r10 by contract"})
    assert run(elf, path).returncode == 0, "an accepted, reviewed finding must pass"
    write_baseline(path, {"caller -> callee r10": "returns r10 by contract", "gone -> away rcx": "old"})
    res = run(elf, path)
    assert res.returncode == 1 and "STALE" in res.stdout, "stale baseline entries must fail the gate"
    write_baseline(path, {"caller -> callee r10": "UNREVIEWED"})
    res = run(elf, path)
    assert res.returncode == 1 and "UNREVIEWED" in res.stdout, "UNREVIEWED reasons must fail the gate"
    assert run(elf, path, "--update").returncode == 0
    with open(path) as fh:
        assert json.load(fh)["accepted"] == {"caller -> callee r10": "UNREVIEWED"}
    print("[PASS] LR4. New findings, stale entries and UNREVIEWED reasons fail; --update records findings as UNREVIEWED")


def test_real_binary_is_clean() -> None:
    subprocess.run(["make", "-s", "build/duop.sym"], cwd=REPO_ROOT, check=True)      # the rule is relative to the repo
    sym = os.path.join(REPO_ROOT, "build/duop.sym")
    res = subprocess.run([sys.executable, AUDIT, sym], capture_output=True, text=True)
    assert res.returncode == 0, f"live caller-saved register clobbers in duop:\n{res.stdout}{res.stderr}"
    print("[PASS] LR5. duop has no unreviewed live caller-saved register clobbers")


def main() -> None:
    if not (shutil.which("as") and shutil.which("ld") and shutil.which("objdump") and shutil.which("nm")):
        print("[SKIP] audit_live_regs: binutils not available")
        return
    with tempfile.TemporaryDirectory(prefix="lr_") as tmp:
        test_clobbered_register_is_reported(tmp)
        test_safe_variants_are_clean(tmp)
        test_indirect_call_clobbers_everything(tmp)
        test_baseline_discipline(tmp)
    test_real_binary_is_clean()
    print("ALL LIVE-REGISTER AUDIT TESTS PASSED.")


if __name__ == "__main__":
    main()
