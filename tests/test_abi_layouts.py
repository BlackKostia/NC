#!/usr/bin/env python3
"""C struct/vtable layouts (include/duop_*.h) versus the assembler's view (include/classes.inc, config.inc):
every offset and size is evaluated by both compilers and must agree on x86_64 and aarch64 (64-bit targets)."""

import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

LAYOUTS = [  # (C header, C expression, assembler symbol)
    ("duop_oop.h", "sizeof(Object)", "Object._size"),
    ("duop_oop.h", "offsetof(Object, vptr)", "Object.vptr"),
    ("duop_oop.h", "sizeof(Widget)", "Widget._size"),
    *[("duop_oop.h", f"offsetof(Widget, {f})", f"Widget.{f}") for f in ("parent", "x", "y", "w", "h", "flags", "id")],
    *[("duop_oop.h", f"offsetof(ObjectVtbl, {f})", f"ObjectVtbl.{f}") for f in ("super", "class_name", "inst_size", "dtor")],
    *[("duop_oop.h", f"offsetof(WidgetVtbl, {f})", f"WidgetVtbl.{f}")
      for f in ("layout", "render", "on_key", "on_mouse", "on_focus", "hit_test")],
    ("duop_oop.h", "sizeof(WidgetVtbl)", "WidgetVtbl._size"),
    ("duop_oop.h", "WF_VISIBLE", "WF_VISIBLE"),
    ("duop_oop.h", "WF_FOCUSED", "WF_FOCUSED"),
    ("duop_oop.h", "WF_DIRTY", "WF_DIRTY"),
    ("duop_oop.h", "WF_ENABLED", "WF_ENABLED"),
    ("duop_config.h", "PATH_MAX", "PATH_MAX"),
]
TARGETS = {"x86_64": ["x86_64-linux-gnu"], "aarch64": ["aarch64-linux-gnu", "-mno-outline-atomics"]}


def nm_values(obj: Path, tool: str = "nm") -> dict[str, int]:
    out = {}
    for line in subprocess.run([tool, str(obj)], capture_output=True, text=True, check=True).stdout.splitlines():
        m = re.match(r"([0-9a-fA-F]+)\s+[aAnN]\s+(\S+)$", line)
        if m:
            v = int(m.group(1), 16)
            out[m.group(2)] = v - (1 << 64) if v >= 1 << 63 else v
    return out


def asm_values(tmp: Path) -> dict[str, int]:
    names = sorted({a for _, _, a in LAYOUTS})
    src = tmp / "layout.s"
    src.write_text('.intel_syntax noprefix\n.include "classes.inc"\n.section .text\n' +
                   "".join(f".globl L__{n.replace('.', '_')}\n.set L__{n.replace('.', '_')}, {n}\n" for n in names))
    obj = tmp / "layout_asm.o"
    subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(src), "-o", str(obj)],
                   check=True, capture_output=True)
    vals = nm_values(obj)
    return {n: vals[f"L__{n.replace('.', '_')}"] for n in names}


def c_values(tmp: Path, triple: list[str]) -> dict[str, int]:
    heads = sorted({h for h, _, _ in LAYOUTS})
    body = "".join(f'    __asm__(".globl C__{i}\\n.set C__{i}, %c0" :: "i"((long long)({e})));\n' for i, (_, e, _) in enumerate(LAYOUTS))
    src = tmp / "layout.c"
    src.write_text("".join(f'#include "{h}"\n' for h in heads) + "void probe(void)\n{\n" + body + "}\n")
    obj = tmp / "layout_c.o"
    subprocess.run(["clang", f"--target={triple[0]}", *triple[1:], "-std=gnu2x", "-ffreestanding", "-O1",
                    "-Wno-unused-command-line-argument", "-I", str(ROOT / "include"), "-c", str(src), "-o", str(obj)],
                   check=True, capture_output=True)
    vals = nm_values(obj)
    return {a: vals[f"C__{i}"] for i, (_, _, a) in enumerate(LAYOUTS)}


def main() -> None:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        asm = asm_values(tmp)
        for arch, triple in TARGETS.items():
            cv = c_values(tmp, triple)
            for name, val in cv.items():
                assert asm[name] == val, f"{arch}: {name}: asm={asm[name]} C={val}"
            print(f"[PASS] LY-{arch}: {len(cv)} struct/vtable offsets and sizes identical in C and assembler")
    print("ALL ABI LAYOUT TESTS PASSED.")


if __name__ == "__main__":
    main()
