#!/usr/bin/env python3
"""duoprc size handling (audit 2026-11-16): a big config is never silently thrown away.

CF1 a 40 KB / 300 KB config applies its last directive too (old limit: whole file ignored above 16 KiB)
CF2 a config beyond the hard limit keeps its first 1 MiB and warns in the status bar (EN/UA)
"""

import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_pty import PtySession  # noqa: E402

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.environ.get("DUOP", os.path.join(REPO_ROOT, "duop"))
PAD = "# padding line to grow the file ..........................................\n"


def start(tmp: str, cfg_text: str, lang: str = "en") -> PtySession:
    for d in ("l", "r"):
        os.makedirs(os.path.join(tmp, d), exist_ok=True)
    cfg = os.path.join(tmp, "duoprc")
    with open(cfg, "w") as f:
        f.write(cfg_text)
    sess = PtySession(BINARY, ["--lang", lang, os.path.join(tmp, "l"), os.path.join(tmp, "r")],
                      extra_env={"DUOP_CONFIG": cfg, "HOME": tmp})
    sess.drain(0.8)
    return sess


def kill(sess: PtySession) -> None:
    try:
        os.kill(sess.pid, 9)
        os.waitpid(sess.pid, 0)
    except OSError:
        pass
    try:
        os.close(sess.master)
    except OSError:
        pass


def test_large_configs_apply_fully() -> None:
    for lines in (500, 4000):                           # ~39 KB and ~310 KB
        with tempfile.TemporaryDirectory(prefix="cf1_") as tmp:
            sess = start(tmp, PAD * lines + "theme 1\n")
            try:
                assert "Catppuccin" in sess.vt.full_text(), f"{lines * len(PAD)} byte config: last directive ignored"
                assert "Config file too large" not in sess.vt.full_text(), "spurious size warning"
            finally:
                kill(sess)
    print("[PASS] CF1. Configs far beyond 16 KiB are applied completely")


def test_oversized_config_warns() -> None:
    for lang, needle in (("en", "Config file too large"), ("ua", "Файл налаштувань завеликий")):
        with tempfile.TemporaryDirectory(prefix="cf2_") as tmp:
            sess = start(tmp, "theme 1\n" + PAD * 16500 + "show_hidden 0\n", lang=lang)   # ~1.2 MB
            try:
                screen = sess.vt.full_text()
                assert "Catppuccin" in screen, f"{lang}: the head of an oversized config was dropped"
                assert needle in screen, f"{lang}: no oversize warning in the status bar"
                assert os.waitpid(sess.pid, os.WNOHANG)[0] == 0, "process died"
                deadline = time.monotonic() + 1.0
                while time.monotonic() < deadline:
                    sess.drain(0.1)
            finally:
                kill(sess)
    print("[PASS] CF2. A config beyond 1 MiB keeps its head and shows an EN/UA warning")


def main() -> None:
    test_large_configs_apply_fully()
    test_oversized_config_warns()
    print("ALL CONFIG LIMIT TESTS PASSED.")


if __name__ == "__main__":
    main()
