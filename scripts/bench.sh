#!/usr/bin/env bash
set -euo pipefail

BIN="${1:-./duop}"
if [[ ! -x "$BIN" ]]; then
    echo "Binary not found: $BIN (run 'make release' first)" >&2
    exit 1
fi

echo "=== Duop Benchmark ==="
ls -lh "$BIN"
size "$BIN"

echo "--- Cold start (--version, 50 runs) ---"
python3 - <<'PY' "$BIN"
import subprocess, sys, time
bin_path = sys.argv[1]
t0 = time.perf_counter()
for _ in range(50):
    subprocess.run([bin_path, "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
dt = (time.perf_counter() - t0) / 50 * 1000
print(f"avg cold start: {dt:.2f} ms")
PY

echo "--- Peak RSS (--version) ---"
if command -v /usr/bin/time >/dev/null 2>&1; then
    /usr/bin/time -f "maxrss: %M KB" "$BIN" --version >/dev/null 2>&1 || true
fi

echo "--- 100,000-file directory open & quit (PTY) ---"
python3 - <<'PY' "$BIN"
import os, pty, select, shutil, subprocess, sys, tempfile, time
bin_path = sys.argv[1]
tmp = tempfile.mkdtemp(prefix="duop_bench_")
try:
    for i in range(100000):
        os.close(os.open(os.path.join(tmp, f"f_{i:06d}.dat"), os.O_CREAT | os.O_WRONLY, 0o644))
    master, slave = pty.openpty()
    t0 = time.perf_counter()
    p = subprocess.Popen([bin_path, tmp, tmp], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    os.close(slave)
    buf = b""
    while time.perf_counter() - t0 < 10.0:
        import select
        r, _, _ = select.select([master], [], [], 0.05)
        if r:
            buf += os.read(master, 65536)
            if b"f_000" in buf or b"100000" in buf:
                break
    dt = (time.perf_counter() - t0) * 1000
    os.write(master, b"\x1b[21~")
    p.wait(timeout=3)
    os.close(master)
    print(f"100k dir first-frame ready: {dt:.1f} ms")
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY
