#!/usr/bin/env python3
"""The C TRY/CATCH fault guard (os_try_begin / os_try_end, include/duop_abi.h; pal_fault.s on x86_64 and aarch64): a fault inside a TRY
resumes at os_try_begin with the signal number, callee-saved registers and sp restored, frames unlinked, nesting, forked children,
x86_64 assembly TRY_BEGIN frames sharing the chain with C frames, and a fault outside any TRY staying fatal. aarch64 runs under qemu-user."""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
CORE = ["src/core/try_rt.c", "src/core/syscall.c", "src/core/string.c", "src/core/string_path.c", "src/core/mem_prims.c", "src/core/memory.c",
        "src/core/utf8.c"]
SCRIPT = "S\nK8\nK7\nK11\nN\nE\nR\nS\nM\nF\n"
EXPECT = ["S sig=11 chain=0", "K8 sig=8 chain=0", "K7 sig=7 chain=0", "K11 sig=11 chain=0", "N inner chain_is_outer=1",
          "N inner=11 outer=11 chain=0", "E sig=0 chain=0", "R probe=11", "S sig=11 chain=0", "M mix=11011", "F child_exit=42 signaled=0"]


def build(arch: str, t: Path, pal_fault: Path | None = None) -> Path:
    objs = []
    for name in (f"try_regs_{arch}.s", *(["try_mix_x86_64.s"] if arch == "x86_64" else [])):
        obj = t / (name + ".o")
        subprocess.run([*H.ARCHS[arch]["as_"], "-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include"),
                        str(ROOT / "tests/harness" / name), "-o", str(obj)], check=True, capture_output=True)
        objs.append(obj)
    return H.build(arch, t, ["tests/harness/try_cli.c", *CORE], objs, cflags=["-I", str(ROOT / "tests/harness")],
                   pal_override={"pal_fault": pal_fault} if pal_fault else None)


def run(arch: str, exe: Path, script: str, timeout: int = 60) -> subprocess.CompletedProcess:
    return H.run(arch, exe, [], script.encode(), timeout=timeout)


def test_scenarios(arch: str, exe: Path) -> None:
    res = run(arch, exe, SCRIPT if arch == "x86_64" else SCRIPT.replace("M\n", ""))
    assert res.returncode == 0, (res.returncode, res.stderr[-300:])
    want = EXPECT if arch == "x86_64" else [ln for ln in EXPECT if not ln.startswith("M ")]
    assert res.stdout.decode().splitlines() == want, res.stdout.decode()
    print(f"[PASS] TRY1-{arch}. SEGV / BUS / FPE / SEGV-by-signal recovery, nesting, clean TRY_END, callee-saved registers, "
          f"forked child{', C + assembly frames in one chain' if arch == 'x86_64' else ''}")


def test_repeated(arch: str, exe: Path) -> None:
    n = 800
    res = run(arch, exe, "S\nK8\nN\n" * n)
    assert res.returncode == 0 and res.stdout.decode().count("S sig=11 chain=0") == n, res.stderr[-200:]
    print(f"[PASS] TRY2-{arch}. {n * 4} recovered faults in one process: no frame, stack or signal-mask leak")


def test_fatal_outside_try(arch: str, exe: Path) -> None:
    res = run(arch, exe, "S\nX\nS\n")
    assert res.returncode in (-11, 128 + 11) and res.stdout.decode().splitlines() == ["S sig=11 chain=0"], (res.returncode, res.stdout, res.stderr[-200:])
    print(f"[PASS] TRY3-{arch}. a fault outside any TRY still kills the process with SIGSEGV after the recovered one")


MUTANTS = {
    "x86_64": [("rbx not saved", "    mov [rdi + TF_RBX], rbx\n", ""), ("r15 not saved", "    mov [rdi + TF_R15], r15\n", ""),
               ("sp after return", "    lea rax, [rsp + 8]\n", "    lea rax, [rsp]\n"), ("frame never linked", "    mov [r8], rdi\n", ""),
               ("prev lost", "1:  mov [rdi + TF_PREV], rax", "1:  mov qword ptr [rdi + TF_PREV], 0")],
    "aarch64": [("x27/x28 not saved", "    stp x27, x28, [x0, #TF_X19 + 64]\n", ""), ("sp not saved", "    mov x9, sp\n    str x9, [x0, #TF_SP]", "    mov x9, xzr\n    str x9, [x0, #TF_SP]"),
                ("resume skips x25/x26", "    stp x10, x11, [x2, #KUC_X19 + 48]\n", ""),
                ("frame not popped", "    str x10, [x8]\n    ldp x10, x11, [x9, #TF_X19]", "    ldp x10, x11, [x9, #TF_X19]"),
                ("owner check inverted", "    b.ne 3f\n    b 2f", "    b.eq 3f\n    b 2f"),
                ("signal not delivered in x0", "    str x10, [x2, #KUC_RET]\n", ""), ("pc not patched", "    str x10, [x2, #KUC_PC]\n", ""),
                ("frame never linked", "    str x0, [x9]\n", "")],
}


def test_mutations(arch: str, t: Path) -> None:
    src = ROOT / f"src/os/linux/{arch}/pal_fault.s"
    script = SCRIPT if arch == "x86_64" else SCRIPT.replace("M\n", "")
    want = EXPECT if arch == "x86_64" else [ln for ln in EXPECT if not ln.startswith("M ")]

    def detected(path: Path, i: int) -> bool:
        (t / f"m{i}").mkdir()
        try:
            exe = build(arch, t / f"m{i}", path)
            res = run(arch, exe, script, timeout=10)                  # a broken resume loops or hangs: ten seconds is plenty
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
            return True
        return res.returncode != 0 or res.stdout.decode().splitlines() != want

    survivors = H.mutcheck(src, MUTANTS[arch], detected, t)
    assert not survivors, f"{arch}: mutants survived: {survivors}"
    print(f"[PASS] TRY4-{arch}. {len(MUTANTS[arch])}/{len(MUTANTS[arch])} mutations of pal_fault.s are caught")


def main() -> None:
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] TRY-{arch}: toolchain/qemu unavailable")
            continue
        with H.workdir() as d:
            exe = build(arch, Path(d))
            test_scenarios(arch, exe)
            test_repeated(arch, exe)
            test_fatal_outside_try(arch, exe)
            test_mutations(arch, Path(d))
    print("ALL C TRY TESTS PASSED.")


if __name__ == "__main__":
    main()
