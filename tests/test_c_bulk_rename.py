#!/usr/bin/env python3
"""U2b.10: src/ui/bulk_rename.c versus frozen x86_64 assembly
(tests/harness/bulk_rename{,_ui}_reference.s): BulkRenameDialog.

BR1 differential (x86_64):
    - BulkRenameDialog_new: OOM on struct & names alloc, only ".." -> NULL, single cursor file,
      4 marked files (with dot, multi-dot, no dot, leading dot ".dotfile")
    - BulkRenameDialog_layout: 80x24 -> 68x20, 50x18 -> 46x14, 30x10 -> 36x12
    - Templates {n}, {name}, {ext}, unknown {x}, Find/Replace + live preview render cell-for-cell
    - Key handling: TAB cycling 0..4, typing/BS in tmpl/find/repl, ignored on focus 3/4,
      ENTER on focus 4 cancels, ESC cancels, ENTER on focus 0..3 applies RENAME_NOREPLACE
      on identical temp directories (preserving colliding files intact!)
BR2 qemu-aarch64: matches x86_64 byte for byte + identical renamed directory tree
BR3 mutation check across src/ui/bulk_rename.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/bulk_rename.c"
REFS = [
    "tests/harness/bulk_rename_reference.s",
    "tests/harness/bulk_rename_ui_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
]

KEY_BACKSPACE = 0x10000B
KEY_TAB = 0x10000C
KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
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
        redefs = [
            "--redefine-sym", "Object_alloc=fake_object_alloc",
            "--redefine-sym", "mem_alloc=fake_mem_alloc",
        ]
        for o in objs:
            subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra += objs
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/bulk_rename_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DBR_SRC="{full}"'])


def seed_fs(d: Path) -> None:
    d.mkdir(parents=True, exist_ok=True)
    (d / "photo_01.jpg").write_text("p1")
    (d / "a.b.txt").write_text("ab")
    (d / "README").write_text("rm")
    (d / ".dotfile").write_text("dot")
    # Pre-existing target for file #2 to verify RENAME_NOREPLACE never clobbers it!
    (d / "2_a.b_Z.txt").write_text("KEEP_ME")


def build_script(workdir: Path) -> str:
    return "\n".join([
        # Only ".." -> returns NULL
        f"S 0 {workdir}",
        "N 80 24 0",
        # Single cursor file + OOM on struct & names
        f"S 1 {workdir}",
        "N 80 24 1",
        "N 80 24 2",
        "N 80 24 0",
        "R",
        # 4 marked files + layout variations + template {n}_{name}{x}.{ext} + find/replace
        f"S 2 {workdir}",
        "N 80 24 2",                 # OOM on marked names array
        "N 80 24 0",
        "L 0 0 50 18",
        "L 0 0 30 10",
        "L 0 0 80 24",
        "T {n}_{name}_X.{ext}!",
        f"K 0x{KEY_BACKSPACE:x} 0",  # trim '!'
        "R",
        f"K 0x{KEY_TAB:x} 0",        # focus=1 (Find)
        "T _X",
        "R",
        f"K 0x{KEY_TAB:x} 0",        # focus=2 (Replace)
        "T _Z",
        "R",
        f"K 0x{KEY_TAB:x} 0",        # focus=3 (OK) -> printable key ignored (rc=0)
        f"K 0x{ord('a'):x} 0",
        f"K 0x{KEY_TAB:x} 0",        # focus=4 (Cancel) -> ENTER cancels!
        f"K 0x{KEY_ENTER:x} 0",
        f"K 0x{KEY_TAB:x} 0",        # wrap focus 4 -> 0
        f"K 0x{KEY_ESC:x} 0",
        # Apply actual renames on workdir (RENAME_NOREPLACE keeps 2_a.b_Z.txt intact!)
        f"K 0x{KEY_ENTER:x} 0",
    ]) + "\n"


def snap_dir(d: Path) -> dict[str, str]:
    return {p.name: p.read_text() for p in sorted(d.iterdir())}


def test_differential(exe: Path, t: Path) -> tuple[str, dict[str, str]]:
    d_ref, d_c = t / "fs_ref", t / "fs_c"
    seed_fs(d_ref)
    seed_fs(d_c)
    r_ref = H.run_impl("x86_64", exe, "ref", stdin=build_script(d_ref).encode())
    r_c = H.run_impl("x86_64", exe, "c", stdin=build_script(d_c).encode())
    assert r_ref.returncode == 0 and r_c.returncode == 0
    out_ref = r_ref.stdout.decode().replace(str(d_ref), "<DIR>")
    out_c = r_c.stdout.decode().replace(str(d_c), "<DIR>")
    assert out_ref == out_c, "ref and c output differ!"
    sn_ref, sn_c = snap_dir(d_ref), snap_dir(d_c)
    assert sn_ref == sn_c, f"fs mismatch: {sn_ref} vs {sn_c}"
    # Verify exact rename + collision preservation (2_a.b_Z.txt untouched, a.b.txt preserved)
    assert sn_c["1_photo_01_Z.jpg"] == "p1"
    assert sn_c["2_a.b_Z.txt"] == "KEEP_ME" and sn_c["a.b.txt"] == "ab"
    assert sn_c["3_README_Z."] == "rm"
    assert sn_c["4__Z.dotfile"] == "dot"
    for needle in ("N ok=0\n", "photo_01.jpg -> 1_photo_01_Z.jpg", "README -> 3_README_Z.",
                   ".dotfile -> 4__Z.dotfile", "call DirModel_reload 1"):
        assert needle in out_c, f"coverage missing: {needle}"
    print(f"[PASS] BR1. bulk_rename matches frozen asm byte for byte & FS ({len(out_c.splitlines())} lines)")
    return out_c, sn_c


def test_mutations(t: Path, base_out: str, base_fs: dict[str, str]) -> None:
    muts = [
        ("oom-obj", "if (!d) return nullptr;", "if (0 && !d) return nullptr;"),
        ("lay-max68", "if (dw > 68) dw = 68;", "if (dw > 60) dw = 60;"),
        ("lay-min36", "if (dw < 36) dw = 36;", "if (dw < 40) dw = 40;"),
        ("lay-max20", "if (dh > 20) dh = 20;", "if (dh > 16) dh = 16;"),
        ("lay-min12", "if (dh < 12) dh = 12;", "if (dh < 14) dh = 14;"),
        ("tok-n1", "u64_to_dec((uint64_t)(idx + 1), num);", "u64_to_dec((uint64_t)idx, num);"),
        ("tok-ext", "if (dot >= 0)", "if (dot > 0)"),
        ("find-repl", "if (d->flen > 0)", "if (0 && d->flen > 0)"),
        ("noreplace", "RENAME_NOREPLACE", "0"),
        ("key-tab5", "d->focus = (d->focus + 1) % 5;", "d->focus = (d->focus + 1) % 4;"),
        ("key-ent4", "if (d->focus == 4) { Dialog_on_cancel(&d->base); return 1; }",
                     "if (d->focus == 9) { Dialog_on_cancel(&d->base); return 1; }"),
        ("key-foc3", "if (d->focus >= 3) return 0;", "if (d->focus >= 5) return 0;"),
        ("key-bs", "if (*len_p > 0) { (*len_p)--; buf[*len_p] = '\\0'; }",
                   "if (*len_p > 99) { (*len_p)--; buf[*len_p] = '\\0'; }"),
        ("fld-foc", "if ((int)d->focus == field_idx)", "if (0 && (int)d->focus == field_idx)"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "bulk_rename.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        md = t / f"md{idx}"
        seed_fs(md)
        r = H.run_impl("x86_64", exe, "c", stdin=build_script(md).encode())
        if r.returncode == 0:
            out = r.stdout.decode().replace(str(md), "<DIR>")
            if out == base_out and snap_dir(md) == base_fs:
                survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] BR3. {len(muts)}/{len(muts)} mutants killed across bulk_rename.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out, fs = test_differential(exe, t)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            d_arm = t / "fs_arm"
            seed_fs(d_arm)
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script(d_arm).encode())
            assert r.returncode == 0
            assert r.stdout.decode().replace(str(d_arm), "<DIR>") == out, "aarch64 output differs"
            assert snap_dir(d_arm) == fs, "aarch64 fs differs"
            print("[PASS] BR2. qemu-aarch64 matches x86_64 byte for byte + FS tree")
        test_mutations(t, out, fs)


if __name__ == "__main__":
    main()
