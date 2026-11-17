#!/usr/bin/env python3
"""src/fs/pkg_fetch.c versus the frozen assembly (tests/harness/pkg_fetch_reference.s): pkg_fetch_url (fork + exec curl/wget).

PF1 differential with the real curl and file:// URLs (x86_64): a fetched file, a missing source, an unwritable destination, a FIFO
    source that never delivers (the 60 s timeout through a scripted clock: the exact number of clock calls, the poll interval,
    the helper is killed and reaped); same return value, same destination bytes
PF2 differential with stand-in helpers bind-mounted over /usr/bin in a user + mount namespace (skipped when the host forbids
    unprivileged namespaces): the exact argv of curl and of the wget fallback, the order of the candidates, the environment
    passed through, exit 127 when no helper exists, non-zero exit and death by signal are failures
PF3 qemu-aarch64: the C module alone gives the same results as on x86_64 (real curl)
PF4 mutation check: one-line mutants of the C module must all be noticed
"""

import os
import shutil
import signal
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/pkg_fetch.c"
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c"]
REF = "tests/harness/pkg_fetch_reference.s"
HANG_STEP = 1                                     # scripted clock: +1 ms per call -> the deadline (first call + 60000) is call 60001


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    cflags = ["-I", str(ROOT / "tests/harness"), f'-DPF_SRC="{ROOT / src if not Path(src).is_absolute() else src}"']
    extra: list[Path] = []
    if arch == "x86_64":
        ref = t / "pf_ref.o"
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(ref)], check=True, capture_output=True)
        H.rename_defined_globals([ref], "ref_")
        subprocess.run(["objcopy", "--redefine-sym", "os_clock_ms=pf_clock", "--redefine-sym", "os_poll_in=pf_poll", str(ref)], check=True)
        extra.append(ref)
    return H.build(arch, t, ["tests/harness/pkg_fetch_cli.c", *CORE], extra, cflags=cflags)


def run_bounded(cmd: list[str], env: dict[str, str], timeout: int = 15) -> subprocess.CompletedProcess:
    """A run in its own session: on a timeout (a mutant that never kills its helper) the whole group, the helper too, is killed."""
    with subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True) as p:
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.communicate()
            raise
    return subprocess.CompletedProcess(cmd, p.returncode, out, err)


def fetch(exe: Path, impl: str, step: int, url: str, dest: Path, arch: str = "x86_64", env: dict[str, str] | None = None) -> str:
    cmd = [*H.ARCHS[arch]["run"], str(exe), impl, str(step), url, str(dest)]
    res = run_bounded(cmd, {"PATH": "/usr/bin:/bin", **(env or {})})
    assert res.returncode == 0, (cmd[-4:], res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace").strip()


def sources(t: Path) -> dict[str, Path]:
    src = t / "src"
    src.mkdir(exist_ok=True)
    (src / "pkg.tar").write_bytes(bytes(range(256)) * 64)
    (src / "empty").write_bytes(b"")
    fifo = src / "never"
    if not fifo.exists():
        os.mkfifo(fifo)
    (t / "ro").mkdir(exist_ok=True)
    (t / "ro").chmod(0o555)
    return {"file": src / "pkg.tar", "empty": src / "empty", "fifo": fifo, "missing": src / "absent", "ro": t / "ro"}


def real_cases(t: Path) -> list[tuple[str, int, str, Path]]:
    s = sources(t)
    return [
        ("file", 0, f"file://{s['file']}", t / "out_file"),
        ("empty", 0, f"file://{s['empty']}", t / "out_empty"),
        ("missing", 0, f"file://{s['missing']}", t / "out_missing"),
        ("ro_dest", 0, f"file://{s['file']}", s["ro"] / "out"),
        ("no_dir", 0, f"file://{s['file']}", t / "nodir" / "out"),
        ("bad_scheme", 0, "nosuch://x", t / "out_scheme"),
        ("dash_url", 0, "-V", t / "out_dash"),                         # after "--" a URL starting with '-' is not an option
        ("timeout", HANG_STEP, f"file://{s['fifo']}", t / "out_fifo"),
        ("fast_clock_ok", 0, f"file://{s['file']}", t / "out_fast"),
    ]


def outcome(exe: Path, impl: str, step: int, url: str, dest: Path, arch: str = "x86_64", **kw) -> tuple[str, bytes | None]:
    if dest.exists():
        dest.unlink()
    line = fetch(exe, impl, step, url, dest, arch, **kw)
    return untimed(line, step), dest.read_bytes() if dest.is_file() else None


def untimed(line: str, step: int) -> str:
    """With the real clock the number of clock calls and whether a poll happened depend on timing: keep only the result."""
    return line if step else " ".join(w for w in line.split() if not w.startswith(("clock=", "poll=")))


def test_real(exe: Path, t: Path) -> dict[str, tuple[str, bytes | None]]:
    if not shutil.which("curl"):
        print("[SKIP] PF1: curl is not installed")
        return {}
    got: dict[str, tuple[str, bytes | None]] = {}
    for tag, step, url, dest in real_cases(t):
        ref = outcome(exe, "ref", step, url, dest)
        c = outcome(exe, "c", step, url, dest)
        assert ref == c, f"{tag}: oracle {ref[0]!r} vs C {c[0]!r}"
        got[tag] = c
    assert got["file"] == ("ret=0", bytes(range(256)) * 64) and got["empty"] == ("ret=0", b""), (got["file"][0], got["empty"])
    for tag in ("missing", "ro_dest", "no_dir", "bad_scheme", "dash_url"):
        assert got[tag][0].startswith("ret=-1"), (tag, got[tag])
    assert got["timeout"][0] == "ret=-1 clock=60001 poll=-1/50", got["timeout"]
    print(f"[PASS] PF1. pkg_fetch_url identical to the asm with the real curl in {len(got)} cases "
          "(fetch, empty, missing, unwritable, bad scheme, '-V' after '--', 60 s timeout = 60001 clock calls, poll -1/50 ms)")
    return got


def userns_ok() -> bool:
    if not shutil.which("unshare"):
        return False
    r = subprocess.run(["unshare", "-rm", "sh", "-c", "mount -t tmpfs none /mnt"], capture_output=True)
    return r.returncode == 0


def fake_tools(t: Path) -> Path:
    (t / "fake_build").mkdir(parents=True, exist_ok=True)
    return H.build("x86_64", t / "fake_build", ["tests/harness/pkg_fetch_fake.c", *CORE])


def in_ns(exe: Path, impl: str, bindir: Path, step: int, url: str, dest: Path, env: dict[str, str]) -> str:
    """Runs one fetch with bindir bind-mounted over /usr/bin (and so over /bin on merged-/usr systems)."""
    script = f'mount --bind "{bindir}" /usr/bin && exec "{exe}" {impl} {step} "{url}" "{dest}"'
    res = run_bounded(["unshare", "-rm", "sh", "-c", script], {"PATH": "/usr/bin:/bin", **env})
    assert res.returncode == 0, (impl, url, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace").strip()


NS_CASES = [  # tag, helpers present, mode, step
    ("curl_ok", ("curl", "wget"), "ok", 0),
    ("curl_fail_no_fallback", ("curl", "wget"), "fail", 0),
    ("curl_signal", ("curl",), "sig", 0),
    ("wget_fallback", ("wget",), "ok", 0),
    ("wget_fail", ("wget",), "fail", 0),
    ("none", (), "ok", 0),
    ("curl_hang", ("curl",), "hang", HANG_STEP),
    ("wget_hang", ("wget",), "hang", HANG_STEP),
]


def ns_run(exe: Path, impl: str, t: Path, fake: Path, tag: str, tools: tuple[str, ...], mode: str, step: int) -> tuple[str, str, bytes | None]:
    bindir = t / f"bin_{tag}"
    bindir.mkdir(exist_ok=True)
    for name in tools:
        if not (bindir / name).exists():
            shutil.copy(fake, bindir / name)
    log, dest = t / f"log_{tag}_{impl}", t / f"dest_{tag}_{impl}"
    for p in (log, dest):
        if p.exists():
            p.unlink()
    line = in_ns(exe, impl, bindir, step, "https://example.invalid/pkg -x", dest, {"PF_LOG": str(log), "PF_MODE": mode, "PF_TAG": tag})
    line = untimed(line, step)
    text = log.read_bytes().decode(errors="backslashreplace").replace(str(dest), "<dest>") if log.exists() else ""
    return line, text, dest.read_bytes() if dest.exists() else None


def test_namespace(exe: Path, t: Path) -> None:
    if not userns_ok():
        print("[SKIP] PF2: unprivileged user + mount namespaces are not available")
        return
    fake = fake_tools(t)
    seen = {}
    for tag, tools, mode, step in NS_CASES:
        ref = ns_run(exe, "ref", t, fake, tag, tools, mode, step)
        c = ns_run(exe, "c", t, fake, tag, tools, mode, step)
        assert ref == c, f"{tag}: oracle {ref} vs C {c}"
        seen[tag] = c
    u = "https://example.invalid/pkg -x"
    assert seen["curl_ok"] == ("ret=0", f"/usr/bin/curl -fsSL -o <dest> -- {u} tag=curl_ok\n", b"fake:/usr/bin/curl"), seen["curl_ok"]
    assert seen["curl_fail_no_fallback"][0].startswith("ret=-1") and seen["curl_fail_no_fallback"][1].count("\n") == 1
    assert seen["curl_signal"][0].startswith("ret=-1")
    assert seen["wget_fallback"][0] == "ret=0", seen["wget_fallback"]
    assert seen["wget_fallback"][1] == f"/usr/bin/wget -q -O <dest> -- {u} tag=wget_fallback\n", seen["wget_fallback"]
    assert seen["wget_fail"][0].startswith("ret=-1")
    assert seen["none"][0].startswith("ret=-1") and seen["none"][1] == "" and seen["none"][2] is None
    for tag in ("curl_hang", "wget_hang"):
        assert seen[tag][0] == "ret=-1 clock=60001 poll=-1/50" and seen[tag][1].count("\n") == 1, (tag, seen[tag])
    print(f"[PASS] PF2. {len(NS_CASES)} stand-in helper scenarios identical to the asm (curl argv, wget fallback argv, environment, "
          "exit 127, exit 22, SIGTERM, hung helper killed after 60001 clock calls)")


def test_aarch64(t: Path, x86: dict[str, tuple[str, bytes | None]]) -> None:
    if not H.available("aarch64") or not x86:
        print("[SKIP] PF3: aarch64 toolchain/qemu or curl not available")
        return
    exe = build("aarch64", t / "a64")
    for tag, step, url, dest in real_cases(t / "a64"):
        got = outcome(exe, "c", step, url, dest, "aarch64")
        assert got == x86[tag], f"aarch64 {tag}: {got} vs x86_64 {x86[tag]}"
    print(f"[PASS] PF3. qemu-aarch64: the C module gives the x86_64 results in {len(x86)} real-curl cases")


MUTANTS = [
    ("timeout +1", "os_clock_ms() + PKG_FETCH_TIMEOUT_MS", "os_clock_ms() + PKG_FETCH_TIMEOUT_MS + 1"),
    ("deadline is strict", "os_clock_ms() >= deadline", "os_clock_ms() > deadline"),
    ("poll interval", "os_poll_in(-1, PKG_FETCH_POLL_MS)", "os_poll_in(-1, PKG_FETCH_POLL_MS + 1)"),
    ("poll fd", "os_poll_in(-1, PKG_FETCH_POLL_MS)", "os_poll_in(0, PKG_FETCH_POLL_MS)"),
    ("exit status ignored", "status == 0 ? 0 : -1", "0"),
    ("curl -f dropped", '"-fsSL"', '"-sSL"'),
    ("no -- before the URL", '"--", url', "url, url"),
    ("wget -O", 'argv[2] = "-O"', 'argv[2] = "-o"'),
    ("wget -q", 'argv[1] = "-q"', 'argv[1] = "-v"'),
    ("wget fallback never tried", "argv[0] = pf_wget1;", "os_exit(127);"),       # /usr/bin vs /bin: one directory on merged-/usr hosts
    ("environment dropped", "(void)os_execve(pf_curl1, (char *const *)argv, envp);", "(void)os_execve(pf_curl1, (char *const *)argv, nullptr);"),
    ("timed-out child not killed", "(void)os_kill(pid, SIGKILL);", "(void)os_kill(pid, 0);"),
]


def mutant_noticed(i: int, name: str, old: str, new: str, src: str, t: Path, fake: Path | None) -> bool:
    mt = t / f"m{i}"
    mt.mkdir()
    mp = mt / "pkg_fetch.c"
    mp.write_text(src.replace(old, new, 1))
    try:
        exe = build("x86_64", mt, str(mp))
        if any(outcome(exe, "ref", step, url, dest) != outcome(exe, "c", step, url, dest) for _, step, url, dest in real_cases(mt)):
            return True
        return fake is not None and any(ns_run(exe, "ref", mt, fake, tag, tools, mode, step) != ns_run(exe, "c", mt, fake, tag, tools, mode, step)
                                        for tag, tools, mode, step in NS_CASES)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError):
        return True
    finally:
        (mt / "ro").chmod(0o755)


def test_mutants(t: Path, have_ns: bool) -> None:
    src = (ROOT / SRC).read_text()
    fake = fake_tools(t / "mfake") if have_ns else None
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, m: tuple[str, str, str]):
        return lambda: noticed.__setitem__(m[0], mutant_noticed(i, *m, src, t, fake))

    H.parallel([job(i, m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    # the -EINTR retry of wait4 is not mutated: no signal handler interrupts the harness, so dropping it is not observable here.
    # Without namespaces the wget fallback and the environment cannot be observed (the real curl always exists).
    expected = set() if have_ns else {"wget -O", "wget -q", "wget fallback never tried", "environment dropped"}
    unexpected = [s for s in survivors if s not in expected]
    assert not unexpected, f"mutants not noticed: {unexpected}"
    print(f"[PASS] PF4. {len(MUTANTS) - len(survivors)}/{len(MUTANTS)} mutants of the C module are noticed (equivalent here: {survivors})")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        try:
            x86: dict[str, tuple[str, bytes | None]] = {}
            if H.available("x86_64"):
                exe = build("x86_64", t / "x86")
                x86 = test_real(exe, t / "x86")
                test_namespace(exe, t / "x86")
                test_aarch64(t, x86)
                test_mutants(t, userns_ok())
        finally:
            for ro in t.rglob("ro"):
                ro.chmod(0o755)
    print("ALL C PKG FETCH TESTS PASSED.")


if __name__ == "__main__":
    main()
