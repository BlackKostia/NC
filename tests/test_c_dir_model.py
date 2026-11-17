#!/usr/bin/env python3
"""src/fs/dir_model.c versus the frozen assembly (tests/harness/dir_model_reference.s): the DirModel class (vtable, DirModel_new /
dtor, DirModel_init_env, alloc_initial_arrays, invalidate_stats / reset_entry_stats, close_stream_resources, entry_name).

DC1 differential (x86_64): environment overrides (valid, zero, garbage, prefixes, repeats, NULL envp); DirModel_new with a path,
    NULL (the cwd) and a path of PATH_MAX bytes - defaults, caps, the reload it triggers, the vtable; the dtor frees everything
    (live blocks back to 0, the streaming fd closed, git context released); stat resets with and without ".."; closing stream
    resources twice; entry_name with NULL arguments
DC2 a defect of the asm, fixed: DirModel_new freed the arrays but leaked the 4.4 KiB object itself when an array allocation failed
DC3 qemu-aarch64: the C module gives the x86_64 results; DC4 mutation check
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/dir_model.c"
REF = "tests/harness/dir_model_reference.s"
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        o = t / "dir_model_ref.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "mem_alloc=dmc_alloc", "--redefine-sym", "mem_free=dmc_free", str(o)], check=True)
        extra = [o]
    return H.build(arch, t, ["tests/harness/dir_model_cli.c", *CORE], extra, cflags=["-I", str(ROOT / "tests/harness"), f'-DDMC_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64", cwd: Path | None = None) -> str:
    cmd = [*H.ARCHS[arch]["run"], str(exe), impl]
    res = subprocess.run(cmd, input=script.encode(), capture_output=True, env={"PATH": "/usr/bin:/bin"}, cwd=cwd, timeout=120)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def script(t: Path) -> str:
    envs = ["-", "", "DUOP_HUGE_THRESHOLD=10", "DUOP_STREAM_BATCH=7 DUOP_HUGE_THRESHOLD=123456789",
            "DUOP_HUGE_THRESHOLD=0 DUOP_STREAM_BATCH=x9", "DUOP_HUGE_THRESHOLD=12ab DUOP_STREAM_BATCH=99999999999999999999",
            "DUOP_HUGE_THRESHOLD DUOP_HUGE_THRESHOLD= XDUOP_STREAM_BATCH=5 DUOP_STREAM_BATCHES=8", "A=1 DUOP_STREAM_BATCH=3 DUOP_STREAM_BATCH=4"]
    s = "".join(f"V {e}\n" for e in envs)
    long = "/" + "x" * 5000
    s += f"N {t}\nN -\nN {long}\nN /\n"
    s += "".join(f"N {t} {k}\n" for k in range(1, 6))                    # each allocation fails once
    s += "".join(f"I {n} {d}\n" for n in (0, 1, 2, 7, 40) for d in (0, 1))
    s += "".join(f"C {a} {b}\n" for a in (0, 1) for b in (0, 1)) + "E\nT\n"
    return s


def test_differential(exe: Path, t: Path, s: str) -> str:
    a, b = run(exe, "ref", s, cwd=t), run(exe, "c", s, cwd=t)
    la, lb = a.splitlines(), b.splitlines()
    oom = [i for i, ln in enumerate(lb) if ln.startswith("N m=0")]
    for i, (x, y) in enumerate(zip(la, lb)):
        if i in oom:
            continue                                                     # DC2: the asm leaks the object there
        assert x == y, f"oracle and C differ:\n  ref {x}\n  c   {y}"
    assert len(la) == len(lb) and oom, (len(la), len(lb), oom)
    news = [ln for ln in lb if ln.startswith("N m=1")]
    assert all(ln.endswith("freed: live=0 git=1") for ln in news), news
    assert f"path={t} reloads=1 {t}" in b, "N - takes the working directory"
    print(f"[PASS] DC1. DirModel class identical to the asm in {len(lb)} commands (env overrides, new with path / cwd / PATH_MAX, "
          "reload, dtor frees all and closes the fd, stat resets, stream close, entry_name, vtable)")
    return b


def test_leak(exe: Path, t: Path) -> None:
    s = "".join(f"N {t} {k}\n" for k in (2, 3, 4))
    ref, c = run(exe, "ref", s, cwd=t).splitlines(), run(exe, "c", s, cwd=t).splitlines()
    assert ref == ["N m=0 live=1"] * 3 and c == ["N m=0 live=0"] * 3, (ref, c)
    print("[PASS] DC2. fixed: a failed array allocation in DirModel_new no longer leaks the object (asm: one block per failure)")


MUTANTS = [
    ("huge default", "g_huge_threshold = HUGE_DIR_THRESHOLD;", "g_huge_threshold = HUGE_DIR_THRESHOLD + 1;"),
    ("zero override accepted", "if ((v = dm_parse_u64(*envp + 20))) g_huge_threshold = v;", "v = dm_parse_u64(*envp + 20); g_huge_threshold = v;"),
    ("batch prefix length", "dm_parse_u64(*envp + 18)", "dm_parse_u64(*envp + 17)"),
    ("digit range", "(uint8_t)(*s - '0') <= 9", "(uint8_t)(*s - '0') < 9"),
    ("file cap", "#define INITIAL_FILE_CAP 512", "#define INITIAL_FILE_CAP 511"),
    ("object leak back", "Object_free(&m->base);", "DirModel_dtor(m);"),
    ("hidden default", "m->show_hidden = 1;", "m->show_hidden = 0;"),
    ("cwd fallback", '(void)str_copy(m->path, "/", PATH_MAX);', '(void)str_copy(m->path, ".", PATH_MAX);'),
    ("reload skipped", "(void)DirModel_reload(m);", ""),
    ("invalidate clears selection", "m->entries[i].flags &= ~(uint32_t)FE_STAT_READY;", "m->entries[i].flags &= ~(uint32_t)(FE_STAT_READY | FE_SELECTED);"),
    ("reset keeps dotdot", "for (uint64_t i = (uint32_t)m->has_dotdot; i < m->raw_count; i++) m->entries[i].flags &= ~(uint32_t)(FE_STAT_READY | FE_SELECTED);",
     "for (uint64_t i = 0; i < m->raw_count; i++) m->entries[i].flags &= ~(uint32_t)(FE_STAT_READY | FE_SELECTED);"),
    ("fd not reset", "        m->load_dirfd = -1;\n", ""),
    ("pos kept", "    m->load_pos = 0;\n", ""),
    ("git ctx kept", "    git_free_ctx(m);\n", ""),
    ("vtable size", '"DirModel", DIRMODEL_SIZE', '"DirModel", sizeof(DirModel)'),
]


def test_mutants(t: Path, s: str, expect: str) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "dir_model.c").write_text(src.replace(old, new, 1))
            try:
                noticed[name] = run(build("x86_64", mt, str(mt / "dir_model.c")), "c", s, cwd=t) != expect
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] DC4. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d).resolve()
        (t / "cwd").mkdir()
        s = script(t / "cwd")
        exe = build("x86_64", t / "x86")
        expect = test_differential(exe, t / "cwd", s)
        test_leak(exe, t / "cwd")
        if H.available("aarch64"):
            got = run(build("aarch64", t / "a64"), "c", s, "aarch64", cwd=t / "cwd")
            assert got == expect, "qemu-aarch64 differs from x86_64"
            print("[PASS] DC3. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] DC3: aarch64 toolchain/qemu not installed")
        test_mutants(t, s, expect)
    print("ALL C DIR MODEL TESTS PASSED.")


if __name__ == "__main__":
    main()
