#!/usr/bin/env python3
"""src/fs/git_status.c versus the frozen assembly (tests/harness/git_status_reference.s + git_status_query_reference.s): branch and
`git status --porcelain=v1 -z` integration (git_refresh / git_lookup / git_branch / git_free_ctx / git_spawn_status /
git_parse_branch).

GS1 differential with the real git (x86_64): repositories with modified, staged, untracked, deleted, renamed, nested and ignored
    files, a detached HEAD, "No commits yet", sub-directories of the work tree, a non-repository, an untrusted repository (filter
    driver), virtual mode, deferral, OOM of each allocation; branch, entries, lookups
GS2 differential with a stand-in git first on PATH: exact argv and environment, stdin and stderr on /dev/null, every porcelain
    shape (R/C records with two names, more than 512 records, names longer than 255 bytes, records cut by the end of the output),
    exit status 1, a full buffer, the 2.5 s deadline through a scripted clock (poll gets the time left; a late git is killed, its
    partial output dropped and git stays off for the session)
GS3 git_parse_branch on hand-made records (".." upstream, newline, 63-byte limit, short and foreign records)
GS4 two defects of the asm, fixed in C: a PATH entry longer than PATH_MAX - 8 was truncated and the truncated name executed; a
    "<dir>/.git" probe that did not fit PATH_MAX was truncated, matched "<dir>/." and ended the search (no git status there)
GS5 qemu-aarch64: the C module alone gives the x86_64 results (stand-in git); GS6 mutation check
"""

import os
import random
import shutil
import subprocess
import threading
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/fs/git_status.c"
REFS = ["tests/harness/git_status_reference.s", "tests/harness/git_status_query_reference.s"]
CORE = ["src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c", "src/core/try_rt.c", "src/core/mem_prims.c",
        "src/fs/git_trust.c"]
REDEF = {"os_clock_ms": "gs_clock", "os_poll_in": "gs_poll", "mem_alloc": "gs_alloc"}
GIT_ENV = {"GIT_CONFIG_NOSYSTEM": "1", "HOME": "/nonexistent", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t"}


def say(msg: str) -> None:
    """Results of the main run only: the mutation check reruns the same tests in worker threads."""
    if threading.current_thread() is threading.main_thread():
        print(msg)


def build(arch: str, t: Path, src: str = SRC) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    path = src if Path(src).is_absolute() else str(ROOT / src)
    extra: list[Path] = []
    if arch == "x86_64":
        inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
        for r in REFS:
            o = t / (Path(r).stem + ".o")
            subprocess.run(["as", *inc, str(ROOT / r), "-o", str(o)], check=True, capture_output=True)
            extra.append(o)
        H.rename_defined_globals(extra, "ref_")
        for o in extra:
            subprocess.run(["objcopy", *[a for k, v in REDEF.items() for a in ("--redefine-sym", f"{k}={v}")], str(o)], check=True)
    return H.build(arch, t, ["tests/harness/git_status_cli.c", *CORE], extra, cflags=["-I", str(ROOT / "tests/harness"), f'-DGS_SRC="{path}"'])


def run(exe: Path, impl: str, script: str, step: int = 0, poll: str = "r", path: str = "/usr/bin:/bin", arch: str = "x86_64") -> str:
    cmd = [*H.ARCHS[arch]["run"], str(exe), impl, str(step), poll]
    res = subprocess.run(cmd, input=script.encode(), capture_output=True, env={"PATH": path}, timeout=60)
    assert res.returncode == 0, (impl, res.returncode, res.stderr[-300:])
    return res.stdout.decode(errors="backslashreplace")


def both(exe: Path, script: str, **kw) -> str:
    a, b = run(exe, "ref", script, **kw), run(exe, "c", script, **kw)
    if not kw.get("step"):                                               # real clock: poll timeouts depend on timing
        a, b = untimed(a), untimed(b)
    if a != b:
        pair = next(((x, y) for x, y in zip(a.splitlines(), b.splitlines()) if x != y), (a[-200:], b[-200:]))
        raise AssertionError(f"oracle and C differ:\n  ref {pair[0]}\n  c   {pair[1]}")
    return b


def untimed(out: str) -> str:
    """With the real clock the poll timeouts depend on timing: keep their count only."""
    return "\n".join(ln.split(" polls=[")[0] + f" polls={ln.count(' ', ln.find('polls=['))}" if "polls=[" in ln else ln for ln in out.splitlines())


def git(repo: Path, *args: str) -> None:
    subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, env={"PATH": "/usr/bin:/bin", **GIT_ENV})


def real_repos(t: Path) -> dict[str, Path]:
    r = t / "repo"
    r.mkdir(parents=True)
    git(r, "init", "-q", "-b", "main")
    for name in ("a.txt", "b.txt", "del.txt", "old.txt", "sub/x.c", "sub/y.c", "deep/er/z"):
        (r / name).parent.mkdir(parents=True, exist_ok=True)
        (r / name).write_text(name)
    (r / ".gitignore").write_text("*.log\n")
    git(r, "add", "-A")
    git(r, "commit", "-q", "-m", "one")
    (r / "a.txt").write_text("changed")
    (r / "b.txt").write_text("staged")
    git(r, "add", "b.txt")
    (r / "del.txt").unlink()
    git(r, "mv", "old.txt", "new name.txt")
    (r / "sub" / "x.c").write_text("changed")
    (r / "untracked").write_text("u")
    (r / "skip.log").write_text("ignored")
    (r / "ünï").write_text("u")
    fresh = t / "fresh"
    fresh.mkdir()
    git(fresh, "init", "-q", "-b", "feature/x")
    (fresh / "f").write_text("f")
    det = t / "detached"
    shutil.copytree(r, det)
    git(det, "checkout", "-q", "--detach")
    untrusted = t / "untrusted"
    shutil.copytree(r, untrusted)
    with open(untrusted / ".git" / "config", "a") as f:
        f.write('[filter "x"]\n\tclean = false\n')
    (t / "plain").mkdir()
    return {"repo": r, "fresh": fresh, "detached": det, "untrusted": untrusted, "plain": t / "plain", "sub": r / "sub", "deep": r / "deep" / "er"}


def lookups(*names: str) -> str:
    return "".join(f"L {n}\n" for n in names) + "N\n"


def test_real(exe: Path, t: Path) -> None:
    if not shutil.which("git"):
        print("[SKIP] GS1: git is not installed")
        return
    d = real_repos(t / "real")
    names = lookups("a.txt", "b.txt", "del.txt", "new name.txt", "sub", "untracked", "skip.log", "nope", "deep", "\xfc")
    script = "".join(f"R {p}\n{names}" for p in d.values() if " " not in str(p))
    script += f"R {d['repo']} V\n{names}D 1\nR {d['plain']}\nD 0\nF\nO 1\nR {d['repo']}\nO 2\nR {d['repo']}\nO 3\nR {d['repo']}\nR {d['repo']}\nF\nR /\n"
    out = untimed(both(exe, script))
    lines = out.splitlines()
    assert "branch=main" in lines[0] and "a.txt:M" in lines[0] and "b.txt:M" in lines[0] and "del.txt:D" in lines[0], lines[0]
    assert "new\\x20name.txt:R" in lines[0] or "new name.txt:R" in lines[0], lines[0]
    assert "untracked:?" in lines[0] and "sub:M" in lines[0] and "skip.log" not in lines[0], lines[0]
    assert any("branch=feature/x" in ln for ln in lines) and any("branch=HEAD\\x20(no\\x20branch)" in ln or "branch=HEAD (no branch)" in ln for ln in lines)
    assert sum(ln.startswith("R r=0 ctx=0") for ln in lines) >= 2, "the untrusted and the plain directory never run git"
    say(f"[PASS] GS1. git_* identical to the asm with the real git in {len(lines)} commands (status kinds, rename, nested, "
          "no commits, detached, untrusted, plain, virtual, deferred, OOM 1..3)")


def fake_bin(t: Path) -> Path:
    b = t / "fakebin"
    b.mkdir(parents=True, exist_ok=True)
    (t / "fake_build").mkdir(parents=True, exist_ok=True)
    exe = H.build("x86_64", t / "fake_build", ["tests/harness/git_status_fake.c", *CORE])
    shutil.copy(exe, b / "git")
    return b


def fake_repo(t: Path, tag: str, out: bytes, mode: str = "o") -> Path:
    d = t / tag
    (d / ".git").mkdir(parents=True, exist_ok=True)
    (d / ".fake_out").write_bytes(out)
    (d / ".fake_mode").write_text(mode)
    log = d / ".fake_log"
    if log.exists():
        log.unlink()
    return d


def porcelain(rng: random.Random, n: int) -> bytes:
    recs = [b"## " + rng.choice([b"main...origin/main [ahead 1]", b"No commits yet on dev", b"x" * 80, b"HEAD (no branch)", b"a.b..c"])]
    for _ in range(n):
        x, y = rng.choice(b" MADRCU?!"), rng.choice(b" MADRCU?\x00")
        name = rng.choice([b"f%d" % rng.randrange(900), b"d%d/sub/f" % rng.randrange(50), b"L" * rng.randrange(250, 300), b"sp ace", b"/lead"])
        rec = bytes([x, y]) + b" " + name + b"\x00"
        if x in b"RC":
            rec += b"orig/" + name + b"\x00"
        recs.append(rec)
    data = b"".join(r if i == 0 else r for i, r in enumerate(recs))
    return recs[0] + b"\x00" + data[len(recs[0]):]


def test_fake(exe: Path, t: Path, bindir: Path) -> list[str]:
    rng = random.Random(0x617)
    path = f"{bindir}:/usr/bin:/bin"
    cases = {"empty": (b"", "o"), "branch_only": (b"## main\x00", "o"), "fail": (b"## main\x00 M a\x00", "f"),
             "cut": (b"## main\x00 M a\x00R  new", "o"), "cut2": (b"## main\x00R  new\x00ol", "o"), "short": (b"## m\x00?? ", "o"), "cut4": (b"## m\x00?? a", "o"), "cut5": (b"## m\x00?? ab", "o"),
             "flood": (b"", "b"), "many": (porcelain(rng, 700), "o")}
    for i in range(12):
        cases[f"rand{i}"] = (porcelain(rng, rng.randrange(0, 80)), "o")
    outs, logs = [], []
    for tag, (data, mode) in cases.items():
        d = fake_repo(t / "fake", tag, data, mode)
        script = f"R {d}\n" + lookups("a", "f1", "d1", "sp", "L" * 255, "new", "lead", "") + f"P {d} 65536\nP {d} 7\n"
        a = run(exe, "ref", script, path=path)
        log_a = (d / ".fake_log").read_text()
        (d / ".fake_log").unlink()
        b = run(exe, "c", script, path=path)
        log_b = (d / ".fake_log").read_text()
        assert untimed(a) == untimed(b), f"{tag}: oracle and C differ:\n{untimed(a)}\n{untimed(b)}"
        assert log_a == log_b, (tag, log_a, log_b)
        outs.append(untimed(b))
        logs.append(log_b)
    first = logs[0].splitlines()[0]
    assert first == ("git --no-optional-locks -c core.fsmonitor=false -C <dir> status --porcelain=v1 --ignore-submodules=all -z -b "
                     "| PATH=/usr/bin:/bin LC_ALL=C fd0=/dev/null fd2=/dev/null"), first
    assert "n=512" in outs[list(cases).index("many")], "at most 512 entries"
    assert outs[list(cases).index("fail")].startswith("R r=0 ctx=1 branch= raw= n=0"), "a failing git leaves an empty listing"
    say(f"[PASS] GS2. {len(cases)} stand-in git outputs identical to the asm (argv, environment, fd 0/2 = /dev/null, R/C records, "
          ">512 records, >255-byte names, cut records, exit 1, full buffer)")
    return outs


def test_deadline(exe: Path, t: Path, bindir: Path) -> None:
    path = f"{bindir}:/usr/bin:/bin"
    res = {}
    for tag, mode, step, poll in (("late_zero", "h", 1, "z"), ("late_clock", "h", 3000, "r"), ("partial", "p", 1, "z"), ("ok_step", "o", 7, "r"), ("late_after_exit", "o", 1300, "s")):
        d = fake_repo(t / "dl", tag, b"## main\x00 M a\x00", mode)
        script = f"R {d}\nR {d}\nP {d} 100\n"
        res[tag] = both(exe, script, step=step, poll=poll, path=path)
        runs = (d / ".fake_log").read_text().count("\n") if (d / ".fake_log").exists() else 0   # a git killed at once may not have logged yet
        assert runs == (6 if tag == "ok_step" else 2) if mode == "o" else runs <= 2, (tag, runs, "a late git switches git off for good (one run per implementation)")
    assert res["late_zero"].splitlines()[0] == "R r=0 ctx=1 branch= raw= n=0 polls=[ 2499 ]", res["late_zero"]
    assert res["late_clock"].splitlines()[0] == "R r=0 ctx=1 branch= raw= n=0 polls=[ ]", res["late_clock"]
    assert res["ok_step"].splitlines()[0].startswith("R r=0 ctx=1 branch=main raw=main n=1 a:M polls=[ 2493"), res["ok_step"]
    assert all(r.splitlines()[2] == "P r=-1 out=" for r in (res["late_zero"], res["late_clock"], res["partial"]))
    assert res["late_after_exit"].splitlines()[0] == "R r=0 ctx=1 branch= raw= n=0 polls=[ 1200 ]", ("late: a git that already exited "
                                                                                                      "still loses its output", res["late_after_exit"])
    say("[PASS] GS2b. deadline: poll gets the 2.5 s budget left, a late git is killed, its output dropped, git stays off")


def test_branch_parser(exe: Path) -> None:
    recs = [b"## main", b"## main...origin/main [ahead 2]", b"## No commits yet on dev", b"## No commits yet", b"## " + b"b" * 100,
            b"## a\nb", b"## a.b", b"## a..", b"#", b"## ", b"#x", b" M a", b"", b"## x\x00 M f\x00"]
    script = "".join(f"B {r.hex()}\n" for r in recs if r) + "B 2323\n"
    out = both(exe, script).splitlines()
    assert out[0] == "B used=8 br=main" or out[0].startswith("B used=7 br=main"), out[0]
    assert out[1].startswith("B used=") and out[1].endswith("br=main"), out[1]
    assert out[2].endswith("br=dev") and out[4].endswith("br=" + "b" * 63), (out[2], out[4])
    say(f"[PASS] GS3. git_parse_branch identical to the asm on {len(out)} records (upstream '..', newline, 63-byte cap, foreign)")


def long_dir(base: Path, total: int) -> Path:
    """A directory whose absolute path is exactly `total` bytes long (nested 200-byte components)."""
    p = base
    while len(str(p)) + 201 < total:
        p = p / ("d" * 200)
    p = p / ("e" * (total - len(str(p)) - 1))
    p.mkdir(parents=True)
    assert len(str(p)) == total
    return p


def test_fixed_defects(exe: Path, t: Path) -> None:
    # 1. PATH entry longer than PATH_MAX - 8: the asm execs the first 4088 bytes + "/git"
    base = long_dir(t / "lp", 4088)
    fake = fake_bin(t / "lpb") / "git"
    shutil.copy(fake, base / "git")
    d = fake_repo(t / "lp_repo", "r", b"## evil\x00", "o")
    path = f"{base}zzz:/usr/bin:/bin"
    ref, c = run(exe, "ref", f"P {d} 4096\n", path=path), run(exe, "c", f"P {d} 4096\n", path=path)
    assert "evil" in ref and "evil" not in c, ("the asm executes the truncated PATH entry, C skips it", ref, c)
    # 2. "<dir>/.git" longer than PATH_MAX: the asm probed the truncation ("<dir>/.gi", "<dir>/.g", "<dir>/.", "<dir>/", "<dir>"),
    #    found an existing directory, let git_trust reject it and stopped: the parent repository was never reached. C skips the
    #    probe that cannot fit and goes on with the parent.
    for n in range(4088, 4096):
        deep = long_dir(t / f"lg{n}", n)
        (deep.parent / ".git").mkdir(exist_ok=True)                                  # the parent is a repository
        fd = os.open(deep, os.O_RDONLY | os.O_DIRECTORY)                             # relative: the full names may exceed PATH_MAX
        try:
            os.mkdir(".gi", dir_fd=fd)
            os.mkdir(".g", dir_fd=fd)
        finally:
            os.close(fd)
        script = f"R {deep}\n"
        ref, c = untimed(run(exe, "ref", script)), untimed(run(exe, "c", script))
        assert c.startswith("R r=0 ctx=1"), (n, "C finds the parent repository", c[:60])
        assert (ref == c) if n <= 4090 else ref.startswith("R r=0 ctx=0"), (n, ref[:60], c[:60])
    say("[PASS] GS4. fixed: an overlong PATH entry is skipped (asm: truncated and executed); a .git probe that cannot fit is skipped "
          "and the parent repository found (asm: no git status for directory paths of 4091..4095 bytes)")


MUTANTS = [
    ("timeout", "#define GIT_TIMEOUT_MS 2500", "#define GIT_TIMEOUT_MS 2501"),
    ("git stays on after a timeout", "g_git_off = 1;", "(void)0;"),
    ("partial output kept", "return 0;                                    /* drop partial output */", "return got;"),
    ("no NUL room", "(uint32_t)(buf_cap - 1)", "(uint32_t)buf_cap"),
    ("exit status ignored", "if (w < 0 || status) return -1;", "if (w < 0) return -1;"),
    ("fsmonitor on", '"core.fsmonitor=false"', '"core.fsmonitor=true"'),
    ("submodules", '"--ignore-submodules=all"', '"--ignore-submodules=none"'),
    ("environment", '"LC_ALL=C", nullptr', "nullptr, nullptr"),
    ("stderr kept", "(void)os_dup2((int)nul, 2);", ""),
    ("stdin kept", "(void)os_dup2((int)nul, 0);", ""),
    ("PATH ignored", 'env_getenv(g_envp, "PATH")', "nullptr"),
    ("truncated PATH entry executed", "if (!n || too_long) continue;", "if (!n) continue;"),
    ("entry cap", "ctx->count >= GIT_MAX_ENTRIES", "ctx->count > GIT_MAX_ENTRIES"),
    ("name cap", "n < GIT_NAME_MAX && path[n]", "n <= GIT_NAME_MAX && path[n]"),
    ("whole path kept", " && path[n] != '/'", ""),
    ("rename second name kept", "(path[-3] == 'R' || path[-3] == 'C')", "(path[-3] == 'R')"),
    ("status column", "x == '?' || y == ' ' || !y ? x : y", "x == '?' || !y ? x : y"),
    ("record minimum", "cur + 4 < end", "cur + 3 < end"),
    ("branch cap", "if (n < GIT_BRANCH_MAX)", "if (n <= GIT_BRANCH_MAX)"),
    ("upstream kept", " || (c == '.' && p[1] == '.')", ""),
    ("no-commits prefix kept", "if (!git_no_commits[k]) p += k;", ""),
    ("untrusted runs", "return git_repo_trusted(cur);", "return 1;"),
    ("ancestors not probed", "cur[i] = 0;\n    }", "return 0;\n    }"),
    ("virtual mode looked up", "if (!dm || !name || dm->virtual_mode) return 0;", "if (!dm || !name) return 0;"),
    ("defer ignored", "if (g_git_defer || dm->virtual_mode) return 0;", "if (dm->virtual_mode) return 0;"),
]


def test_mutants(t: Path, bindir: Path, expect: list[str]) -> None:
    src = (ROOT / SRC).read_text()
    for name, old, _ in MUTANTS:
        assert old in src, f"mutation anchor vanished: {name}"
    noticed: dict[str, bool] = {}

    def job(i: int, name: str, old: str, new: str):
        def go() -> None:
            mt = t / f"m{i}"
            mt.mkdir()
            (mt / "git_status.c").write_text(src.replace(old, new, 1))
            try:
                exe = build("x86_64", mt, str(mt / "git_status.c"))
                test_fake(exe, mt, bindir)
                test_deadline(exe, mt, bindir)
                test_branch_parser(exe)
                test_fixed_defects(exe, mt)
                if shutil.which("git"):
                    test_real(exe, mt)
                noticed[name] = False
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, AssertionError, StopIteration, OSError):
                noticed[name] = True
        return go

    H.parallel([job(i, *m) for i, m in enumerate(MUTANTS)])
    survivors = sorted(n for n, ok in noticed.items() if not ok)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] GS6. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build("x86_64", t / "x86")
        bindir = fake_bin(t / "bin")
        test_real(exe, t / "x86")
        outs = test_fake(exe, t / "x86", bindir)
        test_deadline(exe, t / "x86", bindir)
        test_branch_parser(exe)
        test_fixed_defects(exe, t / "x86")
        if H.available("aarch64"):
            a64 = build("aarch64", t / "a64")
            d0 = fake_repo(t / "a64", "r", b"## main\x00 M a\x00?? b/c\x00", "o")
            got = run(a64, "c", f"R {d0}\nL a\nL b\n", path=f"{bindir}:/usr/bin:/bin", arch="aarch64")
            want = run(exe, "c", f"R {d0}\nL a\nL b\n", path=f"{bindir}:/usr/bin:/bin")
            assert untimed(got) == untimed(want), (got, want)
            print("[PASS] GS5. qemu-aarch64: the C module gives the x86_64 results")
        else:
            print("[SKIP] GS5: aarch64 toolchain/qemu not installed")
        test_mutants(t, bindir, outs)
    print("ALL C GIT STATUS TESTS PASSED.")


if __name__ == "__main__":
    main()
