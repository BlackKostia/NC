---
name: nc-version-release
description: >-
  Manages Semantic Versioning (VERSION, build/version.inc, vX.Y.Z Git tags, ROADMAP.md)
  and atomic Conventional Commits after verified NeoCommander changes. Use before committing
  changes or bumping the application version.
---

# NeoCommander Continuous Versioning & Commit Workflow

Keep `VERSION`, binary metadata (`--version`, `HelpDialog`), `ROADMAP.md`, and Git history synchronized on every successful change.

## 1. SemVer Policy (`VERSION`)

Check current state first:
```bash
python3 ./.agents/skills/nc-version-release/scripts/bump_version.py --show
```

Choose the version action before committing:
- **Changed `src/`, `include/`, or `Makefile` build behavior** when `v$(cat VERSION)` tag ALREADY exists in Git: **MUST bump `VERSION`**:
  - `patch` (`Z+1`): bugfix (`fix`), performance tweak (`perf`), modular refactor (`refactor`), UI/translation fix, build fix.
  - `minor` (`Y+1`, `Z=0`): new user-facing feature or completed `ROADMAP.md` item (`feat`).
  - `major` (`X+1`, `Y=0`, `Z=0`): breaking CLI/config compatibility or `v2.0` milestone.
- **Unreleased multi-commit feature in progress** (current `VERSION` already exceeds latest tag and `v$(cat VERSION)` tag does not exist yet): keep current `VERSION` across modular commits, then tag `vX.Y.Z` when the feature completes.
- **Pure docs / agent skills / test-only commits** (`docs:`, `test:`, `chore:` with zero changes to `src/`/`include/`): keeping `VERSION` unchanged is allowed.

Bump cleanly with:
```bash
python3 ./.agents/skills/nc-version-release/scripts/bump_version.py --bump patch
```

## 2. Update Documentation & Verify Build

1. If completing a `ROADMAP.md` item, mark/update its status in `ROADMAP.md`.
2. Run verification **after** updating `VERSION` so `build/version.inc`, `--version`, `HelpDialog`, and `tests/test_pty.py` build and validate the bumped version:
   ```bash
   ./.agents/skills/nc-pty-verify/scripts/verify_build.sh
   ```

## 3. Commit & Tag

1. Stage intended project files (`git add -A` only after verifying `git status` shows no temp files).
2. Commit with Conventional Commit header:
   - `feat(scope): concise summary (vX.Y.Z)`
   - `fix(scope): concise summary (vX.Y.Z)`
   - `refactor(scope): concise summary`
   - `docs: ...` / `chore(agents): ...` / `test(pty): ...`
   Note: `.githooks/pre-commit` enforces modularity checks, version currency, and PTY tests; `.githooks/commit-msg` enforces Conventional Commit format.
3. When cutting a version milestone/release where `VERSION` increased, create an annotated tag (do not push unless the user asks):
   ```bash
   git tag -a "v$(cat VERSION)" -m "NeoCommander v$(cat VERSION)"
   ```
