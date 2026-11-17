#!/usr/bin/env python3
"""include/duop_ui.h (plan phase P2): the C forms of the assembler OOP/TRY macros behave like oop.inc / try_using.inc.

O1 tests/harness/ui_oop_cli.c self-checks (NEW/DELETE, slot dispatch with defaults and overrides, SUPER_CALL, IS_INSTANCE,
   dtor chain, DialogVtbl, TRY_BEGIN/TRY_END around a real fault) on x86_64 and under qemu-aarch64
O2 every vtable built with WIDGET_VTBL / DIALOG_VTBL lives in read-only data (const, never .data/.bss)
O3 duop_ui.h compiles cleanly (-Wall -Wextra -Werror) with gcc and clang on its own and next to every duop_*.h
"""

import subprocess
import tempfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
CORE = ["src/core/oop_rt.c", "src/core/syscall.c", "src/core/string.c", "src/core/string_path.c", "src/core/mem_prims.c",
        "src/core/try_rt.c", "src/core/utf8.c"]
EXPECT = ["new_alloc", "new_size", "new_vptr", "new_zeroed", "class_name", "slot_override", "slot_default_mouse", "slot_default_layout", "hit_test_default",
          "dtor_once", "delete_null", "inst_sizes", "super_call", "is_self", "is_parent", "is_widget", "is_object", "not_child", "not_sibling",
          "null_not_instance", "dtor_chain", "dialog_override", "dialog_default", "dialog_widget_slots", "dialog_is_widget", "try_clean",
          "try_fault", "try_after_fault"]


def build(arch: str, t: Path) -> Path:
    return H.build(arch, t, ["tests/harness/ui_oop_cli.c", *CORE], cflags=["-I", str(ROOT / "tests/harness")])


def test_selfcheck(arch: str, exe: Path) -> None:
    res = H.run(arch, exe, [], b"", timeout=60)
    lines = res.stdout.decode().splitlines()
    assert res.returncode == 0 and lines[-1] == "RESULT OK", f"{arch}: rc={res.returncode}\n{res.stdout.decode()}{res.stderr.decode()[-300:]}"
    assert [ln[3:] for ln in lines[:-1] if ln.startswith("ok ")] == EXPECT, lines
    print(f"[PASS] O1-{arch}. {len(EXPECT)} OOP / vtable / TRY checks")


def test_vtables_readonly(arch: str, t: Path) -> None:
    nm = "nm" if arch == "x86_64" else "aarch64-linux-gnu-nm"
    out = subprocess.run([nm, "-S", str(t / "prog")], capture_output=True, text=True, check=True).stdout.splitlines()
    kinds = {ln.split()[-1]: ln.split()[-2] for ln in out if ln.split()[-1] in ("Foo_vtbl", "Foo2_vtbl", "Sib_vtbl", "Dialog_vtbl", "Dlg_vtbl")}
    assert len(kinds) == 5 and all(k in "rR" for k in kinds.values()), f"{arch}: vtables must be in .rodata: {kinds}"
    print(f"[PASS] O2-{arch}. WIDGET_VTBL / DIALOG_VTBL vtables are read-only data")


def test_header_compiles() -> None:
    heads = sorted(p.name for p in (ROOT / "include").glob("duop_*.h"))
    with tempfile.TemporaryDirectory() as tmp:
        for name, body in (("alone", '#include "duop_ui.h"\n'), ("all", "".join(f'#include "{h}"\n' for h in heads))):
            src = Path(tmp) / f"{name}.c"
            src.write_text(body + "int dummy;\n")
            for arch in ("x86_64", "aarch64"):
                if not H.available(arch):
                    continue
                t = H.ARCHS[arch]
                res = subprocess.run([*t["cc"], *H.COMMON, *t["extra"], "-c", str(src), "-o", str(Path(tmp) / f"{name}_{arch}.o")], capture_output=True, text=True)
                assert res.returncode == 0, f"{arch}/{name}: {res.stderr[:1500]}"
    print("[PASS] O3. duop_ui.h compiles alone and with every duop_*.h (gcc x86_64, clang aarch64)")


def main() -> None:
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] {arch}: toolchain/qemu not installed")
            continue
        with H.workdir() as w:
            t = Path(w)
            exe = build(arch, t)
            test_selfcheck(arch, exe)
            test_vtables_readonly(arch, t)
    test_header_compiles()
    print("ALL UI OOP MACRO TESTS PASSED.")


if __name__ == "__main__":
    main()
