/* tests/harness/ui_event.h - scripted Event builders and dumpers for UI differential harnesses (plan stage U0b, header-only).
 *
 * Parses compact stdin lines into Event structs (keys, modifiers, layout-independent lat, mouse press/release/drag/wheel, resize)
 * and prints widget / dialog / App state changes so the Python driver diffs the frozen asm oracle against the C23 port. */
#pragma once
#include "duop_classes.h"
#include "duop_tui.h"
#include "script_cli.h"

/* signed decimal integer (or 0x... hex) with leading/trailing space skip */
static inline int64_t ui_parse_num(const char **p)
{
    while (**p == ' ') (*p)++;
    int64_t sign = 1;
    if (**p == '-') { sign = -1; (*p)++; }
    uint64_t v = 0;
    if ((*p)[0] == '0' && ((*p)[1] == 'x' || (*p)[1] == 'X')) {
        *p += 2;
        for (;; (*p)++) {
            int c = **p;
            int d = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
            if (d < 0) break;
            v = (v << 4) | (uint64_t)d;
        }
    } else {
        while (**p >= '0' && **p <= '9') v = v * 10 + (uint64_t)(*(*p)++ - '0');
    }
    if (**p == ' ') (*p)++;
    return sign * (int64_t)v;
}

static inline Event ui_evt_key(int32_t key, int32_t mods, int32_t lat)
{
    Event e = {0};
    e.type = EVT_KEY;
    e.mods = mods;
    e.key = key;
    e.lat = lat;
    return e;
}

static inline Event ui_evt_mouse(int32_t kind, int32_t btn, int32_t x, int32_t y, int32_t mods)
{
    Event e = {0};
    e.type = EVT_MOUSE;
    e.mods = mods;
    e.mouse_x = x;
    e.mouse_y = y;
    e.mouse_btn = btn;
    e.mouse_kind = kind;
    return e;
}

static inline Event ui_evt_resize(int32_t cols, int32_t rows)
{
    Event e = {0};
    e.type = EVT_RESIZE;
    e.mouse_x = cols;
    e.mouse_y = rows;
    return e;
}

/* Parse a scripted event line:
 *   K <key> <mods> [lat]        -> EVT_KEY (lat defaults to key)
 *   M <kind> <btn> <x> <y> [m]  -> EVT_MOUSE (mods defaults to 0)
 *   Z <cols> <rows>             -> EVT_RESIZE
 * Returns true when the line matched one of the event forms. */
static inline bool ui_parse_event(const char *line, Event *out)
{
    if (!line || !line[0]) return false;
    const char *a = line + 1;
    if (line[0] == 'K') {
        int32_t key = (int32_t)ui_parse_num(&a);
        int32_t mods = (int32_t)ui_parse_num(&a);
        while (*a == ' ') a++;
        int32_t lat = *a ? (int32_t)ui_parse_num(&a) : key;
        *out = ui_evt_key(key, mods, lat);
        return true;
    }
    if (line[0] == 'M') {
        int32_t kind = (int32_t)ui_parse_num(&a);
        int32_t btn = (int32_t)ui_parse_num(&a);
        int32_t x = (int32_t)ui_parse_num(&a);
        int32_t y = (int32_t)ui_parse_num(&a);
        while (*a == ' ') a++;
        int32_t mods = *a ? (int32_t)ui_parse_num(&a) : 0;
        *out = ui_evt_mouse(kind, btn, x, y, mods);
        return true;
    }
    if (line[0] == 'Z') {
        int32_t cols = (int32_t)ui_parse_num(&a);
        int32_t rows = (int32_t)ui_parse_num(&a);
        *out = ui_evt_resize(cols, rows);
        return true;
    }
    return false;
}

static inline void ui_dump_event_res(const char *tag, int rc, const App *app, const Dialog *dlg)
{
    sc_put(tag); sc_put(" rc="); sc_num(rc);
    if (app) { sc_put(" redraw="); sc_num(app->need_redraw); }
    if (dlg) { sc_put(" dlg_res="); sc_num(dlg->result); }
    sc_put("\n");
}
