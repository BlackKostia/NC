#!/usr/bin/env python3
"""U3.6: src/ui/preview_pane{,_render}.c versus frozen x86_64 assembly
(tests/harness/preview_pane{,_render}_reference.s): PreviewPane_vtbl, PreviewPane_new,
dtor, load, read_sync, accept, render, pv_copy_line_strip_ansi.

PP1 differential (x86_64):
    - PreviewPane_new & dtor: instanceof Widget/PreviewPane
    - PreviewPane_load: NULL entry/path -> 0, directory -> is_dir=1 / rc=0, file -> pending=1 / rc=1
    - PreviewPane_read_sync & accept: text file (ANSI CSI stripped, tabs -> 2 spaces, CR dropped,
      line numbers, scrolling), binary file (NUL -> is_binary=1, hex rows 8 bytes/row + partial row),
      empty file (pv_empty), thumb_len >= IMG_THUMB_HDR increments thumb_gen
    - PreviewPane_render: tiny geometry (<10 or <6) no-op, box/title/metadata/divider,
      dir preview, pending state, empty file, mode dispatch 0 (image/ELF), 1 (hex), 2 (text)
    - pv_copy_line_strip_ansi: CSI sequences, non-CSI ESC, tabs, CR, LF termination
PP2 OOM check (Object_alloc OOM and PV_BUF_TOTAL mem_alloc OOM both return NULL cleanly)
PP3 qemu-aarch64 matches x86_64 byte for byte + OOM
PP4 mutation check across preview_pane.c and preview_pane_render.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = {
    "PP_SRC": "src/ui/preview_pane.c",
    "PPR_SRC": "src/ui/preview_pane_render.c",
}
REFS = [
    "tests/harness/preview_pane_reference.s",
    "tests/harness/preview_pane_render_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/fs/file_ops_delete.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/preview_pane_mouse.c",
    "src/ui/preview_mode.c",
]


def build(arch: str, t: Path, overrides: dict[str, str] | None = None) -> Path:
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
            "--redefine-sym", "mem_alloc=fake_mem_alloc",
            "--redefine-sym", "Object_alloc=fake_object_alloc",
            "--redefine-sym", "pv_make_thumb=fake_pv_make_thumb",
            "--redefine-sym", "pv_mode_dispatch=fake_pv_mode_dispatch",
        ]
        for o in objs:
            subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra += objs
    defs = []
    for k, rel in SRCS.items():
        p = overrides[k] if (overrides and k in overrides) else str(ROOT / rel)
        defs.append(f'-D{k}="{p}"')
    return H.build(arch, t, ["tests/harness/preview_pane_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


def prepare_fixtures(fx: Path) -> dict[str, str]:
    fx.mkdir(parents=True, exist_ok=True)
    txt = fx / "notes.txt"
    txt.write_bytes(b"line1\t\x1b[32mgreen\x1b[0m\r\nline2\nline3\nline4\nline5\n")
    binf = fx / "blob.bin"
    binf.write_bytes(b"\x7fELF\x00\x01\x02\x03\xaa\xbb\xcc")
    empty = fx / "empty.txt"
    empty.write_bytes(b"")
    return {"txt": str(txt), "bin": str(binf), "empty": str(empty)}


def build_script(fx: dict[str, str]) -> str:
    return "\n".join([
        "N",
        "A",                         # pv_copy_line_strip_ansi
        # Tiny geometry no-ops
        "G 0 0 9 10",
        "R",
        "G 0 0 40 5",
        "R",
        # Normal geometry 50x12
        "G 2 1 50 12",
        # NULL load
        "L 0 0 0",
        "R",
        # Directory load & render
        f"L 1 4096 16877 {fx['txt']}",
        "R",
        # Empty file: pending render, then read_sync -> empty render
        f"L 2 0 33188 {fx['empty']}",
        "R",
        "S 0",
        "R",
        # Text file: read_sync (with thumb_len=32 -> thumb_gen=1), render text scroll=0 and scroll=2
        f"L 2 45 33188 {fx['txt']}",
        "S 32",
        "C 0 2",
        "R",
        "C 2 2",
        "R",
        # Mode dispatch == 0 (handled by image/ELF)
        "C 0 0",
        "R",
        # Binary file: read_sync -> is_binary=1, render hex scroll=0 and scroll=1
        f"L 2 11 33188 {fx['bin']}",
        "S 0",
        "C 0 1",
        "R",
        "C 1 1",
        "R",
    ]) + "\n"


def test_differential(exe: Path, script: bytes) -> str:
    out = H.diff_impls(exe, stdin=script).decode()
    for needle in ("N ok=1 is_pp=1 is_w=1", "A0 |hi  red|", "A1 |plainXnext|",
                   "thl=32 thg=1", "bin=1", "0000: 7f 45 4c 46", "0008: aa bb cc",
                   "line1  green", "line3"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] PP1. preview_pane{{,_render}} matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_oom(exe: Path, arch: str) -> None:
    r = H.run_impl(arch, exe, "oom")
    assert r.returncode == 0 and "OOM1 ok=1 OOM2 ok=1" in r.stdout.decode(), r.stdout.decode()


def test_mutations(t: Path, baseline: str, script: bytes) -> None:
    muts = [
        ("PP_SRC", "load-dir", "if (entry->flags & (FE_IS_DIR | FE_LINK_DIR))", "if (0)"),
        ("PP_SRC", "acc-th", "if (tlen >= IMG_THUMB_HDR)", "if (tlen > 1000u)"),
        ("PP_SRC", "acc-bin", "if (buf[i] == 0 && i < 512u) self->is_binary = 1;",
         "if (0) self->is_binary = 1;"),
        ("PP_SRC", "acc-nl", "if (buf[i] == '\\n') lines++;", "if (0) lines++;"),
        ("PP_SRC", "ansi-csi", "if (p < end && *p == '[')", "if (0)"),
        ("PP_SRC", "ansi-tab", "if (ch == '\\t') { dst[n++] = ' '; dst[n++] = ' '; continue; }",
         "if (ch == '\\t') { dst[n++] = ' '; continue; }"),
        ("PPR_SRC", "ren-minw", "if (self->w < 10 || self->h < 6) return;", "if (self->w < 5 || self->h < 6) return;"),
        ("PPR_SRC", "ren-minh", "if (self->w < 10 || self->h < 6) return;", "if (self->w < 10 || self->h < 4) return;"),
        ("PPR_SRC", "ren-pnd", "if (pv->pending) return;", "if (0) return;"),
        ("PPR_SRC", "ren-hex8", "uint64_t off = (uint64_t)pv->scroll << 3;", "uint64_t off = (uint64_t)pv->scroll;"),
        ("PPR_SRC", "ren-skip", "if (*p++ == '\\n') { skip--; line_no++; }", "if (*p++ == '\\n') { skip--; }"),
        ("PPR_SRC", "ren-lnw", "ScreenBuffer_draw_text_pad(scr, self->x + 2, self->y + 3 + r, num, 5);",
         "ScreenBuffer_draw_text_pad(scr, self->x + 2, self->y + 3 + r, num, 3);"),
    ]
    survivors: list[str] = []
    texts = {k: (ROOT / rel).read_text() for k, rel in SRCS.items()}

    def check(idx: int, key: str, name: str, old: str, new: str) -> None:
        assert old in texts[key] and old != new, name
        mp = t / f"m{idx}" / Path(SRCS[key]).name
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(texts[key].replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", {key: str(mp)})
        r = H.run_impl("x86_64", exe, "c", stdin=script)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] PP4. {len(muts)}/{len(muts)} mutants killed across preview_pane{{,_render}}.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        fx = prepare_fixtures(t / "fx")
        script = build_script(fx).encode()
        exe = build("x86_64", t / "x86")
        out = test_differential(exe, script)
        test_oom(exe, "x86_64")
        print("[PASS] PP2. OOM in PreviewPane_new (obj & buf) returns NULL cleanly")
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=script)
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            test_oom(exe_arm, "aarch64")
            print("[PASS] PP3. qemu-aarch64 matches x86_64 byte for byte + OOM check")
        test_mutations(t, out, script)


if __name__ == "__main__":
    main()
