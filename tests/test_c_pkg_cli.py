#!/usr/bin/env python3
"""src/fs/pkg_cli.c versus the frozen assembly (tests/harness/pkg_cli_reference.s): pkg_cli_dispatch, the `duop pkg` command line.

PC1 differential (x86_64): every subcommand with too few / exact / extra words, unknown and empty ones, list and search output
    (no query, matches in any case, none), install from a path, a pinned "--sha256", the registry fallback (found, missing, its
    install failing, not tried with a pinned hash), remove / verify / update / upgrade / vfs-list results and exit codes; the
    package functions are stand-ins that print their calls
PC2 a defect of the asm, fixed: `install <x> <word> <word>` where the first word is not "--sha256" passed a stale register as the
    expected hash (whatever str_cmp left in rdx); the C passes none
PC3 qemu-aarch64: the C module gives the x86_64 results; PC4 mutation check
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/pkg_cli.c"
REF = "tests/harness/pkg_cli_reference.s"
CORE = ["src/core/string.c", "src/core/string_path.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/mem_prims.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        o = t / "pkg_cli_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra = [o]
    return H.build(arch, t, ["tests/harness/pkg_cli_cli.c", *CORE], extra, cflags=["-I", str(ROOT / "tests/harness"), f'-DPKC_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=60)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


SCRIPT = """-
list
list extra words
LIST
search
search alpha
search ALPHA
search zzz
search pk6
update
update fail
upgrade
upgrade fail
install
install ./a.tar.gz
install ./fail.tar.gz
install ./a.tar.gz --sha256 abc
install ./a.tar.gz --sha256 bad
install ./a.tar.gz --sha256
install known
install known --sha256 abc
install unknown
install multi-fail
remove
remove alpha
remove fail
verify alpha
verify fail
vfs-list sftp://x
vfs-list fail://x
frobnicate x
frobnicate
remove alpha extra args here
"""


def test_differential(exe: Path) -> str:
    a, b = run(exe, "ref", SCRIPT), run(exe, "c", SCRIPT)
    assert a == b, "oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(a.splitlines(), b.splitlines()) if x != y)
    for needle in ("Usage: duop pkg", "exit=1", "exit=0", "OK", "Error", "install reg-url sha=reg-sha", "AlphaTool  1.0", "beta-alpha"):
        assert needle in b, f"coverage: {needle}"
    print(f"[PASS] PC1. identical to the asm on {SCRIPT.count(chr(10))} command lines ({len(b.splitlines())} lines of output)")
    return b


def test_stale_sha(exe: Path) -> None:
    s = "install ./a.tar.gz --sha-256 abc\ninstall known not-a-flag x\n"
    c = run(exe, "c", s)
    assert c.count("install argv[3] sha=null") == 2 and "registry_find known" in c, c
    ref = H.run_impl("x86_64", exe, "ref", stdin=s.encode(), timeout=60)
    shown = ref.stdout.decode(errors="replace").splitlines()
    assert ref.returncode == -11 or "install argv[3] sha=null" not in "\n".join(shown[1:3]), (ref.returncode, shown)
    what = "SIGSEGV" if ref.returncode == -11 else shown[2].strip()
    print(f"[PASS] PC2. fixed: extra words that are not \"--sha256\" give no hash (asm: a stale register used as the hash -> {what})")


MUTANTS = [
    ("list cap", "#define PKC_MAX_LIST 64", "#define PKC_MAX_LIST 63"),
    ("row separator", '{a, "  ", b, "  ", c, "  ", d, "\\n"}', '{a, " ", b, "  ", c, "  ", d, "\\n"}'),
    ("search filter", "if (!query || str_contains_ci(e[i].name, query))", "if (!query || str_contains(e[i].name, query))"),
    ("search query", "argc >= 4 ? argv[3] : nullptr", "argc >= 5 ? argv[3] : nullptr"),
    ("fallback with pin", "if (sha || pkg_registry_find", "if (pkg_registry_find"),
    ("fallback hash", "return pkg_install_archive(envp, reg.url, reg.sha256);", "return pkg_install_archive(envp, reg.url, nullptr);"),
    ("sha flag", 'argc >= 6 && !str_cmp(argv[4], "--sha256")', 'argc >= 7 && !str_cmp(argv[4], "--sha256")'),
    ("list exit", "    mem_free(e);\n    return 0;\n}\n\nstatic int pkc_do_search", "    mem_free(e);\n    return 1;\n}\n\nstatic int pkc_do_search"),
    ("word count", "else if (argc < 4) goto usage;", "else if (argc < 3) goto usage;"),
    ("vfs error", "        r = -1;\n    } else goto usage;", "        return 1;\n    } else goto usage;"),
    ("ok text", 'r ? "Error\\n" : "OK\\n"', 'r ? "Error\\n" : "Ok\\n"'),
    ("exit code", "return r ? 1 : 0;", "return r ? -1 : 0;"),
]


def test_mutants(t: Path, expect: str) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "pkg_cli.c").write_text(src.replace(old, new, 1))
            try:
                noticed[name] = run(build("x86_64", mt, str(mt / "pkg_cli.c")), "c", SCRIPT) != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] PC4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe)
        test_stale_sha(exe)
        if H.available("aarch64"):
            assert run(build("aarch64", t / "a64"), "c", SCRIPT, "aarch64") == expect, "qemu-aarch64 differs"
            print("[PASS] PC3. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] PC3: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C PKG CLI TESTS PASSED.")


if __name__ == "__main__":
    main()
