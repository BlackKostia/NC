#!/usr/bin/env python3
"""U1.2: src/ui/file_pane_layout.c versus frozen x86_64 assembly
(tests/harness/file_pane_layout_reference.s + file_pane_cols_reference.s):
FilePane_layout and file_pane_compute_cols column geometry.

FL1 differential (x86_64): tabular sweep across widths -5..1000 (every boundary 1/2/3/27/28/39/40/53/54)
    and varied (x, y, h) coordinates, checking Widget rect, hdr_zone_count, HitZone x1/x2/y/id, and
    FilePane_ensure_visible invocation
FL2 qemu-aarch64: matches x86_64 byte for byte
FL3 mutation check across file_pane_layout.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/file_pane_layout.c"
REFS = [
    "tests/harness/file_pane_layout_reference.s",
    "tests/harness/file_pane_cols_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c",
]


def build(arch: str, t: Path, src_override: str | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        objs = []
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run(["as", *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            objs.append(o)
        H.rename_defined_globals(objs, "ref_")
        extra += objs
    full = src_override if src_override else str(ROOT / SRC)
    return H.build(arch, t, ["tests/harness/file_pane_layout_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DFPL_SRC="{full}"'])


def build_script() -> str:
    lines: list[str] = []
    for w in (-5, -1, 0, 1, 2, 3, 4, 7, 8, 9, 26, 27, 28, 29, 38, 39, 40, 41, 52, 53, 54, 55, 80, 120, 250, 1000):
        lines.append(f"L 0 0 {w} 24")
    for x, y, w, h in ((1, 2, 20, 10), (40, 1, 28, 30), (41, 3, 40, 25), (80, 5, 54, 40), (12, 7, 90, 50)):
        lines.append(f"L {x} {y} {w} {h}")
    return "\n".join(lines) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in (
        "cnt=1 [1..2@1 id=0]",
        "cnt=2 [1..18@1 id=0] [18..27@1 id=1]",
        "cnt=3 [1..19@1 id=0] [19..28@1 id=1] [28..39@1 id=3]",
        "cnt=3 [1..27@1 id=0] [27..36@1 id=1] [36..53@1 id=2]",
        "call ensure_visible eq=1",
    ):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] FL1. FilePane_layout matches frozen asm across {len(build_script().splitlines())} layouts")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("inner-clamp", "w > 3 ? w - 2 : 1", "w > 4 ? w - 2 : 1"),
        ("w54-thresh", "w >= 54", "w > 54"),
        ("w40-thresh", "w >= 40", "w > 40"),
        ("w28-thresh", "w >= 28", "w > 28"),
        ("date-w", "extra_w = 17;", "extra_w = 16;"),
        ("perm-w", "extra_w = 11;", "extra_w = 10;"),
        ("size-w", "size_w = 9;", "size_w = 8;"),
        ("col-start", "fp->base.x + 1", "fp->base.x"),
        ("row-start", "fp->base.y + 1", "fp->base.y"),
        ("extra-id", "c.extra_is_date ? SORT_MTIME : SORT_EXT", "c.extra_is_date ? SORT_EXT : SORT_MTIME"),
        ("ensure-vis", "FilePane_ensure_visible(fp);", "(void)fp;"),
    ]
    src_txt = (ROOT / SRC).read_text()
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src_txt and old != new, name
        mp = t / f"m{idx}" / "file_pane_layout.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src_txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", str(mp))
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] FL3. {len(muts)}/{len(muts)} mutants killed")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] FL2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
