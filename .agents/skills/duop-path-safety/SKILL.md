---
name: duop-path-safety
description: >-
  Forbids silent path truncation in path_join, str_copy, and str_cat; enforces
  FD-relative (*at) operations and O_NOFOLLOW against symlink races.
---

# Duop Path Safety (`duop-path-safety`)

Silent path truncation can redirect `delete`/`rename`/`copy` onto the wrong file (`cwd/database` truncated to `cwd/data`).

## Rules

1. **No silent truncation:** whenever building paths with `path_join`, `str_copy`, or `str_cat` into a `PATH_MAX` buffer, check that the resulting length did not hit/exceed `PATH_MAX - 1`; if it overflows, fail with `-ENAMETOOLONG` and report an error instead of operating on a truncated path.
2. **FD-relative operations:** prefer `openat`, `newfstatat`, `unlinkat`, `renameat` relative to an already-opened directory FD (`O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`).
3. **Symlink safety:** never follow symlinks when deleting, overwriting (`O_NOFOLLOW`), or traversing directories.
