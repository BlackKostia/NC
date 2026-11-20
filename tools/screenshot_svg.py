#!/usr/bin/env python3
"""Reproducible README screenshots: runs ./duop on a deterministic demo tree inside a pseudo-terminal, replays a key script,
and renders the VirtualTerminal cell grid (text + TrueColor fg/bg, tests/pty_session.py) to SVG files in docs/media/.

    python3 tools/screenshot_svg.py [--bin ./duop] [--out docs/media] [--only main,palette]
"""

import argparse
import copy
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tests"))
from pty_session import PtySession  # noqa: E402

COLS, ROWS = 110, 30
CELL_W, CELL_H, FONT = 8.4, 17, 14
EPOCH = 1763640000  # 2025-11-20 12:00 UTC: fixed mtimes keep the "Modified" column stable

DOWN, F9, F10, CTRL_K, ALT_T = b"\x1b[B", b"\x1b[20~", b"\x1b[21~", b"\x0b", b"\x1bt"
TAB = b"\t"

DEMO_FILES = {
    "project/src/main.c": '#include "duop_abi.h"\n\n/* Entry point: no libc, straight to the kernel */\nint duop_main(int argc, char **argv)\n{\n    App *app = app_new(argc, argv);\n    if (!app)\n        return 1;\n    return app_run(app);\n}\n',
    "project/src/pal_start.s": ".intel_syntax noprefix\n.global _start\n_start:\n    mov rdi, rsp\n    call duop_entry\n",
    "project/src/screen.c": "/* TrueColor diff renderer */\nvoid screen_flush(ScreenBuffer *sb)\n{\n    /* emit only changed cells */\n}\n",
    "project/Makefile": "CFLAGS := -std=gnu2x -Os -ffreestanding\nduop: $(OBJS)\n\t$(LD) -s $^ -o $@\n",
    "project/README.md": "# Demo project\n\nA tiny tree for Duop screenshots.\n",
    "project/config.json": '{\n  "theme": "Tokyo Night",\n  "lang": "en",\n  "preview": true\n}\n',
    "project/build.sh": "#!/bin/sh\nmake release\n",
    "project/notes.txt": "Ship v2.7.0\n",
    "media/photos/.keep": "",
    "media/music/.keep": "",
    "media/report-2026.pdf": "%PDF-1.7\n" + "x" * 48000,
    "media/backup.tar.gz": "\x1f\x8b" + "y" * 250000,
    "media/video.mkv": "z" * 900000,
    "media/logo.qoi": "qoif" + "w" * 5000,
}


def run_git(cwd, *args):
    env = dict(os.environ, GIT_AUTHOR_NAME="duop", GIT_AUTHOR_EMAIL="duop@example.org", GIT_COMMITTER_NAME="duop",
               GIT_COMMITTER_EMAIL="duop@example.org", GIT_AUTHOR_DATE=f"@{EPOCH} +0000", GIT_COMMITTER_DATE=f"@{EPOCH} +0000")
    subprocess.run(["git", *args], cwd=cwd, env=env, check=True, capture_output=True)


def build_demo(base: Path):
    for rel, text in DEMO_FILES.items():
        p = base / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="latin-1")
    proj = base / "project"
    if shutil.which("git"):
        run_git(proj, "init", "-q", "-b", "main")
        run_git(proj, "add", ".")
        run_git(proj, "commit", "-q", "-m", "init")
        (proj / "src/screen.c").write_text(DEMO_FILES["project/src/screen.c"] + "/* dirty */\n")
        (proj / "CHANGELOG.md").write_text("## 2.7.0\n")
    for dirpath, dirs, files in os.walk(base):
        for name in dirs + files:
            p = Path(dirpath) / name
            if ".git" not in p.parts or p.name == ".git":
                os.utime(p, (EPOCH, EPOCH), follow_symlinks=False)


# name -> (extra argv, key script [(bytes, wait_s)], extra env)
SCENES = {
    "main": ([], [], {}),
    "palette": ([], [(CTRL_K, 0.8)], {}),
    "preview": ([], [(DOWN, 0.2), (DOWN, 0.2), (b"\r", 0.5), (DOWN, 0.2), (F9, 1.2)], {}),
    "theme": ([], [(ALT_T, 0.6), (TAB, 0.4)], {}),
    "ukrainian": (["--lang", "ua"], [], {}),
}


def capture(binary: str, demo: Path, scene: str):
    extra, keys, env = SCENES[scene]
    home = demo / "home"
    home.mkdir(exist_ok=True)
    env = dict(env, HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"), XDG_STATE_HOME=str(home / ".state"),
               DUOP_IMG_MODE="blocks", COLORTERM="truecolor")
    s = PtySession(binary, extra + [str(demo / "project"), str(demo / "media")], cols=COLS, rows=ROWS, extra_env=env)
    try:
        s.drain(1.5)
        for seq, wait in keys:
            s.send(seq, wait)
        s.drain(0.4)
        return copy.deepcopy(s.vt)  # snapshot now: the cleanup below closes dialogs and quits
    finally:
        s.send(b"\x1b\x1b", 0.1)
        s.send(F10, 0.2)
        try:
            s.wait_exit(1.5)
        except Exception:  # noqa: BLE001 - screenshots must never hang on a stuck child
            os.kill(s.pid, 9)


def hexc(rgb, default):
    return default if rgb is None else "#%02x%02x%02x" % rgb


def esc(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def runs(row_vals):
    """Yield (start, end, value) for maximal runs of equal values."""
    start = 0
    for i in range(1, len(row_vals) + 1):
        if i == len(row_vals) or row_vals[i] != row_vals[start]:
            yield start, i, row_vals[start]
            start = i


def to_svg(vt, title: str) -> str:
    w, h = COLS * CELL_W, ROWS * CELL_H
    default_bg = hexc(vt.bg[ROWS // 2][COLS // 2], "#1a1b26")
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w + 24:.0f} {h + 44:.0f}" '
           f'font-family="\'JetBrains Mono\',\'DejaVu Sans Mono\',Menlo,Consolas,monospace" font-size="{FONT}">',
           f"<title>{esc(title)}</title>",
           f'<rect width="100%" height="100%" rx="10" fill="{default_bg}"/>',
           '<circle cx="18" cy="15" r="5" fill="#ff5f57"/><circle cx="36" cy="15" r="5" fill="#febc2e"/>'
           '<circle cx="54" cy="15" r="5" fill="#28c840"/>',
           '<g transform="translate(12,32)">']
    for r in range(ROWS):
        y = r * CELL_H
        for a, b, bg in runs([hexc(c, default_bg) for c in vt.bg[r]]):
            if bg != default_bg:
                out.append(f'<rect x="{a * CELL_W:.1f}" y="{y}" width="{(b - a) * CELL_W:.1f}" height="{CELL_H}" fill="{bg}"/>')
        keys = [(hexc(vt.fg[r][c], "#c0caf5"),) for c in range(COLS)]
        for a, b, (fg,) in runs(keys):
            text = "".join(vt.grid[r][a:b])
            if not text.strip():
                continue
            out.append(f'<text x="{a * CELL_W:.1f}" y="{y + CELL_H - 4}" fill="{fg}" textLength="{(b - a) * CELL_W:.1f}" '
                       f'lengthAdjust="spacingAndGlyphs" xml:space="preserve">{esc(text)}</text>')
    out.append("</g></svg>\n")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--bin", default=str(ROOT / "duop"))
    ap.add_argument("--out", default=str(ROOT / "docs" / "media"))
    ap.add_argument("--only", default="", help="comma-separated scene names (%s)" % ",".join(SCENES))
    args = ap.parse_args()
    binary = os.path.abspath(args.bin)
    if not os.access(binary, os.X_OK):
        sys.exit(f"binary not found: {binary} (run 'make release')")
    scenes = [s for s in args.only.split(",") if s] or list(SCENES)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    demo = Path(tempfile.gettempdir()) / "duop-demo"  # fixed path: it is printed in the pane headers
    shutil.rmtree(demo, ignore_errors=True)
    demo.mkdir()
    try:
        build_demo(demo)
        for scene in scenes:
            vt = capture(binary, demo, scene)
            (out / f"{scene}.svg").write_text(to_svg(vt, f"Duop — {scene}"), encoding="utf-8")
            if os.environ.get("DUOP_SHOT_TXT"):
                (out / f"{scene}.txt").write_text(vt.full_text() + "\n", encoding="utf-8")
            print(f"{out / (scene + '.svg')}")
    finally:
        shutil.rmtree(demo, ignore_errors=True)


if __name__ == "__main__":
    main()
