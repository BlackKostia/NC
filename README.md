# Duop (`duop`)

**English** | [Українська](README.uk.md)

A modern, dual-pane TUI file manager written **100% in pure GNU Assembler** (`.intel_syntax noprefix` on x86-64, compile-time PAL for AArch64) with **zero external dependencies** — no `libc`, no `ncurses`, only direct Linux kernel syscalls and a vtable-based OOP runtime.

## Highlights

- **Tiny Static ELF64**: ~134 KiB stripped binary, **0 bytes** in `.data`, ~0.32 ms cold start, ~112.5 ms first frame on a 100,000-file directory (via [`scripts/bench.sh`](scripts/bench.sh)).
- **High-Throughput Core**:
  - Compact 32-byte `FileEntry` + contiguous `name_pool` + 4-byte `order[]` index sorting (Introsort + LSD Radix Sort).
  - Lazy `d_type` open + rolling `io_uring` (`IORING_OP_STATX`) batch statting + `copy_file_range` / `FICLONE` fast-path copy.
  - Non-blocking background tasks (`fork` + `MAP_SHARED` atomic progress, Pause/Resume/Background, Conflict resolution).
  - Event-driven main loop (`ppoll` with infinite idle timeout — 0 wake-ups when idle, `inotify` live refresh, debounced async preview, `DEC 2026` synchronized frames).
- **Rich TUI & Productivity**:
  - TrueColor RGB diff-renderer, 5 built-in themes, live EN/UA localization (`--lang en|ua`, `Alt+L`), SGR-1006 mouse & drag-and-drop.
  - Command Palette (`Ctrl+K`), Recursive Fuzzy Finder (`Ctrl+P`), Recursive Name/Grep Virtual Panel (`Alt+F`), Bookmarks (`Ctrl+D`), Frecency (`z`), Tabs (`Ctrl+T`/`Ctrl+W`), History (`Alt+Left`/`Alt+Right`).
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
make OS=linux ARCH=x86_64 release   # Default x86-64 Linux static ELF
make OS=linux ARCH=aarch64          # AArch64 PAL objects (with aarch64-linux-gnu-as)
make verify                         # Run modularity, lean-gate, and PTY test suites
```

## Keybindings

| Key | Action | Key | Action |
| --- | --- | --- | --- |
| `Tab` | Switch active pane | `Space` | Mark / unmark entry |
| `F1`–`F10` | Help, Rename, View, Edit, Copy, Move, Mkdir, Del, Preview, Quit | `Ctrl+P` | Recursive Fuzzy Finder |
| `Ctrl+K` | Command Palette | `Ctrl+F` / `Alt+F` | Recursive Search / Grep |
| `Ctrl+T` / `Ctrl+W` | New / Close Tab | `Ctrl+D` / `z` | Bookmarks / Frecency |
| `Alt+D` | Disk Usage mode | `Alt+B` | Bulk Rename |
| `Alt+=` | Dir Diff (mark differing/missing) | `Ctrl+\`` | Toggle Embedded PTY Terminal |
| `Alt+T` / `Alt+L` | Cycle Theme / Toggle EN↔UA | `Ctrl+Z` | Undo last Trash / Hex byte |

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
