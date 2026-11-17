#!/usr/bin/env python3
"""M1, the headless build: src/app/cli_args.c + license.c + main_headless.c (`make headless`, any ARCH) versus the assembly entry point
(src/main.s, the product binary ./duop): --help / --version / --license / --lang output byte for byte, the argument grammar against an
independent Python model of main.s, the LICENSE file, ELF shape (static, no INTERP/.dynamic, .data == 0) and qemu-aarch64 for the
aarch64 binary. Mutation checks of cli_args.c run through the freestanding harness."""

import random
import re
import subprocess
import sys
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
sys.path.insert(0, str(ROOT / "tools"))
LANGS = {"DUOP_LANGS": str(ROOT / "lang")}
UK = {**LANGS, "LC_ALL": "uk_UA.UTF-8"}
INFO = [([], ["--version"], {}), ([], ["-V"], {}), ([], ["-v"], {}), ([], ["--help"], {}), ([], ["-h"], {}), ([], ["-L"], {}),
        ([], ["--license"], {}), ([], ["--lang", "uk", "-V"], LANGS), ([], ["--lang=uk", "--help"], LANGS), ([], ["-l", "UA", "-h"], LANGS),
        ([], ["--lang", "xx", "--version"], LANGS), ([], ["-V", "--lang"], LANGS), ([], ["-V", "-h"], LANGS), ([], ["-L", "-V"], LANGS),
        ([], ["-L", "-h", "-V"], UK), ([], ["--version"], UK), ([], ["--help"], UK), ([], ["--lang", "en", "-V"], UK), ([], ["--lang=", "-V"], UK),
        ([], ["/tmp", "-V", "/usr", "/etc"], LANGS), ([], ["--choosedir=/tmp/x", "-V"], LANGS), ([], ["--choosedir", "/tmp/x", "-h"], LANGS),
        ([], ["--bogus", "-V"], LANGS), ([], ["-V"], {"LANG": "uk_UA.UTF-8", **LANGS}), ([], ["-V"], {"LC_MESSAGES": "ua", **LANGS}),
        ([], ["-V"], {"LC_ALL": "", "LANG": "uk", **LANGS}), ([], ["-L"], UK)]
TOKENS = ["-h", "--help", "-v", "-V", "--version", "-L", "--license", "--lang", "-l", "--lang=uk", "--lang=xx", "--lang=", "--choosedir",
          "--choosedir=/c", "--choosedir=", "pkg", "/tmp", "a", "b", "uk", "UA", "xx", "en", "ukr", "-x", "--", "-lang"]
LANGIDX = {"uk": 1, "UA": 1, "xx": 0, "en": 0, "ukr": 0, "": 0}
CLI_C = ["tests/harness/cli_parse_cli.c", "src/app/cli_args.c", "src/app/license.c", "src/tui/i18n_env.c", "src/tui/i18n_pack.c",
         "src/tui/i18n_keys.c", "src/tui/data_dirs.c", "src/core/config.c", "src/core/config_parse.c", "src/core/config_load.c",
         "src/core/string.c", "src/core/string_path.c", "src/core/mem_prims.c", "src/core/syscall.c", "src/core/try_rt.c",
         "src/core/memory.c", "src/core/utf8.c"]


def make(arch: str) -> Path:
    args = ["make", "-j8", "headless"] + ([f"ARCH={arch}"] if arch != "x86_64" else [])
    subprocess.run(args, cwd=ROOT, check=True, capture_output=True)
    return ROOT / ("build" if arch == "x86_64" else f"build_{arch}") / "duop_headless"


def run(binary: Path, arch: str, args: list[str], env: dict[str, str]) -> subprocess.CompletedProcess:
    return subprocess.run([*H.ARCHS[arch]["run"], str(binary), *args], capture_output=True, env={"PATH": "/usr/bin:/bin", **env}, timeout=30)


def test_matches_asm(binary: Path, arch: str) -> None:
    asm = ROOT / "duop"
    for _, args, env in INFO:
        want, got = run(asm, "x86_64", args, env), run(binary, arch, args, env)
        assert (want.returncode, want.stdout) == (got.returncode, got.stdout), f"{arch} {args} {env}: asm rc={want.returncode} {want.stdout[:60]!r} / headless rc={got.returncode} {got.stdout[:60]!r}"
        assert got.returncode == 0 and got.stdout, (args, got)
    print(f"[PASS] HL1. {arch}: {len(INFO)} --help/--version/--license/--lang invocations print exactly what the assembly entry point prints")


def test_no_ui(binary: Path, arch: str) -> None:
    for args in ([], ["/tmp"], ["--lang", "uk"], ["pkg", "list"]):
        res = run(binary, arch, args, LANGS)
        assert res.returncode == 2 and res.stdout == b"" and b"headless build" in res.stderr, (args, res)
    print(f"[PASS] HL2. {arch}: a request for the UI or the pkg sub-command exits 2 with a message on stderr and nothing on stdout")


def test_elf(binary: Path, arch: str) -> None:
    hdr = subprocess.run(["readelf", "-hlSdW", str(binary)], capture_output=True, text=True, check=True).stdout
    want = {"x86_64": "Advanced Micro Devices X86-64", "aarch64": "AArch64"}[arch]
    assert re.search(r"Machine:\s+" + re.escape(want), hdr), hdr[:400]
    assert "Class:                             ELF64" in hdr and "Type:                              EXEC" in hdr
    assert "INTERP" not in hdr and "There is no dynamic section" in hdr, "static executable: no PT_INTERP, no .dynamic"
    data = re.search(r"\]\s+\.data\s+PROGBITS\s+\S+\s+\S+\s+([0-9a-f]+)", hdr)
    assert data is None or int(data.group(1), 16) == 0, "ELF .data must be empty"
    print(f"[PASS] HL3. {arch}: static ELF64 {want}, no INTERP/.dynamic, .data == 0")


def test_license() -> None:
    from_c = subprocess.run([str(ROOT / "build/duop_headless"), "-L"], capture_output=True, timeout=30).stdout
    assert from_c == (ROOT / "LICENSE").read_bytes(), "duop --license must equal the LICENSE file"
    print("[PASS] HL4. --license is byte-identical to the LICENSE file")


def model(args: list[str]) -> str:
    st = dict(lang=-1, help=0, version=0, license=0, pkg=int(bool(args) and args[0] == "pkg"), choosedir="(null)", left="(null)", right="(null)")
    i = 0
    while i < len(args):
        a, nxt = args[i], args[i + 1] if i + 1 < len(args) else None
        if a in ("-h", "--help"): st["help"] = 1
        elif a in ("-v", "-V", "--version"): st["version"] = 1
        elif a in ("-L", "--license"): st["license"] = 1
        elif a in ("--lang", "-l"):
            if nxt is not None:
                st["lang"] = LANGIDX.get(nxt, 0)
                i += 1
        elif a.startswith("--lang="): st["lang"] = LANGIDX.get(a[7:], 0)
        elif a == "--choosedir":
            if nxt is not None:
                st["choosedir"] = nxt
                i += 1
        elif a.startswith("--choosedir="): st["choosedir"] = a[12:]
        elif st["left"] == "(null)": st["left"] = a
        elif st["right"] == "(null)": st["right"] = a
        i += 1
    f = lambda v: v if v else "-"
    return (f"lang={st['lang']} {'help' if st['help'] else '-'} {'version' if st['version'] else '-'} {'license' if st['license'] else '-'} "
            f"{'pkg ' if st['pkg'] else '- '}choosedir={st['choosedir']} left={st['left']} right={st['right']} ")


def script(rng: random.Random, n: int) -> tuple[list[list[str]], str]:
    cases = [[rng.choice(TOKENS) for _ in range(rng.randrange(0, 7))] for _ in range(n)]
    return cases, "".join("P " + " ".join(c) + "\n" for c in cases)


def build_harness(t: Path, cli_args_c: str = "src/app/cli_args.c") -> Path:
    gen = t / "gen"
    gen.mkdir(exist_ok=True)
    subprocess.run([sys.executable, str(ROOT / "tools/gen_i18n.py"), "--out", str(gen / "i18n_en.c"), "--out-slots", str(gen / "i18n_slots.h")], check=True)
    ver = H.version_dir(t)
    srcs = [cli_args_c if c == "src/app/cli_args.c" else c for c in CLI_C] + [str(gen / "i18n_en.c")]
    return H.build("x86_64", t, srcs, cflags=["-I", str(gen), "-I", str(ver), "-I", str(ROOT / "tests/harness")])


def harness(exe: Path, stdin: str, env: dict[str, str]) -> str:
    res = H.run_impl("x86_64", exe, "c", stdin=stdin.encode(), env=env)
    assert res.returncode == 0, res.stderr[-300:]
    return res.stdout.decode()


def test_parse_model(exe: Path) -> None:
    rng = random.Random(311)
    cases, text = script(rng, 4000)
    got = harness(exe, text, LANGS).splitlines()
    assert len(got) == len(cases)
    for case, line in zip(cases, got):
        assert line.rstrip() == model(case).rstrip(), f"{case}: {line!r} != {model(case)!r}"
    assert {m for c in cases for m in ("pkg", "choosedir=/c") if m in model(c)} == {"pkg", "choosedir=/c"}
    print(f"[PASS] HL5. cli_parse equals the Python model of src/main.s's argument loop on {len(cases)} random command lines")


def info_text(exe: Path, args: list[str], env: dict[str, str]) -> str:
    return harness(exe, "I " + " ".join(args) + "\n", env)


def test_mutations(t: Path, exe: Path) -> None:
    src = ROOT / "src/app/cli_args.c"
    base_cases = script(random.Random(5), 600)[1]
    info = [(args, env) for _, args, env in INFO if "--lang" not in args or env]
    golden = (harness(exe, base_cases, LANGS), [info_text(exe, a, e) for a, e in info])
    mutants = [("-v dropped", '"-v", "-V", "--version"', '"-x", "-V", "--version"'),
               ("--lang= offset", "arg + 7", "arg + 6"), ("--choosedir= offset", "arg + 12", "arg + 11"),
               ("missing --lang value taken", "        if (!next) return 0;\n        out->lang", "        out->lang"),
               ("help/version swapped", "args->help ? lang->s[LS_cli_usage] : lang->s[LS_cli_version]", "args->version ? lang->s[LS_cli_version] : lang->s[LS_cli_usage]"),
               ("unknown language keeps -1", "return idx < 0 ? 0 : idx;", "return idx;"),
               ("pkg needs argc >= 1", "argc >= 2 &&", "argc >= 1 &&"),
               ("second positional lost", "else if (!out->right) out->right = arg;", "else if (out->right) out->right = arg;"),
               ("-l dropped", 'cli_is(arg, "--lang", "-l", nullptr)', 'cli_is(arg, "--lang", "-x", nullptr)'),
               ("explicit English ignored", "args->lang >= 0 ? args->lang", "args->lang > 0 ? args->lang"),
               ("license on help", "if (!args->help && !args->version && !args->license) return false;", "if (!args->help && !args->version) return false;")]

    def detected(path: Path, i: int) -> bool:
        (t / f"m{i}").mkdir()
        mexe = build_harness(t / f"m{i}", str(path))
        try:
            return (harness(mexe, base_cases, LANGS), [info_text(mexe, a, e) for a, e in info]) != golden
        except AssertionError:                                          # the mutant crashed: that is noticed too
            return True

    survivors = H.mutcheck(src, mutants, detected, t)
    assert not survivors, f"mutants survived: {survivors}"
    print(f"[PASS] HL6. {len(mutants)}/{len(mutants)} mutations of cli_args.c are caught")


def main() -> None:
    subprocess.run(["make", "-j8"], cwd=ROOT, check=True, capture_output=True)
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] HL-{arch}: toolchain/qemu unavailable")
            continue
        binary = make(arch)
        test_matches_asm(binary, arch)
        test_no_ui(binary, arch)
        test_elf(binary, arch)
    test_license()
    with H.workdir() as d:
        t = Path(d)
        exe = build_harness(t)
        test_parse_model(exe)
        test_mutations(t, exe)
    print("ALL HEADLESS TESTS PASSED.")


if __name__ == "__main__":
    main()
