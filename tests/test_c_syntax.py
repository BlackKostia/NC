#!/usr/bin/env python3
"""U1.3: src/ui/syntax.c versus frozen x86_64 assembly (tests/harness/syntax_reference.s):
syntax_detect and syntax_draw_line.

SY1 differential (x86_64):
    - syntax_detect across nullptr, empty, short strings, every supported extension
      (.py, .sh, .s, .asm, Makefile, dir/Makefile, .c, .h, .json, .md), near-misses
    - syntax_draw_line across plain, Python, Shell, ASM, Makefile, C, JSON, Markdown:
      all 34 keywords + prefix/suffix non-keywords, '#' and '//' comments, single/double
      quoted & unclosed strings, decimal/hex numbers (0xdeadbeef, 0x10AF), punctuation,
      width clipping mid-token/string/number/comment, max_w=0, UTF-8 comments, custom (x, y, bg)
SY2 qemu-aarch64: matches x86_64 byte for byte
SY3 mutation check across syntax.c
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/ui/syntax.c"
REF = "tests/harness/syntax_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c", "src/core/utf8.c",
    "src/core/memory.c", "src/core/syscall.c", "src/core/mem_prims.c", "src/core/string_format.c",
    "src/tui/screen.c", "src/tui/screen_buffer.c", "src/tui/screen_text.c", "src/tui/screen_rect.c",
]


def build(arch: str, t: Path, src_override: str | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "syntax_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra.append(o)
    full = src_override if src_override else str(ROOT / SRC)
    return H.build(arch, t, ["tests/harness/syntax_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), f'-DSYN_SRC="{full}"'])


def build_script() -> str:
    lines: list[str] = []
    # 1. syntax_detect coverage
    detect_paths = [
        "!", "", "a", ".p", ".py", "foo.py", "a/b/run.sh", "x.s", "boot.asm",
        "Makefile", "/tmp/dir/Makefile", "MyMakefile", "Makefile.bak",
        "main.c", "duop.h", "data.json", "README.md", "notes.txt", "file.c.bak", "dir/.md",
    ]
    for p in detect_paths:
        lines.append("D!" if p == "!" else f"D {p}")

    # 2. syntax_draw_line corpus
    cases = [
        # Plain text & nullptr path
        (0, 0, 40, 22, "notes.txt", "def foo(int x): # not highlighted 0x10"),
        (2, 1, 30, 1, "!", "const char *s = \"plain\"; // 123"),
        # Python / Shell / ASM / Makefile (lang 1)
        (0, 0, 80, 22, "a.py", "def f(x): return x if not x and True or false else 'str' # Привіт"),
        (0, 0, 80, 22, "a.py", "class Foo: import sys; from os import path; elif x in a: while 1: for i"),
        (0, 0, 80, 22, "a.sh", "x=0x1f2a + 9876 + 0x10AF # shell comment"),
        (0, 0, 80, 22, "a.s", "mov rax, rbx; call foo; ret; jmp L1; push rbp; pop rbp; lea cmp test add sub xor"),
        (0, 0, 80, 22, "dir/Makefile", "all: # target // also comment"),
        # C / JSON (lang 2): '#' is NOT a comment, '//' IS a comment
        (0, 0, 80, 22, "main.c", "#include \"duop.h\" // C comment"),
        (0, 0, 80, 22, "main.c", "const struct Foo *f(int a, void *b, char c) { return null; }"),
        (0, 0, 80, 22, "main.c", "int x = 10 / 2; /* not slash-slash */ // tail"),
        (0, 0, 80, 22, "data.json", "{\"ok\": true, \"no\": false, \"nil\": null, \"n\": 42, \"hex\": 0xdeadbeef}"),
        # Markdown (lang 3): '#' IS a comment
        (0, 0, 80, 22, "doc.md", "# Heading with def int 123"),
        (0, 0, 80, 22, "doc.md", "plain text with 'single' and \"double\" and // comment"),
        # Identifier edge cases: near-misses, underscores, uppercase, digits inside ident
        (0, 0, 80, 22, "main.c", "define _if if1 INT Void_0 Z9_a0 _0123"),
        # Strings: empty, adjacent, unclosed, clipped
        (0, 0, 80, 22, "main.c", "\"\" '' \"abc\"'def' \"unclosed string"),
        (3, 2, 10, 2, "main.c", "\"unclosed_long_string\""),
        # Width clipping mid-token, mid-number, mid-comment, max_w=0, empty line
        (1, 0, 5, 22, "main.c", "return 12345"),
        (1, 0, 4, 22, "main.c", "0xdeadbeef"),
        (1, 0, 6, 22, "main.c", "ab // comment_text"),
        (1, 0, 0, 22, "main.c", "int x = 1;"),
        (1, 0, 20, 22, "main.c", ""),
    ]
    for x, y, w, bg, path, text in cases:
        lines.append(f"L {x} {y} {w} {bg} {path}\t{text}")
    return "\n".join(lines) + "\n"


def test_differential(exe: Path) -> str:
    s = build_script().encode()
    out = H.diff_impls(exe, stdin=s).decode()
    for needle in ("accent/", "exec_fg/", "warn_fg/", "muted/", "a=1", "D 0\n", "D 1\n", "D 2\n", "D 3\n"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] SY1. syntax_detect & syntax_draw_line match frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    s = build_script().encode()
    muts = [
        ("detect-null", "if (!path) return 0;", "if (0 && !path) return 0;"),
        ("ends-len", "if (slen < xlen) return 0;", "if (slen <= xlen) return 0;"),
        ("detect-mk", "str_cmp(path_basename(path), \"Makefile\") == 0", "str_cmp(path_basename(path), \"Makefilx\") == 0"),
        ("detect-md", "if (syn_ends_with(path, \".md\")) return 3;", "if (syn_ends_with(path, \".md\")) return 2;"),
        ("is-ident-us", "c == '_'", "c == '-'"),
        ("is-ident-dig", "(c >= '0' && c <= '9')", "(c > '0' && c <= '9')"),
        ("kw-match", "if (n == len && kw[n] == '\\0') return 1;", "if (n == len) return 1;"),
        ("hash-lang", "lang == 1 || lang == 3", "lang == 1"),
        ("slash-slash", "ch == '/' && p[1] == '/'", "ch == '/'"),
        ("num-hex-x", "c == 'x'", "c == 'X'"),
        ("num-hex-af", "(c >= 'a' && c <= 'f')", "(c >= 'a' && c < 'f')"),
        ("str-single", "ch == '\"' || ch == '\\''", "ch == '\"'"),
        ("kw-bold", "ScreenBuffer_set_pen(scr, theme->accent, bg, ATTR_BOLD);", "ScreenBuffer_set_pen(scr, theme->accent, bg, ATTR_NONE);"),
        ("ident-clip", "int draw_w = len < rem ? len : rem;", "int draw_w = len + (rem & 0);"),
    ]
    src_txt = (ROOT / SRC).read_text()
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src_txt and old != new, name
        mp = t / f"m{idx}" / "syntax.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src_txt.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", str(mp))
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] SY3. {len(muts)}/{len(muts)} mutants killed")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=build_script().encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] SY2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
