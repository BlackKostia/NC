"""Expected Disk Usage numbers for PTY tests: allocated bytes (st_blocks * 512) like `du`,
directories included, symlinks not followed, hard-linked inodes counted once, formatted exactly
like format_size()."""

import os


def fmt_size(n):
    unit, rem = 0, 0
    while n >= 1024 and unit < 6:
        n, rem = divmod(n, 1024)
        unit += 1
    if unit == 0:
        return f"{n} B"
    u = "BKMGTPE"[unit]
    return f"{n} {u}" if n >= 100 else f"{n}.{rem * 10 // 1024} {u}"


def du_bytes(path, seen=None):
    seen = set() if seen is None else seen
    st = os.lstat(path)
    is_dir = os.path.isdir(path) and not os.path.islink(path)
    if not is_dir and st.st_nlink > 1:
        if (st.st_dev, st.st_ino) in seen:
            return 0
        seen.add((st.st_dev, st.st_ino))
    total = st.st_blocks * 512
    if is_dir:
        for name in sorted(os.listdir(path)):
            total += du_bytes(os.path.join(path, name), seen)
    return total


def du_text(path):
    return fmt_size(du_bytes(path))
