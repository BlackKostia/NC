#!/usr/bin/env python3
"""tests/c_harness.py shared utilities: version_dir, build_with_refs (renamed oracle next to the C module), snapshot (never reads a
FIFO), mutcheck (reports surviving mutants) and diff_impls (one implementation per process, identical output required)."""

import os
import tempfile
from pathlib import Path

import c_harness as H

SCRIPT_C = r'''
#include "script_cli.h"
extern int ref_twice(int);
int twice(int);
int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    bool ref = argc > 1 && !str_cmp(argv[1], "ref");
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        uint64_t v;
        sc_hex(line, &v);
        sc_num(ref ? ref_twice((int)v) : twice((int)v));
        sc_put(" ");
        sc_esc(line);
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
'''
REF_S = ".intel_syntax noprefix\n.text\n.global twice\ntwice:\n    lea eax, [rdi + rdi]\n    ret\n"
CORE = ["src/core/string.c", "src/core/string_path.c", "src/core/mem_prims.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/memory.c", "src/core/utf8.c"]
IMPL_C = "int twice(int v) { return v * 2; }\n"


def test_build_and_diff(t: Path) -> None:
    (t / "ref_twice.s").write_text(REF_S)
    (t / "cli.c").write_text(SCRIPT_C)
    (t / "impl.c").write_text(IMPL_C)
    (t / "bad.c").write_text("int twice(int v) { return v * 2 + (v == 255); }\n")
    harness = ["-I", str(H.ROOT / "tests/harness")]
    (t / "v").mkdir()
    ver = H.version_dir(t / "v")
    assert ".macro DUOP_VER_ASCII\n" in (ver / "version.inc").read_text() and ".macro DUOP_VER_ASCIZ\n" in (ver / "version.inc").read_text() and "DUOP_VERSION" in (ver / "version.h").read_text()
    (t / "ok").mkdir()
    exe = H.build_with_refs("x86_64", t / "ok", [str(t / "cli.c"), str(t / "impl.c"), *CORE], [str(t / "ref_twice.s")], cflags=harness)
    assert H.diff_impls(exe, stdin=b"1\nff\n20\n") == b"2 1\n510 ff\n64 20\n"
    (t / "bad").mkdir()
    exe = H.build_with_refs("x86_64", t / "bad", [str(t / "cli.c"), str(t / "bad.c"), *CORE], [str(t / "ref_twice.s")], cflags=harness)
    try:
        H.diff_impls(exe, stdin=b"1\nff\n")
    except AssertionError as exc:
        assert "differ" in str(exc), exc
    else:
        raise AssertionError("diff_impls missed a differing implementation")
    print("[PASS] HU1. build_with_refs renames the oracle; diff_impls runs one implementation per process and flags a difference")


def test_snapshot(t: Path) -> None:
    root = t / "tree"
    (root / "d").mkdir(parents=True)
    (root / "d" / "f").write_bytes(b"data /tmp/x")
    os.symlink("d/f", root / "ln")
    os.mkfifo(root / "pipe")
    snap = H.snapshot(root, scrub=lambda b: b.replace(b"/tmp/x", b"@"))
    kinds = {rel: kind for rel, kind, *_ in snap}
    assert kinds == {"d": "d", "d/f": "f", "ln": "l", "pipe": "s"}, kinds
    assert dict((r, rest[-1]) for r, _, *rest in snap)["d/f"] == b"data @"
    (root / "d" / "f").write_bytes(b"data2")
    assert H.snapshot(root) != snap
    print("[PASS] HU2. snapshot records files, links and dirs, scrubs content, and never opens a FIFO")


def test_mutcheck(t: Path) -> None:
    src = t / "m.c"
    src.write_text("int f(int a) { return a + 1; }\n")
    seen = []
    survivors = H.mutcheck(src, [("a+2", "a + 1", "a + 2"), ("noop-equivalent", "int f", "int  f")],
                           lambda p, i: seen.append(p.read_text()) or "a + 2" in p.read_text(), t)
    assert survivors == ["noop-equivalent"] and len(seen) == 2
    for bad in ([("gone", "zzz", "y")], [("same", "a", "a")]):
        try:
            H.mutcheck(src, bad, lambda p, i: True, t)
        except AssertionError:
            continue
        raise AssertionError(f"mutcheck accepted {bad}")
    print("[PASS] HU3. mutcheck reports survivors and rejects vanished anchors and no-op mutations")


def main() -> None:
    with tempfile.TemporaryDirectory() as d:
        t = Path(d)
        test_build_and_diff(t)
        test_snapshot(t)
        test_mutcheck(t)
    print("ALL C HARNESS UTILITY TESTS PASSED.")


if __name__ == "__main__":
    main()
