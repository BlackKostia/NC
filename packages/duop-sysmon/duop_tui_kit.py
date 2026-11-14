"""Reusable zero-dependency TrueColor TUI toolkit for Duop packages."""

from __future__ import annotations

import os
import re
import select
import shutil
import signal
import sys
import termios
import tty
from typing import Iterable, Sequence

RESET = "\x1b[0m"
BOLD = "\x1b[1m"
DIM = "\x1b[2m"

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


class Theme:
    """Tokyo Night inspired TrueColor RGB palette."""

    BG = (26, 27, 38)
    PANEL_BG = (31, 35, 53)
    BORDER = (65, 72, 104)
    BORDER_FOCUS = (122, 162, 247)
    TEXT = (192, 202, 245)
    MUTED = (86, 95, 137)
    ACCENT = (122, 162, 247)
    CYAN = (125, 207, 255)
    GREEN = (158, 206, 106)
    YELLOW = (224, 175, 104)
    ORANGE = (255, 158, 100)
    RED = (247, 118, 142)
    PURPLE = (187, 154, 247)
    BAR_EMPTY = (59, 66, 97)


def fg_rgb(r: int, g: int, b: int) -> str:
    return f"\x1b[38;2;{r};{g};{b}m"


def bg_rgb(r: int, g: int, b: int) -> str:
    return f"\x1b[48;2;{r};{g};{b}m"


def styled(
    text: str,
    fg: tuple[int, int, int] | None = None,
    bg: tuple[int, int, int] | None = None,
    bold: bool = False,
) -> str:
    parts: list[str] = []
    if bold:
        parts.append(BOLD)
    if fg is not None:
        parts.append(fg_rgb(*fg))
    if bg is not None:
        parts.append(bg_rgb(*bg))
    if not parts:
        return text
    return "".join(parts) + text + RESET


def gradient_rgb(pct: float) -> tuple[int, int, int]:
    """Interpolate green -> yellow -> red for 0..100 percentage."""
    p = max(0.0, min(100.0, pct))
    if p < 50.0:
        t = p / 50.0
        c1, c2 = Theme.GREEN, Theme.YELLOW
    else:
        t = (p - 50.0) / 50.0
        c1, c2 = Theme.YELLOW, Theme.RED
    return (
        int(c1[0] + (c2[0] - c1[0]) * t),
        int(c1[1] + (c2[1] - c1[1]) * t),
        int(c1[2] + (c2[2] - c1[2]) * t),
    )


def visible_len(s: str) -> int:
    return len(_ANSI_RE.sub("", s))


def truncate(s: str, max_width: int) -> str:
    if max_width <= 0:
        return ""
    if visible_len(s) <= max_width:
        return s
    out: list[str] = []
    vis = 0
    i = 0
    n = len(s)
    while i < n and vis < max_width:
        if s[i] == "\x1b":
            m = _ANSI_RE.match(s, i)
            if m:
                out.append(m.group(0))
                i = m.end()
                continue
        out.append(s[i])
        vis += 1
        i += 1
    out.append(RESET)
    return "".join(out)


def pad_right(s: str, width: int) -> str:
    vlen = visible_len(s)
    if vlen > width:
        return truncate(s, width)
    return s + (" " * (width - vlen))


def format_bytes(num_bytes: float) -> str:
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    val = float(max(0.0, num_bytes))
    for u in units:
        if val < 1024.0 or u == units[-1]:
            if u == "B":
                return f"{int(val)} {u}"
            return f"{val:.1f} {u}"
        val /= 1024.0
    return f"{val:.1f} PiB"


def format_uptime(seconds: float) -> str:
    total = int(max(0, seconds))
    days, rem = divmod(total, 86400)
    hours, rem = divmod(rem, 3600)
    mins, secs = divmod(rem, 60)
    if days > 0:
        return f"{days}d {hours:02d}h {mins:02d}m"
    return f"{hours:02d}:{mins:02d}:{secs:02d}"


def progress_bar(pct: float, width: int, show_pct: bool = True) -> str:
    """Render a sub-character Unicode progress bar with TrueColor gradient."""
    pct_clamped = max(0.0, min(100.0, pct))
    pct_label = f" {pct_clamped:5.1f}%" if show_pct else ""
    bar_w = max(4, width - len(pct_label))

    blocks = " ▏▎▍▌▋▊▉█"
    filled_exact = (pct_clamped / 100.0) * bar_w
    full_cells = int(filled_exact)
    frac = filled_exact - full_cells
    partial_idx = int(frac * 8)

    color = gradient_rgb(pct_clamped)
    parts: list[str] = [fg_rgb(*color)]
    if full_cells > 0:
        parts.append("█" * full_cells)
    rem_cells = bar_w - full_cells
    if rem_cells > 0 and partial_idx > 0:
        parts.append(blocks[partial_idx])
        rem_cells -= 1
    if rem_cells > 0:
        parts.append(fg_rgb(*Theme.BAR_EMPTY) + ("░" * rem_cells))
    parts.append(RESET)
    if show_pct:
        parts.append(styled(pct_label, fg=Theme.TEXT, bold=pct_clamped >= 80.0))
    return "".join(parts)


def sparkline(values: Sequence[float], width: int) -> str:
    """Render a single-line Unicode sparkline for 0..100 values."""
    if width <= 0:
        return ""
    ticks = "▁▂▃▄▅▆▇█"
    vals = list(values[-width:])
    if len(vals) < width:
        vals = [0.0] * (width - len(vals)) + vals
    out: list[str] = []
    for v in vals:
        clamped = max(0.0, min(100.0, v))
        idx = min(7, int((clamped / 100.0) * 7.99))
        out.append(fg_rgb(*gradient_rgb(clamped)) + ticks[idx])
    out.append(RESET)
    return "".join(out)


def braille_graph(values: Sequence[float], width: int, height: int = 4) -> list[str]:
    """Render a 2x4 Braille dot-matrix graph of 0..100 values."""
    if width <= 0 or height <= 0:
        return []
    # Braille dot bit masks per (col 0..1, row 0..3 from top)
    dot_bits = (
        (0x01, 0x08),
        (0x02, 0x10),
        (0x04, 0x20),
        (0x40, 0x80),
    )
    total_cols = width * 2
    total_rows = height * 4
    vals = list(values[-total_cols:])
    if len(vals) < total_cols:
        vals = [0.0] * (total_cols - len(vals)) + vals

    lines: list[str] = []
    for row_blk in range(height):
        row_chars: list[str] = []
        y_top = (height - 1 - row_blk) * 4
        for col_blk in range(width):
            v0 = max(0.0, min(100.0, vals[col_blk * 2]))
            v1 = max(0.0, min(100.0, vals[col_blk * 2 + 1]))
            h0 = int(round((v0 / 100.0) * total_rows))
            h1 = int(round((v1 / 100.0) * total_rows))
            mask = 0
            for sub_y in range(4):
                # sub_y=0 is top dot of this Braille cell
                world_y = y_top + (3 - sub_y)
                if world_y < h0:
                    mask |= dot_bits[sub_y][0]
                if world_y < h1:
                    mask |= dot_bits[sub_y][1]
            peak = max(v0, v1)
            color = Theme.MUTED if mask == 0 else gradient_rgb(peak)
            row_chars.append(fg_rgb(*color) + chr(0x2800 + mask))
        row_chars.append(RESET)
        lines.append("".join(row_chars))
    return lines


def draw_box(
    title: str,
    lines: Iterable[str],
    width: int,
    border_color: tuple[int, int, int] | None = None,
    title_color: tuple[int, int, int] | None = None,
    subtitle: str = "",
) -> list[str]:
    """Render a rounded Unicode box around pre-formatted content lines."""
    b_fg = border_color or Theme.BORDER
    t_fg = title_color or Theme.ACCENT
    inner_w = max(4, width - 4)

    title_seg = f" {styled(title, fg=t_fg, bold=True)} " if title else ""
    sub_seg = f" {styled(subtitle, fg=Theme.MUTED)} " if subtitle else ""
    fill_len = max(
        0,
        (width - 2) - visible_len(title_seg) - visible_len(sub_seg) - 1,
    )
    top = (
        fg_rgb(*b_fg)
        + "╭─"
        + RESET
        + title_seg
        + fg_rgb(*b_fg)
        + ("─" * fill_len)
        + RESET
        + sub_seg
        + fg_rgb(*b_fg)
        + "╮"
        + RESET
    )
    out = [top]
    for raw in lines:
        content = pad_right(raw, inner_w)
        out.append(
            fg_rgb(*b_fg) + "│ " + RESET + content + fg_rgb(*b_fg) + " │" + RESET
        )
    out.append(fg_rgb(*b_fg) + "╰" + ("─" * (width - 2)) + "╯" + RESET)
    return out


def merge_columns(
    left_lines: Sequence[str],
    right_lines: Sequence[str],
    left_width: int,
    gap: int = 1,
) -> list[str]:
    """Place two equal-or-different-height boxes side by side."""
    total = max(len(left_lines), len(right_lines))
    spacer = " " * gap
    out: list[str] = []
    for i in range(total):
        l_txt = left_lines[i] if i < len(left_lines) else (" " * left_width)
        r_txt = right_lines[i] if i < len(right_lines) else ""
        out.append(pad_right(l_txt, left_width) + spacer + r_txt)
    return out


class RawTerminal:
    """Context manager for alternate screen, hidden cursor, and non-blocking keys."""

    def __init__(self) -> None:
        self._fd = sys.stdin.fileno()
        self._old_attrs: list | None = None
        self.resized = False
        self._prev_sigwinch = None

    def _on_sigwinch(self, _signum: int, _frame: object) -> None:
        self.resized = True

    def __enter__(self) -> RawTerminal:
        if os.isatty(self._fd):
            self._old_attrs = termios.tcgetattr(self._fd)
            tty.setcbreak(self._fd)
        self._prev_sigwinch = signal.signal(signal.SIGWINCH, self._on_sigwinch)
        sys.stdout.write("\x1b[?1049h\x1b[?25l\x1b[2J")
        sys.stdout.flush()
        return self

    def __exit__(self, *_exc: object) -> None:
        sys.stdout.write("\x1b[?25h\x1b[?1049l" + RESET)
        sys.stdout.flush()
        if self._old_attrs is not None:
            termios.tcsetattr(self._fd, termios.TCSADRAIN, self._old_attrs)
        if self._prev_sigwinch is not None:
            signal.signal(signal.SIGWINCH, self._prev_sigwinch)

    @staticmethod
    def size() -> tuple[int, int]:
        sz = shutil.get_terminal_size((100, 32))
        return sz.columns, sz.lines

    def read_key(self, timeout: float) -> str | None:
        if not os.isatty(self._fd):
            return None
        rlist, _, _ = select.select([self._fd], [], [], max(0.0, timeout))
        if not rlist:
            return None
        data = os.read(self._fd, 16)
        if not data:
            return None
        return data.decode("utf-8", errors="ignore")
