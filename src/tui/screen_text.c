/* src/tui/screen_text.c - text and box drawing on a ScreenBuffer (freestanding C23; replaces screen_text.s).
 * Everything uses the current pen. */
#include "duop_tui.h"

typedef struct { uint64_t cp, len; } Utf8Dec;
Utf8Dec utf8_decode(const char *s);
int utf8_char_width(uint32_t cp);

/* Rounded box (╭╮╰╯─│) of w x h cells; with fill_interior the inside is filled with spaces first. Smaller than 2x2: nothing. */
void ScreenBuffer_draw_box(ScreenBuffer *s, int x, int y, int w, int h, int fill_interior)
{
    if (w < 2 || h < 2) return;
    if (fill_interior) ScreenBuffer_fill_rect(s, x + 1, y + 1, w - 2, h - 2, ' ');
    ScreenBuffer_set_cell_pen(s, x, y, CH_BOX_TL);
    ScreenBuffer_set_cell_pen(s, x + w - 1, y, CH_BOX_TR);
    ScreenBuffer_set_cell_pen(s, x, y + h - 1, CH_BOX_BL);
    ScreenBuffer_set_cell_pen(s, x + w - 1, y + h - 1, CH_BOX_BR);
    ScreenBuffer_draw_hline(s, x + 1, y, w - 2, CH_BOX_H);
    ScreenBuffer_draw_hline(s, x + 1, y + h - 1, w - 2, CH_BOX_H);
    for (int i = 1; i < h - 1; i++) {
        ScreenBuffer_set_cell_pen(s, x, y + i, CH_BOX_V);
        ScreenBuffer_set_cell_pen(s, x + w - 1, y + i, CH_BOX_V);
    }
}

/* Control characters become spaces, zero-width marks are skipped, a character that would pass max_cols stops the text. */
int ScreenBuffer_draw_text(ScreenBuffer *s, int x, int y, const char *utf8, int max_cols)
{
    int cols = 0;
    if (!utf8 || max_cols <= 0) return 0;
    for (;;) {
        Utf8Dec d = utf8_decode(utf8);
        if (!d.len) break;
        utf8 += d.len;
        uint32_t cp = (uint32_t)d.cp;
        if (cp < 0x20 || cp == 0x7F) cp = ' ';
        int w = utf8_char_width(cp);
        if (!w) continue;                                   /* combining mark */
        if (cols + w > max_cols) break;
        ScreenBuffer_set_cell_pen(s, x, y, cp);
        if (w == 2) ScreenBuffer_set_cell_pen(s, x + 1, y, CELL_WIDE_TAIL);
        x += w;
        cols += w;
    }
    return cols;
}

/* Draws up to `width` columns and pads the rest of them with spaces. */
void ScreenBuffer_draw_text_pad(ScreenBuffer *s, int x, int y, const char *utf8, int width)
{
    for (int cols = ScreenBuffer_draw_text(s, x, y, utf8, width); cols < width; cols++)
        ScreenBuffer_set_cell_pen(s, x + cols, y, ' ');
}
