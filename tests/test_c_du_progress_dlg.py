#!/usr/bin/env python3
"""U2b.12: src/ui/du_progress_dlg.c versus frozen x86_64 assembly
(tests/harness/du_progress_dlg_reference.s): DuProgressDialog_vtbl,
DuProgressDialog_new, DuProgressDialog_layout, DuProgressDialog_render.

DPD1 differential (x86_64):
    - DuProgressDialog_new: title, instanceof Dialog, centred layout
    - DuProgressDialog_layout: wide (90x28 -> 64x9), mid (54x20 -> 50x9), narrow (36x15 -> 40x9)
    - DuProgressDialog_render: total=0 (empty bar), partial (3/10), full (10/10), overflow (12/10 -> 0),
      dirs/files/bytes formatting, Esc hint, theme loaded via app->theme even when theme arg is NULL
DPD2 OOM check (DuProgressDialog_new returns NULL cleanly)
DPD3 qemu-aarch64 matches x86_64 byte for byte + OOM
DPD4 mutation check across src/ui/du_progress_dlg.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/du_progress_dlg.c"
REF = "tests/harness/du_progress_dlg_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
]


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "du_progress_dlg_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "Object_alloc=fake_object_alloc", str(o)],
                       check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/du_progress_dlg_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DDPD_SRC="{full}"'])


def build_script() -> str:
    # P done total dirs files bytes
    return "\n".join([
        "N 90 28",
        "P 0 0 0 0 0",
        "R",
        "P 3 10 42 1234 52428800",
        "R",
        "P 10 10 100 5000 1073741824",
        "R",
        "P 12 10 5 10 1024",
        "R",
        "L 0 0 54 20",
        "R",
        "L 0 0 36 15",
        "R",
    ]) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("N ok=1 is_d=1", "3 / 10", "10 / 10", "42 ", "1234 ", "rect=-2,3,40,9"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] DPD1. du_progress_dlg matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_oom(exe: Path, arch: str) -> None:
    r = H.run_impl(arch, exe, "oom")
    assert r.returncode == 0 and "OOM ok=1" in r.stdout.decode(), r.stdout.decode()


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("lay-max64", "if (dw > DPD_W_MAX) dw = DPD_W_MAX;", "if (dw > 58) dw = 58;"),
        ("lay-min40", "if (dw < DPD_W_MIN) dw = DPD_W_MIN;", "if (dw < 46) dw = 46;"),
        ("lay-h9", "self->h = DPD_H;", "self->h = 8;"),
        ("lay-x", "self->x = (w - dw) >> 1;", "self->x = 0;"),
        ("lay-y", "self->y = (h - DPD_H) >> 1;", "self->y = h - DPD_H;"),
        ("bar-ovf", "if (q <= (uint32_t)bar_w) filled = q;",
         "filled = q <= (uint32_t)bar_w ? q : (uint32_t)bar_w;"),
        ("bar-rem", "bar_w - (int)filled", "bar_w"),
        ("row-fld", "dpd_text_at(d, scr, line, 2);", "dpd_text_at(d, scr, line, 1);"),
        ("row-scn", "dpd_text_at(d, scr, line, 4);", "dpd_text_at(d, scr, line, 5);"),
        ("row-hnt", "dpd_text_at(d, scr, ls->s[LS_du_scan_hint], 6);",
         "dpd_text_at(d, scr, ls->s[LS_du_scan_hint], 5);"),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "du_progress_dlg.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] DPD4. {len(muts)}/{len(muts)} mutants killed across du_progress_dlg.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        test_oom(exe, "x86_64")
        print("[PASS] DPD2. OOM in DuProgressDialog_new returns NULL cleanly")
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            test_oom(exe_arm, "aarch64")
            print("[PASS] DPD3. qemu-aarch64 matches x86_64 byte for byte + OOM check")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
