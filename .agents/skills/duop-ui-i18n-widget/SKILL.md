---
name: duop-ui-i18n-widget
description: >-
  Guides TUI widgets, dialogs, themes, Kitty/ANSI graphics, SGR-1006 mouse hit zones,
  and synchronized English/Ukrainian i18n strings in Duop. Use when editing or
  adding files in src/ui/ or src/tui/, adding Theme colors, or adding localized UI text.
---

# Duop UI Widget & I18n Workflow

## 1. Synchronized English + Ukrainian Localization (Default Project Languages)

Every user-visible string MUST be added/updated immediately in **both** default project languages (`en` + `uk`) in the same change — never hardcode display text inside `src/ui/` or `src/app/`, and never leave one language behind:

1. Add a `.space 8` pointer slot (or `.space N*8` array) to `LangStrings` in `include/types.inc`.
2. Add the English `en_<name>` UTF-8 `.asciz` literal in `src/tui/i18n.s` and its pointer at the same slot position in `lang_en_table` (keep the `.if (. - lang_en_table) != LangStrings._size` guard). English is the built-in base and the fallback for any key a pack omits.
3. Add the pack key `LK <name>, LangStrings.<name>` (arrays: `<name>.1 .. <name>.N`) at the same position in `src/tui/i18n_keys.s`, and the Ukrainian `<name> = <text>` line to `lang/uk.lang` (quote values with outer spaces; escapes `\n \t \" \\`, `{version}`).
4. **Automatic Hook & Gate**: `.agents/hooks/duop_lifecycle.py` (`PostToolUse`) automatically checks EN+UA i18n symmetry via `check_modularity.py` whenever `src/ui/`, `src/tui/`, `src/app/`, `include/types.inc`, or `lang/uk.lang` is edited, and reminds to synchronize `en` + `uk` translations on UI edits. Other languages are extra `lang/<id>.lang` files — no code change.
5. Access the active language via `call i18n_get` (note: preserves all registers except `rax`) and load `[rax + LangStrings.<field>]`.

## 2. UTF-8 Column Width & Rendering

- **Column width != byte count**: Cyrillic UTF-8 takes 2 bytes per terminal column, wide glyphs take 2 columns. Measure strings and truncate via `utf8_display_width` (`src/core/utf8.s`), never raw `str_len`.
- **Render through `ScreenBuffer`**: Draw only via `Screen_*` APIs (`Screen_put_str`, `Screen_put_glyph`, `Screen_fill_rect`, `Screen_draw_box`) so diff-rendering and `CELL_WIDE_TAIL` remain consistent.
- **TrueColor tokens only**: Load colors from `call theme_get` -> `[rax + Theme.<token>]`; never embed raw RGB constants unless adding a named `Theme` field for all themes (`src/tui/theme.s`).

## 3. OOP Widget / Dialog Contract & Mouse Zones

- New modal dialogs (`ProgressDialog`, `FuzzyDialog`, `ChmodDialog`, etc.) go into dedicated `src/ui/<dialog>.s` files inheriting `Dialog_vtbl` via `DIALOG_VTBL_SLOTS` in `include/classes.inc`.
- Register clickable controls in `HitZone` arrays with `[x1, x2)` exclusive-right column intervals calculated dynamically from `utf8_display_width` (so translated EN/UA labels remain clickable without clipping).
- Handle both EN and UA layouts when adding `Alt+<char>` shortcuts (matching how `Alt+L` / `Alt+д` works in `src/app/app.s`).

## 4. Verification

- Add or extend a scenario in `tests/test_pty.py` testing BOTH English and Ukrainian modes (`--lang en` and `--lang ua` or `Alt+L` switch) plus mouse clicks (`\x1b[<btn;x;yM`) when applicable.
- Run `./.agents/skills/duop-pty-verify/scripts/verify_build.sh`.
