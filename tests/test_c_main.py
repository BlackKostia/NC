#!/usr/bin/env python3
"""A3.5: src/app/main.c (+ pal_start.s + cli_args.c + license.c) versus frozen src/main.s.

MN1 differential (x86_64):
    - --help / -h, --version / -v / -V, --license / -L, --lang / -l / --lang=, env LANG
    - pkg subcommand forwarding (argc, argv, envp, return code)
    - TUI path: stdin EOF early exit (rc=0, no raw mode)
    - TUI path: App_new OOM (term_exit_raw called, rc=1)
    - TUI path: normal run with positional left/right, --lang, --choosedir / --choosedir=,
      Object_free, term_exit_raw, rc=0
MN2 qemu-aarch64 matches x86_64 byte for byte
MN3 MEMCHECK=1 build invokes mc_init + mc_report on every exit path
MN4 mutation check (14 mutants across main.c)
"""

import subprocess
import tempfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/app/main.c"
REF = "tests/harness/main_reference.s"
CORE = ["src/core/string.c", "src/core/string_format.c", "src/core/mem_prims.c"]

CASES = [
    (["-h"], {}),
    (["--help", "--lang", "uk"], {}),
    (["-V"], {"LANG": "uk_UA.UTF-8"}),
    (["--version", "--lang=en"], {"LANG": "uk_UA.UTF-8"}),
    (["-L"], {}),
    (["--license"], {}),
    (["pkg", "list"], {"DUOP_TEST_PKG_RC": "0"}),
    (["pkg", "verify", "foo"], {"DUOP_TEST_PKG_RC": "7"}),
    ([], {"DUOP_TEST_EOF": "1"}),
    (["/left", "/right"], {"DUOP_TEST_OOM": "1"}),
    (["/left", "/right", "--lang", "uk", "--choosedir=/tmp/cd"], {}),
    (["--choosedir", "/tmp/out", "-l", "xx", "/only"], {}),
]


def build_ref(t: Path) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), "-I", str(ROOT / "build")]
    ref_o = t / "main_ref.o"
    subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(ref_o)], check=True, capture_output=True)
    stubs_o = t / "stubs.o"
    cc = H.ARCHS["x86_64"]["cc"]
    cflags = ["-std=gnu2x", "-Os", "-ffreestanding", "-fno-pic", "-fno-pie", "-fcf-protection=none",
              "-fno-stack-protector", "-fno-asynchronous-unwind-tables", "-fno-unwind-tables",
              "-fno-ident", "-funsigned-char", "-fno-strict-aliasing", "-fno-common",
              "-ffunction-sections", "-Wall", "-Wextra", "-Werror", "-fno-stack-clash-protection",
              "-I", str(ROOT / "include"), "-I", str(ROOT / "build")]
    objs = [ref_o]
    for idx, src in enumerate(["tests/harness/main_stubs.c", *CORE]):
        o = t / f"r{idx}.o"
        subprocess.run([*cc, *cflags, "-c", str(ROOT / src), "-o", str(o)], check=True, capture_output=True)
        objs.append(o)
    for pal in ("pal_sys_fd.s", "pal_sys_proc.s", "pal_simd.s"):
        po = t / f"pal_{pal}.o"
        subprocess.run(["as", *inc, str(ROOT / f"src/os/linux/x86_64/{pal}"), "-o", str(po)],
                       check=True, capture_output=True)
        objs.append(po)
    exe = t / "ref_prog"
    subprocess.run(["ld", "-z", "noexecstack", "--gc-sections", *[str(o) for o in objs], "-o", str(exe)],
                   check=True, capture_output=True)
    return exe


def build_c(arch: str, t: Path, src_ovr: Path | None = None, memcheck: bool = False) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    extra_flags = ["-I", str(ROOT / "build")]
    if memcheck:
        extra_flags.append("-DMEMCHECK=1")
    main_src = str(src_ovr) if src_ovr else SRC
    return H.build(arch, t, [main_src, "src/app/cli_args.c", "src/app/license.c",
                             "tests/harness/main_stubs.c", *CORE],
                   cflags=extra_flags)


def run_case(arch: str, exe: Path, argv: list[str], env: dict[str, str]) -> tuple[int, bytes]:
    r = subprocess.run([*H.ARCHS[arch]["run"], str(exe), *argv],
                       capture_output=True, env={"PATH": "/usr/bin:/bin", **env}, timeout=15)
    return r.returncode, r.stdout


def run_all(arch: str, exe: Path) -> list[tuple[int, bytes]]:
    return [run_case(arch, exe, argv, env) for argv, env in CASES]


def test_differential(t: Path) -> tuple[list[tuple[int, bytes]], Path]:
    ref_exe = build_ref(t / "ref")
    c_exe = build_c("x86_64", t / "c_x86")
    want = run_all("x86_64", ref_exe)
    got = run_all("x86_64", c_exe)
    for (argv, env), w, g in zip(CASES, want, got):
        assert w == g, f"diff on {argv} {env}:\n  ref={w!r}\n  c  ={g!r}"
    print(f"[PASS] MN1. main.c matches frozen main.s byte for byte across {len(CASES)} cases")
    return got, c_exe


def test_memcheck(t: Path) -> None:
    mc_exe = build_c("x86_64", t / "c_mc", memcheck=True)
    for argv, env in (["-V"], {}), (["pkg", "list"], {"DUOP_TEST_PKG_RC": "3"}), (
            [], {"DUOP_TEST_EOF": "1"}), (["/a"], {"DUOP_TEST_OOM": "1"}), (["/a", "/b"], {}):
        rc, out = run_case("x86_64", mc_exe, argv, env)
        txt = out.decode()
        assert txt.startswith("mc_init env=1\n"), f"missing mc_init for {argv}: {txt!r}"
        assert txt.endswith("mc_report\n"), f"missing mc_report for {argv}: {txt!r}"
        if argv == ["pkg", "list"]:
            assert rc == 3
        elif env.get("DUOP_TEST_OOM"):
            assert rc == 1
        else:
            assert rc == 0
    print("[PASS] MN3. MEMCHECK=1 calls mc_init and mc_report on every exit path")


def test_mutations(t: Path, baseline: list[tuple[int, bytes]]) -> None:
    src = (ROOT / SRC).read_text()
    muts = [
        ("envp", "g_envp = envp;", ""),
        ("i18n", "i18n_load(envp);", ""),
        ("pkg", "if (args.pkg) rc = pkg_cli_dispatch(argc, argv, envp);", "if (0) rc = pkg_cli_dispatch(argc, argv, envp);"),
        ("info", "else if (!cli_print_info(&args, envp))", "else if (1)"),
        ("eof", "if (input_probe_eof()) return 0;", ""),
        ("sig", "signals_install();", ""),
        ("raw-in", "(void)term_enter_raw();", ""),
        ("oom-rc", "return 1;", "return 0;"),
        ("oom-raw", "term_exit_raw();\n        return 1;", "return 1;"),
        ("run", "App_run(app);", ""),
        ("cdir", "App_write_choosedir(app, choosedir);", "(void)choosedir;"),
        ("free", "Object_free((Object *)app);", ""),
        ("raw-out", "Object_free((Object *)app);\n    term_exit_raw();", "Object_free((Object *)app);"),
        ("mc", "mc_report();", ""),
    ]
    killed = 0
    for name, old, new in muts:
        assert old in src, f"mutant {name} needle not found"
        mp = t / f"mut_{name}.c"
        mp.write_text(src.replace(old, new, 1))
        if name == "mc":
            me = build_c("x86_64", t / f"m_{name}", src_ovr=mp, memcheck=True)
            _, out = run_case("x86_64", me, ["-V"], {})
            assert not out.decode().endswith("mc_report\n"), "mutant mc survived!"
        else:
            me = build_c("x86_64", t / f"m_{name}", src_ovr=mp)
            assert run_all("x86_64", me) != baseline, f"mutant {name} survived!"
        killed += 1
    print(f"[PASS] MN4. {killed}/{len(muts)} mutants killed across main.c")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_c_main_") as td:
        t = Path(td)
        base, _ = test_differential(t)
        a64 = build_c("aarch64", t / "c_a64")
        got_a64 = run_all("aarch64", a64)
        assert got_a64 == base, "aarch64 output differs from x86_64"
        print("[PASS] MN2. qemu-aarch64 matches x86_64 byte for byte")
        test_memcheck(t)
        test_mutations(t, base)
    print("ALL MAIN C23 TESTS PASSED.")


if __name__ == "__main__":
    main()
