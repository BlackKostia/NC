#!/usr/bin/env python3
"""U2b.4: src/ui/info_dialog.c versus frozen x86_64 assembly
(tests/harness/info_dialog_reference.s): InfoDialog.

ID1 differential (x86_64):
    - InfoDialog_new: OOM, regular file (CRC32 + SHA-256), directory (hash_ok=0 -> "(dir/n/a)"),
      missing path (hash_ok=0), NULL app (fallback 80x24)
    - InfoDialog_layout: wide (90x24 -> dw=76), medium (64x24 -> dw=60), narrow (40x24 -> dw=44)
    - InfoDialog_render: Path/Size/Inode/Links/Owner/CRC32/SHA256 (and "(dir/n/a)" for dir)
    - InfoDialog_on_key: ESC, ENTER, 'q' all invoke Dialog_on_cancel; other keys ignored
ID2 real asm bug fix proven in C vs frozen asm:
    - InfoDialog_layout in asm tail-jumped to dlg_layout_right_buttons with rsi=x, rdx=y
      (zero-width Close button). C passes LS_dlg_btn_close -> clickable Close button that
      triggers on_confirm (= Dialog_on_cancel -> DLG_CANCEL=2)!
ID3 qemu-aarch64: matches x86_64 byte for byte (diff + fix)
ID4 mutation check across src/ui/info_dialog.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/info_dialog.c"
REF = "tests/harness/info_dialog_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c", "src/core/utf8.c",
    "src/core/memory.c", "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/core/hash.c", "src/core/hash_file.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
]

KEY_ENTER = 0x10000E
KEY_ESC = 0x10000F


def build(arch: str, t: Path, src_override: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "info_dialog_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "Object_alloc=fake_object_alloc", str(o)],
                       check=True, capture_output=True)
        extra.append(o)
    full = str(src_override if src_override else (ROOT / SRC))
    return H.build(arch, t, ["tests/harness/info_dialog_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DINF_SRC="{full}"'])


def build_diff_script(sample: Path, subdir: Path, missing: Path) -> str:
    return "\n".join([
        f"N 0 80 24 1 {sample}",           # OOM
        f"N 1 80 24 0 {missing}",          # NULL app + missing path
        f"N 0 80 24 0 {subdir}",           # directory -> hash_ok=0, (dir/n/a)
        "R",
        f"N 0 80 24 0 {sample}",           # regular file -> CRC32 + SHA256
        "R",
        "L 0 0 90 24",                     # dw=76
        "L 0 0 64 24",                     # dw=60
        "L 0 0 40 24",                     # dw=44
        "L 0 0 80 24",
        f"K 0x{ord('x'):x} 0",             # ignored
        f"K 0x{KEY_ESC:x} 0",              # cancel
        f"K 0x{KEY_ENTER:x} 0",            # cancel
        f"K 0x{ord('q'):x} 0",             # cancel
    ]) + "\n"


def build_fix_script(sample: Path) -> str:
    # 80x24 -> dw=76, h=13, x=2, y=5 -> rx=76, by=16; " Close "(7) at [69..76@16]
    return "\n".join([
        f"N 0 80 24 0 {sample}",
        "R",
        "M 1 0 72 16",                     # click Close button -> DLG_CANCEL (2)
    ]) + "\n"


def test_differential(exe: Path, sample: Path, subdir: Path, missing: Path) -> tuple[str, str]:
    s = build_diff_script(sample, subdir, missing).encode()
    out = H.diff_impls(exe, stdin=s).decode()
    # "hello duop\n" CRC32 = 0x5c36c040? verify actual sha256/crc via presence of hex + (dir/n/a)
    for needle in ("N ok=0\n", "hok=0", "hok=1", "(dir/n/a)", "Path:   ", "Size:   ",
                   "Inode:  ", "Links:  ", "Owner:  ", "CRC32:  ", "SHA256: ",
                   "K res=0", "K res=2", "call App_close_dialog 1 2"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] ID1. info_dialog matches frozen asm byte for byte ({len(out.splitlines())} lines)")

    fs = build_fix_script(sample).encode()
    c_fix = H.run_impl("x86_64", exe, "fix_c", stdin=fs)
    ref_fix = H.run_impl("x86_64", exe, "fix_ref", stdin=fs)
    assert c_fix.returncode == 0 and ref_fix.returncode == 0
    co, ro = c_fix.stdout.decode(), ref_fix.stdout.decode()
    assert "bc=1 [76..76@16]" in ro, f"expected asm Bug (zero-width Close):\n{ro}"
    assert "bc=1 [69..76@16]" in co, f"expected C Close button [69..76@16]:\n{co}"
    assert "call App_close_dialog 1 2" in co and "call App_close_dialog" not in ro
    assert " Close " in co
    print("[PASS] ID2. C fixes asm dlg_layout_right_buttons defect (Close button clickable)")
    return out, co


def test_mutations(t: Path, sample: Path, subdir: Path, missing: Path, base_diff: str, base_fix: str) -> None:
    ds = build_diff_script(sample, subdir, missing).encode()
    fs = build_fix_script(sample).encode()
    muts = [
        ("oom-null", "if (!raw) return nullptr;", "if (0 && !raw) return nullptr;", "c", ds, base_diff),
        ("s-ifreg", "(st.mode & S_IFMT) == S_IFREG", "0", "c", ds, base_diff),
        ("hash-ok", "d->hash_ok = 1;", "d->hash_ok = 0;", "c", ds, base_diff),
        ("lay-max76", "if (dw > 76) dw = 76;", "if (dw > 70) dw = 70;", "c", ds, base_diff),
        ("lay-min44", "if (dw < 44) dw = 44;", "if (dw < 50) dw = 50;", "c", ds, base_diff),
        ("lay-h13", "self->h = 13;", "self->h = 12;", "c", ds, base_diff),
        ("lay-btn", "dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_close], nullptr);",
                    "dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], nullptr);", "fix_c", fs, base_fix),
        ("hex-shift", "v >>= 4;", "v >>= 3;", "c", ds, base_diff),
        ("kv-valx", "d->base.base.x + 11", "d->base.base.x + 12", "c", ds, base_diff),
        ("key-esc", "lat == KEY_ESC || lat == KEY_ENTER || lat == 'q'",
                    "lat == KEY_ENTER || lat == 'q'", "c", ds, base_diff),
        ("key-ent", "lat == KEY_ESC || lat == KEY_ENTER || lat == 'q'",
                    "lat == KEY_ESC || lat == 'q'", "c", ds, base_diff),
        ("key-q", "lat == KEY_ESC || lat == KEY_ENTER || lat == 'q'",
                  "lat == KEY_ESC || lat == KEY_ENTER", "c", ds, base_diff),
    ]
    survivors: list[str] = []
    txt = (ROOT / SRC).read_text()

    def check(idx: int, name: str, old: str, new: str, mode: str, inp: bytes, base: str) -> None:
        assert old in txt and old != new, name
        mp = t / f"m{idx}" / "info_dialog.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, mode, stdin=inp)
        if r.returncode == 0 and r.stdout.decode() == base:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] ID4. {len(muts)}/{len(muts)} mutants killed across info_dialog.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        sample = t / "hello.txt"
        sample.write_text("hello duop\n")
        subdir = t / "sub"
        subdir.mkdir()
        missing = t / "missing"

        exe = build("x86_64", t / "x86")
        out, fix_out = test_differential(exe, sample, subdir, missing)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r1 = H.run_impl("aarch64", exe_arm, "c", stdin=build_diff_script(sample, subdir, missing).encode())
            r2 = H.run_impl("aarch64", exe_arm, "fix_c", stdin=build_fix_script(sample).encode())
            assert r1.returncode == 0 and r1.stdout.decode() == out, "aarch64 diff mismatch"
            assert r2.returncode == 0 and r2.stdout.decode() == fix_out, "aarch64 fix mismatch"
            print("[PASS] ID3. qemu-aarch64 matches x86_64 byte for byte (diff + fix)")
        test_mutations(t, sample, subdir, missing, out, fix_out)


if __name__ == "__main__":
    main()
