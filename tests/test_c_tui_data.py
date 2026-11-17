#!/usr/bin/env python3
"""src/tui/{theme,kbd_map,kbd_layout,data_dirs,screen_rect}.c versus the frozen assembly (tests/harness/*_reference.s):
random themes/duoprc colours, layout files, screen rectangles (host differential), the real directory scan on the
kernel stack (binary dir, symlinks, env lists, XDG/HOME) and an aarch64 (qemu-user) smoke run."""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
HOST_CFLAGS = [f for f in H.COMMON if f != "-ffreestanding"] + ["-fno-stack-clash-protection"]
PAL_INC = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
DIFF_C = ["src/tui/theme.c", "src/tui/kbd_map.c", "src/tui/screen_rect.c", "src/core/config.c", "src/core/config_parse.c",
          "src/core/config_load.c", "src/core/string.c", "src/core/string_path.c", "src/core/utf8.c"]
CLI_C = ["tests/harness/data_dirs_cli.c", "src/tui/data_dirs.c", "src/core/config.c", "src/core/config_parse.c",
         "src/core/config_load.c", "src/core/string.c", "src/core/string_path.c", "src/core/mem_prims.c", "src/core/syscall.c",
         "src/core/try_rt.c", "src/core/memory.c", "src/core/utf8.c"]


def ref_object(tmp: Path, name: str) -> Path:
    o = tmp / f"{name}_ref.o"
    subprocess.run(["as", *PAL_INC, str(ROOT / f"tests/harness/{name}_reference.s"), "-o", str(o)], check=True)
    return o


def test_differential() -> None:
    with H.workdir() as d:
        t = Path(d)
        refs = [ref_object(t, n) for n in ("theme", "kbd_map", "screen_rect")]
        H.rename_defined_globals(refs, "ref_")
        objs = [str(o) for o in refs]
        for i, c in enumerate(DIFF_C):
            o = t / f"c{i}.o"
            subprocess.run(["gcc", *HOST_CFLAGS, "-c", str(ROOT / c), "-o", str(o)], check=True)
            objs.append(str(o))
        simd = t / "pal_simd.o"
        subprocess.run(["as", *PAL_INC, str(ROOT / "src/os/linux/x86_64/pal_simd.s"), "-o", str(simd)], check=True)
        exe = t / "diff"
        link = subprocess.run(["gcc", "-O2", "-no-pie", "-w", "-I", str(ROOT / "include"),
                               str(ROOT / "tests/harness/tui_data_diff.c"), *objs, str(simd), "-o", str(exe)], capture_output=True, text=True)
        assert link.returncode == 0, link.stderr[-2000:]
        res = subprocess.run([str(exe)], capture_output=True, text=True, timeout=600)
        assert res.returncode == 0, res.stdout + res.stderr
        print("[PASS] TU1.", res.stdout.strip())


def build_cli(t: Path) -> Path:
    ref = ref_object(t, "data_dirs")
    H.rename_defined_globals([ref], "ref_")
    return H.build("x86_64", t, CLI_C, [ref])


def scan(exe: Path, env: dict[str, str]) -> tuple[list[str], list[str]]:
    res = subprocess.run([str(exe), "scan"], capture_output=True, env=env, timeout=30)
    assert res.returncode == 0, res.stderr
    lines = res.stdout.decode().splitlines()
    return [l[2:] for l in lines if l.startswith("R ")], [l[2:] for l in lines if l.startswith("C ")]


def test_scan() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build_cli(t)
        tree = t / "tree"
        for rel in ("cfg/duop/layouts", "home/.config/duop/layouts", "bin/layouts", "share/duop/layouts", "real/layouts", "l1", "l2"):
            (tree / rel).mkdir(parents=True)
        names = ["a.layout", "b.layout", ".hidden.layout", "c.txt", ".layout", "d.layout.bak", "ü.layout"]
        for rel in ("cfg/duop/layouts", "home/.config/duop/layouts", "bin/layouts", "share/duop/layouts", "real/layouts", "l1", "l2"):
            for n in names:
                (tree / rel / f"{rel.replace('/', '_')}_{n}" if n.startswith("a") else tree / rel / n).write_text("x")
        (tree / "bin/layouts/sub.layout").mkdir()                      # a directory with a matching name is still handed over
        shutil.copy(exe, tree / "bin/prog")
        shutil.copy(exe, tree / "real/prog")
        os.makedirs(tree / "links")
        os.symlink("../real/prog", tree / "links/rel")                 # relative symlink: resolves to real/layouts
        os.symlink(tree / "real/prog", tree / "links/abs")             # absolute symlink
        base = {"PATH": os.environ["PATH"]}
        cases = {
            "env_list": ({"DUOP_TESTDATA": f"{tree}/l1:{tree}/l2::{tree}/missing:{tree}/l1"}, "bin/prog"),
            "env_empty": ({"DUOP_TESTDATA": "", "XDG_CONFIG_HOME": f"{tree}/cfg"}, "bin/prog"),
            "xdg": ({"XDG_CONFIG_HOME": f"{tree}/cfg", "HOME": f"{tree}/home"}, "bin/prog"),
            "home": ({"HOME": f"{tree}/home"}, "bin/prog"),
            "home_empty_xdg": ({"XDG_CONFIG_HOME": "", "HOME": f"{tree}/home"}, "bin/prog"),
            "none": ({}, "bin/prog"),
            "rel_link": ({"HOME": f"{tree}/home"}, "links/rel"),
            "abs_link": ({}, "links/abs"),
            "long_entry": ({"DUOP_TESTDATA": "/" + "x" * 5000 + f":{tree}/l1"}, "bin/prog"),
        }
        for name, (env, prog) in cases.items():
            r, c = scan(tree / prog, {**base, **env})
            assert r == c, f"{name}: asm {r} != C {c}"
            if name in ("env_list", "xdg", "rel_link", "abs_link", "none"):
                assert r, f"{name}: nothing was scanned"
        r, c = scan(tree / "links/rel", {**base, "HOME": f"{tree}/home"})
        assert any("/real/layouts/" in l for l in r), f"relative symlink must resolve to the real binary dir: {r}"
        r, c = scan(tree / "bin/prog", {**base, "DUOP_TESTDATA": f"{tree}/l1"})
        assert not any(".hidden" in l or "c.txt" in l for l in c), c
        print("[PASS] TU2. data_dirs scan order identical to the asm in 9 environments (env list, XDG, HOME, symlinks, long entry)")


def test_read_file() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build_cli(t)
        f = t / "f.txt"
        for body in (b"", b"abc", b"x" * 100, bytes(b if b not in (0, 10) else 65 for b in os.urandom(3000))):
            f.write_bytes(body)
            for cap in (1, 2, 3, 4, 50, 101, 4096, 60000):
                lines = subprocess.run([str(exe), "read", str(f), str(cap)], capture_output=True, timeout=30).stdout.decode("latin1").split("\n")
                r, c = lines[0][2:], lines[1][2:]
                assert r == c, (len(body), cap, r[:40], c[:40])
                assert lines[2] == "TAIL intact ", lines[2]
        r = subprocess.run([str(exe), "read", str(t / "missing"), "10"], capture_output=True).stdout.decode().splitlines()
        assert r[0] == "R -1 " and r[1] == "C -1 ", r
        c0 = subprocess.run([str(exe), "read", str(f), "0"], capture_output=True).stdout.decode().splitlines()
        assert c0[1] == "C -1 " and c0[2] == "TAIL intact ", c0
        print("[PASS] TU3. data_read_file identical to the asm for 4 sizes x 8 caps; cap 0 refused without touching memory")


def test_aarch64() -> None:
    if not H.available("aarch64"):
        print("[SKIP] TU4: aarch64 toolchain/qemu unavailable")
        return
    with H.workdir() as d:
        t = Path(d)
        exe = H.build("aarch64", t, [c for c in CLI_C if c != "tests/harness/data_dirs_cli.c"] + ["tests/harness/data_dirs_a64.c"])
        tree = t / "tree"
        (tree / "l1").mkdir(parents=True)
        (tree / "l1/k.layout").write_text("keys = q\nchars = й\n")
        res = H.run("aarch64", exe, ["scan"], stdin=b"")
        assert res.returncode == 0, res.stderr
        env_run = subprocess.run(["qemu-aarch64", "-E", f"DUOP_TESTDATA={tree}/l1", str(exe), "scan"], capture_output=True)
        assert env_run.stdout.decode().strip() == f"C {tree}/l1/k.layout k.layout", env_run.stdout
        print("[PASS] TU4. data_dirs.c scans a $DUOP_TESTDATA list on aarch64 (qemu-user)")


def main() -> None:
    test_differential()
    test_scan()
    test_read_file()
    test_aarch64()
    print("ALL C TUI DATA TESTS PASSED.")


if __name__ == "__main__":
    main()
