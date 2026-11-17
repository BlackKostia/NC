/* src/tui/screen_rect.c - ScreenBuffer rectangle helpers for graphics overlays (Sixel / Kitty images drawn over
 * cells): does the next flush rewrite any cell of a rect, and forcing a rect to be rewritten (replaces screen_rect.s).
 * Arithmetic is 32-bit wrapping like the assembly: callers pass unvalidated widget geometry. */
#include "duop_tui.h"

/* Clips (x, y, w, h) to the buffer; false when nothing is left. */
static bool sr_clip(const ScreenBuffer *s, int32_t *x, int32_t *y, int32_t *w, int32_t *h)
{
    if (*x < 0) { *w = (int32_t)((uint32_t)*w + (uint32_t)*x); *x = 0; }
    if (*y < 0) { *h = (int32_t)((uint32_t)*h + (uint32_t)*y); *y = 0; }
    int32_t room = s->width - *x;
    if (*w > room) *w = room;
    room = s->height - *y;
    if (*h > room) *h = room;
    return *w > 0 && *h > 0;
}

/* Byte offset of cell (x, y): 32-bit index arithmetic, 16-byte cells. */
static size_t sr_off(const ScreenBuffer *s, int32_t x, int32_t y)
{
    return (size_t)(uint32_t)((uint32_t)y * (uint32_t)s->width + (uint32_t)x) << 4;
}

int ScreenBuffer_rect_changed(ScreenBuffer *s, int x, int y, int w, int h)
{
    if (s->force_full) return 1;
    if (!sr_clip(s, &x, &y, &w, &h)) return 0;
    for (int32_t row = y, end = y + h; row < end; row++) {
        size_t off = sr_off(s, x, row);
        if (os_mem_mismatch16((char *)s->back + off, (char *)s->front + off, (size_t)w) < (size_t)w) return 1;
    }
    return 0;
}

void ScreenBuffer_rect_invalidate(ScreenBuffer *s, int x, int y, int w, int h)
{
    if (!sr_clip(s, &x, &y, &w, &h)) return;
    for (int32_t row = y, end = y + h; row < end; row++) {
        Cell *c = (Cell *)((char *)s->front + sr_off(s, x, row));
        for (int32_t i = 0; i < w; i++) c[i].ch = 0xFFFFFFFFu;       /* never equal to a real cell: rewritten */
    }
}
