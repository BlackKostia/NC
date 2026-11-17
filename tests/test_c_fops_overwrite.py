#!/usr/bin/env python3
"""src/fs/file_ops_overwrite.c versus the frozen assembly (tests/harness/file_ops_overwrite_reference.s): crash-safe "Overwrite".

OW1 differential, x86_64: fo_open_overwrite / fo_overwrite_open / fo_overwrite_commit on two identical trees (oracle on A, C on B):
    return values (fd presence, the rax:rdx pair), the temp name written to out_tmp (the whole 4 KiB buffer), the files and modes the
    trees end up with - regular targets, missing targets, directories, symlinks, every other st_mode kind, a read-only directory
    (EACCES -> in place), sub-directory prefixes around the PATH_MAX - 48 limit, 0..9 pre-existing colliding temp names (8 attempts)
OW2 the observable guarantees, on x86_64 and under qemu-aarch64 (C only there, outputs normalised for the pid): the target is
    the complete old or the complete new file, no temp file is left, modes are applied
OW3 mutation check: one-line mutants of the C module must all be noticed
"""

import os
import re
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
CLI_C = ["tests/harness/fops_ovw_cli.c", "src/fs/file_ops_overwrite.c", "src/core/string.c", "src/core/utf8.c", "src/core/memory.c", "src/core/syscall.c",
         "src/core/try_rt.c", "src/core/mem_prims.c"]
REF = "tests/harness/file_ops_overwrite_reference.s"
S_REG, S_DIR, S_LNK = 0o100000, 0o040000, 0o120000
PID = re.compile(r"\.duop-ovw\.[0-9a-f]{8}\.")
ENV = {"PATH": os.environ.get("PATH", "")}


def build(arch: str, t: Path, src: str = "src/fs/file_ops_overwrite.c") -> Path:
    files = [src if c.endswith("file_ops_overwrite.c") else c for c in CLI_C]
    if arch != "x86_64":
        return H.build(arch, t, files)
    ref, thunk = t / "ovw_ref.o", t / "ovw_thunk.o"
    inc = ["-I", str(ROOT / "include/os/linux/x86_64"), "-I", str(ROOT / "include")]
    subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(ref)], check=True, capture_output=True)
    H.rename_defined_globals([ref], "ref_")
    subprocess.run(["as", *inc, str(ROOT / "tests/harness/ovw_thunk_x86_64.s"), "-o", str(thunk)], check=True, capture_output=True)
    return H.build(arch, t, files, [ref, thunk], cflags=["-I", str(ROOT / "tests/harness")])


def tree(root: Path) -> Path:
    """The starting tree: regular files, a directory, symlinks and a read-only directory with a writable file."""
    root.mkdir()
    for name, data in (("reg", b"old-reg"), ("other", b"old-other"), ("sub_f", b"old-sub"), ("long", b"L" * 300)):
        (root / name).write_bytes(data)
    (root / "reg").chmod(0o640)
    (root / "dir").mkdir()
    (root / "sub").mkdir()
    (root / "sub" / "f").write_bytes(b"old-sub-f")
    os.symlink("reg", root / "link")
    os.symlink("nowhere", root / "dangling")
    ro = root / "ro"
    ro.mkdir()
    (ro / "f").write_bytes(b"old-ro-f")
    (ro / "f").chmod(0o666)
    ro.chmod(0o555)
    return root


def run(exe: Path, a: Path, b: Path, script: str, arch: str = "x86_64") -> list[str]:
    res = subprocess.run([*H.ARCHS[arch]["run"], str(exe), str(a), str(b)], input=script.encode(), capture_output=True, env=ENV, timeout=120)
    assert res.returncode == 0, (res.returncode, res.stderr[-300:])
    return res.stdout.decode().splitlines()


def differential(exe: Path, t: Path, tag: str, script: str) -> list[str]:
    a, b = tree(t / f"{tag}_a"), tree(t / f"{tag}_b")
    try:
        lines = run(exe, a, b, script)
        assert lines and not any(" DIFF" in ln for ln in lines), f"{tag}: oracle and C differ:\n" + "\n".join(lines)
        snap_a, snap_b = H.snapshot(a), H.snapshot(b)
        assert snap_a == snap_b, f"{tag}: trees differ after the run:\n{snap_a}\n{snap_b}"
    finally:
        for d in (a, b):
            (d / "ro").chmod(0o755)
    return lines


def test_differential(exe: Path, t: Path) -> int:
    n = 0
    cases = {
        "reg_replace": f"O reg {S_REG | 0o640:o} 600\nO reg {S_REG | 0o640:o} 644\nO reg {S_REG | 0o640:o} 600 N\n",
        "missing_inplace": "O fresh 0 600\nO fresh2 0 644\nO long 0 600\nO long 40000 600\n",
        "dir_target": f"O dir {S_DIR | 0o755:o} 600\nO dir {S_REG:o} 600\n",
        "symlink_target": f"O link {S_LNK | 0o777:o} 600\nO link {S_REG:o} 600\nO dangling {S_LNK:o} 600\nO dangling {S_REG:o} 600\n",
        "sub_prefix": f"O sub/f {S_REG:o} 600\nO sub/missing 0 600\nO nodir/f {S_REG:o} 600\nO ./other {S_REG:o} 640\n",
        "mode_kinds": "".join(f"O other {m:o} 600\n" for m in (0o010000, 0o020000, 0o060000, 0o140000, 0o120000, 0o040000, 0, 0o100000)),
        "plain_open": "W reg 600\nW sub/f 644\nW nodir/x 600\nW dir 600\nW reg 777\n",
        "commit_alone": f"W reg 600\nM missing_tmp reg\nM reg other\nM reg nodir/x\nM nope nope\n",
    }
    if os.geteuid() != 0:
        cases["ro_dir_fallback"] = f"O ro/f {S_REG:o} 600\nO ro/f {S_REG:o} 644 N\nW ro/f 600\nO ro/new 0 600\n"
    cases["eperm_fallback"] = f"P\nO reg {S_REG:o} 600\nO long {S_REG:o} 644\nW reg 600\nO fresh 0 600\n"
    for tag, script in cases.items():
        differential(exe, t, tag, script)
        n += script.count("\n")
    for k in range(0, 10):                                               # k colliding temp names: success on the (k+1)-th try, -EEXIST after 8
        differential(exe, t, f"collide{k}", f"O reg {S_REG:o} 600\nX {k}\nO reg {S_REG:o} 600\nW other 600\n")
        n += 4
    for plen in (2, 4046, 4047, 4048, 4049, 4050, 4090, 5000):          # prefix length around PATH_MAX - 48 (4048)
        name = ("p" * (plen - 1) + "/f") if plen < 200 else "/".join(["d" * 200] * (plen // 201)) + "/" + "q" * (plen % 201 - 1) + "/f"
        differential(exe, t, f"long{plen}", f"O {name} 0 600\nW {name} 600\n")
        n += 2
    print(f"[PASS] OW1. fo_open_overwrite / fo_overwrite_open / fo_overwrite_commit identical to the asm in {n} scripted calls "
          f"(return pair, 4 KiB out_tmp buffer, trees and modes, collisions 0..9, prefix limit, read-only dir)")
    return n


def outcome(arch: str, exe: Path, t: Path, tag: str, script: str) -> tuple[list[str], Path]:
    d = tree(t / f"{tag}_{arch}")
    other = tree(t / f"{tag}_{arch}_x")
    lines = run(exe, other, d, script, arch)
    (d / "ro").chmod(0o755)
    (other / "ro").chmod(0o755)
    return [PID.sub(".duop-ovw.<pid>.", ln) for ln in lines], d


def test_guarantees(arch: str, exe: Path, t: Path) -> list[str]:
    lines, d = outcome(arch, exe, t, "g1", f"O reg {S_REG | 0o640:o} 600\nO fresh 0 644\nO dir {S_DIR:o} 600\nO link {S_LNK:o} 600\n")
    out = {ln.split()[1]: ln for ln in lines}
    assert "c=" in out["reg"] and " commit=0" in out["reg"] and "/1 " in out["reg"], out["reg"]
    assert (d / "reg").read_bytes() == b"payload:reg" and (d / "reg").stat().st_mode & 0o7777 == 0o600, "replaced through the temp file with the new mode"
    assert (d / "fresh").read_bytes() == b"payload:fresh" and "/0 " in out["fresh"]
    assert "/-21" in out["dir"] or "c=-21/0" in out["dir"], out["dir"]                  # EISDIR in place
    assert "c=-40/0" in out["link"], out["link"]                                        # ELOOP: O_NOFOLLOW
    assert not [p for p in d.iterdir() if p.name.startswith(".duop-ovw.")], "no temp file left after a committed overwrite"
    lines2, d2 = outcome(arch, exe, t, "g2", f"O reg {S_REG:o} 600 N\nW reg 600\n")
    left = sorted(p.name for p in d2.iterdir() if p.name.startswith(".duop-ovw."))
    assert len(left) == 2 and (d2 / "reg").read_bytes() == b"old-reg", (left, "an uncommitted temp file leaves the old target intact")
    assert re.search(r"\.duop-ovw\.[0-9a-f]{8}\.00000001$", left[0]) and left[1].endswith(".00000002"), left
    lines3, _ = outcome(arch, exe, t, "g3", f"O reg {S_REG:o} 600\nX 8\nO reg {S_REG:o} 600\n")
    assert "c=-17/0" in lines3[-1] or "c=-17/0" in lines3[-2], lines3                  # 8 colliding names: -EEXIST
    print(f"[PASS] OW2-{arch}. old-or-new guarantee, mode applied, ELOOP/EISDIR in place, sequence numbers, EEXIST after 8 collisions")
    return lines + lines2 + lines3


MUTANTS = [
    ("retries 9", "#define OVW_TRIES 8", "#define OVW_TRIES 9"),
    ("EEXIST not retried", "== -EEXIST", "== -EBADF"),
    ("EACCES fallback dropped", "r == -EACCES || ", ""),
    ("EPERM fallback dropped", "|| r == -EPERM", ""),
    ("O_EXCL dropped", "O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC", "O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC"),
    ("O_TRUNC dropped (in place)", "O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC", "O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC"),
    ("prefix limit off by one", "> PATH_MAX - OVW_NAME_ROOM", "> PATH_MAX - OVW_NAME_ROOM + 1"),
    ("prefix limit off by one (low)", "> PATH_MAX - OVW_NAME_ROOM", ">= PATH_MAX - OVW_NAME_ROOM"),
    ("only S_IFREG replaced", "(dst_mode & S_IFMT) == S_IFREG", "(dst_mode & S_IFMT) != S_IFDIR"),
    ("used flag lost", "{r, 1}", "{r, 0}"),
    ("in-place mode ignored", "O_NOFOLLOW | O_CLOEXEC, new_mode)", "O_NOFOLLOW | O_CLOEXEC, 0)"),
    ("sequence never advances", "__atomic_add_fetch(&g_fo_ovw_seq, 1, __ATOMIC_SEQ_CST)", "g_fo_ovw_seq + 1"),
    ("hex digit table", '"0123456789abcdef"', '"0123456789ABCDEF"'),
    ("commit replaces nothing", "os_renameat2(dfd, tmp, dfd, name, 0)", "os_renameat2(dfd, tmp, dfd, tmp, 0)"),
]
SCRIPT = (f"O long 0 600\nO reg {S_REG:o} 600\nO fresh 0 600\nO dir {S_DIR:o} 600\nO link {S_LNK:o} 600\nO sub/f {S_REG:o} 600\nW reg 600\nM zzz reg\n"
          f"X 3\nO reg {S_REG:o} 640\nX 8\nO reg {S_REG:o} 600\nO ro/f {S_REG:o} 600\n" + f"O {'p' * 4047}/f {S_REG:o} 600\nO {'p' * 4048}/f {S_REG:o} 600\nW {'p' * 4047}/f 600\nW {'p' * 4048}/f 600\n"
          f"O reg {S_REG:o} 600 N\nO reg {S_REG:o} 644\nP\nO reg {S_REG:o} 600\nO long {S_REG:o} 600\n")


def test_mutants(t: Path) -> None:
    src = (ROOT / "src/fs/file_ops_overwrite.c").read_text()
    survivors: list[str] = []
    for i, (name, old, new) in enumerate(MUTANTS):
        assert old in src, f"mutation anchor vanished: {name}"
        mp = t / f"mut{i}.c"
        mp.write_text(src.replace(old, new, 1))
        mt = t / f"m{i}"
        mt.mkdir()
        try:
            exe = build("x86_64", mt, str(mp))
            a, b = tree(mt / "a"), tree(mt / "b")
            lines = run(exe, a, b, SCRIPT)
            noticed = any(" DIFF" in ln for ln in lines) or H.snapshot(a) != H.snapshot(b)
            (a / "ro").chmod(0o755)
            (b / "ro").chmod(0o755)
        except (subprocess.CalledProcessError, AssertionError, OSError):          # an unreadable result file is a difference too
            noticed = True
        if not noticed:
            survivors.append(name)
    assert not survivors, f"mutants not noticed: {survivors}"
    print(f"[PASS] OW3. {len(MUTANTS)}/{len(MUTANTS)} mutants of the C module are noticed")


def main() -> None:
    outs: dict[str, list[str]] = {}
    for arch in ("x86_64", "aarch64"):
        if not H.available(arch):
            print(f"[SKIP] {arch}: toolchain/qemu not installed")
            continue
        with H.workdir() as d:
            t = Path(d)
            exe = build(arch, t)
            if arch == "x86_64":
                test_differential(exe, t)
            outs[arch] = test_guarantees(arch, exe, t)
            if arch == "x86_64":
                test_mutants(t)
    if len(outs) == 2:
        norm = lambda ls: [re.sub(r"c=\d+/", "c=fd/", re.sub(r" same\b", "", re.sub(r"ref=\S+ ", "", ln))) for ln in ls]       # the oracle exists on x86_64 only; fd numbers differ under qemu
        assert norm(outs["x86_64"]) == norm(outs["aarch64"]), "x86_64 and aarch64 behave differently"
        print("[PASS] OW2x. x86_64 and qemu-aarch64 produce identical results")
    print("ALL C FILE-OPS OVERWRITE TESTS PASSED.")


if __name__ == "__main__":
    main()
