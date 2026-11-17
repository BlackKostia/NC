#!/usr/bin/env python3
"""src/tui/i18n_env.c and i18n_pack.c versus the frozen assembly (tests/harness/i18n_*_reference.s): random *.lang
packs spread over a $DUOP_LANGS path (quoting, escapes, {version}, CRLF, unknown keys, duplicates, over-long ids,
oversized files, arena / registry exhaustion), the shipped lang/uk.lang, id/code/locale lookup and environment
detection; i18n_get must stay a rax-only leaf (asm callers keep their registers live across it)."""

import os
import random
import re
import subprocess
import tempfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
VERSION = (ROOT / "VERSION").read_text().strip()
KEYS = re.findall(r"^\s+LK ([\w.]+),", (ROOT / "src/tui/i18n_keys.s").read_text(), re.M)
CLI_C = ["tests/harness/i18n_cli.c", "src/tui/i18n_env.c", "src/tui/i18n_pack.c", "src/tui/data_dirs.c", "src/core/config.c",
         "src/core/config_parse.c", "src/core/config_load.c", "src/core/string.c", "src/core/string_path.c", "src/core/mem_prims.c",
         "src/core/syscall.c", "src/core/try_rt.c", "src/core/memory.c", "src/core/utf8.c"]
ENV = {"PATH": os.environ.get("PATH", "")}


def build(t: Path) -> Path:
    ver = t / "ver"
    ver.mkdir()
    (ver / "version.inc").write_text(f'.macro DUOP_VER_ASCII\n    .ascii "{VERSION}"\n.endm\n.macro DUOP_VER_ASCIZ\n    .asciz "{VERSION}"\n.endm\n')
    (ver / "version.h").write_text(f'#pragma once\n#define DUOP_VERSION "{VERSION}"\n')
    inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), "-I", str(ver)]
    objs = []
    for name, src in (("i18n_env_ref", "tests/harness/i18n_env_reference.s"), ("i18n_pack_ref", "tests/harness/i18n_pack_reference.s")):
        o = t / f"{name}.o"
        subprocess.run(["as", *inc, str(ROOT / src), "-o", str(o)], check=True)
        objs.append(o)
    H.rename_defined_globals(objs, "ref_")
    for m in ("i18n", "i18n_keys"):                                # shared data: the English table and the key table
        o = t / f"{m}.o"
        subprocess.run(["as", *inc, str(ROOT / f"src/tui/{m}.s"), "-o", str(o)], check=True)
        objs.append(o)
    return H.build("x86_64", t, CLI_C, objs, cflags=["-I", str(ver)])


def run(exe: Path, impl: str, *args: str, env: dict | None = None) -> str:
    res = subprocess.run([str(exe), impl, *args], capture_output=True, env={**ENV, **(env or {})}, timeout=60)
    assert res.returncode == 0, (impl, args, res.stderr)
    return res.stdout.decode()


def both(exe: Path, *args: str, env: dict | None = None) -> str:
    r, c = run(exe, "ref", *args, env=env), run(exe, "c", *args, env=env)
    assert r == c, f"{args} {env}: asm and C differ\n--- asm\n{r[:800]}\n--- C\n{c[:800]}"
    return c


WORDS = ["Файли", "Copy", " lead", "trail ", "a\\nb", "tab\\tx", 'q\\"q', "back\\\\slash", "{version}", "v{version}!", "{ver", "{version",
         "日本語", "x" * 70, "", "\\q", "emoji ✓", "end\\"]


def value(rng: random.Random) -> str:
    parts = " ".join(rng.choice(WORDS) for _ in range(rng.randrange(0, 4)))
    form = rng.randrange(5)
    if form == 0:
        return f'"{parts}"'
    if form == 1:
        return f'"{parts}'                                           # unterminated quote
    if form == 2:
        return parts + rng.choice(["", " ", "\t", "\r"])
    return f'"{parts}" trailing' if form == 3 else parts


def pack(rng: random.Random, code: bool = True) -> str:
    out = []
    for _ in range(rng.randrange(0, 40)):
        k = rng.randrange(9)
        key = rng.choice(KEYS)
        if k == 0:
            out.append("# " + rng.choice(WORDS))
        elif k == 1:
            out.append("")
        elif k == 2:
            out.append(rng.choice(["nosuch.key = 1", "= x", "key only", "weird-key = z", "  " + key]))
        elif k == 3:
            out.append(f"{key}={value(rng)}")
        else:
            out.append(f"{rng.choice(['', '  ', chr(9)])}{key}{rng.choice([' ', '', '  '])}={rng.choice([' ', '', '  '])}{value(rng)}")
    if code:
        out.insert(rng.randrange(len(out) + 1), f"code = {rng.choice(['XX', 'Dé', 'UA', 'pt-BR', 'qq', '  fr '])}")
    return rng.choice(["\n", "\r\n"]).join(out) + rng.choice(["", "\n"])


def make_dirs(t: Path, rng: random.Random, tag: str) -> str:
    dirs = []
    for d in range(rng.randrange(1, 4)):
        p = t / f"{tag}_{d}"
        p.mkdir()
        dirs.append(str(p))
        for _ in range(rng.randrange(0, 6)):
            name = rng.choice(["uk", "de", "fr", "a1", "zz", "pt", "uk", "de", "x", "ABC", "longidlongidlong", "id15_chars_xxxx", ".hidden", "ж"])
            ext = rng.choice([".lang", ".lang", ".lang", ".txt", ".lang.bak"])
            (p / (name + ext)).write_text(pack(rng, code=rng.random() < 0.85), encoding="utf-8")
    return ":".join(dirs)


def test_random_packs(exe: Path) -> None:
    rng = random.Random(1117)
    with tempfile.TemporaryDirectory() as d:
        for i in range(70):
            t = Path(d) / f"s{i}"
            t.mkdir()
            both(exe, "dump", "uk", "UA", "de", "DE_de", "pt-BR", "fr.UTF-8", "xx", "en", "EN", "a1", "ZZ", env={"DUOP_LANGS": make_dirs(t, rng, "p")})
    print("[PASS] I18N1. 70 random pack sets (every slot of every language, find by id/code/locale) identical to the asm")


def test_limits(exe: Path) -> None:
    rng = random.Random(5)
    with tempfile.TemporaryDirectory() as d:
        t = Path(d)
        big = t / "big"
        big.mkdir()
        body = "code = BG\n" + "".join(f"{k} = {'x' * 200}\n" for k in KEYS[:300])
        (big / "bg.lang").write_text(body + "# pad\n" * 20000)                           # > 65536 bytes: truncated at the cap
        out = both(exe, "dump", "bg", env={"DUOP_LANGS": str(big)})
        assert "count=2" in out and "find bg=1" in out, out[:200]
        many = t / "many"
        many.mkdir()
        for i in range(22):                                                               # I18N_MAX = 16 languages in total
            (many / f"l{i:02d}.lang").write_text(f"code = L{i}\n" + pack(rng, code=False))
        out = both(exe, "dump", "l00", "l14", "l15", "l21", env={"DUOP_LANGS": str(many)})
        assert "count=16" in out, out[:200]                                           # English + the first 15 packs found
        arena = t / "arena"
        arena.mkdir()
        for i in range(15):                                                               # 15 x ~45 KiB: the 512 KiB arena runs out
            (arena / f"a{i:02d}.lang").write_text(f"code = A{i}\n" + "".join(f"{k} = {'y' * 150}\n" for k in KEYS[:400])[:64000])
        out = both(exe, "dump", *[f"a{i:02d}" for i in range(15)], env={"DUOP_LANGS": str(arena)})
        loaded = int(re.search(r"count=(\d+)", out).group(1)) - 1
        assert 5 <= loaded < 15, f"arena should hold some but not all 15 packs, held {loaded}"
    print(f"[PASS] I18N2. oversized file cap, 16-language registry limit and arena exhaustion ({loaded} of 15 packs fit) identical to the asm")


def test_shipped_and_lookup(exe: Path) -> None:
    out = both(exe, "dump", "uk", "UA", "ua", "uk_UA.UTF-8", "xx", env={"DUOP_LANGS": str(ROOT / "lang")})
    assert "find uk=1" in out and "find UA=1" in out and "find uk_UA.UTF-8=1" in out and "find xx=-1" in out, out[:300]
    assert VERSION in out, "{version} expands in the shipped pack"
    for s, want in (("uk", "1"), ("UK_ua", "1"), ("en", "0"), ("EN_US.UTF-8", "0"), ("", "-1"), ("_x", "-1"), ("ukr", "-1"), ("u", "-1")):
        assert both(exe, "find", s, env={"DUOP_LANGS": str(ROOT / "lang")}).strip() == want, s
    cases = [({"LC_ALL": "uk_UA.UTF-8"}, "1"), ({"LC_ALL": "de_DE", "LANG": "uk"}, "0"), ({"LC_ALL": "", "LANG": "uk_UA"}, "1"),
             ({"LC_MESSAGES": "ua", "LANG": "en"}, "1"), ({"LANG": "C"}, "0"), ({}, "0")]
    for env, want in cases:
        assert both(exe, "detect", env={**env, "DUOP_LANGS": str(ROOT / "lang")}).strip() == want, env
    # the asm returned the *pointer* of an empty LANG (ZF from `cmp byte [rax], 0`) as the index when LC_ALL, LC_MESSAGES
    # and LANG were all set but empty; callers survived only because i18n_set_lang maps out-of-range to English
    empty = {"LC_ALL": "", "LC_MESSAGES": "", "LANG": "", "DUOP_LANGS": str(ROOT / "lang")}
    assert run(exe, "c", "detect", env=empty).strip() == "0", "all-empty locale variables -> English"
    print("[PASS] I18N3. shipped uk.lang, {version}, id/code/locale lookup and LC_ALL/LC_MESSAGES/LANG precedence identical to the asm")


def test_semantics(exe: Path) -> None:
    with tempfile.TemporaryDirectory() as d:
        t = Path(d)
        (t / "xx.lang").write_text('code = XX\nname = " padded name "\nhdr_brand = a\\tb\\n\\"q\\" {version}\nsb_dir_tag = plain \r\n')
        (t / "nocode.lang").write_text("name = nope\n")
        (t / "toolongidtoolongid.lang").write_text("code = TL\n")
        (t / "aa.lang").write_text("code = AA\n")
        out = both(exe, "dump", "xx", "nocode", "aa", "toolongidtoolongid", env={"DUOP_LANGS": str(t)})
        assert "find xx=2" in out and "find aa=1" in out and "find nocode=-1" in out and "find toolongidtoolongid=-1" in out, out[:300]
        assert "\n1: padded name \n" in out, "quoted value keeps its outer blanks"
        assert f'a\\x09b\\x0a"q" {VERSION}\n' in out, out[:900]
        assert "sb_dir_tag trailing CR trimmed" and "plain\n" in out
    print("[PASS] I18N4. quotes, escapes, {version}, CRLF, missing code, over-long id and id ordering behave as documented")


def test_get_is_rax_only() -> None:
    obj = ROOT / "build/tui/i18n_env.o"
    if not obj.exists():
        print("[SKIP] I18N5: build/tui/i18n_env.o missing (run make first)")
        return
    dis = subprocess.run(["objdump", "-d", "--no-show-raw-insn", "-M", "intel", str(obj)], capture_output=True, text=True, check=True).stdout
    body = re.search(r"<i18n_get>:\n(.*?)\n\n", dis, re.S).group(1)
    regs = set(re.findall(r"\b(r[a-ds]x|r[sd]i|r\d+[dwb]?|e[a-ds]x|e[sd]i|[a-d]l)\b", re.sub(r"<[^>]*>|#.*", "", body)))
    assert regs <= {"rax", "eax", "al"}, f"i18n_get must touch only rax (asm callers rely on it): {regs}"
    print("[PASS] I18N5. i18n_get is a leaf that touches rax only")


def test_aarch64_compiles() -> None:
    if not H.available("aarch64"):
        print("[SKIP] I18N6: aarch64 toolchain unavailable")
        return
    with H.workdir() as d:
        (Path(d) / "version.h").write_text('#pragma once\n#define DUOP_VERSION "9.9.9"\n')
        for m in ("i18n_env", "i18n_pack"):
            subprocess.run(["clang", "--target=aarch64-linux-gnu", "-mno-outline-atomics", *H.COMMON, "-I", d, "-c", str(ROOT / f"src/tui/{m}.c"),
                            "-o", str(Path(d) / f"{m}.o")], check=True, capture_output=True)
    print("[PASS] I18N6. i18n_env.c / i18n_pack.c compile warning-free for aarch64 (the English table stays x86 asm for now)")


def main() -> None:
    with H.workdir() as d:
        exe = build(Path(d))
        test_random_packs(exe)
        test_limits(exe)
        test_shipped_and_lookup(exe)
        test_semantics(exe)
    test_get_is_rax_only()
    test_aarch64_compiles()
    print("ALL C I18N TESTS PASSED.")


if __name__ == "__main__":
    main()
