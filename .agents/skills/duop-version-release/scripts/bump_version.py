#!/usr/bin/env python3
"""SemVer inspection and bump helper for Duop VERSION."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def run_git(root: Path, *args: str) -> str:
    res = subprocess.run(
        ["git", *args],
        cwd=root,
        text=True,
        capture_output=True,
        check=False,
    )
    return res.stdout.strip() if res.returncode == 0 else ""


def tag_exists(root: Path, version: str) -> bool:
    res = subprocess.run(
        ["git", "rev-parse", "-q", "--verify", f"refs/tags/v{version}"],
        cwd=root,
        capture_output=True,
        check=False,
    )
    return res.returncode == 0


def parse_semver(ver: str) -> tuple[int, int, int]:
    m = SEMVER_RE.match(ver.strip())
    if not m:
        raise ValueError(f"Invalid SemVer '{ver}'; expected X.Y.Z")
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect or bump Duop VERSION")
    parser.add_argument("--root", default=".", help="Repository root")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--show", action="store_true", help="Print version & tag status")
    group.add_argument("--bump", choices=("patch", "minor", "major"), help="Bump SemVer")
    group.add_argument("--set", metavar="X.Y.Z", help="Set explicit SemVer")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    ver_file = root / "VERSION"
    if not ver_file.is_file():
        print("ERROR: VERSION file not found", file=sys.stderr)
        return 1

    cur_ver = ver_file.read_text(encoding="utf-8").strip()
    major, minor, patch = parse_semver(cur_ver)

    if args.show:
        latest_tag = run_git(root, "describe", "--tags", "--abbrev=0") or "(none)"
        head = run_git(root, "rev-parse", "--short", "HEAD") or "(unborn)"
        count_since = (
            run_git(root, "rev-list", "--count", f"{latest_tag}..HEAD")
            if latest_tag != "(none)"
            else run_git(root, "rev-list", "--count", "HEAD")
        )
        print(
            f"VERSION={cur_ver} | HEAD={head} | latest_tag={latest_tag} "
            f"| commits_since_tag={count_since or 0} | tag_v{cur_ver}_exists={tag_exists(root, cur_ver)}"
        )
        return 0

    if args.bump == "patch":
        new_ver = f"{major}.{minor}.{patch + 1}"
    elif args.bump == "minor":
        new_ver = f"{major}.{minor + 1}.0"
    elif args.bump == "major":
        new_ver = f"{major + 1}.0.0"
    else:
        nm = parse_semver(args.set)
        new_ver = f"{nm[0]}.{nm[1]}.{nm[2]}"

    if tag_exists(root, new_ver):
        print(f"ERROR: Git tag v{new_ver} already exists!", file=sys.stderr)
        return 1

    ver_file.write_text(f"{new_ver}\n", encoding="utf-8")
    print(f"Updated VERSION: {cur_ver} -> {new_ver}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
