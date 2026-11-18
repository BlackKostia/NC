#!/usr/bin/env python3
"""src/fs/pkg_registry.c versus the frozen assembly (tests/harness/pkg_registry_reference.s): pkg_registry_update / list / find /
upgrade and pkg_semver_cmp.

PR1 differential (x86_64): registries copied from a local file (tabs, CRLF, comments, empty lines, missing fields, fields beyond
    their caps, nameless lines, 70 entries, a file above 64 KiB) or fetched (http / https; a failing download; no
    DUOP_PKG_REGISTRY); listing with max 0 / 1 / 64 / 80 (slots after the last entry untouched); finding present, absent,
    nameless and beyond-the-64th names; upgrades of older / equal / newer / unknown packages and a failing install; version
    comparisons ("v" prefixes, missing parts, non-digits, 32-bit wrap-around)
PR2 qemu-aarch64: the C module gives the x86_64 results; PR3 mutation check
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/pkg_registry.c"
REF = "tests/harness/pkg_registry_reference.s"
CORE = ["src/core/string.c", "src/core/string_path.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c",
        "src/core/mem_prims.c", "src/core/config.c", "src/fs/file_ops_delete.c", "src/fs/file_ops.c", "src/fs/file_ops_copy.c",
        "src/fs/file_ops_read.c", "src/fs/file_ops_overwrite.c", "src/fs/task.c", "src/fs/task_conflict.c", "build/i18n_en.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        o = t / "pkg_registry_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra = [o]
    stub = t / "stubs.c"
    stub.write_text('#include "duop_task.h"\n#include "duop_tui.h"\nconst LangStrings *i18n_get(void) { return &lang_en_table; }\n'
                    'int g_task_parent_pid; TaskShared *g_task_shm;\n')
    return H.build(arch, t, ["tests/harness/pkg_registry_cli.c", str(stub), *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DPKR_SRC="{path}"'])


def line(*fields: str) -> str:
    return "\t".join(fields) + "\n"


def registry_text(n_extra: int = 0) -> str:
    s = "# Duop registry\n\n"
    s += line("alpha", "1.2.3", "theme", "a" * 64, "https://good/alpha.tar", "Alpha theme")
    s += line("beta", "v2.0", "plugin", "b" * 64, "http://x/fail/beta.tar", "Beta").replace("\n", "\r\n")
    s += line("gamma", "0.9.10", "lang", "c" * 64, "https://good/gamma.tar")
    s += line("delta")
    s += line("", "9.9.9", "nameless")
    s += line("n" * 100, "1" * 40, "k" * 30, "s" * 100, "u" * 300, "d" * 200)
    s += "epsilon\t1.0.0\t\t\t\t\textra\tfields\n"
    s += line("zeta", "10.0.0", "theme", "d" * 64, "https://good/zeta.tar", "Zeta " + "é" * 10)
    for i in range(n_extra):
        s += line(f"pkg{i:03d}", f"{i}.0.0", "plugin", "e" * 64, f"https://good/p{i}.tar", "x" * (i % 50))
    return s


def tree(root: Path, n_extra: int, big: bool = False) -> Path:
    root.mkdir(parents=True)
    text = registry_text(n_extra)
    if big:
        text += "# " + "z" * 70000 + "\n" + line("late", "1.0.0")
    (root / "local.tsv").write_text(text)
    (root / "remote.tsv").write_text(registry_text(2))
    (root / "installed.txt").write_text("alpha 1.2.2\nbeta 1.9.0\ngamma 0.10.0\nzeta 9.99.99\nunknown 1.0\npkg001 0.9\nepsilon 1.0.0\n")
    return root


SEMVER = [("1.2.3", "1.2.3"), ("1.2.3", "1.2.4"), ("1.10.0", "1.9.9"), ("v1.0", "1.0.0"), ("V2", "v2.0.1"), ("1", "1.0.0"), ("", "0"),
          ("1.2.3-beta", "1.2.3"), ("1..2", "1.0.2"), ("4294967296.0.0", "0.0.0"), ("2147483648", "1"), ("1.2.v3", "1.2.3"), ("x", "y"),
          ("01.002.0003", "1.2.3"), ("1.2.3.4", "1.2.3.5"), ("V3", "v2.9")]


def script() -> str:
    s = "U\n" + "".join(f"L {m}\n" for m in (0, 1, 3, 64, 80))
    s += "".join(f"F {n}\n" for n in ("alpha", "beta", "delta", "none", "", "pkg060", "pkg061", "pkg070", "n" * 63, "epsilon"))
    s += "G\n" + "".join(f"S {a or '%'} {b or '%'}\n".replace("%", "") for a, b in SEMVER)
    return s


SCENARIOS = {  # tag: (DUOP_PKG_REGISTRY or None, extra entries, big file)
    "local": ("{root}/local.tsv", 70, False),
    "big": ("{root}/local.tsv", 0, True),
    "https": ("https://good/registry.tsv", 0, False),
    "http": ("http://good.example/r.tsv", 0, False),
    "fetch_fails": ("https://broken/r.tsv", 0, False),
    "missing_file": ("{root}/nope.tsv", 0, False),
    "unset": (None, 0, False),
}


def run(exe: Path, impl: str, root: Path, reg: str | None, arch: str = "x86_64") -> str:
    env = {"PATH": "/usr/bin:/bin", "PKG_ROOT": str(root)}
    if reg is not None:
        env["DUOP_PKG_REGISTRY"] = reg.format(root=root)
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), impl], input=script().encode(), capture_output=True, env=env, timeout=30)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace").replace(str(root), "@@")


def outputs(exe: Path, t: Path, impl: str, arch: str = "x86_64") -> dict[str, str]:
    out = {}
    for tag, (reg, extra, big) in SCENARIOS.items():
        out[tag] = run(exe, impl, tree(t / f"{tag}_{impl[0]}_{arch[:3]}", extra, big), reg, arch)
    return out


def test_differential(exe: Path, t: Path) -> dict[str, str]:
    a, b = outputs(exe, t, "ref"), outputs(exe, t, "c")
    for tag in SCENARIOS:
        assert a[tag] == b[tag], f"{tag}: oracle and C differ:\n" + "\n".join(f"  ref {x}\n  c   {y}" for x, y in zip(a[tag].splitlines(), b[tag].splitlines()) if x != y)
    text = "".join(b.values())
    assert "U r=0" in b["local"] and "U r=-1" in b["unset"] and "U r=-1" in b["fetch_fails"] and "  install " in b["local"], "coverage"
    print(f"[PASS] PR1. registry identical to the asm in {sum(v.count(chr(10)) for v in b.values())} lines over {len(SCENARIOS)} scenarios "
          "(local / fetched / failing sources, malformed lines, caps, 64-entry find window, upgrades, semver)")
    return b


MUTANTS = [
    ("field cap", "if (*p != '\\r' && n < cap - 1) dst[n++] = *p;", "if (*p != '\\r' && n < cap) dst[n++] = *p;"),
    ("CR kept", "if (*p != '\\r' && n < cap - 1)", "if (n < cap - 1)"),
    ("comment parsed", "if (eol != p && *p != '#') {", "if (eol != p) {"),
    ("nameless counted", "if (out[n].name[0]) n++;", "n++;"),
    ("max ignored", "while (p < end && n < max) {", "while (p < end) {"),
    ("file cap", "#define PKR_FILE_CAP 65536", "#define PKR_FILE_CAP 65535"),
    ("find window", "#define PKR_FIND_MAX 64", "#define PKR_FIND_MAX 80"),
    ("upgrade window", "#define PKR_UPGRADE_MAX 32", "#define PKR_UPGRADE_MAX 3"),
    ("upgrade equal", "if (pkg_semver_cmp(inst[i].version, reg.version) >= 0) continue;", "if (pkg_semver_cmp(inst[i].version, reg.version) > 0) continue;"),
    ("install failure ignored", "if (pkg_install_archive(envp, reg.url, reg.sha256) != 0) r = -1;", "(void)pkg_install_archive(envp, reg.url, reg.sha256);"),
    ("https only", 'if (str_starts_with(src, "http://") || str_starts_with(src, "https://"))', 'if (str_starts_with(src, "https://"))'),
    ("v prefix", "if (*p == 'v' || *p == 'V') p++;", "if (*p == 'v') p++;"),
    ("dot kept", "    if (*p == '.') p++;\n", ""),
    ("parts", "for (int i = 0; i < 3; i++) {", "for (int i = 0; i < 2; i++) {"),
    ("unsigned compare", "if (x != y) return x < y ? -1 : 1;", "if (x != y) return (uint32_t)x < (uint32_t)y ? -1 : 1;"),
]


def test_mutants(t: Path, expect: dict[str, str]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i:02d}"
            mt.mkdir()
            (mt / "pkg_registry.c").write_text(src.replace(old, new, 1))
            try:
                noticed[name] = outputs(build("x86_64", mt / "b", str(mt / "pkg_registry.c")), mt, "c") != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError, OSError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] PR3. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe, t / "d00")
        if H.available("aarch64"):
            assert outputs(build("aarch64", t / "a64"), t / "d99", "c", "aarch64") == expect, "qemu-aarch64 differs"
            print("[PASS] PR2. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] PR2: aarch64 toolchain/qemu not installed")
        test_mutants(t, expect)
    print("ALL C PKG REGISTRY TESTS PASSED.")


if __name__ == "__main__":
    main()
