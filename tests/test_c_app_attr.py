#!/usr/bin/env python3
"""A2.3: src/app/app_attr.c versus frozen x86_64 assembly oracle.

AAT1 differential (x86_64):
    - App_cmd_info, App_cmd_chmod (NULL, FE_IS_PARENT, OOM, normal)
    - App_cmd_link (symlink/hardlink, NULL, FE_IS_PARENT, OOM)
    - App_cmd_trash (NULL, FE_IS_PARENT, error, OK + undo_push)
    - App_cmd_undo (empty, undone, error)
    - App_apply_chmod on real files & symlinks (missing ENOENT, invalid owner_buf
      cases incl. u32 overflow -> EINVAL, chmod regular 0751, chown to self on
      regular & symlink, symlink unchanged uid:gid -> EOPNOTSUPP)
    - App_apply_link on real files (symlink OK/EEXIST, hardlink OK/EEXIST)
AAT2 qemu-aarch64 matches x86_64 byte for byte
AAT3 mutation check (15 mutants)
"""

import os
import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/app/app_attr.c"
REF = "tests/harness/app_attr_reference.s"
CORE = [
    "src/core/oop_rt.c", "src/core/string.c", "src/core/string_path.c",
    "src/core/utf8.c", "src/core/memory.c", "src/core/mem_prims.c",
    "build/i18n_en.c",
]


def build(arch: str, t: Path, src_ovr: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "app_attr_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "FilePane_get_selected_entry=fake_FilePane_get_selected_entry",
            "--redefine-sym", "DirModel_entry_name=fake_DirModel_entry_name",
            "--redefine-sym", "trash_move_file=fake_trash_move_file",
            "--redefine-sym", "undo_push=fake_undo_push",
            "--redefine-sym", "undo_pop_and_apply=fake_undo_pop_and_apply",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    defs = [f'-DATTR_SRC="{src_ovr or (ROOT / SRC)}"']
    return H.build(arch, t, ["tests/harness/app_attr_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


def make_script(d: Path) -> bytes:
    d.mkdir(parents=True, exist_ok=True)
    reg = d / "reg.txt"
    reg.write_text("hello")
    reg.chmod(0o644)
    lnk = d / "sym.lnk"
    if not lnk.is_symlink():
        lnk.symlink_to(reg)
    uid, gid = os.getuid(), os.getgid()
    own = f"{uid}:{gid}"
    lines = [
        "I 0 0 0", "I 1 32 0", "I 1 0 1", "I 1 0 0",
        "M 0 0 0", "M 1 32 0", "M 1 0 1", "M 1 0 0",
        "L 0 0 0 0", "L 0 1 32 0", "L 0 1 0 1", "L 0 1 0 0", "L 1 1 0 0",
        "T 0 0 0", "T 1 32 0", "T 1 0 -2", "T 1 0 0",
        "U 0", "U 1", "U -17",
        # App_apply_chmod
        f"A {d}/missing {0o600} {uid} {gid} {own}",
        f"A {reg} {0o600} {uid} {gid} !",
        f"A {reg} {0o600} {uid} {gid} 1000",
        f"A {reg} {0o600} {uid} {gid} 1000:",
        f"A {reg} {0o600} {uid} {gid} 1000:1000x",
        f"A {reg} {0o600} {uid} {gid} 4294967296:0",
        f"A {reg} {0o751} {uid} {gid} {own}",             # chmod 0751, same owner
        f"A {reg} {0o640} {uid + 1} {gid} {own}",         # chmod 0640 + chown to self
        f"A {lnk} {0o777} {uid} {gid} {own}",             # symlink unchanged owner -> EOPNOTSUPP
        f"A {lnk} {0o777} {uid} {gid + 1} {own}",         # symlink changed gid -> lchown OK
        # App_apply_link
        f"K 0 {d} reg.txt {d}/new_sym",
        f"K 0 {d} reg.txt {d}/new_sym",                   # EEXIST
        f"K 1 {d} reg.txt {d}/new_hard",
        f"K 1 {d} reg.txt {d}/new_hard",                  # EEXIST
    ]
    return ("\n".join(lines) + "\n").encode()


def run_one(arch: str, exe: Path, impl: str, d: Path) -> str:
    s = make_script(d)
    r = H.run_impl(arch, exe, impl, stdin=s)
    assert r.returncode == 0, (arch, impl, r.returncode, r.stderr[-200:])
    # normalize temp dir prefix so ref & c outputs compare identically
    return r.stdout.decode().replace(str(d), "<DIR>")


def test_differential(exe: Path, t: Path) -> str:
    ref_out = run_one("x86_64", exe, "r", t / "d_ref")
    c_out = run_one("x86_64", exe, "c", t / "d_c")
    assert ref_out == c_out, H.unified_diff(ref_out, c_out)
    for needle in ("call InfoDialog_new 1 p=|/act/target.txt|",
                   "call ChmodDialog_new 1 p=|/act/target.txt|",
                   "tag=18", "tag=19",
                   "call undo_push k=3 o=|/act/target.txt|",
                   "E_NOENT", "E_INVAL", "E_OPNOTSUPP", "E_EXIST",
                   f"AC mode={0o751}", f"AC mode={0o640}",
                   "AK sr=1 lnk=1", "AK sr=1 lnk=0"):
        assert needle in c_out, f"coverage missing: {needle}"
    print(f"[PASS] AAT1. app_attr matches frozen asm byte for byte ({len(c_out.splitlines())} lines)")
    return c_out


def test_mutations(t: Path, baseline: str) -> None:
    src = (ROOT / SRC).read_text()
    muts = [
        ("par-guard", "if (!allow_dotdot && (fe->flags & FE_IS_PARENT)) return 0;",
         "if (allow_dotdot && (fe->flags & FE_IS_PARENT)) return 0;"),
        ("link-hard", "const char *title = is_hard ? lang->s[LS_dlg_title_hardlink] : lang->s[LS_dlg_title_symlink];",
         "const char *title = lang->s[LS_dlg_title_symlink]; (void)is_hard;"),
        ("link-tag", "uint32_t tag = is_hard ? OP_HARDLINK : OP_SYMLINK;",
         "uint32_t tag = OP_SYMLINK; (void)is_hard;"),
        ("trash-undo", "undo_push(UNDO_TRASH, tb->src, tb->trash, tb->info);", ""),
        ("undo-empty", "if (rc == 0) {", "if (rc == 99) {"),
        ("u32-ovf", "if (v > 0xFFFFFFFFull) return nullptr;", "if (v > 0xFFFFFFFFFFFFull) return nullptr;"),
        ("u32-empty", "if (digits == 0) return nullptr;", "if (digits > 99) return nullptr;"),
        ("is-lnk", "int is_lnk = ((st.mode & S_IFMT) == S_IFLNK);", "int is_lnk = 0; (void)st;"),
        ("chmod-call", "if (!is_lnk) {", "if (is_lnk) {"),
        ("chown-diff", "if (uid != dlg->uid || gid != dlg->gid) {",
         "if (uid != dlg->uid && gid != dlg->gid) {"),
        ("lnk-eop", "if (is_lnk) { aa_err_status(app, -EOPNOTSUPP); return; }", ""),
        ("stat-nofollow", "intptr_t sr = os_statat(AT_FDCWD, target, &st, 0);",
         "intptr_t sr = os_statat(AT_FDCWD, target, &st, 1);"),
        ("apply-sym", "rc = is_hard ? os_linkat(AT_FDCWD, src, AT_FDCWD, dst, 0) : os_symlinkat(src, AT_FDCWD, dst);",
         "rc = os_linkat(AT_FDCWD, src, AT_FDCWD, dst, 0); (void)is_hard;"),
        ("apply-reload", "App_reload_panes(app, nullptr);", ""),
        ("bad-inval", "if (aa_parse_uid_gid((const char *)dlg->owner_buf, &uid, &gid) < 0) {",
         "if (aa_parse_uid_gid((const char *)dlg->owner_buf, &uid, &gid) < -99) {"),
    ]
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src and old != new, name
        mp = t / f"m{idx}" / "app_attr.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        d = t / f"md{idx}"
        s = make_script(d)
        r = H.run_impl("x86_64", exe, "c", stdin=s)
        if r.returncode == 0 and r.stdout.decode().replace(str(d), "<DIR>") == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] AAT3. {len(muts)}/{len(muts)} mutants killed across app_attr.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe, t)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            arm_out = run_one("aarch64", exe_arm, "c", t / "d_arm")
            assert arm_out == out, "aarch64 differs"
            print("[PASS] AAT2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
