#!/usr/bin/env python3
"""src/fs/git_trust.c versus the frozen assembly: git_repo_trusted() on ~60 repository layouts -- missing / empty / plain config,
filter and include sections in any letter case, NUL bytes, files around the 32 KiB limit, symlinked .git or config, fifo and
directory configs, unreadable config, .git that is not a directory, over-long paths -- must give the same answer."""

import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
CLI_C = ["tests/harness/git_trust_cli.c", "src/fs/git_trust.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c",
         "src/core/try_rt.c", "src/core/mem_prims.c"]
ENV = {"PATH": os.environ.get("PATH", "")}


def build(t: Path) -> Path:
    ref = t / "git_trust_ref.o"
    subprocess.run(["as", "-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include"), str(ROOT / "tests/harness/git_trust_reference.s"), "-o", str(ref)], check=True)
    H.rename_defined_globals([ref], "ref_")
    return H.build("x86_64", t, CLI_C, [ref])


def layouts(t: Path) -> dict[str, str]:
    cases: dict[str, str] = {}

    def repo(name: str, config: bytes | None, mode: int = 0o644) -> Path:
        d = t / name / ".git"
        d.mkdir(parents=True)
        if config is not None:
            (d / "config").write_bytes(config)
            os.chmod(d / "config", mode)
        cases[name] = str(d)
        return d

    repo("missing", None)
    repo("empty", b"")
    repo("plain", b"[core]\n\trepositoryformatversion = 0\n\tbare = false\n[remote \"origin\"]\n\turl = https://example.invalid/x.git\n")
    for i, text in enumerate([b"[filter \"lfs\"]\n\tclean = git-lfs clean\n", b"[FILTER]\n", b"[core]\nfIlTeR = x\n", b"[include]\n\tpath = ../x\n", b"[INCLUDEIF \"gitdir:/\"]\n",
                              b"[core]\n\tname = my-include-notes\n", b"[core]\nfsmonitor = true\n", b"[alias]\n\tx = !echo hi\n"]):
        repo(f"words{i}", text)
    repo("nul_mid", b"[core]\n\x00[filter]\n")
    repo("nul_end", b"[core]\n\x00")
    for size in (32766, 32767, 32768, 32769, 32770, 100000):
        repo(f"size{size}", (b"# pad\n" * (size // 6 + 1))[:size])
    repo("size32768_filter_at_end", (b"#" * 32760 + b"\n[filter]")[:32768])
    repo("size32769_clean", b"#" * 32769)
    repo("unreadable", b"[core]\n", mode=0)
    d = repo("config_symlink", None)
    (t / "config_symlink" / "real").write_bytes(b"[core]\n")
    os.symlink("../real", d / "config")
    d = repo("config_dir", None)
    (d / "config").mkdir()
    d = repo("config_fifo", None)
    os.mkfifo(d / "config")
    d = repo("config_dangling", None)
    os.symlink("nowhere", d / "config")
    (t / "gitfile").mkdir()
    (t / "gitfile" / ".git").write_text("gitdir: ../elsewhere\n")
    cases["gitfile"] = str(t / "gitfile" / ".git")
    (t / "real_git").mkdir()
    (t / "real_git" / "dotgit").mkdir()
    (t / "real_git" / "dotgit" / "config").write_bytes(b"[core]\n")
    os.symlink("dotgit", t / "real_git" / ".git")
    cases["git_symlink"] = str(t / "real_git" / ".git")
    cases["no_such_dir"] = str(t / "nothing" / ".git")
    cases["empty_path"] = ""
    for n in (4000, 4079, 4080, 4081, 4095):                       # PATH_MAX - 16 = 4080: the longest accepted .git path is 4079 bytes
        cases[f"len{n}"] = deep_dir(t / f"deep{n}", n, plain=n != 4095)
    return cases


def deep_dir(base: Path, total: int, plain: bool) -> str:
    """a real directory whose absolute path is exactly `total` bytes long (components of at most 200 bytes), with a plain config"""
    base.mkdir()
    cwd = os.getcwd()
    path = str(base)
    try:
        os.chdir(base)
        while len(path) < total:
            comp = "p" * min(200, total - len(path) - 1)
            os.mkdir(comp)
            os.chdir(comp)
            path += "/" + comp
        if plain:
            Path("config").write_bytes(b"[core]\n")
    finally:
        os.chdir(cwd)
    assert len(path) == total
    return path


def main() -> None:
    with H.workdir() as d:
        t = Path(d)
        exe = build(t)
        cases = layouts(t)
        res = subprocess.run([str(exe)], input="\n".join(cases.values()).encode() + b"\n", capture_output=True, timeout=60, env=ENV)
        assert res.returncode == 0, res.stderr
        out = res.stdout.decode().splitlines()
        assert len(out) == len(cases), (len(out), len(cases))
        bad = {k: o for k, o in zip(cases, out) if o[0] != o[2]}
        assert not bad, bad
        got = {k: o[2] for k, o in zip(cases, out)}
        for k in ("missing", "empty", "plain", "words6", "words7", "size32768", "size32767", "len4079"):
            assert got[k] == "1", (k, got[k])
        for k in ("words0", "words1", "words2", "words3", "words4", "words5", "len4080", "len4081", "nul_mid", "nul_end", "size32769", "size32770", "size100000", "size32768_filter_at_end",
                  "config_symlink", "config_dir", "config_fifo", "config_dangling", "gitfile", "git_symlink", "no_such_dir", "empty_path", "len4095"):
            assert got[k] == "0", (k, got[k])
        if os.geteuid() != 0:
            assert got["unreadable"] == "0", got["unreadable"]
        print(f"[PASS] GT1. git_repo_trusted identical to the asm on {len(cases)} repository layouts (config words, NUL, size limit, links, fifo, long paths)")
    print("ALL C GIT TRUST TESTS PASSED.")


if __name__ == "__main__":
    main()
