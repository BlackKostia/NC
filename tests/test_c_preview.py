#!/usr/bin/env python3
"""src/fs/preview_io.c + preview_helper.c versus the frozen assembly (tests/harness/preview_io_reference.s +
preview_helper_reference.s): the asynchronous preview reader and its helper process.

PV1 pv_make_thumb differential (x86_64): random BMP / TGA / PNM / QOI / GIF / PNG / JPEG files (valid and broken), text, empty
    and missing files; every output protocol (quadrants, half blocks, Sixel, Kitty with and without cols), box sizes from 1x1
    to 400x300, small and large caps, unaligned output buffers; the result and every byte of a guarded output buffer
PV2 request / reply differential through the real helper process: text heads, images with thumbnails in the shared ping-pong
    slots, missing files, directories, FIFOs, package listings, a PATH_MAX - 1 path and one byte more, a reply larger than the
    receive buffer (stream reset), back-to-back requests, a helper stuck on "dead storage" replaced after PV_STUCK_MS, stop
PV3 fixed in C: Kitty output for a zero-width box divided by zero (SIGFPE; the UI never asks for one, pv_make_thumb's contract
    allows it); hardening: the decoder opens the file non-blocking and decodes regular files only
PV4 qemu-aarch64: the C modules alone give the x86_64 results; PV5 mutation check
"""

import os
import random
import subprocess
import sys
import time
from pathlib import Path

import c_harness as H

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_c_img as I  # noqa: E402  (random image generators)

ROOT = H.ROOT
SRCS = ["src/fs/preview_io.c", "src/fs/preview_helper.c"]
REFS = ["tests/harness/preview_io_reference.s", "tests/harness/preview_helper_reference.s"]
IMG = [f"src/fs/img_{m}.c" for m in ("core", "bmp", "tga", "pnm", "gif", "png", "jpeg", "kitty", "quant", "sixel")] + ["src/fs/inflate.c"]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
PATH_MAX, CAP_BIG = 4096, 16 + 160 * 100 * 4 + 2048


def build(arch: str, t: Path, srcs: list[str] | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    asm = H.ARCHS[arch]["as_"]
    extra: list[Path] = []
    o = t / "pal_uring.o"
    subprocess.run([*asm, *inc, str(ROOT / f"src/os/linux/{arch}/pal_uring.s"), "-o", str(o)], check=True, capture_output=True)
    extra.append(o)
    if arch == "x86_64":
        refs = []
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run([*asm, *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            refs.append(o)
        H.rename_defined_globals(refs, "ref_")
        extra += refs
    return H.build(arch, t, ["tests/harness/preview_cli.c", *(srcs or SRCS), *IMG, *CORE], extra, cflags=["-I", str(ROOT / "tests/harness")])


def run(exe: Path, impl: str, script: str, arch: str = "x86_64", timeout: int = 120) -> str:
    res = H.run_impl(arch, exe, impl, stdin=script.encode(), timeout=timeout)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode()


def first_diff(a: str, b: str) -> tuple[str, str]:
    return next(((x, y) for x, y in zip(a.splitlines(), b.splitlines()) if x != y), (a[-200:], b[-200:]))


def images(t: Path, rng: random.Random, per_kind: int = 6) -> list[Path]:
    t.mkdir(parents=True, exist_ok=True)
    out = []
    for kind, ext in (("bmp", "bmp"), ("tga", "tga"), ("pnm", "ppm"), ("qoi", "qoi"), ("gif", "gif"), ("png", "png"), ("jpeg", "jpg")):
        for i in range(per_kind):
            data = getattr(I, kind)(rng)
            if i % 3 == 2:
                data = I.mutate(rng, data)
            p = t / f"{kind}{i}.{ext}"
            p.write_bytes(data)
            out.append(p)
    (t / "text.txt").write_text("hello preview\n" * 50)
    (t / "empty.png").write_bytes(b"")
    return out + [t / "text.txt", t / "empty.png", t / "missing.png"]


def thumb_script(rng: random.Random, files: list[Path]) -> str:
    lines = []
    for f in files:
        for _ in range(5):
            w, h = rng.choice([(1, 1), (8, 4), (60, 40), (160, 100), (400, 300), (3, 200)])
            proto, cols = rng.randrange(4), rng.choice([0, 1, 40])
            cap = rng.choice([16, 100, 5000, CAP_BIG])
            lines.append(f"T {f} {w} {h} {proto} {cols} {rng.randrange(1 << 24):x} {cap} {rng.randrange(8)}\n")
    return "".join(lines)


def test_thumbs(exe: Path, t: Path) -> tuple[str, list[Path]]:
    rng = random.Random(0x9F)
    files = images(t / "img", rng)
    script = thumb_script(rng, files)
    a, b = run(exe, "ref", script), run(exe, "c", script)
    assert a == b, f"pv_make_thumb differs:\n  ref {first_diff(a, b)[0]}\n  c   {first_diff(a, b)[1]}"
    rs = [int(ln.split()[1][2:]) for ln in b.splitlines()]
    assert sum(r > 16 for r in rs) > 50 and sum(r == 16 for r in rs) > 10 and sum(r == 0 for r in rs) > 10, "generator coverage"
    print(f"[PASS] PV1. pv_make_thumb identical to the asm in {len(rs)} calls ({sum(r > 16 for r in rs)} payloads, "
          f"{sum(r == 16 for r in rs)} header only, {sum(r == 0 for r in rs)} not an image; guarded unaligned buffers)")
    return script, files


def ipc_script(t: Path, files: list[Path]) -> str:
    d = t / "ipc"
    d.mkdir(parents=True, exist_ok=True)
    (d / "big.txt").write_bytes(bytes(range(256)) * 300)
    (d / "sub").mkdir(exist_ok=True)
    fifo = d / "pipe"
    if not fifo.exists():
        os.mkfifo(fifo)
    longp = d / ("L" * 200)
    while len(str(longp)) < PATH_MAX - 210:
        longp = longp / ("L" * 200)
    tail = PATH_MAX - 1 - len(str(longp)) - 1
    long_ok, long_bad = f"{longp}/{'x' * tail}", f"{longp}/{'x' * (tail + 1)}"
    imgs = [f for f in files if f.suffix in (".bmp", ".png", ".gif", ".ppm")][:8]
    s = f"F\nQ {d / 'big.txt'} 0 0 0 0 0\nW\nF\n"
    for i, f in enumerate(imgs):
        s += f"Q {f} {[40, 160, 7][i % 3]} {[20, 100, 9][i % 3]} {i % 4} {i % 2 * 30} 202020\nW\n"
    s += f"Q {d / 'missing'} 10 10 0 0 0\nW\nQ {d / 'sub'} 10 10 0 0 0\nW\nQ {fifo} 0 0 0 0 0\nW\nQ PKG:demo 10 10 0 0 0\nW\n"
    s += f"Q {long_ok} 0 0 0 0 0\nW\nQ {long_bad} 0 0 0 0 0\n"
    s += f"Q {d / 'big.txt'} 0 0 0 0 0\nW 100\nF\nQ {d / 'big.txt'} 0 0 0 0 0\nW\n"                 # reply > buffer: reset, restart
    s += "".join(f"Q {imgs[i % len(imgs)]} 30 30 {i % 4} 0 0\n" for i in range(4)) + "W\nW\nW\nW\n"   # back to back
    s += f"Q {imgs[0]} 0 0 0 0 0\nW\nC\nZ 1100\nQ {d / 'big.txt'} 0 0 0 0 0\nW\nC\n"          # no thumbnail for text-only; an idle helper is kept
    s += f"Q /STUCK/x 0 0 0 0 0\nQ {d / 'big.txt'} 0 0 0 0 0\nZ 1100\nQ {d / 'big.txt'} 0 0 0 0 0\nW\nC\nS\nF\nQ {imgs[0]} 50 50 2 0 0\nW\nC\nS\nC\n"
    return s


def test_ipc(exe: Path, t: Path, files: list[Path]) -> str:
    script = ipc_script(t, files)
    a, b = run(exe, "ref", script), run(exe, "c", script)
    assert a == b, f"request/reply differs:\n  ref {first_diff(a, b)[0]}\n  c   {first_diff(a, b)[1]}"
    ls = b.splitlines()
    assert ls[0] == "F 0" and ls[1] == "Q 1" and ls[2].startswith("W seq=1 len=32768 ") and ls[3] == "F 1", ls[:4]
    assert sum(" tlen=0 " not in ln for ln in ls if ln.startswith("W seq=")) >= 6, "thumbnails travel through the shared slots"
    assert "Q -1" in ls, "a path of PATH_MAX bytes is refused"
    cs = [ln for ln in ls if ln.startswith("C ")]
    assert cs[:2] == ["C 1 live", "C 1 live"] and cs[2] == "C 2 live" and cs[-1].endswith(" none"), ("idle helper kept, stuck one replaced", cs)
    print(f"[PASS] PV2. request/reply through the helper identical to the asm ({len(ls)} steps: heads, thumbnails in shm slots, "
          "errors, FIFO, package, PATH_MAX boundary, oversized reply, back-to-back, stuck helper replaced, stop)")
    return script


def test_fixed(exe: Path, t: Path) -> str:
    d = t / "fixed"
    d.mkdir()
    p = d / "k.ppm"
    p.write_bytes(I.pnm(random.Random(1)))                                  # a decodable picture
    script = f"T {p} 0 30 3 40 0 {CAP_BIG} 0\n"                             # Kitty, box cols 40, box width 0
    ref = H.run_impl("x86_64", exe, "ref", stdin=script.encode())
    c = run(exe, "c", script)
    assert ref.returncode == -8 and c.startswith("T r=") and int(c.split()[1][2:]) > 16, ("asm: SIGFPE, C: native size", ref.returncode, c)
    os.mkfifo(d / "photo.tga")                                              # hardening: the decoder opens non-blocking, regular files only
    t0 = time.time()
    out = run(exe, "c", f"T {d / 'photo.tga'} 40 40 0 0 0 {CAP_BIG} 0\nQ {d / 'photo.tga'} 40 40 0 0 0\nW\n", timeout=20)
    assert time.time() - t0 < 5 and "W seq=1 len=0 " in out, out
    kitty_zero = script
    print("[PASS] PV3. fixed: Kitty output for a zero-width box divided by zero (asm: SIGFPE); the decoder never blocks on a FIFO")
    return kitty_zero


MUTANTS = [
    ("src/fs/preview_io.c", "stuck limit", "(uint64_t)(now - g_pv_sent_ms) >= PV_STUCK_MS", "(uint64_t)(now - g_pv_sent_ms) >= 5 * PV_STUCK_MS"),
    ("src/fs/preview_io.c", "path limit", "if (len > PATH_MAX - 1) return -1;", "if (len > PATH_MAX) return -1;"),
    ("src/fs/preview_io.c", "busy never cleared", "if (hdr[0] == g_pv_seq) g_pv_busy = 0;", "(void)0;"),
    ("src/fs/preview_io.c", "slot parity", "(seq & 1) * (size_t)PV_SHM_SLOT_SZ", "(size_t)0"),
    ("src/fs/preview_io.c", "oversized reply accepted", "if (hdr[2] > cap) goto broken;", "if (hdr[2] > cap + PREVIEW_BUF_SIZE) goto broken;"),
    ("src/fs/preview_io.c", "seq not advanced", "{++g_pv_seq,", "{g_pv_seq,"),
    # (the loop bound "got < PREVIEW_BUF_SIZE" is not mutated: a regular file fills the head in one read, so a lower bound is
    #  equivalent here)
    ("src/fs/preview_helper.c", "head read size", "PREVIEW_BUF_SIZE - got)", "PREVIEW_BUF_SIZE - got - 1)"),
    ("src/fs/preview_helper.c", "thumb for text requests", "err >= 0 && load_le32(&rq.treq)", "err >= 0"),
    ("src/fs/preview_helper.c", "pixel protocols upscale", "req->proto >= IMG_PROTO_SIXEL && ", "false && "),
    ("src/fs/preview_helper.c", "block cap ignored", "if (bytes > cap) return IMG_THUMB_HDR;", ""),
    ("src/fs/preview_helper.c", "zero box width divides", "req->w ? (ow * cols + req->w - 1) / req->w : 0", "(ow * cols + req->w - 1) / req->w"),
    ("src/fs/preview_helper.c", "kitty cols", "(ow * cols + req->w - 1) / req->w", "(ow * cols) / req->w"),
    ("src/fs/preview_helper.c", "sixel background", "req->bg, out + IMG_THUMB_HDR", "0, out + IMG_THUMB_HDR"),
    ("src/fs/preview_helper.c", "src size header", "put32(out + 4, (uint32_t)img->w);", "put32(out + 4, (uint32_t)img->h);"),
    ("src/fs/preview_helper.c", "size limit", "(uint64_t)st.size <= PV_MAX_IMG", "(uint64_t)st.size <= 64"),
    ("src/fs/preview_helper.c", "package preview skipped", "if (n >= 0) { *err = 0;", "if (n >= 1 << 30) { *err = 0;"),
    ("src/fs/preview_helper.c", "header fmt", "put32(out, (uint32_t)fmt);", "put32(out, 0);"),
]


def test_mutants(t: Path, scripts: tuple[str, str, str], expect: tuple[str, str, str]) -> None:
    srcs = {s: (ROOT / s).read_text() for s in SRCS}
    for f, name, old, _ in MUTANTS:
        assert old in srcs[f], f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, f: str, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            paths = []
            for s in SRCS:
                p = mt / Path(s).name
                p.write_text(srcs[s].replace(old, new, 1) if s == f else srcs[s])
                paths.append(str(p))
            try:
                exe = build("x86_64", mt, paths)
                noticed[name] = any(run(exe, "c", sc) != e for sc, e in zip(scripts, expect))
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] PV5. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C modules are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build("x86_64", t / "x86")
        thumbs, files = test_thumbs(exe, t)
        ipc = test_ipc(exe, t, files)
        scripts = (thumbs, ipc, test_fixed(exe, t))
        expect = tuple(run(exe, "c", sc) for sc in scripts)
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            for sc, e in zip(scripts[:2], expect[:2]):
                assert run(a64, "c", sc, "aarch64") == e, "qemu-aarch64 differs from x86_64"
            print("[PASS] PV4. qemu-aarch64: the C modules give the x86_64 results (thumbnails and the helper protocol)")
        else:
            print("[SKIP] PV4: aarch64 toolchain/qemu not installed")
        test_mutants(t, scripts, expect)
    print("ALL C PREVIEW TESTS PASSED.")


if __name__ == "__main__":
    main()
