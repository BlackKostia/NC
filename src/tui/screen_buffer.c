/* src/tui/screen_buffer.c - ScreenBuffer cell grid operations (freestanding C23; replaces screen_buffer.s).
 * Every write goes to the back buffer and is clipped cell by cell: out-of-range coordinates are ignored, never faulted. */
#include "duop_pal.h"
#include "duop_tui.h"

intptr_t ScreenBuffer_resize(ScreenBuffer *s, int width, int height)
{
    if (width < 1) width = 1;
    if (height < 1) height = 1;
    size_t need = (size_t)width * (size_t)height;
    if (need > s->cell_cap) {                         /* a little slack (+256 cells) keeps small resizes free */
        size_t cells = need + 256;
        void *front = mem_realloc(s->front, cells * sizeof(Cell));
        if (!front) return -ENOMEM;
        s->front = front;
        void *back = mem_realloc(s->back, cells * sizeof(Cell));
        if (!back) return -ENOMEM;                    /* the grown front is harmless: cell_cap is unchanged */
        s->back = back;
        s->cell_cap = cells;
    }
    s->width = width;
    s->height = height;
    s->force_full = 1;
    return 0;
}

void ScreenBuffer_clear(ScreenBuffer *s, uint32_t fg, uint32_t bg)
{
    int32_t n = (int32_t)((uint32_t)s->width * (uint32_t)s->height);
    if (n <= 0 || !s->back) return;
    for (Cell *c = s->back; n > 0; n--, c++) *c = (Cell){' ', fg, bg, ATTR_NONE};
}

void ScreenBuffer_set_pen(ScreenBuffer *s, uint32_t fg, uint32_t bg, uint32_t attrs)
{
    s->pen_fg = (int32_t)fg;
    s->pen_bg = (int32_t)bg;
    s->pen_attrs = (int32_t)attrs;
}

static inline Cell *cell_at(ScreenBuffer *s, int x, int y)
{
    if (x < 0 || y < 0 || x >= s->width || y >= s->height) return nullptr;
    return s->back + (ptrdiff_t)(y * s->width + x);
}

void ScreenBuffer_set_cell(ScreenBuffer *s, int x, int y, uint32_t cp, uint32_t fg, uint32_t bg)
{
    Cell *c = cell_at(s, x, y);
    if (c) *c = (Cell){cp, fg, bg, ATTR_NONE};
}

void ScreenBuffer_set_cell_pen(ScreenBuffer *s, int x, int y, uint32_t cp)
{
    Cell *c = cell_at(s, x, y);
    if (c) *c = (Cell){cp, (uint32_t)s->pen_fg, (uint32_t)s->pen_bg, (uint32_t)s->pen_attrs};
}

void ScreenBuffer_fill_rect(ScreenBuffer *s, int x, int y, int w, int h, uint32_t cp)
{
    if (w <= 0 || h <= 0) return;
    for (int dy = 0; dy < h; dy++)
        for (int dx = 0; dx < w; dx++) ScreenBuffer_set_cell_pen(s, (int)((uint32_t)x + (uint32_t)dx), (int)((uint32_t)y + (uint32_t)dy), cp);
}

void ScreenBuffer_draw_hline(ScreenBuffer *s, int x, int y, int len, uint32_t cp)
{
    for (int i = 0; i < len; i++) ScreenBuffer_set_cell_pen(s, (int)((uint32_t)x + (uint32_t)i), y, cp);
}
