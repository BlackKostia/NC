# Duop v2.7.0 — Hybrid Zero-`libc` Release (`x86_64` & `aarch64`)

**Duop** (`duop`) is a dual-pane terminal file manager for Linux shipped as a single static ELF64 binary with **zero external runtime dependencies** — no `libc`, no `ncurses`, no shared libraries.

## Highlights of `v2.7.0`

- **100% Portable Freestanding C23 + Assembly PAL Architecture**:
  - Completed the migration from pure x86-64 GNU Assembler to **171 portable freestanding C23 modules** (`src/core/`, `src/tui/`, `src/fs/`, `src/ui/`, `src/app/`) over a compile-time **assembly Platform Abstraction Layer + SIMD** (`src/os/linux/{x86_64,aarch64}/`, 28 `.s` files).
  - Full static binaries for both **Linux `x86_64`** (`191,528 B` / `187 KiB`) and **Linux `aarch64`** (`214,128 B` / `209 KiB`), `.data = 0`, NX-safe.
- **Extreme Directory Throughput**:
  - **26.4 ms** median first-frame time (`15.4 MiB` Peak RSS) on a **4,798,976-file directory** where `mc`, `yazi`, `lf`, `nnn`, `ranger`, and `vifm` time out at 60 s ([benchmark report](https://github.com/BlackKostia/duop/blob/main/docs/BENCHMARK_20M_2026-11-17.md)).
  - **112.7 ms** first frame on a 100,000-file directory; **2.6 ms** cold spawn; **0 idle CPU wake-ups** (`ppoll` + `inotify`).
- **Built-in Developer & SRE Tooling**:
  - Command Palette (`Ctrl+K`), Recursive Fuzzy Finder (`Alt+P`), Recursive Grep Virtual Panel (`Ctrl+F`), Tabs, Bookmarks, Frecency.
  - Pixel-exact image preview without external helpers (Kitty graphics `f=32`, Sixel, Unicode blocks for PNG, JPEG, GIF, BMP, TGA, PNM, QOI).
  - Syntax highlighting, ELF64 inspector, in-place Hex editor with Undo (`Ctrl+Z`), Archive VFS (`.tar`, `.tar.gz`, `.zip`), Git status badges, Disk Usage analyzer (`Alt+D`), Bulk Rename (`Alt+B`), Dir Diff (`Alt+=`), XDG Trash + Undo, and an embedded PTY terminal (`Ctrl+\``).
  - Data-driven localization (`lang/*.lang`, English + Ukrainian included) and physical keyboard layout maps (`layouts/*.layout`).
- **Verified Reliability**:
  - **186 automated test suites** (real PTY sessions, differential C23-vs-ASM oracle checks, `qemu-aarch64`, fault-injection via `faultlab`, SEU bit-flip tests).

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/BlackKostia/duop/main/scripts/install.sh | bash
```

Or download `duop-linux-x86_64.tar.gz` / `duop-linux-aarch64.tar.gz` below and verify against `SHA256SUMS`:

```bash
sha256sum -c SHA256SUMS --ignore-missing
```
