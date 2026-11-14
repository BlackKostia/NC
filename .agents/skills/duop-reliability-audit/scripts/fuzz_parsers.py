#!/usr/bin/env python3
"""Mutation fuzzer for every Duop input parser, driven through the real UI in a PTY.

  python3 fuzz_parsers.py [--target T] [--iters N] [--seed S] [--out DIR]

Targets (default: all):
  image    PNG/JPEG/GIF/BMP/TGA/PPM/QOI decoded in-process by the viewer (F3 -> Image)
  archive  tar / tar.gz / zip opened as a VFS panel, first member viewed (inflate)
  lang     *.lang interface packs (DUOP_LANGS) selected with --lang
  layout   *.layout keyboard maps (DUOP_LAYOUTS)
  config   duoprc (XDG_CONFIG_HOME)
  pkg      manifest.ini of installed packages listed in the package manager (Alt+K)

Mutations: truncation, byte flips to boundary values, huge length/dimension fields, inserted
NULs / long lines. A crash (Duop exits by a signal or hangs > 5 s) is saved to --out with the
input that triggered it; the run exits 1 when anything was found.
"""

from __future__ import annotations

import argparse
import io
import os
import random
import shutil
import struct
import tarfile
import tempfile
import time
import zipfile

from PIL import Image

from rt_common import alive, describe_status, kill, launch, read_raw, wait_exit

ROOT_LANG = os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "lang", "uk.lang")


def mutate(data: bytes, rnd: random.Random) -> bytes:
    d = bytearray(data)
    r = rnd.random()
    if r < 0.2 and d:
        return bytes(d[:rnd.randint(0, len(d))])
    if r < 0.3:
        pos = rnd.randrange(len(d) + 1)
        return bytes(d[:pos] + rnd.choice([b"\x00" * 64, b"A" * 5000, b"\n" * 300, b"=" * 900]) + d[pos:])
    for _ in range(rnd.randint(1, 16)):
        if not d:
            break
        i = rnd.randrange(len(d))
        d[i] = rnd.choice([0, 0xFF, 0x7F, 0x80, ord("="), ord("\n"), rnd.randrange(256)])
    if r > 0.85 and len(d) > 24:
        off = rnd.choice([4, 6, 8, 12, 16, 18, 20])
        d[off:off + 4] = b"\xff\xff\x7f\xff"
    return bytes(d)


def image_seeds():
    im = Image.new("RGB", (37, 23))
    im.putdata([(i * 7 % 256, i * 13 % 256, i * 29 % 256) for i in range(37 * 23)])
    out = []
    for fmt, ext, kw in (("PNG", "png", {}), ("JPEG", "jpg", {"quality": 80}), ("GIF", "gif", {}),
                         ("BMP", "bmp", {}), ("TGA", "tga", {}), ("PPM", "ppm", {})):
        b = io.BytesIO()
        im.save(b, fmt, **kw)
        out.append((ext, b.getvalue()))
    q = bytearray(b"qoif" + struct.pack(">IIBB", 37, 23, 3, 0))
    for p in im.getdata():
        q += bytes([0xFE, *p])
    out.append(("qoi", bytes(q + b"\x00" * 7 + b"\x01")))
    return out


def archive_seeds():
    files = {"a.txt": b"hello " * 300, "dir/b.bin": bytes(range(256)) * 40, "dir/sub/c.txt": b"x" * 10}
    out = []
    for mode, ext in (("w", "tar"), ("w:gz", "tar.gz")):
        b = io.BytesIO()
        with tarfile.open(fileobj=b, mode=mode, format=tarfile.USTAR_FORMAT) as t:
            for n, data in files.items():
                ti = tarfile.TarInfo(n)
                ti.size = len(data)
                t.addfile(ti, io.BytesIO(data))
        out.append((ext, b.getvalue()))
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_DEFLATED) as z:
        for n, data in files.items():
            z.writestr(n, data)
    out.append(("zip", b.getvalue()))
    return out


class Fuzzer:
    def __init__(self, args):
        self.rnd = random.Random(args.seed)
        self.iters, self.out = args.iters, args.out
        self.crashes = 0

    def record(self, target, name, data, why):
        os.makedirs(self.out, exist_ok=True)
        path = os.path.join(self.out, f"{target}-{int(time.time() * 1000)}-{name}")
        open(path, "wb").write(data)
        self.crashes += 1
        print(f"CRASH [{target}] {why} -- input saved to {path}", flush=True)

    def check(self, s, target, name, data):
        if not alive(s.pid):
            self.record(target, name, data, describe_status(wait_exit(s.pid, 0.1)))
            return False
        return True

    # -- UI-driven targets: one Duop session walks many mutated files --------------------------
    def files_session(self, target, seeds, keys):
        tmp = tempfile.mkdtemp()
        left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
        os.makedirs(left)
        os.makedirs(right)
        made = []
        for i in range(self.iters):
            ext, seed = self.rnd.choice(seeds)
            name = f"f{i:04d}.{ext}"
            data = mutate(seed, self.rnd)
            open(os.path.join(left, name), "wb").write(data)
            made.append((name, data))
        s = launch(["--lang", "en", left, right], {"HOME": tmp})
        try:
            read_raw(s, 0.6)
            for name, data in sorted(made):
                for k, w in keys:
                    os.write(s.master, k)
                    read_raw(s, w)
                if not self.check(s, target, name, data):
                    break
            else:
                print(f"[{target}] survived {len(made)} mutants")
        finally:
            kill(s)
            shutil.rmtree(tmp, ignore_errors=True)

    # -- startup targets: a fresh Duop per mutated data file ---------------------------------
    def startup(self, target, seed, place, extra_keys=b""):
        survived = 0
        for i in range(self.iters):
            tmp = tempfile.mkdtemp()
            os.makedirs(os.path.join(tmp, "l"))
            os.makedirs(os.path.join(tmp, "r"))
            data = mutate(seed, self.rnd)
            env, args = place(tmp, data)
            s = launch(args + [os.path.join(tmp, "l"), os.path.join(tmp, "r")], env)
            try:
                read_raw(s, 0.35)
                if extra_keys:
                    os.write(s.master, extra_keys)
                    read_raw(s, 0.3)
                if self.check(s, target, f"{i}", data):
                    survived += 1
            finally:
                kill(s)
                shutil.rmtree(tmp, ignore_errors=True)
        print(f"[{target}] survived {survived}/{self.iters} mutants")


def place_lang(tmp, data):
    d = os.path.join(tmp, "lang")
    os.makedirs(d)
    open(os.path.join(d, "xx.lang"), "wb").write(data)
    return {"HOME": tmp, "DUOP_LANGS": d}, ["--lang", "xx"]


def place_layout(tmp, data):
    d = os.path.join(tmp, "lay")
    os.makedirs(d)
    open(os.path.join(d, "xx.layout"), "wb").write(data)
    return {"HOME": tmp, "DUOP_LAYOUTS": d}, ["--lang", "en"]


def place_config(tmp, data):
    d = os.path.join(tmp, "cfg", "duop")
    os.makedirs(d)
    open(os.path.join(d, "duoprc"), "wb").write(data)
    return {"HOME": tmp, "XDG_CONFIG_HOME": os.path.join(tmp, "cfg")}, ["--lang", "en"]


def place_pkg(tmp, data):
    d = os.path.join(tmp, "pkgs", "fz")
    os.makedirs(d)
    open(os.path.join(d, "manifest.ini"), "wb").write(data)
    open(os.path.join(d, "sha256"), "w").write("0" * 64)
    return {"HOME": tmp, "DUOP_PKG_DIR": os.path.join(tmp, "pkgs")}, ["--lang", "en"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="all")
    ap.add_argument("--iters", type=int, default=60)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "duop-fuzz-crashes"))
    args = ap.parse_args()
    f = Fuzzer(args)
    lang_seed = open(ROOT_LANG, "rb").read() if os.path.exists(ROOT_LANG) else b"code = XX\n"
    layout_seed = b"keys  = qwertyuiop\nchars = \xd0\xb9\xd1\x86\xd1\x83\xd0\xba\xd0\xb5\xd0\xbd\xd0\xb3\xd1\x88\xd1\x89\xd0\xb7\n"
    config_seed = (b"theme = catppuccin\nlang = en\nshow_hidden = on\nsort = size\n"
                   b"color accent = #ff8800\nbind alt+x = quit\nopen txt = cat %f\n"
                   b"menu Test = echo \"%p\"\n")
    pkg_seed = (b"name = fz\nversion = 1.0.0\nkind = tool\ndescription = fuzz\nexec = fz\n"
                b"menu = Fuzz\nargs = --cwd {dir} {path}\nscope = any\nmode = tui\n")
    targets = {
        "image": lambda: f.files_session("image", image_seeds(),
                                         [(b"\x1b[B", 0.03), (b"\x1bOR", 0.12), (b"i", 0.25), (b"\x1b", 0.08), (b"\x1b", 0.05)]),
        "archive": lambda: f.files_session("archive", archive_seeds(),
                                           [(b"\x1b[B", 0.03), (b"\r", 0.15), (b"\x1b[B", 0.03), (b"\x1bOR", 0.15),
                                            (b"\x1b", 0.08), (b"\x7f", 0.12)]),
        "lang": lambda: f.startup("lang", lang_seed, place_lang, b"\x1bOP"),
        "layout": lambda: f.startup("layout", layout_seed, place_layout, b"\x1b\xd0\xb4"),
        "config": lambda: f.startup("config", config_seed, place_config, b"\x1bu"),
        "pkg": lambda: f.startup("pkg", pkg_seed, place_pkg, b"\x1bk"),
    }
    chosen = targets if args.target == "all" else {args.target: targets[args.target]}
    for name, run in chosen.items():
        run()
    print(f"FUZZ: {f.crashes} crashes" + (f" (inputs in {args.out})" if f.crashes else ""))
    return 1 if f.crashes else 0


if __name__ == "__main__":
    raise SystemExit(main())
