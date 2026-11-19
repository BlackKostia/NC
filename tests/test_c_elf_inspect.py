#!/usr/bin/env python3
"""U1.4: src/ui/elf_inspect.c versus frozen x86_64 assembly (tests/harness/elf_inspect_reference.s):
elf_preview_try_render with DUOP_TRY_BEGIN hardware-fault recovery on guard pages.

EI1 differential (x86_64):
    - valid ELF64 x86-64 / AArch64 / unknown machine, ET_REL / ET_EXEC / ET_DYN / unknown type
    - sections table: empty-name section skipped, normal sections, 260-byte name clamped to 255,
      missing NUL in shstrtab, widget height clipping, width clipping
    - full-file reload via fs_read_file_alloc (prefix buffer + target_path pointing to complete ELF,
      missing file, non-ELF file, <64B file) with zero memory leak verification
    - malformed ELFs: <64B, bad magic, ELF32, e_shoff=0, e_shnum=0, e_shstrndx>=e_shnum,
      e_shoff wraparound (0xFFFFFFFFFFFFFFF0), e_shoff+shnum*64 > len, shstrtab OOB, sh_name OOB
    - guard-page SIGSEGV caught by DUOP_TRY_BEGIN -> returns 0 cleanly without leaking full_buf
EI2 C NULL-buf safety fix (pv->buf == NULL with buf_len >= 64 returns 0 instead of faulting before TRY)
EI3 qemu-aarch64: matches x86_64 byte for byte (including guard-page SIGSEGV recovery!)
EI4 mutation check across elf_inspect.c
"""

import struct
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/elf_inspect.c"
REF = "tests/harness/elf_inspect_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c", "src/core/try_rt.c",
    "src/fs/file_ops_read.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
]


def build(arch: str, t: Path, src_override: str | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "elf_inspect_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "mem_free=ei_free", str(o)], check=True, capture_output=True)
        extra.append(o)
    full = src_override if src_override else str(ROOT / SRC)
    core_no_for = [c for c in CORE if c != "src/fs/file_ops_read.c"]
    return H.build(arch, t, ["tests/harness/elf_inspect_cli.c", *core_no_for], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"),
                           f'-DEI_SRC="{full}"', f'-DFOR_SRC="{ROOT / "src/fs/file_ops_read.c"}"'])


def make_elf(machine: int = 62, etype: int = 2, entry: int = 0x401000, phnum: int = 3,
             sections: list[bytes] | None = None, *, shstrndx: int | None = None,
             shoff_override: int | None = None, shnum_override: int | None = None,
             raw_shstrtab: bytes | None = None, shstr_off_ov: int | None = None,
             shstr_sz_ov: int | None = None, sh_name_ov: list[int] | None = None) -> bytes:
    secs = sections if sections is not None else [b"", b".text", b".rodata", b".bss"]
    if raw_shstrtab is not None:
        shstr = raw_shstrtab
        offs = sh_name_ov or [0] * len(secs)
    else:
        buf = bytearray()
        offs = []
        for s in secs:
            offs.append(len(buf))
            buf.extend(s + b"\x00")
        shstr = bytes(buf)
        if sh_name_ov:
            offs = sh_name_ov

    shoff = 64 if shoff_override is None else shoff_override
    shnum = len(secs) if shnum_override is None else shnum_override
    sidx = (len(secs) - 1 if len(secs) else 0) if shstrndx is None else shstrndx
    str_off = 64 + len(secs) * 64 if shstr_off_ov is None else shstr_off_ov
    str_sz = len(shstr) if shstr_sz_ov is None else shstr_sz_ov

    ehdr = bytearray(64)
    ehdr[0:5] = b"\x7fELF\x02"
    struct.pack_into("<HHIQQQIHHHHHH", ehdr, 16,
                     etype, machine, 1, entry, 64, shoff, 0, 64, 56, phnum, 64, shnum, sidx)
    shdrs = bytearray()
    for i in range(len(secs)):
        sh = bytearray(64)
        struct.pack_into("<I", sh, 0, offs[i])
        if i == sidx:
            struct.pack_into("<QQ", sh, 24, str_off, str_sz)
        shdrs.extend(sh)
    return bytes(ehdr + shdrs + shstr)


def build_fixtures(d: Path) -> str:
    d.mkdir(parents=True, exist_ok=True)
    files: dict[str, bytes] = {
        "x64_exec.elf": make_elf(62, 2, 0x0000000000401234, 4, [b"", b".text", b".rodata", b".shstrtab"]),
        "a64_dyn.elf": make_elf(183, 3, 0x0000000000001080, 7, [b"", b".init", b".text", b".shstrtab"]),
        "other_rel.elf": make_elf(40, 1, 0, 0, [b"", b".text", b".shstrtab"]),
        "unknown_t.elf": make_elf(99, 4, 0xDEADBEEFCAFEBABE, 1, [b"", b".data", b".shstrtab"]),
        "many_secs.elf": make_elf(62, 2, 0x401000, 2, [b""] + [f".sec{i}".encode() for i in range(12)] + [b".shstrtab"]),
        "long_sec.elf": make_elf(62, 2, 0x401000, 1, [b"", b"A" * 260, b".shstrtab"]),
        "nonul.elf": make_elf(62, 2, 0x401000, 1, [b"X"], shstrndx=0, raw_shstrtab=b"NO_NUL__", sh_name_ov=[0]),
        "short.bin": b"\x7fELF\x02" + b"\x00" * 58,
        "badmagic.bin": b"NOT_ELF!" + b"\x00" * 64,
        "badmagic2.bin": b"BADM\x02" + b"\x00" * 64,
        "elf32.bin": b"\x7fELF\x01" + b"\x00" * 64,
        "shoff0.elf": make_elf(62, 2, 0x401000, 1, [b""], shoff_override=0),
        "shnum0.elf": make_elf(62, 2, 0x401000, 1, [b""], shnum_override=0),
        "bad_sidx.elf": make_elf(62, 2, 0x401000, 1, [b"", b".text"], shstrndx=2),
        "wrap.elf": make_elf(62, 2, 0x401000, 1, [], shoff_override=0xFFFFFFFFFFFFFFF0, shnum_override=4, shstrndx=0),
        "sh_oob.elf": make_elf(62, 2, 0x401000, 1, [b"", b".text"], shnum_override=99),
        "str_off_oob.elf": make_elf(62, 2, 0x401000, 1, [b"", b".text"], shstr_off_ov=99999),
        "str_off_eq.elf": make_elf(62, 2, 0x401000, 1, [b""], shstrndx=0, raw_shstrtab=b"", shstr_off_ov=128, shstr_sz_ov=0),
        "str_sz_oob.elf": make_elf(62, 2, 0x401000, 1, [b"", b".text"], shstr_sz_ov=99999),
        "name_oob.elf": make_elf(62, 2, 0x401000, 1, [b"", b".text", b".shstrtab"], sh_name_ov=[0, 5000, 1]),
    }
    # Large ELF whose section headers live past the 4096-byte preview prefix
    big_pad = bytearray(make_elf(62, 2, 0x402000, 2, [b"", b".text", b".shstrtab"]))
    # Relocate section headers to offset 5000
    shdrs_and_str = big_pad[64:]
    eh = bytearray(big_pad[:64])
    struct.pack_into("<Q", eh, 40, 5000)
    # Fix shstrtab sh_offset inside shdr[2]
    sh_fix = bytearray(shdrs_and_str)
    struct.pack_into("<Q", sh_fix, 2 * 64 + 24, 5000 + 3 * 64)
    files["big_full.elf"] = bytes(eh) + b"\x00" * (5000 - 64) + bytes(sh_fix)
    files["big_prefix.elf"] = files["big_full.elf"][:512]

    paths: dict[str, Path] = {}
    for name, data in files.items():
        p = d / name
        p.write_bytes(data)
        paths[name] = p

    lines: list[str] = []
    # Standard valid & corrupt renders
    for name in ("x64_exec.elf", "a64_dyn.elf", "other_rel.elf", "unknown_t.elf",
                 "long_sec.elf", "nonul.elf", "short.bin", "badmagic.bin", "badmagic2.bin",
                 "elf32.bin", "shoff0.elf", "shnum0.elf", "bad_sidx.elf", "wrap.elf",
                 "sh_oob.elf", "str_off_oob.elf", "str_off_eq.elf", "str_sz_oob.elf", "name_oob.elf"):
        sz = len(files[name])
        lines.append(f"F 1 1 56 12 {sz} {sz} {paths[name]} -")
    # Height-clipped many sections
    sz_m = len(files["many_secs.elf"])
    lines.append(f"F 0 0 40 9 {sz_m} {sz_m} {paths['many_secs.elf']} -")
    # Prefix + full reload from target_path (success, missing, non-ELF, short, ELF32)
    sz_p = len(files["big_prefix.elf"])
    lines.append(f"F 0 0 56 12 {sz_p} {sz_p} {paths['big_prefix.elf']} {paths['big_full.elf']}")
    lines.append(f"F 0 0 56 12 {sz_p} {sz_p} {paths['big_prefix.elf']} {d / 'missing.elf'}")
    lines.append(f"F 0 0 56 12 {sz_p} {sz_p} {paths['big_prefix.elf']} {paths['badmagic.bin']}")
    lines.append(f"F 0 0 56 12 {sz_p} {sz_p} {paths['big_prefix.elf']} {paths['short.bin']}")
    lines.append(f"F 0 0 56 12 {sz_p} {sz_p} {paths['big_prefix.elf']} {paths['elf32.bin']}")
    # Guard-page fault: only 64 bytes mapped before PROT_NONE page, but claim full length (triggers SIGSEGV inside TRY!)
    lines.append(f"F 0 0 56 12 64 {len(files['x64_exec.elf'])} {paths['x64_exec.elf']} -")
    return "\n".join(lines) + "\n"


def test_differential(exe: Path, script: bytes) -> str:
    out = H.diff_impls(exe, stdin=script).decode()
    assert "leak=0" in out and "leak=1" not in out and "leak=-1" not in out, "memory leak detected"
    for needle in ("ELF64 x86-64 ET_EXEC", "ELF64 AArch64 ET_DYN", "ELF64 ET_REL",
                   "Entry: 0x0000000000401234", "Phdrs: 4  Shdrs: 4", "Sections:", ".rodata",
                   "NO_NUL__", "F rc=0 leak=0"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] EI1. elf_preview_try_render matches frozen asm + guard-page SIGSEGV ({len(out.splitlines())} lines)")
    return out


def test_null_buf(exe: Path) -> None:
    r = H.run_impl("x86_64", exe, "c", stdin=b"N 64\nN 0\n")
    assert r.returncode == 0 and r.stdout == b"N rc=0\nN rc=0\n", r
    print("[PASS] EI2. C handles NULL pv->buf cleanly (fixes asm pre-TRY crash)")


def test_mutations(t: Path, script: bytes, baseline: str) -> None:
    muts = [
        ("magic-chk", "load_le32(buf) != ELF_MAGIC_LE", "load_le32(buf) == 0"),
        ("class-chk", "buf[4] != 2", "buf[4] != 1"),
        ("mach-x64", "e_machine == 62", "e_machine == 63"),
        ("mach-a64", "e_machine == 183", "e_machine == 184"),
        ("type-rel", "e_type == 1", "e_type == 9"),
        ("type-exec", "e_type == 2", "e_type == 9"),
        ("type-dyn", "e_type == 3", "e_type == 9"),
        ("shstr-idx", "e_shstrndx >= e_shnum", "e_shstrndx > e_shnum"),
        ("shoff-oob", "e_shoff >= buf_len", "e_shoff == 1"),  # >= vs > is equivalent because e_shnum>=1 => e_shnum*64 > 0
        ("sh-table-oob", "(uint64_t)e_shnum * 64 > buf_len - e_shoff", "(uint64_t)e_shnum * 64 == 0xFFFFFFFFull"),
        ("str-off-oob", "str_off >= buf_len", "str_off > buf_len"),
        ("str-sz-oob", "str_sz > buf_len - str_off", "str_sz == 0xFFFFFFFFull"),
        ("sec-h-clip", "y - pv->base.y >= pv->base.h", "y - pv->base.y > pv->base.h + 10"),
        ("sec-255", "if (max_n > 255) max_n = 255;", "if (max_n > 10) max_n = 10;"),
        ("reload-cond", "e_shoff > *buf_len || sh_bytes > *buf_len - e_shoff", "0 && (e_shoff > *buf_len || sh_bytes > *buf_len - e_shoff)"),
        ("free-full", "if (full_buf) mem_free(full_buf);", "if (0 && full_buf) mem_free(full_buf);"),
    ]
    src_txt = (ROOT / SRC).read_text()
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src_txt and old != new, name
        mp = t / f"m{idx}" / "elf_inspect.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src_txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", str(mp))
        r = H.run_impl("x86_64", exe, "c", stdin=script)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] EI4. {len(muts)}/{len(muts)} mutants killed")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        script = build_fixtures(t / "fx").encode()
        exe = build("x86_64", t / "x86")
        out = test_differential(exe, script)
        test_null_buf(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=script)
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] EI3. qemu-aarch64 matches x86_64 byte for byte (incl. TRY fault recovery)")
        test_mutations(t, script, out)


if __name__ == "__main__":
    main()
