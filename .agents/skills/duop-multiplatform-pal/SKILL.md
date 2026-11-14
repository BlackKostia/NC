---
name: duop-multiplatform-pal
description: >-
  Enforces compile-time zero-overhead Platform Abstraction Layer (PAL) discipline
  for Duop across target OS and CPU architectures (Linux x86-64, FreeBSD x86-64,
  AArch64). Use whenever adding OS syscalls, kernel structs, errno checks, terminal/signal
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

All code in `src/core/`, `src/tui/`, `src/fs/`, `src/ui/`, `src/app/`, and `src/main.s` **MUST** include `"pal.inc"` (never a raw `<os>_sys.inc`) and obey two tiers:

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
- Use OS-agnostic `FileStat` (`FileStat.dev`, `FileStat.ino`, `FileStat.size`, `FileStat.mtime`, `FileStat.mode`, 40 bytes in `include/pal.inc`) filled via `os_statat` / `os_fstat`.
- Use `os_dir_read` + `os_dir_next` (abstracting Linux `getdents64` vs FreeBSD `getdirentries` + `d_fileno == 0` whiteouts).
- Use `os_mem_remap` (`mremap` on Linux; `mmap + mem_copy + munmap` fallback on FreeBSD/others).
- Use `os_poll_in`, `os_clock_ms`, `os_get_winsize`, `os_term_save_and_raw`, `os_term_restore`, `os_signals_install`.

## 3. Porting Checklists

### Adding a New Syscall / OS Feature
1. Define the normalized constant/macro or `os_*` contract in `include/pal.inc` (and `include/os/linux/x86_64/pal_target.inc` + `src/os/linux/x86_64/pal_os.s`).
2. Add corresponding definitions/stubs in any sibling target dirs (`include/os/<os>/<arch>/`, `src/os/<os>/<arch>/`).
3. Never use raw `syscall`, `svc`, `OS_SYS_*`, `KSTAT_*`, `KDIRENT_*`, `KTERMIOS_*`, `KSIGACTION_*`, or `linux_sys.inc` outside `include/os/` and `src/os/`.
4. Verify with `tests/test_pal_architecture.py` and `./.agents/skills/duop-pty-verify/scripts/verify_build.sh`.

### Preparing / Extending for AArch64 (`ARCH=aarch64`)
- Keep shared algorithms scalar by default (`core/string.s`, `core/memory.s`); avoid unguarded `xmm`/`ymm`/`zmm` SSE/AVX instructions in shared x86-64 paths unless isolated behind matching NEON counterparts under arch-specific modules.
- Preserve strict ABI hygiene (`x0..x7` / `x19..x29` callee-saved on `AAPCS64`, `x8` syscall number + `svc #0` on Linux AArch64).
- Note `check_modularity.py` treats `.intel_syntax noprefix` as an x86-only requirement and enforces PAL boundary rules statically across all `src/` layers.
- Run `tools/abi_verify.c` (`make audit-all`) whenever modifying `include/os/<os>/<arch>/pal_target.inc` to verify all kernel struct offsets and flags against OS headers.
