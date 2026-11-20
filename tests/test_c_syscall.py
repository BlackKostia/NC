#!/usr/bin/env python3
"""src/core/syscall.c (retrying I/O, env lookup, foreground/background exec, double-fork opener, signal flags) on
x86_64 and aarch64 (qemu-user) through a freestanding harness."""

import re
import subprocess
from pathlib import Path

import c_harness as H

NAMES = ["env_home", "env_prefix_miss", "env_empty", "env_null", "argv_status", "argv_missing", "sh_arg_status",
         "sh_arg_args", "bg_status", "open_external_nodisplay", "open_external_display", "sigwinch", "sigterm", "big_write"]
CORE = ["src/core/syscall.c", "src/core/try_rt.c", "src/core/string.c", "src/core/mem_prims.c"]


def run(arch: str) -> dict[str, int]:
    with H.workdir() as tmp:
        exe = H.build(arch, Path(tmp), ["tests/harness/syscall_cli.c", *CORE])
        res = H.run(arch, exe, [], b"", timeout=60)
        assert res.returncode == 0, (arch, res.returncode, res.stderr[-400:])
        text = res.stdout.decode("latin-1")
        # the harness writes lines, escape sequences from term_enter/exit_raw, and finally 300000 payload bytes
        # term_exit/enter_raw escape sequences are glued in front of some lines, so match the known names only
        vals = {k: int(v) for k, v in re.findall(r"(" + "|".join(NAMES) + r")=(-?\d+)\n", text)}
        assert "\x1b[?1049l" in text and "\x1b[?1049h" in text, f"{arch}: raw-mode escape sequences missing"
        assert "LEAK" not in text and "LEAK" not in res.stderr.decode("latin-1"), f"{arch}: background child leaked stdio"
        head, _, rest = text.partition("fault_slot_installed=1\n")
        payload = rest[: -len("big_write=300000\n")]
        want = "".join(chr(ord("a") + i % 26) for i in range(300000))
        assert payload == want, f"{arch}: 300000-byte write_all payload corrupted/short ({len(payload)} bytes)"
        return vals


def test_envp_owned_by_core() -> None:
    """g_envp (read by git_status / preview_helper in src/fs) is defined in src/core, not in the entry point: no fs -> main edge."""
    def symbols(obj: str) -> dict[str, str]:
        out = subprocess.run(["nm", str(H.ROOT / "build" / obj)], capture_output=True, text=True, check=True).stdout
        return {ln.split()[-1]: ln.split()[-2] for ln in out.splitlines() if len(ln.split()) >= 2}
    assert symbols("core/syscall.o").get("g_envp") == "B", "g_envp must be a .bss symbol of src/core/syscall.c"
    assert symbols("app/main.o").get("g_envp") == "U", "main.c only fills g_envp in"
    for obj in ("fs/git_status.o", "fs/preview_helper.o"):
        assert symbols(obj).get("g_envp") == "U", obj
    print("[PASS] Y-envp. g_envp is owned by src/core/syscall.c; main.s and the fs helpers only reference it")


def main() -> None:
    expect = {"env_home": 1, "env_prefix_miss": 1, "env_empty": 1, "env_null": 1,
              "sh_arg_args": 0, "bg_status": 4 << 8, "open_external_nodisplay": -1, "open_external_display": 0,
              "sigwinch": 1, "sigterm": 1, "big_write": 300000}
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] Y-{arch}: toolchain/qemu unavailable")
            continue
        got = run(arch)
        for k, v in expect.items():
            assert got.get(k) == v, f"{arch}: {k}={got.get(k)} expected {v}"
        assert got["argv_status"] == 5 << 8 and got["sh_arg_status"] == 3 << 8, got
        assert got["argv_missing"] == 127 << 8, f"{arch}: exec failure must surface as exit 127, got {got['argv_missing']}"
        print(f"[PASS] Y-{arch}: exec/wait statuses, env lookup, double-fork opener, signal flags, 300 KB write_all")
    test_envp_owned_by_core()
    print("ALL C SYSCALL TESTS PASSED.")


if __name__ == "__main__":
    main()
