/* include/duop_tui.h - C view of the terminal layer (the .c files under src/tui): value types, ScreenBuffer, data-file scanning.
 * Layouts mirror include/types.inc and classes.inc exactly; tests/test_abi_layouts.py compares every offset. */
#pragma once
#include "duop_config.h"          /* I18N_ID_LEN, key codes */
#include "duop_keys.h"
#include "duop_oop.h"

#define KBD_MAP_MAX 1024           /* keyboard layout entries {codepoint -> Latin key}, all files */
#define KBD_FILE_MAX 16384         /* bytes read from one *.layout file */

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

/* ---- Input (src/tui/input*.c): one decoded keyboard/mouse/resize event, 32 bytes ---- */
typedef struct Event {
    int32_t type;                  /* EVT_* */
    int32_t mods;                  /* MOD_* */
    int32_t key;                   /* Unicode codepoint or KEY_* */
    int32_t mouse_x, mouse_y;      /* 0-based cell */
    int32_t mouse_btn;             /* MOUSE_* */
    int32_t mouse_kind;            /* MACT_* */
    int32_t lat;                   /* layout-independent hotkey: the Latin key under `key` (*.layout files), else = key */
} Event;
_Static_assert(sizeof(Event) == 32, "Event is shared with assembly");

#define IMG_PROTO_QUAD 0           /* 2x2 quadrant blocks (default text-cell output) */
#define IMG_PROTO_HALF 1           /* 1x2 half blocks (DUOP_IMG_MODE=halfblock) */
#define IMG_PROTO_SIXEL 2          /* DEC Sixel (DA1 reports ;4 or DUOP_IMG_MODE=sixel) */
#define IMG_PROTO_KITTY 3          /* Kitty graphics protocol, f=32 RGBA */
#define IN_BUF_SIZE 512            /* raw input bytes buffered between reads */

/* ---- ScreenBuffer (classes.inc): double-buffered cell grid + the output byte stream ---- */
typedef struct ScreenBuffer {
    Object base;
    Cell *front, *back;
    char *out_buf;
    uint64_t out_len, out_cap, cell_cap;
    int32_t width, height, force_full, pen_fg, pen_bg, pen_attrs;
} ScreenBuffer;

/* ---- Interface languages (i18n.s: English table + key table; i18n_env.c: registry; i18n_pack.c: *.lang packs) ----
 * One table = one pointer per slot; slot 0 is the language code, 1 its name. The order and count are the assembler's
 * `LangStrings` (include/types.inc), proven equal by tests/test_abi_layouts.py. */
#define LANG_SLOTS 265
#define I18N_MAX 16                /* interface languages: built-in English + *.lang packs */
#define I18N_FILE_MAX 65536        /* bytes read from one *.lang file */
#define I18N_ARENA 524288          /* static storage for loaded packs (tables + text) */
typedef struct LangStrings { const char *s[LANG_SLOTS]; } LangStrings;
extern const LangStrings lang_en_table;

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

/* ---- Input decoder (input.c, input_parse.c, input_seq.c) ---- */
extern uint8_t in_buf[IN_BUF_SIZE];           /* raw bytes read from stdin; the parsers consume [in_pos, in_len) */
extern uint32_t in_pos, in_len;
int input_next_event(Event *evt, int timeout_ms);   /* 1 event, 0 timeout / none, -2 stdin EOF */
int input_poll_event(Event *evt, int timeout_ms);   /* the same without the layout-independent key; used by modal loops */
int input_is_eof(void);
int input_probe_eof(void);                    /* non-blocking stdin EOF probe before raw mode */
void input_set_wake_fd(int fd);               /* aux slot 0: background task pipe */
void input_set_aux_fd(int slot, int fd);      /* slot 0..3; fd -1 = none: readability ends the idle wait early */
int wait_and_read(int timeout_ms);            /* bytes read, 0 timeout, -1 EINTR, -2 EOF / fatal */
int wait_and_read_fd(int timeout_ms, int use_aux);
uint64_t parse_uint(const char *p);           /* leading decimal digits, wraps at 2^32 (zero-extended: asm callers store rax) */
static inline uint32_t parse_uint_adv(const uint8_t **p)   /* the same, advancing *p past the digits */
{
    uint32_t v = 0, d;
    while ((d = (uint32_t)**p - '0') <= 9) { v = v * 10 + d; (*p)++; }
    return v;
}
int input_parse_csi(Event *evt);              /* ESC [ ... at in_buf[in_pos] */
int input_parse_ss3(Event *evt);              /* ESC O x */

/* ---- Terminal capabilities (term_caps.c) ---- */
typedef struct { uint64_t w, h; } CellPx;     /* rax:rdx, as the asm callers read eax / edx */
void term_caps_init(char **envp);
void term_caps_query(void);                   /* ask for DA1 (Sixel support) and the cell size in pixels */
void term_caps_refresh(int cols, int rows);   /* cell pixels from TIOCGWINSZ, else the CSI 16 t reply */
int term_caps_filter(uint8_t *buf, int from, int len);   /* removes terminal replies from buf[from..len); returns the bytes removed */
int term_img_proto(void);
CellPx term_cell_px(void);                    /* pixels per cell, 0 = unknown */
int term_caps_changed(void);                  /* 1 once after the protocol or cell size changed */

/* ---- Interface languages: registry (i18n_env.c), pack loader (i18n_pack.c), key table (i18n_keys.s) ---- */
void i18n_lang_reset(void);                   /* registry = { English } */
int i18n_count(void);
int i18n_has_id(const char *id);
void i18n_register(LangStrings *tbl, const char *id);   /* insert keeping the packs sorted by id */
int i18n_find(const char *s);                 /* index of an id, code or locale ("uk", "UA", "uk_UA.UTF-8"), or -1 */
int i18n_detect_env(char **envp);             /* first set of LC_ALL / LC_MESSAGES / LANG; English (0) without a pack */
const LangStrings *i18n_get(void);            /* touches rax only: the asm callers keep every other register live */
const LangStrings *i18n_set_lang(int idx);    /* out-of-range selects English */
int i18n_get_idx(void);
void i18n_load(char **envp);                  /* (re)build the registry from the packs on the data path */
int i18n_key_offset(const char *key);         /* byte offset of the LangStrings slot named `key`, or -1 */
