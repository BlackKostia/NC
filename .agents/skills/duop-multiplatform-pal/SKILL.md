---
name: duop-multiplatform-pal
description: >-
  Enforces compile-time zero-overhead Platform Abstraction Layer (PAL) discipline
  for Duop across target OS and CPU architectures (Linux x86-64, Linux AArch64, later ARM32 and FreeBSD). Use whenever adding OS syscalls, kernel structs, errno checks, terminal/signal
  adapters, SIMD routines, or Makefile platform targets.
---

# Duop Multi-Platform Compile-Time PAL (`duop-multiplatform-pal`)

Preserve bare-metal static performance (`0 ns` runtime dispatch overhead) while keeping Duop cleanly portable across operating systems (`OS=linux|freebsd`) and prepared for multiple ISAs (`ARCH=x86_64|aarch64`).

## 1. Golden Rule: Compile-Time Only, Zero Runtime Dispatch

- **NEVER** introduce runtime OS/arch variables (`cmp [g_os], ...`) or function-pointer vtables for OS syscalls.
- Platform selection happens **exclusively at build time** in `Makefile` via `OS ?= linux`, `ARCH ?= x86_64`:
  - Headers: `-I include/os/$(OS)/$(ARCH)` resolves `.include "pal_target.inc"` inside `include/pal.inc`.
  - Backend objects: `src/os/$(OS)/$(ARCH)/*.s`.
- Every compiled binary contains **zero bytes of dead code** from other OSes or architectures.

## 2. Two-Tier Zero-Overhead PAL Boundary

All code in `src/core/`, `src/tui/`, `src/fs/`, `src/ui/`, `src/app/`, and `src/main.s` obeys two tiers. **C modules** include `duop_abi.h` (prototypes of the `os_*` PAL functions, `FileStat`, `os_is_err`, `load_le*`) and `duop_pal.h` (kernel constants: `O_*`, `AT_*`, `S_IF*`, `PAL_DT_*`, `PAL_IN_*`, errno values) and call **functions only** (`os_openat`, `os_read`, `os_statat`, `os_dir_read/next_ex`, `os_watch_*`, `os_thread_*`, …; implemented in `src/os/<os>/<arch>/pal_sys_*.s`, `pal_os.s`, `pal_file.s`). Remaining **assembly** modules include `"pal.inc"` (never a raw `<os>_sys.inc`) and may use the inline `OS_*` macros:

### Tier A — Zero-Cost Inline Syscall Macros (`.macro OS_*`)
For uniform POSIX/`*at` calls where only syscall numbers, flag values, or error-return conventions differ (e.g., Linux `-errno` vs FreeBSD `CF=1, +errno`):
- Always prefer modern uniform syscalls over legacy x86-only ones:
  - `OS_OPENAT` (never raw `open`), `OS_RENAMEAT`, `OS_MKDIRAT`, `OS_UNLINKAT`, `OS_SYMLINKAT`, `OS_READLINKAT`
  - `os_statat` / `os_fstat` (over `newfstatat`/`fstatat`, never legacy `stat`/`lstat`)
  - `os_poll_in` (via `ppoll`, never x86-only `poll` missing on AArch64)
- Macros emit inline instructions directly at the call site (**0 extra `call/ret` overhead**).
- Normalize errors to canonical **signed negative `-errno`** in `rax` on all platforms (e.g., FreeBSD macros emit `jnc 99f; neg rax; 99:`).

### Tier B — OS-Normalized ABI Functions & Structs (`FileStat`)
Kernel structs (`struct stat`, `dirent`/`dirent64`, `termios`, `sigaction`, `pollfd`, `timespec`, `winsize`) differ wildly across OSes and ISAs and **must never appear outside `include/os/` and `src/os/`**:
- Use OS-agnostic `FileStat` (`dev`, `ino`, `size`, `mtime`, `mtime_nsec`, `mode`, `nlink`, `uid`, `gid`: 56 bytes on every target, `include/pal.inc` and `_Static_assert` in `include/duop_abi.h`) filled via `os_statat` / `os_fstat`.
- Use `os_dir_read` + `os_dir_next` (abstracting Linux `getdents64` vs FreeBSD `getdirentries` + `d_fileno == 0` whiteouts).
- Use `os_mem_remap` (`mremap` on Linux; `mmap + mem_copy + munmap` fallback on FreeBSD/others).
- Use `os_poll_in`, `os_clock_ms`, `os_get_winsize`, `os_term_save_and_raw`, `os_term_restore`, `os_signals_install`.

## 3. Porting Checklists

### Adding a New Syscall / OS Feature
1. Define the normalized constant/macro or `os_*` contract in `include/pal.inc` (and `include/os/linux/x86_64/pal_target.inc` + `src/os/linux/x86_64/pal_os.s`).
2. Add corresponding definitions/stubs in any sibling target dirs (`include/os/<os>/<arch>/`, `src/os/<os>/<arch>/`).
3. Never use raw `syscall`, `svc`, `OS_SYS_*`, `KSTAT_*`, `KDIRENT_*`, `KTERMIOS_*`, `KSIGACTION_*`, or `linux_sys.inc` outside `include/os/` and `src/os/`.
4. Verify with `tests/test_pal_architecture.py` and `./.agents/skills/duop-pty-verify/scripts/verify_build.sh`.

### AArch64 (`ARCH=aarch64`) and the next targets
- The AArch64 PAL (`src/os/linux/aarch64/`) is executed under `qemu-aarch64` by `make ARCH=aarch64 pal-selftest` (63 checks) and by the aarch64 branches of the `tests/test_c_*` differential tests (`tests/c_harness.py`); fault/SIGBUS/PTY behaviour needs a native arm64 runner (qemu-user cannot truncate mmaps, rejects `clone()` without `CLONE_SYSVSEM`).
- Shared code is portable C (`-funsigned-char`, `-fno-strict-aliasing`, `-mno-outline-atomics`; no `char` signedness, unaligned or `long` width assumptions). SIMD only in `pal_simd.s` per ISA behind `os_mem_*`. AAPCS64: `x19..x29` callee-saved, `x8` + `svc #0`; no legacy `open/stat/dup2/pipe/rename` syscalls (use `*at` forms).
- Kernel facts live in `include/os/<os>/<arch>/pal_target.inc`, mirrored in `include/duop_pal.h` and verified for every target by `tools/abi_cross.py` against that target's UAPI headers (`tools/abi_entries.def` is the table; add the matching header to `tools/abi_verify.c`). `tests/test_abi_cross.py` fails on drift (e.g. aarch64 `O_NOFOLLOW` is `0x8000`, not `O_DIRECT`).
- ARM32 (ELF32, 4-byte pointers, `PTR_SIZE`, `O_LARGEFILE`, 64-bit syscall argument pairs, `clock_gettime64`) and FreeBSD (`CF` error flag normalised to `-errno`, `kqueue`) are Stage 5 of `docs/HYBRID_PORTABILITY_PLAN.md`.
- `make check-toolchain` lists the compilers/linkers/qemu that are available; `tools/check_c_syntax.py` syntax-checks C for x86_64 and aarch64 in about a second.
