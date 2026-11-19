#!/usr/bin/env python3
"""A2.5: src/app/app_close_dialog.c versus frozen x86_64 assembly oracle.

ACD1 differential (x86_64):
    - App_cmd_help, App_cmd_mkdir
    - App_close_dialog: NULL active_dialog, DLG_CANCEL (frees without running op),
      OP_MKDIR (empty, OK, -EEXIST), OP_NEWFILE (empty, OK, -EACCES),
      OP_RENAME (empty, NULL entry, relative OK + undo_push, absolute '/tmp/abs' OK,
      -EEXIST), OP_COPY, OP_MOVE, OP_DELETE, OP_QUIT, OP_PKG_INST (25),
      OP_FILTER (clears msg_expire_ms, copies filter, apply_filter, cursor/scroll=0),
      OP_GOTO (empty, VFS load OK, chdir OK, chdir -ENOENT),
      delegated App_close_dialog_ext (OK & -errno)
ACD2 qemu-aarch64 matches x86_64 byte for byte
ACD3 mutation check (15 mutants)
"""

import subprocess
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/app/app_close_dialog.c"
REF = "tests/harness/app_close_dialog_reference.s"
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
        o = t / "app_close_dialog_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        redefs = [
            "--redefine-sym", "FilePane_get_selected_entry=fake_FilePane_get_selected_entry",
            "--redefine-sym", "DirModel_entry_name=fake_DirModel_entry_name",
            "--redefine-sym", "FilePane_ensure_visible=fake_FilePane_ensure_visible",
            "--redefine-sym", "DirModel_apply_filter=fake_DirModel_apply_filter",
            "--redefine-sym", "DirModel_chdir=fake_DirModel_chdir",
            "--redefine-sym", "pkg_vfs_load_dir=fake_pkg_vfs_load_dir",
            "--redefine-sym", "fs_mkdir=fake_fs_mkdir",
            "--redefine-sym", "fs_touch=fake_fs_touch",
            "--redefine-sym", "fs_rename_noreplace=fake_fs_rename_noreplace",
            "--redefine-sym", "undo_push=fake_undo_push",
        ]
        subprocess.run(["objcopy", *redefs, str(o)], check=True, capture_output=True)
        extra.append(o)
    defs = [f'-DCD_SRC="{src_ovr or (ROOT / SRC)}"']
    return H.build(arch, t, ["tests/harness/app_close_dialog_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


SCRIPT = "\n".join([
    "H",
    "M",
    # C <has_dlg> <res> <op_tag> <aux1> <aux2> <buf_or_!>
    "C 0 1 1 0 0 dir1",          # NULL active_dialog
    "C 1 2 1 0 0 dir1",          # DLG_CANCEL -> free only
    "C 1 1 1 0 0 !",             # OP_MKDIR empty
    "C 1 1 1 0 0 newdir",        # OP_MKDIR OK
    "C 1 1 1 -17 0 dupdir",      # OP_MKDIR -EEXIST
    "C 1 1 6 0 0 !",             # OP_NEWFILE empty
    "C 1 1 6 0 0 new.txt",       # OP_NEWFILE OK
    "C 1 1 6 -13 0 bad.txt",     # OP_NEWFILE -EACCES
    "C 1 1 2 1 0 !",             # OP_RENAME empty
    "C 1 1 2 0 0 ren.txt",       # OP_RENAME NULL entry
    "C 1 1 2 1 0 ren.txt",       # OP_RENAME relative OK
    "C 1 1 2 1 0 /tmp/abs.txt",  # OP_RENAME absolute OK
    "C 1 1 2 1 -17 taken.txt",   # OP_RENAME -EEXIST
    "C 1 1 3 0 0 /dst/cp",       # OP_COPY
    "C 1 1 4 0 0 /dst/mv",       # OP_MOVE
    "C 1 1 5 0 0 !",             # OP_DELETE
    "C 1 1 11 0 0 !",            # OP_QUIT
    "C 1 1 25 0 0 pkg.tgz",      # OP_PKG_INST
    "C 1 1 7 0 0 *.py",          # OP_FILTER
    "C 1 1 8 -1 0 !",            # OP_GOTO empty
    "C 1 1 8 0 0 vfs://box",     # OP_GOTO VFS OK
    "C 1 1 8 -1 0 /home/u",      # OP_GOTO chdir OK
    "C 1 1 8 -1 -2 /missing",    # OP_GOTO chdir -ENOENT
    "C 1 1 13 0 0 !",            # delegated ext OK
    "C 1 1 13 -2 0 !",           # delegated ext -ENOENT
]) + "\n"


def test_differential(exe: Path) -> str:
    out = H.diff_impls(exe, stdin=SCRIPT.encode()).decode()
    for needle in ("call HelpDialog_new 1", "tag=1",
                   "call fs_mkdir |/work/newdir|", "call fs_touch |/work/new.txt|",
                   "call fs_rename_noreplace o=|/work/old.txt| n=|/work/ren.txt|",
                   "call fs_rename_noreplace o=|/work/old.txt| n=|/tmp/abs.txt|",
                   "call undo_push k=1 o=|/work/old.txt| c=|/tmp/abs.txt|",
                   "call reload_both_panes 1 f=|abs.txt|",
                   "call App_task_start 1 op=1 dst=|/dst/cp|",
                   "call App_task_start 1 op=3 dst=|-|",
                   "CD ad=0 run=0 rd=1", "call App_pkg_install_confirm 1",
                   "call DirModel_apply_filter |*.py|",
                   "call pkg_vfs_load_dir env=1 m=1 u=|vfs://box| rc=0",
                   "call DirModel_chdir |/home/u| rc=0",
                   "E_EXIST", "E_ACCES", "E_NOENT"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] ACD1. app_close_dialog matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    src = (ROOT / SRC).read_text()
    muts = [
        ("ok-chk", "if (result == DLG_OK) {", "if (result != DLG_OK) {"),
        ("mkdir-empty", "if (buf[0] == '\\0') return 0;", "if (buf[0] != '\\0') return 0;"),
        ("mkdir-ok", "App_set_status(app, i18n_get()->s[LS_app_ok_mkdir], MSG_OK);",
         "App_set_status(app, i18n_get()->s[LS_app_ok_newfile], MSG_OK);"),
        ("touch-ok", "App_set_status(app, i18n_get()->s[LS_app_ok_newfile], MSG_OK);",
         "App_set_status(app, i18n_get()->s[LS_app_ok_mkdir], MSG_OK);"),
        ("ren-abs", "if (buf[0] == '/') (void)str_copy(rb->new_p, buf, PATH_MAX);",
         "if (buf[0] == 'X') (void)str_copy(rb->new_p, buf, PATH_MAX);"),
        ("ren-undo", "undo_push(UNDO_RENAME, rb->old_p, rb->new_p, nullptr);", ""),
        ("ren-base", "reload_both_panes(app, path_basename(buf));",
         "reload_both_panes(app, buf);"),
        ("copy-op", "case OP_COPY: App_task_start(app, TASK_OP_COPY, buf); break;",
         "case OP_COPY: App_task_start(app, TASK_OP_MOVE, buf); break;"),
        ("quit-run", "case OP_QUIT: app->running = 0; break;",
         "case OP_QUIT: app->running = 1; break;"),
        ("pkg-inst", "case 25: App_pkg_install_confirm(app, idlg); break;", "case 25: break;"),
        ("flt-exp", "sb->msg_expire_ms = 0;", "sb->msg_expire_ms = 1;"),
        ("flt-cur", "pane->cursor = 0; pane->scroll = 0;", "pane->cursor = 1; pane->scroll = 0;"),
        ("goto-vfs", "if (pkg_vfs_load_dir((char **)(uintptr_t)app->envp, m, buf) != 0) {",
         "if (pkg_vfs_load_dir((char **)(uintptr_t)app->envp, m, buf) == 0) {"),
        ("err-reload", "if (err < 0) {", "if (err > 0) {"),
        ("free-dlg", "Object_free((Object *)dlg);", ""),
    ]
    survivors: list[str] = []

    def check(idx: int, name: str, old: str, new: str) -> None:
        assert old in src and old != new, name
        mp = t / f"m{idx}" / "app_close_dialog.c"
        mp.parent.mkdir(parents=True, exist_ok=True)
        mp.write_text(src.replace(old, new, 1))
        exe = build("x86_64", t / f"mb{idx}", mp)
        r = H.run_impl("x86_64", exe, "c", stdin=SCRIPT.encode())
        if r.returncode == 0 and r.stdout.decode() == baseline:
            survivors.append(name)

    H.parallel([lambda i=i, m=m: check(i, *m) for i, m in enumerate(muts)])
    assert not survivors, f"surviving mutants: {survivors}"
    print(f"[PASS] ACD3. {len(muts)}/{len(muts)} mutants killed across app_close_dialog.c")


def main() -> None:
    with H.workdir() as wd:
        t = Path(wd)
        exe = build("x86_64", t / "x86")
        out = test_differential(exe)
        if H.available("aarch64"):
            exe_arm = build("aarch64", t / "arm64")
            r = H.run_impl("aarch64", exe_arm, "c", stdin=SCRIPT.encode())
            assert r.returncode == 0 and r.stdout.decode() == out, "aarch64 differs"
            print("[PASS] ACD2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, out)


if __name__ == "__main__":
    main()
