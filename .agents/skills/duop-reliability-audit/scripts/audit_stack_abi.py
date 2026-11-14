#!/usr/bin/env python3
"""Static ASM Stack & Struct Bounds Auditor for Duop x86-64 assembly.

Parses .struct definitions and .equ/.set constants from include/**/*.inc,
then scans src/**/*.s routines for:
  1. Undersized stack frames for structs (e.g. FileStat._size = 56 vs sub rsp, 48).
  2. Overlapping stack buffers/slots (including Routine__step +16 frame offsets).
  3. Non-FileStat stack reads/writes overlapping an active FileStat region.
  4. Mismatched sub rsp / add rsp cleanup within a routine.
  5. Optional (--strict-align) 16-byte RSP alignment before call.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]

RE_EQU = re.compile(r"^\s*\.(?:equ|set)\s+([A-Za-z_][A-Za-z0-9_]*)\s*,\s*(.+)$")
RE_ASSIGN = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)$")
RE_STRUCT_START = re.compile(r"^\s*\.struct\s+(-?\d+|0x[0-9a-fA-F]+)?")
RE_STRUCT_FIELD = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_.]*)\s*:\s*\.(byte|word|long|quad|space|skip|fill)\b(.*)$"
)
RE_CLASS_BEGIN = re.compile(r"^\s*CLASS_BEGIN\s+([A-Za-z_][A-Za-z0-9_]*)")
RE_EXTENDS = re.compile(r"^\s*EXTENDS\s+([A-Za-z_][A-Za-z0-9_]*)")
RE_FIELD = re.compile(r"^\s*FIELD\s+([A-Za-z_][A-Za-z0-9_.]*)\s*,\s*(.+)$")
RE_CLASS_END = re.compile(r"^\s*CLASS_END\s+([A-Za-z_][A-Za-z0-9_]*)")
RE_STRUCT_LABEL = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_.]*)\s*:")
RE_LABEL = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
RE_SUB_RSP = re.compile(r"^\s*sub\s+rsp\s*,\s*(.+)$")
RE_ADD_RSP = re.compile(r"^\s*add\s+rsp\s*,\s*(.+)$")
RE_PUSH = re.compile(r"^\s*push\s+(r[a-z0-9]+|qword\b.*)$")
RE_POP = re.compile(r"^\s*pop\s+(r[a-z0-9]+)\b")
RE_CALL = re.compile(r"^\s*call\s+([A-Za-z_][A-Za-z0-9_.]*|\[.*\]|r[a-z0-9]+)")
RE_RSP_REF = re.compile(r"\[rsp(?:\s*\+\s*([^\]]+))?\]")
RE_FILESTAT_FIELD = re.compile(r"FileStat\.(?!_size\b)([A-Za-z_][A-Za-z0-9_]*)")


def strip_comment(line: str) -> tuple[str, str]:
    in_str = False
    quote = ""
    line = re.sub(r"/\*.*?\*/", "", line)
    for i, ch in enumerate(line):
        if in_str:
            if ch == quote and (i == 0 or line[i - 1] != "\\"):
                in_str = False
        elif ch in ('"', "'"):
            in_str = True
            quote = ch
        elif ch == "#":
            return line[:i], line[i + 1 :].strip()
    return line, ""


def eval_expr(expr: str, consts: dict[str, int]) -> int | None:
    expr = expr.strip()
    if not expr:
        return None
    tokens = re.findall(r"[A-Za-z_][A-Za-z0-9_.]*|0x[0-9a-fA-F]+|\d+|[+\-*/()]", expr)
    if not tokens:
        return None
    rebuilt: list[str] = []
    for tok in tokens:
        if tok in consts:
            rebuilt.append(str(consts[tok]))
        elif re.fullmatch(r"0x[0-9a-fA-F]+|\d+|[+\-*/()]", tok):
            rebuilt.append(tok)
        else:
            return None
    try:
        val = eval("".join(rebuilt).replace("/", "//"), {"__builtins__": {}}, {})
        return int(val)
    except Exception:
        return None


def parse_includes() -> tuple[dict[str, int], dict[str, int]]:
    consts: dict[str, int] = {}
    structs: dict[str, int] = {}
    inc_files = sorted((ROOT / "include").rglob("*.inc"))

    for _ in range(3):
        for path in inc_files:
            in_struct = False
            struct_offset = 0
            for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
                code, _ = strip_comment(raw)
                code_s = code.strip()
                if not code_s:
                    continue
                m = RE_EQU.match(code_s) or RE_ASSIGN.match(code_s)
                if m and not in_struct:
                    val = eval_expr(m.group(2), consts)
                    if val is not None:
                        consts[m.group(1)] = val
                    continue
                ms = RE_STRUCT_START.match(code_s)
                if ms:
                    in_struct = True
                    struct_offset = int(ms.group(1), 0) if ms.group(1) else 0
                    continue
                mcb = RE_CLASS_BEGIN.match(code_s)
                if mcb:
                    in_struct = True
                    struct_offset = 0
                    continue
                if in_struct:
                    me = RE_EXTENDS.match(code_s)
                    if me:
                        struct_offset = structs.get(me.group(1), 0)
                        continue
                    mfi = RE_FIELD.match(code_s)
                    if mfi:
                        fname = mfi.group(1)
                        consts[fname] = struct_offset
                        sz = eval_expr(mfi.group(2), consts)
                        if sz is not None:
                            struct_offset += sz
                        continue
                    mce = RE_CLASS_END.match(code_s)
                    if mce:
                        cname = mce.group(1)
                        consts[f"{cname}._size"] = struct_offset
                        structs[cname] = struct_offset
                        in_struct = False
                        continue
                    if code_s.startswith(".text") or code_s.startswith(".section") or code_s.startswith(".macro"):
                        in_struct = False
                        continue
                    mf = RE_STRUCT_FIELD.match(code_s)
                    if mf:
                        fname, ftype, rest = mf.group(1), mf.group(2), mf.group(3).strip()
                        consts[fname] = struct_offset
                        if fname.endswith("._size"):
                            structs[fname[: -len("._size")]] = struct_offset
                        size_map = {"byte": 1, "word": 2, "long": 4, "quad": 8}
                        if ftype in size_map:
                            count = len([x for x in rest.split(",") if x.strip()]) if rest else 1
                            struct_offset += size_map[ftype] * max(1, count)
                        elif ftype in ("space", "skip"):
                            sz = eval_expr(rest.split(",")[0], consts)
                            if sz is not None:
                                struct_offset += sz
                        continue
                    ml = RE_STRUCT_LABEL.match(code_s)
                    if ml:
                        fname = ml.group(1)
                        consts[fname] = struct_offset
                        if fname.endswith("._size"):
                            structs[fname[: -len("._size")]] = struct_offset
    return consts, structs


def split_routines(path: Path) -> list[dict]:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    routines: list[dict] = []
    cur = None
    in_text = False
    for idx, raw in enumerate(lines, 1):
        code, comment = strip_comment(raw)
        s = code.strip()
        if s.startswith(".text") or s.startswith(".section .text"):
            in_text = True
            continue
        if s.startswith(".section ") and ".text" not in s:
            in_text = False
            cur = None
            continue
        if s in (".rodata", ".bss", ".data"):
            in_text = False
            cur = None
            continue
        if not in_text:
            continue
        ml = RE_LABEL.match(s)
        if ml and not ml.group(1).startswith(".L") and not ml.group(1).startswith("."):
            cur = {
                "name": ml.group(1),
                "start_line": idx,
                "lines": [],
                "is_step": "__" in ml.group(1),
            }
            routines.append(cur)
        elif cur is not None:
            cur["lines"].append((idx, s, comment))
    return routines


def audit_file(
    path: Path, consts: dict[str, int], structs: dict[str, int], strict_align: bool = False
) -> list[str]:
    findings: list[str] = []
    rel = path.relative_to(ROOT)
    routines = split_routines(path)
    fs_size = structs.get("FileStat", 56)
    parent_info: dict[str, dict] = {}

    for rt in routines:
        name = rt["name"]
        is_step = rt["is_step"]
        pushes = 0
        frame_bytes = None
        sub_lines: list[tuple[int, int]] = []
        add_lines: list[tuple[int, int]] = []
        filestat_bases: set[int] = set()
        other_struct_refs: list[tuple[int, str, int, int]] = []  # (lineno, sname, base, size)
        scratch_offsets: list[tuple[int, int, str, bool]] = []
        alignment_checked = False
        temp_push_depth = 0
        last_stat_arg_off: dict[str, int | None] = {"rsi": None, "rdx": None}

        for lineno, raw_s, comment in rt["lines"]:
            if not raw_s and not comment:
                continue
            if comment and "FileStat" in comment:
                bracketed = re.findall(r"\[(\d+)\]\s*=\s*([^,\]]*FileStat[^,\]]*)", comment)
                for off_s, _desc in bracketed:
                    filestat_bases.add(int(off_s))
                if not bracketed and comment.strip().startswith("FileStat") and sub_lines:
                    filestat_bases.add(0)

            for stmt in [p.strip() for p in raw_s.split(";") if p.strip()]:
                if frame_bytes is None and RE_PUSH.match(stmt):
                    pushes += 1
                    continue
                if frame_bytes is not None:
                    if RE_PUSH.match(stmt):
                        temp_push_depth += 8
                        continue
                    if RE_POP.match(stmt):
                        temp_push_depth = max(0, temp_push_depth - 8)
                        continue

                ms = RE_SUB_RSP.match(stmt)
                if ms:
                    val = eval_expr(ms.group(1), consts)
                    if val is not None:
                        sub_lines.append((lineno, val))
                        if frame_bytes is None:
                            frame_bytes = val
                    continue
                ma = RE_ADD_RSP.match(stmt)
                if ma:
                    val = eval_expr(ma.group(1), consts)
                    if val is not None:
                        add_lines.append((lineno, val))
                    continue

                is_lea = stmt.startswith("lea ")
                # Track lea rsi/rdx, [rsp + ...] for os_fstat / os_statat detection
                mlea_arg = re.match(r"^lea\s+(rsi|rdx)\s*,\s*\[rsp(?:\s*\+\s*([^\]]+))?\]", stmt)
                if mlea_arg:
                    arg_reg = mlea_arg.group(1)
                    off_v = eval_expr((mlea_arg.group(2) or "0").strip(), consts)
                    if off_v is not None:
                        off_v -= temp_push_depth
                        if is_step and off_v >= 16:
                            off_v -= 16
                        elif is_step:
                            off_v = None
                        last_stat_arg_off[arg_reg] = off_v if (off_v is not None and off_v >= 0) else None
                elif re.match(r"^mov\s+(rsi|rdx)\s*,\s*rsp\b", stmt):
                    arg_reg = stmt.split()[1].rstrip(",")
                    last_stat_arg_off[arg_reg] = 0 if not is_step else None

                mc = RE_CALL.match(stmt)
                if mc:
                    callee = mc.group(1)
                    if callee in ("os_fstat", "os_fstat_du") and last_stat_arg_off["rsi"] is not None:
                        filestat_bases.add(last_stat_arg_off["rsi"])
                    elif callee in ("os_statat", "os_fstatat") and last_stat_arg_off["rdx"] is not None:
                        filestat_bases.add(last_stat_arg_off["rdx"])
                    last_stat_arg_off["rsi"] = None
                    last_stat_arg_off["rdx"] = None
                    if strict_align and not is_step and not alignment_checked and frame_bytes is not None:
                        if len(sub_lines) == 1:
                            total = 8 + pushes * 8 + frame_bytes
                            if total % 16 != 0:
                                findings.append(
                                    f"{rel}:{lineno} ({name}): 16-byte stack misalignment before `{stmt}` "
                                    f"(pushes={pushes}, frame={frame_bytes}, mod16={total % 16})"
                                )
                        alignment_checked = True
                    continue

                for ref in RE_RSP_REF.finditer(stmt):
                    expr = (ref.group(1) or "0").strip()
                    if RE_FILESTAT_FIELD.search(expr):
                        base_expr = RE_FILESTAT_FIELD.sub("0", expr)
                        base_val = eval_expr(base_expr, consts)
                        if base_val is not None:
                            base_val -= temp_push_depth
                            if is_step and base_val >= 16:
                                base_val -= 16
                            if base_val >= 0:
                                filestat_bases.add(base_val)
                    else:
                        msf = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\.(?!_size\b)([A-Za-z_][A-Za-z0-9_]*)", expr)
                        if msf and msf.group(1) in structs and msf.group(1) != "FileStat":
                            sname = msf.group(1)
                            base_expr = re.sub(rf"{re.escape(sname)}\.(?!_size\b)\w+", "0", expr)
                            base_val = eval_expr(base_expr, consts)
                            if base_val is not None:
                                base_val -= temp_push_depth
                                if is_step and base_val >= 16:
                                    base_val -= 16
                                if base_val >= 0:
                                    other_struct_refs.append((lineno, sname, base_val, structs[sname]))
                        off_val = eval_expr(expr, consts)
                        if off_val is not None:
                            off_val -= temp_push_depth
                            if is_step:
                                if off_val >= 16:
                                    scratch_offsets.append((lineno, off_val - 16, stmt, is_lea))
                            elif frame_bytes is not None and 0 <= off_val < frame_bytes:
                                scratch_offsets.append((lineno, off_val, stmt, is_lea))

        if not is_step:
            parent_info[name] = {
                "rt": rt,
                "frame_bytes": frame_bytes,
                "filestat_bases": filestat_bases,
                "other_struct_refs": other_struct_refs,
                "scratch_offsets": scratch_offsets,
            }
            # Skip sub/add mismatch check for fork()/exec() child-exit routines (OS_EXIT) or stack-arg cleanup
            has_os_exit = any("OS_EXIT" in stmt for _, stmt, _ in rt["lines"])
            if not has_os_exit and len(sub_lines) == 1 and add_lines:
                sub_val = sub_lines[0][1]
                # Only flag mismatched epilogue if sub_val > 16 and no add_rsp matches sub_val and final add_rsp > 16
                if sub_val > 16 and not any(aval == sub_val for _, aval in add_lines):
                    alino, aval = add_lines[-1]
                    if aval > 16:
                        findings.append(
                            f"{rel}:{alino} ({name}): mismatched `add rsp, {aval}` vs `sub rsp, {sub_val}`"
                        )
        else:
            # Verify __step frame-sharing lea rsp, [rsp - 8] / [rsp + 8] symmetry
            has_lea_sub = any("lea rsp, [rsp - 8]" in stmt for _, stmt, _ in rt["lines"])
            has_lea_add = any("lea rsp, [rsp + 8]" in stmt for _, stmt, _ in rt["lines"])
            if has_lea_sub and not has_lea_add:
                findings.append(f"{rel}:{rt['start_line']} ({name}): `__step` uses `lea rsp, [rsp - 8]` without `lea rsp, [rsp + 8]`")
            parent_name = name.split("__", 1)[0]
            if parent_name in parent_info:
                pinfo = parent_info[parent_name]
                pinfo["filestat_bases"].update(filestat_bases)
                pinfo["other_struct_refs"].extend(other_struct_refs)
                pinfo["scratch_offsets"].extend(scratch_offsets)

    for pname, info in parent_info.items():
        rt = info["rt"]
        frame_bytes = info["frame_bytes"]
        sorted_bases = sorted(info["filestat_bases"])

        if frame_bytes is not None and sorted_bases:
            for base in sorted_bases:
                if base + fs_size > frame_bytes:
                    findings.append(
                        f"{rel}:{rt['start_line']} ({pname}): FileStat at [rsp + {base}] needs "
                        f"{base + fs_size}B (FileStat._size={fs_size}), but frame is only {frame_bytes}B"
                    )
        if frame_bytes is not None and info["other_struct_refs"]:
            seen_other: set[tuple[str, int]] = set()
            for slino, sname, sbase, ssize in info["other_struct_refs"]:
                if (sname, sbase) in seen_other:
                    continue
                seen_other.add((sname, sbase))
                if sbase + ssize > frame_bytes:
                    findings.append(
                        f"{rel}:{slino} ({pname}): {sname} at [rsp + {sbase}] needs "
                        f"{sbase + ssize}B ({sname}._size={ssize}), but frame is only {frame_bytes}B"
                    )

        for i in range(len(sorted_bases) - 1):
            b1, b2 = sorted_bases[i], sorted_bases[i + 1]
            if b2 < b1 + fs_size:
                findings.append(
                    f"{rel}:{rt['start_line']} ({pname}): overlapping FileStat buffers at "
                    f"[rsp + {b1}] and [rsp + {b2}] (FileStat._size={fs_size})"
                )

        if sorted_bases:
            for lineno, off_val, stmt, is_lea in info["scratch_offsets"]:
                for base in sorted_bases:
                    if is_lea and off_val == base:
                        continue
                    if base <= off_val < base + fs_size:
                        findings.append(
                            f"{rel}:{lineno} ({pname}): stack access `{stmt}` (frame offset {off_val}) "
                            f"overlaps FileStat[{base}..{base + fs_size - 1}]"
                        )

    return findings


def main() -> int:
    parser = argparse.ArgumentParser(description="Duop static ASM stack & struct bounds auditor")
    parser.add_argument("--strict-align", action="store_true", help="Also check 16-byte call alignment")
    args = parser.parse_args()

    consts, structs = parse_includes()
    all_findings: list[str] = []
    s_files = sorted((ROOT / "src").rglob("*.s"))
    for path in s_files:
        all_findings.extend(audit_file(path, consts, structs, strict_align=args.strict_align))

    if all_findings:
        print(f"STACK/ABI AUDIT FAILED ({len(all_findings)} issue(s)):")
        for f in all_findings:
            print(f"  - {f}")
        return 1

    print(
        f"STACK/ABI AUDIT PASSED (FileStat._size={structs.get('FileStat', '?')}, "
        f"checked {len(s_files)} .s files)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
