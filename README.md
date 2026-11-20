# Duop (`duop`)

**English** | [Українська](README.uk.md)

An ultra-fast, compact dual-pane CLI/TUI file manager for Linux (`x86_64` & `aarch64`), built on a **hybrid zero-`libc` architecture**: a **pure assembly PAL + SIMD layer** (`src/os/`, 28 `.s` files) beneath **100% portable freestanding C23** (`src/core/`, `src/tui/`, `src/fs/`, `src/ui/`, `src/app/`, 171 `.c` files) with **zero external runtime dependencies** — no `libc`, no `ncurses`, only direct kernel syscalls and a vtable-based OOP runtime.

> **Architecture & target status:** Migration from pure x86-64 GNU Assembler to **Asm PAL + freestanding `no-libc` C23** ([HYBRID_PORTABILITY_PLAN.md](docs/HYBRID_PORTABILITY_PLAN.md)) is **complete** (`v2.6.90+`, zero non-PAL assembly files remain). Both **Linux x86-64** and **Linux AArch64** build full static zero-`libc` `duop` binaries (`.data = 0`, NX-safe) verified via 182 automated test suites including real PTY sessions on x86-64 and under `qemu-aarch64`.

## Highlights

- **Tiny Static ELF64**: ~183 KB stripped binary on `x86_64` (~210 KB on `aarch64`, `.data = 0`, no `libc`, no third-party libraries), ~0.32 ms cold start, ~112.5 ms first frame on a 100,000-file directory (via [`scripts/bench.sh`](scripts/bench.sh)).
- **High-Throughput Core**:
  - Compact 32-byte `FileEntry` + contiguous `name_pool` + 4-byte `order[]` index sorting (Introsort + LSD Radix Sort).
  - Lazy `d_type` open + rolling `io_uring` (`IORING_OP_STATX`) batch statting + `copy_file_range` / `FICLONE` fast-path copy.
  - Non-blocking background tasks (`fork` + `MAP_SHARED` atomic progress, Pause/Resume/Background, Conflict resolution).
  - Event-driven main loop (`ppoll` with infinite idle timeout — 0 wake-ups when idle, `inotify` live refresh, debounced async preview, `DEC 2026` synchronized frames).
- **Rich TUI & Productivity**:
  - TrueColor RGB diff-renderer, 3 built-in themes (`Tokyo Night`, `Catppuccin`, `Emerald`), live EN/UA localization (`--lang en|ua`, `Alt+L`), SGR-1006 mouse & drag-and-drop.
  - Command Palette (`Ctrl+K`), Recursive Fuzzy Finder (`Alt+P`), Recursive Name/Grep Virtual Panel (`Ctrl+F`), Bookmarks (`Ctrl+D`), Frecency (`z`), Tabs (`Ctrl+T`/`Ctrl+W`), History (`Alt+Left`/`Alt+Right`), Package Manager (`Alt+K`) & User Menu (`Alt+U`).
  - Archive VFS (`.tar`, `.tar.gz`, `.zip`), Git branch/status badges, Disk Usage analyzer (`Alt+D`), Bulk Rename (`Alt+B`), Dir Diff (`Alt+=`), Right-click Context Menu + `OSC 52` clipboard.
  - Syntax highlighting (C, x86-64 asm, Python, shell, JSON, Makefile/Markdown), ELF64 inspector, In-place Hex editor (`e`, `Ctrl+Z`, `Ctrl+S`), Pixel-exact image preview — Kitty graphics (f=32) or Sixel (auto-detected via DA1, cell size from TIOCGWINSZ / CSI 16 t), 2×2 quadrant blocks elsewhere, `DUOP_IMG_MODE=kitty|sixel|blocks|halfblock` to force (PNG incl. palette/16-bit/Adam7, baseline JPEG, GIF, BMP, TGA, PNM, QOI; `Alt+V` and the F3 "Open as" dialog switch Image / Hex / Text), and Embedded PTY Terminal (`Ctrl+\``).
- **Shell Integration**: `--choosedir=FILE` ([`scripts/duop-cd.sh`](scripts/duop-cd.sh)), `~/.config/duop/duoprc`, XDG Trash + `Ctrl+Z` Undo.

## Quick Start

```bash
make release
./duop
```

Or run the benchmark suite:

```bash
./scripts/bench.sh ./duop
```

### Build Options (Compile-Time PAL)

```bash
make OS=linux ARCH=x86_64 release   # Full Linux x86-64 static ELF64 (zero-libc)
make OS=linux ARCH=aarch64 release  # Full Linux AArch64 static ELF64 (zero-libc, clang + aarch64-linux-gnu-binutils)
make verify                         # Run modularity, lean-gate, ELF hardening, and PTY test suites
```

## Keybindings

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| `Tab` | Switch active pane | `Space` | Mark / unmark entry |
| `F1`–`F10` | Help, Rename, View, Edit, Copy, Move, Mkdir, Del, Preview, Quit | `Alt+P` | Recursive Fuzzy Finder |
| `Ctrl+K` | Command Palette | `Ctrl+F` | Recursive Search / Grep |
| `Ctrl+T` / `Ctrl+W` | New / Close Tab | `Ctrl+D` / `z` | Bookmarks / Frecency |
| `Alt+D` | Disk Usage mode (progress window + `Esc` cancel on long scans) | `Alt+B` | Bulk Rename |
| `Alt+=` | Dir Diff (mark differing/missing) | `Ctrl+\`` | Toggle Embedded PTY Terminal |
| `Alt+K` / `Alt+U` | Package Manager / User Menu | `Ctrl+P` | Toggle Live Preview (`F9`) |
| `Alt+T` / `Alt+L` | Cycle Theme / Next interface language | `Ctrl+Z` | Undo last Trash / Hex byte |

### Interface Languages

English is built in; every other interface language is a `*.lang` pack loaded at startup, so a new language is a new file — no rebuild. Ukrainian ships as [`lang/uk.lang`](lang/uk.lang); copy it as a template:

```text
# ~/.config/duop/lang/de.lang
code = DE
name = Deutsch
hdr_btn_help = " Hilfe "
f_labels.1   = Hilfe
cli_usage    = Aufruf: duop [--lang ID] [LINKS [RECHTS]]\n
```

Keys are the `LangStrings` fields ([`include/types.inc`](include/types.inc)); a missing key falls back to English. `"..."` keeps outer spaces, `\n` `\t` `\"` `\\` are escapes and `{version}` expands to the Duop version. The language is chosen by `--lang <id|code>`, `lang = <id>` in `duoprc`, or `LC_ALL` / `LC_MESSAGES` / `LANG` (`de_DE.UTF-8` → `de`); `Alt+L` cycles all installed languages. Search path: `$DUOP_LANGS` (`:`-separated, replaces the defaults) or `~/.config/duop/lang`, then `lang/` and `../share/duop/lang` next to the binary, `/usr/local/share/duop/lang`, `/usr/share/duop/lang`.

### Keyboard Layouts

Hotkeys follow the physical key, so `Alt+T`, `Alt+L`, `j`/`k` or the dialog letters work without switching away from a non-Latin layout. The mapping is plain data in `*.layout` files, loaded at startup — add a layout by dropping a file, no rebuild:

```text
# ~/.config/duop/layouts/el.layout
name  = Ελληνικά
keys  = qwertyuiopasdfghjklzxcvbnm
chars = ;ςερτυθιοπασδφγηξκλζχψωβνμ
```

Each `chars` line lists what the layout types on the keys of the preceding `keys` line; ASCII characters are ignored and text typed into input fields is never changed. Search path: `$DUOP_LAYOUTS` (`:`-separated, replaces the defaults) or `~/.config/duop/layouts` (`$XDG_CONFIG_HOME`), then `layouts/` and `../share/duop/layouts` next to the binary, `/usr/local/share/duop/layouts`, `/usr/share/duop/layouts`. Ukrainian ships as [`layouts/uk.layout`](layouts/uk.layout).

## Developer

- **Author**: Kostiantyn Nedbailo (Недбайло Костянтин Геннадійович) — `<ChessPlayerSedoy@gmail.com>`

## License

Licensed under the [MIT License](LICENSE).
