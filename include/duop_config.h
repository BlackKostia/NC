/* include/duop_config.h - Duop compile-time limits mirrored from include/config.inc (checked by tests/test_abi_layouts.py). */
#pragma once

#define PATH_MAX 4096

/* ---- Runtime configuration (~/.config/duop/duoprc), src/core/config*.c ---- */
#include "duop_abi.h"

#define CFG_MAX_BINDS 32
#define CFG_MAX_OPENS 32
#define CFG_MAX_MENUS 24
#define CFG_COLOR_FIELDS 29
#define I18N_ID_LEN 16
#define CFG_FILE_HARD 1048576u                 /* bigger files keep their head and raise g_cfg_warn */

#define MOD_ALT 2
#define MOD_CTRL 4
#define KEY_F1 0x100011
#define KEY_F10 0x10001A
#define KEY_F11 0x10001B
#define KEY_F12 0x10001C

enum { SORT_NAME = 0, SORT_SIZE = 1, SORT_MTIME = 2, SORT_EXT = 3 };

/* 15024 bytes; the fields below are read by assembly (theme.s, app*.s) at fixed offsets: theme 0, lang 4, hidden 8,
 * sort 12, color_mask 16, colors 32. -1 means "not set in duoprc". */
typedef struct Config {
    int32_t theme, lang, hidden, sort;
    uint32_t color_mask;                       /* bit i set when colors[i] came from the file */
    uint32_t bind_cnt, open_cnt, menu_cnt;
    uint32_t colors[CFG_COLOR_FIELDS];         /* 0x01RRGGBB */
    uint8_t pad[12];
    struct { int32_t key, mods, action, pad; } binds[CFG_MAX_BINDS];
    struct { char ext[16]; char cmd[240]; } opens[CFG_MAX_OPENS];
    struct { char label[64]; char cmd[192]; } menus[CFG_MAX_MENUS];
    char lang_id[I18N_ID_LEN];
} Config;
_Static_assert(sizeof(Config) == 15024, "Config is shared with assembly");

extern Config g_config;
extern int32_t g_cfg_warn;                     /* 1 when duoprc exceeded CFG_FILE_HARD */

typedef struct { char *tok; char *next; } CfgToken;
typedef struct { uint32_t key, mods; } CfgKey;

const char *cfg_getenv(char **envp, const char *key_eq);   /* value after "KEY=" or NULL */
char *skip_ws(char *p);                                    /* skips spaces and tabs */
int32_t parse_hex_rgb(const char *s);                      /* "#RRGGBB" / "RRGGBB" -> 0x01RRGGBB, -1 when invalid */
CfgKey parse_key_spec(const char *tok);                    /* "F1".."F12", "Ctrl+x", "Alt+x", one char; key 0 = invalid */
CfgToken next_token(char *cursor);                         /* whitespace/'='-delimited or "quoted" token, cut in place */
void parse_config_line(char *line);                        /* one line of duoprc, modified in place */
void config_load(char **envp);
Config *config_get(void);
int config_lookup_bind(int key, int mods);                 /* action id 1..19 or -1 */
const char *config_lookup_open(const char *filename);      /* command for the file extension, or NULL */
int config_menu_count(void);
int config_menu_item(int idx, const char **out_label, const char **out_cmd);
