/* include/duop_tui.h - C view of the terminal layer (the .c files under src/tui): value types, ScreenBuffer, data-file scanning.
 * Layouts mirror include/types.inc and classes.inc exactly; tests/test_abi_layouts.py compares every offset. */
#pragma once
#include "duop_oop.h"

#define KBD_MAP_MAX 1024           /* keyboard layout entries {codepoint -> Latin key}, all files */
#define KBD_FILE_MAX 16384         /* bytes read from one *.layout file */
#define KEY_UP 0x100001u           /* first special key code; everything below is a Unicode codepoint */

#define CELL_WIDE_TAIL 0xFFFFFFFFu

/* ---- Value types (types.inc) ---- */
typedef struct Cell { uint32_t ch, fg, bg, attrs; } Cell;

/* 128 bytes: the name, 29 colours (0x01RRGGBB; the same order as Config.colors) and a pad word. */
typedef struct Theme {
    const char *name;
    union {
        struct {
            uint32_t bg, surface, surface_alt, header_bg, header_fg, accent, accent_fg, border_active, border_inactive,
                text, muted, dir_fg, exec_fg, link_fg, hidden_fg, selected_fg, selected_bg, cursor_active_bg,
                cursor_inactive_bg, badge_bg, badge_hover_bg, badge_fg, dialog_bg, dialog_border, ok_fg, warn_fg, err_fg,
                scroll_track, scroll_thumb;
        };
        uint32_t colors[29];
    };
    uint32_t pad;
} Theme;
_Static_assert(sizeof(Theme) == 128, "Theme is shared with assembly");

/* ---- ScreenBuffer (classes.inc): double-buffered cell grid + the output byte stream ---- */
typedef struct ScreenBuffer {
    Object base;
    Cell *front, *back;
    char *out_buf;
    uint64_t out_len, out_cap, cell_cap;
    int32_t width, height, force_full, pen_fg, pen_bg, pen_attrs;
} ScreenBuffer;

/* ---- Runtime data files (data_dirs.c): one DataSpec describes one kind of "*<ext>" file ---- */
typedef struct DataSpec {
    const char *env;               /* "DUOP_LAYOUTS=": ':'-separated dirs that replace the default search path */
    const char *sub;               /* "layouts": subdirectory under duop/ config + share dirs and beside the binary */
    const char *ext;               /* ".layout": file name suffix that is loaded */
    void (*load)(const char *path, const char *name);
} DataSpec;

const Theme *theme_get(int idx);                              /* the active copy of theme idx (mod 3) with duoprc colours applied */
int theme_count(void);

void kbd_map_reset(void);
int kbd_latin(int key);                                       /* Latin key under `key` when a layout maps it, else key */
void kbd_layout_parse(char *text);                            /* NUL-terminated *.layout text, modified in place */
void kbd_layout_load(char **envp);                            /* every *.layout file on the data path */

void data_dirs_scan(char **envp, const DataSpec *spec);
intptr_t data_read_file(const char *path, char *buf, size_t cap);   /* bytes read (cap - 1 at most, NUL-terminated); -1 when it cannot be opened */

int ScreenBuffer_rect_changed(ScreenBuffer *s, int x, int y, int w, int h);   /* 1 when the next flush rewrites a cell of the rect */
void ScreenBuffer_rect_invalidate(ScreenBuffer *s, int x, int y, int w, int h);
