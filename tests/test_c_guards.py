#!/usr/bin/env python3
"""The C-aware safety gates of the agent hooks and git hooks: null-alloc audit (tools/faultlab/audit_null_alloc_c.py), the
destructive-op / unchecked-allocation guards of PreToolUse, the .c/.h lean gate, the post-edit C syntax gate and the narrowed
faultlab trigger. Synthetic sources only; the real tree must audit clean."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".agents/hooks"))
sys.path.insert(0, str(ROOT / "tools/faultlab"))
import audit_null_alloc_c as an  # noqa: E402
import duop_lifecycle as dl  # noqa: E402
import duop_safety_guards as sg  # noqa: E402

os.environ["DUOP_TDD_BYPASS"] = "1"                                  # these tests are about the other gates


def test_null_alloc_audit() -> None:
    bad = "char *f(size_t n)\n{\n    char *p = mem_alloc(n);\n    p[0] = 1;\n    return p;\n}\n"
    assert an.audit_text(bad, "x.c") and an.audit_text(bad, "x.c")[0].startswith("DEREF")
    stored = "void g(Obj *o)\n{\n    char *p = mem_alloc(8);\n    o->buf = p;\n}\n"
    assert an.audit_text(stored, "x.c")[0].startswith("STORED")
    for ok in ("void f(void)\n{\n    char *p = mem_alloc(8);\n    if (!p) return;\n    p[0] = 1;\n}\n",
               "void f(void)\n{\n    char *p = mem_alloc(8);\n    if (p == nullptr) return;\n    p[0] = 1;\n}\n",
               "void f(void)\n{\n    char *p = mem_alloc(8);\n    mem_free(p);\n}\n",
               "char *f(void)\n{\n    char *p = mem_alloc(8);\n    return p;\n}\n",
               "void f(void)\n{\n    char *p;\n    if (!(p = mem_alloc(8))) return;\n    p[0] = 1;\n}\n",
               "void f(void)\n{\n    char *p = mem_alloc(8);  /* null-ok */\n    p[0] = 1;\n}\n",
               "void f(Cx *c)\n{\n    c->level = mem_alloc(64);\n    if (!c->level) return;\n    c->level[0] = 1;\n}\n"):
        assert not an.audit_text(ok, "x.c"), ok
    assert an.audit_text("void f(Cx *c)\n{\n    c->level = mem_alloc(64);\n    c->level[0] = 1;\n}\n", "x.c")
    res = subprocess.run([sys.executable, str(ROOT / "tools/faultlab/audit_null_alloc_c.py")], capture_output=True, text=True)
    assert res.returncode == 0, res.stdout
    print("[PASS] CG1. audit_null_alloc_c: unchecked mem_alloc results are found, tested / freed / returned ones are not; src/**/*.c is clean")


def test_pre_tool_guards() -> None:
    assert sg.check_pre_tool_c_guards(ROOT, "src/fs/x.c", "void f(void)\n{\n    char *p = mem_alloc(8);\n    *p = 1;\n}\n")
    assert sg.check_pre_tool_c_guards(ROOT, "src/fs/x.c", "int f(void)\n{\n    return os_openat(AT_FDCWD, p, O_WRONLY | O_TRUNC, 0);\n}\n")
    assert sg.check_pre_tool_c_guards(ROOT, "src/fs/x.c", "int f(void)\n{\n    return os_renameat2(AT_FDCWD, a, AT_FDCWD, b, 0);\n}\n")
    for ok in ("int f(void)\n{\n    return os_openat(AT_FDCWD, p, O_WRONLY | O_TRUNC | O_NOFOLLOW, 0);\n}\n",
               "int f(void)\n{\n    return os_renameat2(AT_FDCWD, a, AT_FDCWD, b, RENAME_NOREPLACE);\n}\n",
               "int f(void)\n{\n    /* atomic-replace: tmp file renamed over the target */\n    return os_renameat2(AT_FDCWD, a, AT_FDCWD, b, 0);\n}\n"):
        assert sg.check_pre_tool_c_guards(ROOT, "src/fs/x.c", ok) is None, ok
    assert sg.check_pre_tool_c_guards(ROOT, "tests/harness/x.c", "char *p = mem_alloc(8); *p = 1;") is None   # only src/**/*.c
    print("[PASS] CG2. PreToolUse C guards: unchecked allocation, O_TRUNC / renameat2 without a no-clobber flag; annotated or safe code passes")


def test_hook_integration() -> None:
    def pre(rel: str, content: str) -> dict:
        payload = {"hookEventName": "PreToolUse", "conversationId": "cg-selftest", "cwd": str(ROOT),
                   "toolCall": {"name": "write_file", "args": {"Path": str(ROOT / rel), "Content": content}}}
        return dl.handle_pre_tool_use(payload, ROOT)

    big = "int f(void)\n{\n" + "    int a = 0;\n" * 520 + "    return a;\n}\n"
    out = pre("src/fs/huge_new.c", big)
    assert out.get("decision") == "deny" and "Lean-module gate" in out.get("reason", ""), out           # .c is lean-gated now
    out = pre("src/fs/leak_new.c", "void f(void)\n{\n    char *p = mem_alloc(8);\n    p[1] = 0;\n}\n")
    assert out.get("decision") == "deny" and "Error-path guard" in out.get("reason", ""), out
    assert pre("src/fs/fine_new.c", "int f(int x)\n{\n    return x + 1;\n}\n").get("decision") == "allow"
    assert dl.lean_target("include/duop_new.h") and dl.lean_target("src/fs/a.c")
    assert "duop-asm-to-c-migration" in dl.handle_session_start({}, ROOT)["injectSteps"][0]["systemMessage"]["systemMessage"]
    print("[PASS] CG3. Lifecycle hook: .c / .h files are lean-gated, unchecked allocations denied, SessionStart names the C workflow")


def test_post_edit_and_faultlab_scope() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        probe = ROOT / "src/fs/zz_guard_probe.c"
        try:
            probe.write_text("int probe(void) { return not_declared(); }\n")
            note = sg.run_post_tool_c_audits(ROOT, "src/fs/zz_guard_probe.c")
            assert note and "check_c_syntax" in note, note
            probe.write_text("int probe(void) { return 0; }\n")
            assert sg.run_post_tool_c_audits(ROOT, "src/fs/zz_guard_probe.c") is None
        finally:
            probe.unlink(missing_ok=True)
        del tmp
    spath = dl.state_file_for({"conversationId": "cg-faultlab"}, ROOT)
    spath.unlink(missing_ok=True)
    for rel, expect in (("src/ui/header_bar.s", False), ("src/app/app_keys.s", False), ("src/fs/trash_undo.c", True), ("src/core/memory.c", True)):
        payload = {"hookEventName": "PostToolUse", "conversationId": "cg-faultlab", "cwd": str(ROOT),
                   "toolCall": {"name": "edit_file", "args": {"Path": str(ROOT / rel)}}}
        os.environ["DUOP_LEAN_BYPASS"] = "1"
        dl.handle_post_tool_use(payload, ROOT)
        state = dl.load_state(spath)
        assert bool(state.get("needs_faultlab")) == expect, (rel, state)
        spath.unlink(missing_ok=True)
    print("[PASS] CG4. Post-edit: C syntax gate reports compile errors; faultlab is demanded for fs/core/os only")


def main() -> None:
    test_null_alloc_audit()
    test_pre_tool_guards()
    test_hook_integration()
    test_post_edit_and_faultlab_scope()
    print("ALL C GUARD TESTS PASSED.")


if __name__ == "__main__":
    main()
