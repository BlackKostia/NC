/* tests/harness/ui_render.h - the render-diff side of the UI harnesses (plan stage U0, header-only, freestanding).
 *
 * A widget is rendered by the frozen asm and by its C port into identical ScreenBuffers with a synthetic theme whose 29 colours
 * are all different (colour i = 0x01000000 | (i + 1) * 0x010307), then the back buffer is printed row by row: the text (wide
 * tails skipped) and the runs of (fg, bg, attrs), colours shown as theme slot names. Equal dumps = equal pixels on the terminal. */
#pragma once
#include "script_cli.h"
#include "duop_tui.h"

static Theme g_ui_theme;

static inline const Theme *ui_theme(void)
{
    for (int i = 0; i < 29; i++) g_ui_theme.colors[i] = 0x01000000u | (uint32_t)(i + 1) * 0x010307u;
    g_ui_theme.name = "ui-test";
    return &g_ui_theme;
}

static inline void ui_put_color(uint32_t c)
{
    static const char *const names[29] = {"bg", "surface", "surface_alt", "header_bg", "header_fg", "accent", "accent_fg",
        "border_active", "border_inactive", "text", "muted", "dir_fg", "exec_fg", "link_fg", "hidden_fg", "selected_fg",
        "selected_bg", "cursor_active_bg", "cursor_inactive_bg", "badge_bg", "badge_hover_bg", "badge_fg", "dialog_bg",
        "dialog_border", "ok_fg", "warn_fg", "err_fg", "scroll_track", "scroll_thumb"};
    for (int i = 0; i < 29; i++)
        if (g_ui_theme.colors[i] == c) { sc_put(names[i]); return; }
    static const char hx[] = "0123456789abcdef";
    char t[11] = "#";
    for (int i = 0; i < 8; i++) t[1 + i] = hx[(c >> (28 - 4 * i)) & 15];
    t[9] = 0;
    sc_put(t);
}

/* rows y0 .. y0 + h - 1 of the back buffer */
static inline void ui_dump(const ScreenBuffer *s, int y0, int h)
{
    for (int y = y0; y < y0 + h && y < s->height; y++) {
        const Cell *row = s->back + (size_t)y * (size_t)s->width;
        sc_put("  |");
        for (int x = 0; x < s->width; x++) {
            if (row[x].ch == CELL_WIDE_TAIL) continue;
            char u[8];
            int n = utf8_encode(row[x].ch ? row[x].ch : '?', u);
            u[n > 0 ? n : 0] = 0;
            sc_esc(u);
        }
        sc_put("|\n");
        for (int x = 0; x < s->width;) {
            int e = x;
            while (e < s->width && row[e].fg == row[x].fg && row[e].bg == row[x].bg && row[e].attrs == row[x].attrs) e++;
            sc_put("   "); sc_num(x); sc_put("-"); sc_num(e - 1); sc_put(" ");
            ui_put_color(row[x].fg); sc_put("/"); ui_put_color(row[x].bg); sc_put(" a="); sc_num(row[x].attrs); sc_put("\n");
            x = e;
        }
    }
}
