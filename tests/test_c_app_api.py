#!/usr/bin/env python3
"""include/duop_app.h is the single door from src/ui and src/fs into the application controller (docs/HYBRID_PORTABILITY_PLAN.md, E6):
every App_* entry point the UI/fs sources call is declared there, every declaration has a definition in src/app, the signatures agree
with the `# void App_x(...)` comments of the assembly, and the header compiles for x86_64 and aarch64."""

import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "include/duop_app.h"
DECL = re.compile(r"^void (App_\w+)\(([^)]*)\);", re.M)
CALLERS = [*ROOT.glob("src/ui/*.s"), *ROOT.glob("src/ui/*.c"), *ROOT.glob("src/fs/*.s"), *ROOT.glob("src/fs/*.c"),
           *ROOT.glob("src/tui/*.c"), *ROOT.glob("src/core/*.c")]
ASM_REF = re.compile(r"\b(?:call|j[a-z]+|lea\s+\w+,\s*\[rip\s*\+|offset|adrp\s+\w+,|bl|b|\.quad)\s+(App_\w+)")
C_REF = re.compile(r"\b(App_\w+)\s*\(")


def declared() -> dict[str, list[str]]:
    out = {}
    for name, params in DECL.findall(HEADER.read_text()):
        out[name] = [p.strip() for p in params.split(",")]
    return out


def types(params: list[str]) -> list[str]:
    """parameter list -> list of types (names dropped, `App *this` == `App *app`)."""
    res = []
    for p in params:
        p = re.sub(r"\s+", " ", p.strip())
        res.append(re.sub(r"\s*\b[a-z_][a-z_0-9]*$", "", p).replace(" *", "*") if " " in p.replace("*", "* ") else p)
    return res


def used() -> dict[str, list[str]]:
    """App_* symbols referenced by the UI/fs/tui/core sources and not defined by them (pkg_dialog.s owns App_cmd_packages)."""
    own = {m for f in CALLERS if f.suffix == ".s" for m in re.findall(r"^(App_\w+):", f.read_text(encoding="utf-8", errors="replace"), re.M)}
    seen: dict[str, list[str]] = {}
    for f in CALLERS:
        text = f.read_text(encoding="utf-8", errors="replace")
        for m in (ASM_REF if f.suffix == ".s" else C_REF).finditer(text):
            seen.setdefault(m.group(1), []).append(f.relative_to(ROOT).as_posix())
    return {k: v for k, v in seen.items() if k not in own}


def test_every_used_symbol_is_declared() -> None:
    decl, use = declared(), used()
    assert len(decl) >= 20, decl
    missing = {k: v[:2] for k, v in use.items() if k not in decl}
    assert not missing, f"App_* called from ui/fs/tui/core but missing in include/duop_app.h: {missing}"
    print(f"[PASS] AA1. all {len(use)} App_* symbols used outside src/app are declared in duop_app.h")


def test_declared_symbols_are_defined() -> None:
    labels = set()
    for f in [*ROOT.glob("src/app/*.s"), *ROOT.glob("src/app/*.c")]:
        labels |= set(re.findall(r"^(App_\w+):" if f.suffix == ".s" else r"^\w[\w \*]*\b(App_\w+)\(", f.read_text(), re.M))
    gone = sorted(set(declared()) - labels)
    assert not gone, f"declared but not defined in src/app: {gone}"
    print(f"[PASS] AA2. all {len(declared())} declarations have a definition in src/app")


def test_signatures_match_asm_comments() -> None:
    comments = {}
    for f in ROOT.glob("src/app/*.s"):
        for name, params in re.findall(r"^#\s*void (App_\w+)\(([^)]*)\)", f.read_text(), re.M):
            comments[name] = [p.strip() for p in params.split(",")]
    checked = 0
    for name, params in declared().items():
        if name in comments:
            assert types(comments[name]) == types(params), (name, comments[name], params)
            checked += 1
    assert checked >= 8, checked
    print(f"[PASS] AA3. {checked} signatures equal the `# void App_x(...)` comments of the assembly")


def test_header_compiles() -> None:
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / "t.c"
        src.write_text('#include "duop_app.h"\nvoid probe(App *a){ App_cmd_quit(a); App_set_status(a, "x", 0); }\n')
        subprocess.run(["gcc", "-std=gnu2x", "-ffreestanding", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "include"), "-fsyntax-only", str(src)], check=True)
        subprocess.run(["clang", "--target=aarch64-linux-gnu", "-std=gnu2x", "-ffreestanding", "-Wall", "-Wextra", "-Werror", "-I", str(ROOT / "include"),
                        "-fsyntax-only", str(src)], check=True)
    print("[PASS] AA4. duop_app.h compiles warning-free for x86_64 and aarch64")


def test_detects_drift() -> None:
    text = HEADER.read_text()
    assert "void App_cmd_quit(App *app);" in text
    for old, new, what in (("void App_cmd_quit(App *app);\n", "", "removed declaration"),
                           ("void App_close_dialog(App *app, int result);", "void App_close_dialog(App *app);", "changed signature")):
        mutated = text.replace(old, new)
        assert mutated != text
        decl = {n: [p.strip() for p in ps.split(",")] for n, ps in DECL.findall(mutated)}
        if what == "removed declaration":
            assert "App_cmd_quit" not in decl and "App_cmd_quit" in used(), "UI still calls it: AA1 would fail"
        else:
            assert types(decl["App_close_dialog"]) != types(["App *this", "int result"]), "AA3 would fail"
    print("[PASS] AA5. a removed declaration or a changed signature is detected")


def main() -> None:
    test_every_used_symbol_is_declared()
    test_declared_symbols_are_defined()
    test_signatures_match_asm_comments()
    test_header_compiles()
    test_detects_drift()
    print("ALL APP API TESTS PASSED.")


if __name__ == "__main__":
    main()
