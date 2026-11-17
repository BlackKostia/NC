#!/usr/bin/env python3
"""src/tui/input*.c and term_caps.c versus the frozen assembly (tests/harness/input*_reference.s, term_caps_reference.s):
random byte streams (keys, Alt, UTF-8 good/bad/split, CSI/SS3, SGR/X10 mouse, terminal replies, oversized or cut-off
sequences) fed through stdin files, the reply filter on random buffers, environment-driven protocol choice, pixel cell
size on a real pty, aux-fd wake-ups, SIGWINCH, EOF probing; plus scripted semantics and an aarch64 (qemu-user) run."""

import fcntl
import os
import pty
import random
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
REFS = ["input", "input_parse", "input_seq", "term_caps"]
CLI_C = ["tests/harness/input_cli.c", "src/tui/input.c", "src/tui/input_parse.c", "src/tui/input_seq.c", "src/tui/term_caps.c",
         "src/tui/kbd_map.c", "src/core/config.c", "src/core/config_parse.c", "src/core/config_load.c", "src/core/string.c",
         "src/core/string_path.c", "src/core/mem_prims.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/memory.c",
         "src/core/utf8.c"]
ENV = {"PATH": os.environ.get("PATH", "")}


def build(t: Path) -> Path:
    objs = []
    for m in REFS:
        o = t / f"{m}_ref.o"
        subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"),
                        str(ROOT / f"tests/harness/{m}_reference.s"), "-o", str(o)], check=True)
        objs.append(o)
    H.rename_defined_globals(objs, "ref_")
    return H.build("x86_64", t, CLI_C, objs)


def run(exe: Path, impl: str, *args: str, data: bytes = b"", env: dict | None = None, stdin=None) -> str:
    with tempfile.TemporaryFile() as f:
        f.write(data)
        f.seek(0)
        res = subprocess.run([str(exe), impl, *args], stdin=stdin or f, capture_output=True, env=env or ENV, timeout=60)
    assert res.returncode == 0, (impl, args, res.stderr)
    return res.stdout.decode("latin1")


def both(exe: Path, *args: str, **kw) -> str:
    r, c = run(exe, "ref", *args, **kw), run(exe, "c", *args, **kw)
    assert r == c, f"{args}: asm and C differ\n--- asm\n{r[:600]}\n--- C\n{c[:600]}"
    return c


# ---- random streams ----
def csi(rng: random.Random) -> bytes:
    kind = rng.randrange(7)
    nums = lambda: str(rng.choice([0, 1, 1, 2, 3, 4, 5, 6, 7, 8, 11, 15, 24, 99, rng.randrange(0, 300), 4294967295, 4294967297]))
    if kind == 0:
        return b"\x1b[" + rng.choice([b"A", b"B", b"C", b"D", b"H", b"F", b"Z", b"P", b"Q", b"R", b"S", b"X", b"@"])
    if kind == 1:
        return b"\x1b[" + nums().encode() + b"~"
    if kind == 2:
        return f"\x1b[{nums()};{nums()}{rng.choice('~ABCDHF')}".encode()
    if kind == 3:
        return f"\x1b[<{nums()};{nums()};{nums()}{rng.choice('Mm')}".encode()
    if kind == 4:
        return b"\x1b[M" + bytes(rng.randrange(0, 256) for _ in range(3))
    if kind == 5:
        return b"\x1b[" + rng.choice([b"?62;4;22c", b"?1;2c", b"6;20;10t", b"?6t", b"6;1t", b"?4c", b"1;2;3;4;5t", b"6;;t"])
    return b"\x1b[" + bytes(rng.choice(b"0123456789;:<=>? ") for _ in range(rng.randrange(0, 8))) + rng.choice([b"", b"m", b"\x01"])


def token(rng: random.Random) -> bytes:
    k = 9 if rng.random() < 0.02 else rng.choice([0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13])
    if k == 0:
        return bytes([rng.randrange(0x20, 0x7F)])
    if k == 1:
        return bytes([rng.randrange(0, 0x20)])
    if k == 2:
        return chr(rng.choice([rng.randrange(0x80, 0x800), rng.randrange(0x800, 0xD800), rng.randrange(0x10000, 0x110000)])).encode()
    if k == 3:
        return bytes([rng.randrange(0x80, 0x100)])                                  # stray continuation / lead byte
    if k == 4:
        return chr(rng.randrange(0x400, 0x500)).encode()[:1]                        # split multi-byte character
    if k == 5:
        return b"\x1b" + bytes([rng.randrange(0x20, 0x7F)])
    if k == 6:
        return b"\x1b" + chr(rng.randrange(0x80, 0x800)).encode()                   # Alt + non-ASCII
    if k == 7:
        return b"\x1bO" + bytes([rng.randrange(0x40, 0x60)])
    if k == 8:
        return b"\x1b"
    if k == 9:
        return b"\x1b[" + b"1;" * rng.randrange(100, 400)                           # oversized, unterminated CSI
    if k == 10:
        return b"\x1b\x1b"
    return csi(rng)


def stream(rng: random.Random) -> bytes:
    out = b"".join(token(rng) for _ in range(rng.randrange(1, 220)))
    return out[:rng.choice([len(out), len(out), rng.randrange(0, len(out) + 1)])]


def test_event_streams(exe: Path) -> None:
    rng = random.Random(20261117)
    total = 0
    for _ in range(260):
        data = stream(rng)
        out = both(exe, "events", data=data)
        total += out.count("\n")
    print(f"[PASS] IN1. {total} events from 260 random streams identical to the asm (incl. cut-off tails, 512-byte refills)")


def test_filter(exe: Path) -> None:
    rng = random.Random(7)
    for i in range(400):
        data = b"".join(token(rng) if rng.random() < 0.6 else csi(rng) for _ in range(rng.randrange(0, 40)))[:8000]
        both(exe, "filter", str(rng.randrange(0, 5) if data else 0), data=data)
    out = both(exe, "filter", "0", data=b"a\x1b[?62;4;22cb\x1b[6;20;10tc\x1b[Ad")
    assert "removed=21" in out and "left=61 62 63 1b 5b 41 64" in out and "proto=2" in out and "cw=10 ch=20" in out, out
    out = both(exe, "filter", "2", data=b"\x1b[?4c")
    assert "removed=0" in out, "a reply before `from` is not touched"
    print("[PASS] IN2. term_caps_filter identical on 400 random buffers; DA1 -> Sixel and CSI 6;h;w t -> 10x20 cell recorded")


def test_init_and_uint(exe: Path) -> None:
    cases = [{}, {"DUOP_IMG_MODE": "sixel"}, {"DUOP_IMG_MODE": "KITTY"}, {"DUOP_IMG_MODE": "HalfBlock"}, {"DUOP_IMG_MODE": "bogus"},
             {"DUOP_IMG_MODE": ""}, {"KITTY_WINDOW_ID": "1"}, {"TERM": "xterm-KiTTy"}, {"TERM": "xterm"}, {"TERM_PROGRAM": "WezTerm"},
             {"TERM_PROGRAM": "ghostty"}, {"TERM_PROGRAM": "iTerm", "DUOP_IMG_MODE": "sixel", "TERM": "kitty"}]
    seen = set()
    for extra in cases:
        out = both(exe, "init", env={**ENV, **extra})
        seen.add(out.splitlines()[0].split()[0])
    assert seen == {"proto=0", "proto=1", "proto=2", "proto=3"}, seen
    for s in ("0", "7", "123", "4294967295", "4294967296", "99999999999", "12ab", "", "x", "007"):
        both(exe, "uint", s)
    assert both(exe, "uint", "4294967297").strip() == "v=1"
    print("[PASS] IN3. protocol choice (DUOP_IMG_MODE, Kitty/WezTerm/Ghostty env, DA1 override) and parse_uint wrap identical to the asm")


def test_refresh(exe: Path) -> None:
    for cols, rows, xp, yp in ((80, 24, 800, 480), (81, 25, 1000, 700), (0, 24, 800, 480), (80, 0, 800, 480), (80, 24, 0, 480),
                               (80, 24, 800, 0), (100, 50, 99, 49)):
        outs = []
        for impl in ("ref", "c"):
            m, s = pty.openpty()
            fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", rows or 1, cols or 1, xp, yp))
            res = subprocess.run([str(exe), impl, "refresh", str(cols), str(rows)], stdin=subprocess.DEVNULL, stdout=s, stderr=subprocess.PIPE, env=ENV)
            os.close(s)
            assert res.returncode == 0, res.stderr
            outs.append(os.read(m, 4096).decode().replace("\r", ""))
            os.close(m)
        assert outs[0] == outs[1], (cols, rows, xp, yp, outs)
    m, s = pty.openpty()
    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 800, 480))
    out = subprocess.run([str(exe), "c", "refresh", "80", "24"], stdin=subprocess.DEVNULL, stdout=s, env=ENV).returncode
    assert out == 0 and "cw=10 ch=20" in os.read(m, 4096).decode(), "pixels / cells"
    print("[PASS] IN4. term_caps_refresh (pty pixel size, zero cols/rows/pixels -> CSI reply fallback) identical to the asm")


def test_misc(exe: Path) -> None:
    for impl in ("ref", "c"):
        assert run(exe, impl, "winch").split() == ["r=1", "t=3", "again=0"], impl
    both(exe, "winch")
    assert both(exe, "probe", data=b"").strip() == "eof=1"
    assert both(exe, "probe", data=b"abc").strip() == "eof=0"
    r, w = os.pipe()
    out = both(exe, "probe", stdin=r)
    os.close(w)
    os.close(r)
    assert out.strip() == "eof=0", "an open idle pipe is not EOF"
    held = []
    for impl in ("ref", "c"):                                     # stdin: an idle pipe whose writer stays open
        r, w = os.pipe()
        held.append((r, w))
        res = run(exe, impl, "aux", "5000", stdin=r)
        assert res.split() == ["aux_r=0", "aux_fast=1", "none_r=0", "none_waited=1"], (impl, res)
    for r, w in held:
        os.close(r)
        os.close(w)
    print("[PASS] IN5. SIGWINCH flag, EOF probe (file/empty/idle pipe) and aux-fd early wake-up behave like the asm")


def piped(exe: Path, impl: str, chunks: list[tuple[float, bytes]]) -> str:
    """Feed chunks with delays through a pipe, then close it: the timing-dependent ESC / split-sequence paths."""
    r, w = os.pipe()
    p = subprocess.Popen([str(exe), impl, "events"], stdin=r, stdout=subprocess.PIPE, env=ENV)
    os.close(r)
    for delay, data in chunks:
        time.sleep(delay)
        os.write(w, data)
    time.sleep(0.15)
    os.close(w)
    out = p.communicate(timeout=30)[0].decode()
    return "\n".join(l for l in out.splitlines() if l.startswith("r=") and "r=-2" not in l)


def test_timing(exe: Path) -> None:
    scripts = {
        "esc_then_late_key": [(0.05, b"\x1b"), (0.3, b"a")],
        "esc_sequence_split": [(0.05, b"\x1b"), (0.005, b"[A")],
        "csi_split_mid": [(0.05, b"\x1b[1;"), (0.005, b"5A")],
        "utf8_split": [(0.05, b"\xd0"), (0.004, b"\xb9")],
        "mouse_split": [(0.05, b"\x1b[<0;10"), (0.004, b";5M")],
        "alt_utf8_split": [(0.05, b"\x1b\xd0"), (0.004, b"\xb9")],
    }
    for name, chunks in scripts.items():
        results = []
        for _ in range(3):
            r, c = piped(exe, "ref", chunks), piped(exe, "c", chunks)
            assert r == c, f"{name}:\n{r}\n---\n{c}"
            results.append(c)
        assert len(set(results)) == 1, f"{name}: unstable"
    assert "k=10000f" in piped(exe, "c", scripts["esc_then_late_key"]).splitlines()[0], "lone ESC after the 25 ms wait"
    assert "k=100001" in piped(exe, "c", scripts["esc_sequence_split"]).splitlines()[0], "ESC [ A within 25 ms is the Up key"
    print("[PASS] IN6. timing paths (lone ESC vs sequence, split CSI / UTF-8 / mouse / Alt+UTF-8) equal the asm and are stable")


def test_semantics(exe: Path) -> None:
    ev = lambda data: [l.split() for l in run(exe, "c", "events", data=data).splitlines() if l.startswith("r=1")]
    assert ev(b"q\r\t\x7f\x03")[0][3] == "k=71"
    rows = ev(b"\x1b[1;5A\x1b[<35;10;5M\x1b[<0;3;4m\x1b[<64;1;1M\x1bOQ\x1b[24~\x1bx")
    assert rows[0][2:4] == ["m=4", "k=100001"], rows[0]
    assert rows[1][1] == "t=2" and rows[1][4:7] == ["x=9", "y=4", "b=3"] and rows[1][7] == "a=4", rows[1]       # motion, no button
    assert rows[2][7] == "a=2" and rows[2][4:6] == ["x=2", "y=3"], rows[2]                                      # 'm' = release
    assert rows[3][6] == "b=64" and rows[3][7] == "a=5", rows[3]                                                # wheel up
    assert rows[4][3] == "k=100012" and rows[5][3] == "k=10001c" and rows[6][2:4] == ["m=2", "k=78"], rows
    print("[PASS] IN7. keys, modifiers, SGR press/release/motion/wheel, SS3 and tilde keys decode as documented")


def test_aarch64(x86: Path) -> None:
    if not H.available("aarch64"):
        print("[SKIP] IN8: aarch64 toolchain/qemu unavailable")
        return
    with H.workdir() as d:
        exe = H.build("aarch64", Path(d), CLI_C + ["tests/harness/input_ref_stubs.c"])
        rng = random.Random(99)
        for data in [b"a\x1b[1;2A\x1b[<0;4;5M\xd0\xb9\x1bx\x1b[?62;4c\x1b[6;18;9t\x1b[15~"] + [stream(rng) for _ in range(12)]:
            with tempfile.TemporaryFile() as f:
                f.write(data)
                f.seek(0)
                res = subprocess.run(["qemu-aarch64", str(exe), "c", "events"], stdin=f, capture_output=True, timeout=60)
            assert res.stdout.decode() == run(x86, "c", "events", data=data), "aarch64 and x86_64 decode differently"
        print("[PASS] IN8. the C input stack decodes 13 streams identically on aarch64 (qemu-user) and x86_64")


def main() -> None:
    with H.workdir() as d:
        exe = build(Path(d))
        test_event_streams(exe)
        test_filter(exe)
        test_init_and_uint(exe)
        test_refresh(exe)
        test_misc(exe)
        test_timing(exe)
        test_semantics(exe)
        test_aarch64(exe)
    print("ALL C INPUT TESTS PASSED.")


if __name__ == "__main__":
    main()
