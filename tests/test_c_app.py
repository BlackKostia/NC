#!/usr/bin/env python3
"""A3.4: src/app/app.c versus frozen x86_64 assembly oracle.

AP1 differential (x86_64):
    - App_vtbl layout (class_name, super, inst_size, dtor)
    - App_new full success: defaults, cfg theme/hidden/sort, lang override vs
      cfg lang_id vs env detect, g_cfg_warn truncated status, active_pane, layout
    - App_new OOM rollback at every single allocation (Object_alloc + all 7 widgets)
    - App_dtor child destruction order (with and without active_dialog) + 4 cleanups
AP2 qemu-aarch64 matches x86_64 byte for byte
AP3 mutation check (14 mutants)
"""

import subprocess
import tempfile
from pathlib import Path

import c_harness as H

ROOT = H.ROOT
SRC = "src/app/app.c"
REF = "tests/harness/app_reference.s"
CORE = ["src/core/string.c", "src/core/string_format.c", "src/core/memory.c", "src/core/mem_prims.c"]


def build(arch: str, t: Path, src_ovr: Path | None = None) -> Path:
    t.mkdir(parents=True, exist_ok=True)
    inc = ["-I", str(ROOT / f"include/os/linux/{arch}"), "-I", str(ROOT / "include")]
    extra = []
    if arch == "x86_64":
        o = t / "app_reference.o"
        subprocess.run(["as", *inc, str(ROOT / REF), "-o", str(o)], check=True, capture_output=True)
        H.rename_defined_globals([o], "ref_")
        extra.append(o)
    defs = [f'-DAPP_SRC="{src_ovr or (ROOT / SRC)}"']
    return H.build(arch, t, ["tests/harness/app_cli.c", *CORE], extra,
                   cflags=["-I", str(ROOT / "tests/harness"), "-I", str(ROOT / "build"), *defs])


# N <fail_mask> <cfg_theme> <find_ret> <detect_ret> <lang_ovr> <hidden> <sort> <warn> <w> <h> <dlg> <lang_id> <left> <right>
SCRIPT = "\n".join([
    "V",
    # 1. All defaults (-1 config), env lang detect, no warn, no dialog
    "N 0 -1 -1 2 -1 -1 -1 0 120 40 0 auto /tmp/a /tmp/b",
    # 2. Config theme=0 (boundary >=0), cfg lang_id found=0 (boundary >=0), hidden=0, sort=0, warn=1, with dialog
    "N 0 0 0 3 -1 0 0 1 80 24 1 uk - -",
    # 3. Explicit CLI lang_override=0 (boundary >=0), cfg theme=2, hidden=1, sort=2
    "N 0 2 1 3 0 1 2 0 100 30 0 en /left /right",
    # 4..11. OOM at every single constructor (bits 0..7)
    "N 1 -1 -1 0 -1 -1 -1 0 80 24 0 en /a /b",
    "N 2 -1 -1 0 -1 -1 -1 0 80 24 0 en /a /b",
    "N 4 -1 -1 0 -1 -1 -1 0 80 24 0 en /a /b",
    "N 8 -1 -1 0 -1 -1 -1 0 80 24 0 en /a /b",
    "N 16 -1 -1 0 -1 -1 -1 0 80 24 0 en /a /b",
    "N 32 -1 -1 0 -1 -1 -1 0 80 24 0 en /a /b",
    "N 64 -1 -1 0 -1 -1 -1 0 80 24 0 en /a /b",
    "N 128 -1 -1 0 -1 -1 -1 0 80 24 0 en /a /b",
]) + "\n"


def test_differential(exe: Path) -> str:
    out = H.diff_impls(exe, stdin=SCRIPT.encode()).decode()
    for needle in ("VTBL cls=App sup=1 sz=560 dtor=1",
                   "App_set_status 1 k=2 m=CFG_TRUNCATED",
                   "Object_free dialog", "Object_free preview", "Object_free screen",
                   "dirwatch_cleanup", "nav_state_cleanup", "du_cache_cleanup", "du_links_cleanup",
                   "DirModel_apply_filter L h=0", "DirModel_sort R s=2"):
        assert needle in out, f"coverage missing: {needle}"
    print(f"[PASS] AP1. app matches frozen asm byte for byte ({len(out.splitlines())} lines)")
    return out


def test_mutations(t: Path, baseline: str) -> None:
    src = (ROOT / SRC).read_text()
    muts = [
        ("git-def", "g_git_defer = 1;", "g_git_defer = 0;"),
        ("th-ge0", "if (cfg->theme >= 0) app->theme_idx = cfg->theme;",
         "if (0) app->theme_idx = cfg->theme;"),
        ("lang-ovr", "if (lang < 0) {", "if (lang <= 0) {"),
        ("lang-fnd", "if (lang < 0) lang = i18n_detect_env(envp);",
         "if (lang <= 0) lang = i18n_detect_env(envp);"),
        ("hid-ge0", "if (cfg->hidden >= 0) {", "if (cfg->hidden > 0) {"),
        ("srt-ge0", "if (cfg->sort >= 0) {", "if (cfg->sort > 0) {"),
        ("cfg-warn", "if (g_cfg_warn) {", "if (0) {"),
        ("oom-scr", "if (!scr) return false;", ""),
        ("oom-hdr", "if (!hdr) return false;", ""),
        ("oom-lp", "if (!lp) return false;", ""),
        ("oom-rp", "if (!rp) return false;", ""),
        ("oom-prv", "if (!prv) return false;", ""),
        ("dtor-dlg", "Object_free((Object *)(uintptr_t)app->active_dialog);", ""),
        ("dtor-du", "du_links_cleanup();", ""),
    ]
    killed = 0
    for name, old, new in muts:
        assert old in src, f"mutant {name} needle not found"
        mp = t / f"mut_{name}.c"
        mp.write_text(src.replace(old, new, 1))
        me = build("x86_64", t / f"m_{name}", src_ovr=mp)
        r = H.run_impl("x86_64", me, "c", stdin=SCRIPT.encode())
        assert r.returncode != 0 or r.stdout.decode() != baseline, f"mutant {name} survived!"
        killed += 1
    print(f"[PASS] AP3. {killed}/{len(muts)} mutants killed across app.c")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="duop_c_app_") as td:
        t = Path(td)
        exe = build("x86_64", t / "x86_64")
        base = test_differential(exe)
        a64 = build("aarch64", t / "aarch64")
        got = H.run_impl("aarch64", a64, "c", stdin=SCRIPT.encode()).stdout.decode()
        assert got == base, "aarch64 output differs from x86_64"
        print("[PASS] AP2. qemu-aarch64 matches x86_64 byte for byte")
        test_mutations(t, base)
    print("ALL APP C23 TESTS PASSED.")


if __name__ == "__main__":
    main()
