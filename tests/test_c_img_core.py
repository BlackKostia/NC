#!/usr/bin/env python3
"""src/fs/img_core.c versus the frozen assembly (tests/harness/img_core_reference.s): img_detect / img_decode / img_alloc / img_free /
img_fit / img_scale / img_scale_rect.

IC1 differential (x86_64): img_detect on every magic and its neighbours, short buffers, ".tga" in any case and no path; img_alloc
    around 0, IMG_MAX_DIM and IMG_MAX_PIXELS and under OOM; img_fit on random and extreme (negative, zero, 2^31 - 1) sizes;
    img_scale / img_scale_rect up and down, sub-rectangles, degenerate sizes, unaligned guarded output; img_decode of random
    BMP / TGA / PNM / QOI / GIF / PNG / JPEG files (valid and broken), wrong formats, and decoders that fault on an unmapped page
    (the TRY guard turns the fault into IMG_E_CORRUPT and frees the picture)
IC2 a defect of the asm, fixed: img_alloc multiplied the whole rdx, so an int height with garbage in the upper half of the register
    (allowed by the ABI) made a valid size "too many pixels"
IC3 the scaler is not slower than the asm (hot path of the viewer and the thumbnails: within 10 %)
IC4 qemu-aarch64: the C module gives the x86_64 results (the image core was x86-64 only); IC5 mutation check
"""

import random
import subprocess
import sys
from pathlib import Path

import c_harness as H

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_c_img as I  # noqa: E402  (random image generators)

ROOT = H.ROOT
SRC = "src/fs/img_core.c"
REF = "tests/harness/img_core_reference.s"
DECODERS = [f"src/fs/img_{m}.c" for m in ("bmp", "tga", "pnm", "gif", "png", "jpeg")] + ["src/fs/inflate.c"]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
MAXD, MAXP = 16384, 40000000
KINDS = (("bmp", "bmp", 4), ("tga", "tga", 6), ("pnm", "ppm", 5), ("qoi", "qoi", 7), ("gif", "gif", 3), ("png", "png", 1), ("jpeg", "jpg", 2))


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        ref, thunk = t / "img_core_ref.o", t / "ic_thunk.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(ref)], check=True, capture_output=True)
        H.rename_defined_globals([ref], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "mem_alloc=ic_alloc", str(ref)], check=True)
        subprocess.run(["as", str(ROOT / "tests/harness/img_core_thunk_x86_64.s"), "-o", str(thunk)], check=True, capture_output=True)
        extra = [ref, thunk]
    return H.build(arch, t, ["tests/harness/img_core_cli.c", *DECODERS, *CORE], extra, cflags=["-I", str(ROOT / "tests/harness"), f'-DIC_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64") -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=300)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode()


def detect_script(rng: random.Random) -> str:
    magics = [b"\x89PNG", b"\xff\xd8\xff", b"\xff\xd8\xfe", b"GIF8", b"GIF7", b"qoif", b"qoiF", b"BM", b"BN", b"P5", b"P6", b"P4", b"P7",
              b"RIFF\0\0\0\0WEBQ", b"RIFF\0\0\0\0WEBP", b"RIFF", b"", b"\0" * 18]   # "RIFF" right after "...WEBP": stale bytes past n
    out = []
    for m in magics:
        for extra in (0, 1, 2, 3, 8, 14, 17, 18, 40):
            data = m + bytes(rng.randrange(256) for _ in range(extra))
            for path in ("-", "/x/pic.tga", "/x/PIC.TGA", "a.TgA", ".tga", "tga", "/x/pic.tgb", "/x/pic.tga.png"):
                out.append(f"D {data.hex() or 'x'} {path}\n")
    return "".join(out)


def alloc_script() -> str:
    vals = [-1, 0, 1, 2, 4096, MAXD - 1, MAXD, MAXD + 1, 1 << 31 - 1]
    s = "".join(f"A {w} {h}\n" for w in vals for h in vals)
    s += "".join(f"A {w} {h}\n" for w, h in ((MAXP // 4000, 4000), (MAXP // 4000 + 1, 4000), (6325, 6324), (6325, 6325), (10000, 4000), (10000, 4001)))
    return s + "O 1\nA 10 10\nO 2\nA 10 10\nA 20 20\n"


def fit_script(rng: random.Random) -> str:
    ext = [-5, 0, 1, 2, 3, 7, 100, 4096, 65535, (1 << 31) - 1, -(1 << 31)]
    s = "".join(f"N {rng.choice(ext)} {rng.choice(ext)} {rng.choice(ext)} {rng.choice(ext)}\n" for _ in range(400))
    return s + "".join(f"N {rng.randrange(1, 5000)} {rng.randrange(1, 5000)} {rng.randrange(1, 400)} {rng.randrange(1, 400)}\n" for _ in range(400))


def scale_script(rng: random.Random) -> str:
    s = []
    for _ in range(160):
        w, h = rng.randrange(1, 90), rng.randrange(1, 90)
        ow, oh = rng.choice([1, 2, w, w // 2 + 1, w * 2, rng.randrange(1, 200)]), rng.choice([1, 3, h, h * 3, rng.randrange(1, 200)])
        if rng.random() < 0.5:
            x, y = rng.randrange(w), rng.randrange(h)
            s.append(f"S {w} {h} {rng.randrange(1 << 30)} {ow} {oh} {x} {y} {rng.randrange(1, w - x + 1)} {rng.randrange(1, h - y + 1)} {rng.randrange(4)}\n")
        else:
            s.append(f"S {w} {h} {rng.randrange(1 << 30)} {ow} {oh} {rng.randrange(4)}\n")
    return "".join(s) + "S 5 5 1 0 4\nS 5 5 1 4 0\nS 5 5 1 -3 4\nS 1 1 7 300 1\nS 4000 3 2 7 3\n"


def decode_files(t: Path, rng: random.Random) -> list[tuple[Path, int]]:
    t.mkdir(parents=True, exist_ok=True)
    files = []
    for kind, ext, fmt in KINDS:
        for i in range(8):
            data = getattr(I, kind)(rng)
            if i % 4 == 3:
                data = I.mutate(rng, data)
            p = t / f"{kind}{i}.{ext}"
            p.write_bytes(data)
            files.append((p, fmt))
    return files


def decode_script(rng: random.Random, files: list[tuple[Path, int]]) -> str:
    s = []
    for p, fmt in files:
        s.append(f"F {p} {fmt}\n")
        s.append(f"F {p} {rng.choice([0, 8, 9, 99, fmt % 7 + 1])}\n")                    # unsupported / wrong decoder
        size = p.stat().st_size
        s.append(f"F {p} {fmt} {max(1, size * rng.randrange(1, 9) // 10)}\n")           # decoder runs into an unmapped page
    return "".join(s)


def scripts(t: Path) -> dict[str, str]:
    rng = random.Random(0x1C)
    return {"detect": detect_script(rng), "alloc": alloc_script(), "fit": fit_script(rng), "scale": scale_script(rng),
            "decode": decode_script(rng, decode_files(t / "files", rng))}


def test_differential(exe: Path, ss: dict[str, str]) -> dict[str, str]:
    outs = {}
    for name, s in ss.items():
        a, b = run(exe, "ref", s), run(exe, "c", s)
        if a != b:
            x, y = next((x, y) for x, y in zip(a.splitlines(), b.splitlines()) if x != y)
            raise AssertionError(f"{name}: oracle and C differ:\n  ref {x}\n  c   {y}")
        outs[name] = b
    d = outs["decode"].splitlines()
    ok, corrupt = sum(ln.startswith("F rc=0 ") for ln in d), sum(ln.startswith("F rc=-3 ") for ln in d)
    assert ok > 20 and corrupt > 10 and sum(ln.startswith("F rc=-2 ") for ln in d) > 10, (ok, corrupt)
    assert all(" px=0" in ln or ln.startswith("F rc=0 ") for ln in d), "a failed decode never leaves a picture behind"
    det = {int(ln.split()[1]) for ln in outs["detect"].splitlines()}
    assert det == set(range(9)), f"every format detected: {sorted(det)}"
    print(f"[PASS] IC1. img_core identical to the asm: {sum(o.count(chr(10)) for o in outs.values())} calls "
          f"({ok} decoded, {corrupt} corrupt incl. faults on an unmapped page, all 9 detections, alloc limits, OOM, fit, scale)")
    return outs


def test_alloc_hi(exe: Path) -> None:
    s = "A 100 100 hi\nA 1 1 hi\n"
    ref, c = run(exe, "ref", s).splitlines(), run(exe, "c", s).splitlines()
    assert ref[0].startswith("A rc=-2 ") and c[0].startswith("A rc=0 ") and c[1].startswith("A rc=0 "), (ref, c)
    print("[PASS] IC2. fixed: img_alloc no longer reads the undefined upper half of an int argument (asm: 100x100 'too many pixels')")


def test_speed(exe: Path) -> None:
    s = "P 1600 1200 800 600 6\nP 300 200 1200 800 3\n"
    best = {"ref": [10 ** 9] * 2, "c": [10 ** 9] * 2}
    for _ in range(3):
        for impl in ("ref", "c"):
            ms = [int(ln.split()[1]) for ln in run(exe, impl, s).splitlines()]
            best[impl] = [min(a, b) for a, b in zip(best[impl], ms)]
    for r, c in zip(best["ref"], best["c"]):
        assert c <= r * 1.10 + 2, f"img_scale slower than the asm: {best}"
    print(f"[PASS] IC3. img_scale speed: asm {best['ref']} ms, C {best['c']} ms (down / up)")


MUTANTS = [
    ("tga needs 18", "if (n < 18 || !path) return 0;", "if (n < 17 || !path) return 0;"),
    ("tga ext case", "!str_casecmp(path + len - 4, \".tga\")", "!str_cmp(path + len - 4, \".tga\")"),
    ("jpeg magic", "(m & 0xFFFFFF) == 0xFFD8FF", "(m & 0xFFFF) == 0xD8FF"),
    ("pnm P4", "(d[1] == '5' || d[1] == '6')", "(d[1] >= '4' && d[1] <= '6')"),
    ("webp length", "n >= 12 && ", ""),
    ("leak on failure", "if (rc != 0) img_free(out);", ""),
    ("max dim", "w > IMG_MAX_DIM ||", "w >= IMG_MAX_DIM ||"),
    ("max pixels", "if (px > IMG_MAX_PIXELS)", "if (px >= IMG_MAX_PIXELS)"),
    ("fit bound", "if (oh <= by)", "if (oh < by)"),
    ("fit clamp", "return (int32_t)v > 0 ? (int32_t)v : 1;", "return (int32_t)v > 0 ? (int32_t)v : 0;"),
    ("span min", "*s1 = b > a ? b : a + 1;", "*s1 = b;"),
    ("average rounding", "(uint32_t)(g / taps) << 8", "(uint32_t)((g + taps / 2) / taps) << 8"),
    ("rect origin", "(uint32_t)y0 + (uint32_t)rect[1]", "(uint32_t)y0"),
    ("channel order", "(uint32_t)(b / taps) << 16 | (uint32_t)(g / taps) << 8", "(uint32_t)(g / taps) << 16 | (uint32_t)(b / taps) << 8"),
    ("row index", "(uint32_t)y * (uint32_t)iw + (uint32_t)x0", "(uint32_t)y * (uint32_t)iw"),
]
# Not mutated (unreachable with the real decoders and spans): the IMG_E_CORRUPT check of a decoder that returns 0 without a
# picture, and the colour of an empty source block (isc_span always yields s1 > s0).


def test_mutants(t: Path, ss: dict[str, str], expect: dict[str, str]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "img_core.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "img_core.c"))
                noticed[name] = any(run(exe, "c", s) != expect[k] for k, s in ss.items())
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] IC5. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build("x86_64", t / "x86")
        ss = scripts(t)
        outs = test_differential(exe, ss)
        test_alloc_hi(exe)
        test_speed(exe)
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            for name, s in ss.items():
                assert run(a64, "c", s, "aarch64") == outs[name], f"qemu-aarch64 differs from x86_64 in {name}"
            print(f"[PASS] IC4. qemu-aarch64: the C module gives the x86_64 results in all {len(ss)} scripts")
        else:
            print("[SKIP] IC4: aarch64 toolchain/qemu not installed")
        test_mutants(t, ss, outs)
    print("ALL C IMG CORE TESTS PASSED.")


if __name__ == "__main__":
    main()
