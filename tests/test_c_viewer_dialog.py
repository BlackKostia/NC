#!/usr/bin/env python3
"""U3.4: src/ui/viewer_dialog{,_render}.c versus frozen x86_64 assembly
(tests/harness/viewer_dialog{,_end,_render,_input}_reference.s): ViewerDialog_vtbl,
ViewerDialog_new, dtor, layout, render, on_key, on_mouse, on_btn0, vw_scroll/home/end.

VD1 differential (x86_64):
    - ViewerDialog_new: regular text file (mmap RO), binary file (NUL -> hex_mode=1),
      empty file (fallback), nonexistent path (data=0)
    - ViewerDialog_layout: wide (90x20), narrow (30x12), tiny (20x8 -> vis_rows=3), tiny (20x5 -> vis_rows=0)
    - ViewerDialog_render: text mode (line numbers, CRLF, tabs -> 2 spaces, syntax highlight,
      unterminated last line, scrollbar), hex mode (8-digit offset, 16-byte rows + partial row + ASCII),
      image mode delegation (ViewerDialog_render_image)
    - ViewerDialog_on_key: delegation priority (hex_edit/mode/zoom), text & hex scroll
      (Up/k, Down/j, PgUp, PgDn/Space, Home, End with trailing & unterminated LF),
      h/H toggle preserving byte offset, close keys (Esc/q/Q/F3/F10)
    - ViewerDialog_on_mouse: vim_zoom_mouse short-circuit, wheel up (-3) / down (+3),
      button click delegation via Dialog_on_mouse
    - ViewerDialog_dtor: frees img/hex_edit and unmaps vs frees heap
VD2 OOM check (ViewerDialog_new returns NULL cleanly)
VD3 qemu-aarch64 matches x86_64 byte for byte + OOM
VD4 mutation check across viewer_dialog.c and viewer_dialog_render.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRCS = {
    "VD_SRC": "src/ui/viewer_dialog.c",
    "VDR_SRC": "src/ui/viewer_dialog_render.c",
}
REFS = [
    "tests/harness/viewer_dialog_reference.s",
    "tests/harness/viewer_dialog_end_reference.s",
    "tests/harness/viewer_dialog_render_reference.s",
    "tests/harness/viewer_dialog_input_reference.s",
]
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c",
    "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c", "src/core/string_path.c",
    "src/fs/file_ops_read.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
    "build/i18n_en.c",
    "src/ui/dialog.c",
    "src/ui/syntax.c",
    "src/ui/viewer_scrollbar.c",
]

KEY_UP = 0x100001
KEY_DOWN = 0x100002
KEY_HOME = 0x100005
KEY_END = 0x100006
KEY_PGUP = 0x100007
KEY_PGDN = 0x100008
KEY_ESC = 0x10000F
KEY_F3 = 0x100013
KEY_F10 = 0x10001A


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
            "--redefine-sym", "Object_alloc=fake_object_alloc",
            "--redefine-sym", "viewer_img_free=fake_viewer_img_free",
            "--redefine-sym", "hex_edit_free=fake_hex_edit_free",
            "--redefine-sym", "hex_edit_on_key=fake_hex_edit_on_key",
            "--redefine-sym", "viewer_mode_key=fake_viewer_mode_key",
            "--redefine-sym", "vim_zoom_key=fake_vim_zoom_key",
            "--redefine-sym", "vim_zoom_mouse=fake_vim_zoom_mouse",
            "--redefine-sym", "ViewerDialog_render_image=fake_ViewerDialog_render_image",
        ]
        for o in objs:
            subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra += objs
    defs = []
    for k, rel in SRCS.items():
        p = overrides[k] if (overrides and k in overrides) else str(ROOT / rel)
        defs.append(f'-D{k}="{p}"')
    return H.build(arch, t, ["tests/harness/viewer_dialog_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


def prepare_fixtures(fx: Path) -> dict[str, str]:
    fx.mkdir(parents=True, exist_ok=True)
    txt = fx / "sample.c"
    lines = [f"// line {i}\r\n" if i == 1 else f"\tint x{i} = {i}; /* ok */\n" for i in range(1, 25)]
    lines.append("last_unterminated_line")
    txt.write_bytes("".join(lines).encode())

    txt_lf = fx / "trailing.txt"
    txt_lf.write_bytes(b"first\nsecond\nthird\n")

    binf = fx / "data.bin"
    binf.write_bytes(bytes(range(0, 40)) + b"Hello\x00World\x7f\x80\xff")

    empty = fx / "empty.txt"
    empty.write_bytes(b"")

    return {
        "txt": str(txt),
        "txt_lf": str(txt_lf),
        "bin": str(binf),
        "empty": str(empty),
        "missing": str(fx / "missing.txt"),
    }


def build_script(fx: dict[str, str]) -> str:
    return "\n".join([
        # 1. Text file: render, scroll, End (unterminated), Home, PgDn/Space, PgUp, Hex toggle
        f"N 84 14 {fx['txt']}",
        "R",
        f"K 0x{KEY_UP:x} 0",         # at top
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{ord('j'):x} 0",
        f"K 0x{ord('k'):x} 0",
        f"K 0x{KEY_PGDN:x} 0",
        f"K 0x{ord(' '):x} 0",
        "R",
        f"K 0x{KEY_END:x} 0",        # counts total_lines (25) & lands on last page
        "R",
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{KEY_PGUP:x} 0",
        f"K 0x{KEY_HOME:x} 0",
        # Toggle text -> hex -> text
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{ord('h'):x} 0",       # hex_mode=1, hex_row=top_off>>4
        "R",
        f"K 0x{KEY_DOWN:x} 0",
        f"K 0x{KEY_END:x} 0",
        f"K 0x{KEY_UP:x} 0",
        f"K 0x{KEY_HOME:x} 0",
        f"K 0x{ord('H'):x} 0",       # hex_mode=0, top_off=0, top_line=0
        # Image mode delegation on render
        "I 1",
        "R",
        "I 0",
        # Delegation priority & close keys
        "H 1 0 0 0",
        f"K 0x{ord('q'):x} 0",       # consumed by hex_edit
        "H 0 1 0 0",
        f"K 0x{ord('q'):x} 0",       # consumed by viewer_mode_key
        "H 0 0 1 0",
        f"K 0x{ord('q'):x} 0",       # consumed by vim_zoom_key
        "H 0 0 0 1",
        "M 5 65 10 5",               # consumed by vim_zoom_mouse
        "H 0 0 0 0",
        f"K 0x{KEY_ESC:x} 0",
        f"K 0x{ord('q'):x} 0",
        f"K 0x{ord('Q'):x} 0",
        f"K 0x{KEY_F3:x} 0",
        f"K 0x{KEY_F10:x} 0",
        # Mouse wheel & Dialog_on_mouse delegation (buttons on row y+h-2=11)
        "M 5 65 10 5",               # wheel down +3
        "M 5 64 10 5",               # wheel up -3
        "M 1 0 76 11",               # click Close button
        # Layout edge cases
        "L 0 0 38 14",
        "L 0 0 30 12",
        "L 0 0 20 8",
        "L 0 0 20 5",
        "R",                         # vis_rows == 0
        # 2. Trailing-LF file End
        f"N 80 12 {fx['txt_lf']}",
        f"K 0x{KEY_END:x} 0",
        f"K 0x{KEY_END:x} 0",        # cached total_lines
        # 3. Binary file (auto hex_mode=1)
        f"N 84 12 {fx['bin']}",
        "R",
        f"K 0x{KEY_END:x} 0",
        f"K 0x{KEY_DOWN:x} 0",
        # 4. Empty & missing files
        f"N 80 12 {fx['empty']}",
        "R",
        f"N 80 12 {fx['missing']}",
        "R",
    ]) + "\n"


def test_differential(exe: Path, script: bytes) -> str:
    out = H.diff_impls(exe, stdin=script).decode()
    for needle in ("N ok=1 is_vd=1 is_d=1", "00000000:", "last_unterminated_line",
                   "tot=25", "tot=3", "call ViewerDialog_render_image im=1",
                   "call App_close_dialog 1 2", "call viewer_img_free", "call hex_edit_free"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] VD1. viewer_dialog{{,_render}} matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_oom(exe: Path, arch: str) -> None:
    r = H.run_impl(arch, exe, "oom")
    assert r.returncode == 0 and "OOM ok=1" in r.stdout.decode(), r.stdout.decode()


def test_mutations(t: Path, baseline: str, script: bytes) -> None:
    muts = [
        ("VD_SRC", "bin-nul", "if (pos < scan) v->hex_mode = 1;", "if (pos <= scan) v->hex_mode = 1;"),
        ("VD_SRC", "lay-w30", "if (dw < 30) dw = w;", "if (dw < 40) dw = w;"),
        ("VD_SRC", "lay-h12", "if (dh < 12) dh = h;", "if (dh < 15) dh = h;"),
        ("VD_SRC", "btn0-sh", "v->hex_row = v->top_off >> 4;", "v->hex_row = v->top_off;"),
        ("VD_SRC", "end-lf", "if (data[len - 1] != '\\n') total++;", "if (0) total++;"),
        ("VD_SRC", "key-f10", "case KEY_F10:", "case 0x7FFFFF:"),
        ("VD_SRC", "wheel-3", "vw_scroll(v, ev->mouse_btn == MOUSE_WHEEL_UP ? -3 : 3);",
         "vw_scroll(v, ev->mouse_btn == MOUSE_WHEEL_UP ? -1 : 1);"),
        ("VDR_SRC", "ren-img", "if (v->img_mode != 0)", "if (0)"),
        ("VDR_SRC", "ren-numw", "if (nw < 5) nw = 5;", "if (nw < 8) nw = 8;"),
        ("VDR_SRC", "ren-cr", "if (ch == '\\r') continue;", "if (0) continue;"),
        ("VDR_SRC", "ren-tab", "if (ch == '\\t') { line[dst++] = ' '; line[dst++] = ' '; continue; }",
         "if (ch == '\\t') { line[dst++] = ' '; continue; }"),
        ("VDR_SRC", "hex-asc", "b >= 0x20 && b <= 0x7E ? (char)b : '.'", "'.'"),
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
    print(f"[PASS] VD4. {len(muts)}/{len(muts)} mutants killed across viewer_dialog{{,_render}}.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        fx = prepare_fixtures(t / "fx")
        script = build_script(fx).encode()
        exe = build("x86_64", t / "x86")
        out = test_differential(exe, script)
        test_oom(exe, "x86_64")
        print("[PASS] VD2. OOM in ViewerDialog_new returns NULL cleanly")
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=script)
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            test_oom(exe_arm, "aarch64")
            print("[PASS] VD3. qemu-aarch64 matches x86_64 byte for byte + OOM check")
        test_mutations(t, out, script)


if __name__ == "__main__":
    main()
