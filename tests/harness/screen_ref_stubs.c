/* aarch64 has no frozen asm: the harness' ref_ScreenBuffer_* entry points forward to the C module. */
#include "duop_tui.h"

const ObjectVtbl ref_ScreenBuffer_vtbl;
ScreenBuffer *ref_ScreenBuffer_new(int w, int h) { return ScreenBuffer_new(w, h); }
void ref_ScreenBuffer_dtor(ScreenBuffer *s) { ScreenBuffer_dtor(s); }
intptr_t ref_ScreenBuffer_resize(ScreenBuffer *s, int w, int h) { return ScreenBuffer_resize(s, w, h); }
void ref_ScreenBuffer_flush(ScreenBuffer *s) { ScreenBuffer_flush(s); }
void ref_ScreenBuffer_clear(ScreenBuffer *s, uint32_t a, uint32_t b) { ScreenBuffer_clear(s, a, b); }
void ref_ScreenBuffer_set_pen(ScreenBuffer *s, uint32_t a, uint32_t b, uint32_t c) { ScreenBuffer_set_pen(s, a, b, c); }
void ref_ScreenBuffer_set_cell(ScreenBuffer *s, int x, int y, uint32_t cp, uint32_t f, uint32_t b) { ScreenBuffer_set_cell(s, x, y, cp, f, b); }
void ref_ScreenBuffer_set_cell_pen(ScreenBuffer *s, int x, int y, uint32_t cp) { ScreenBuffer_set_cell_pen(s, x, y, cp); }
void ref_ScreenBuffer_fill_rect(ScreenBuffer *s, int x, int y, int w, int h, uint32_t cp) { ScreenBuffer_fill_rect(s, x, y, w, h, cp); }
void ref_ScreenBuffer_draw_hline(ScreenBuffer *s, int x, int y, int n, uint32_t cp) { ScreenBuffer_draw_hline(s, x, y, n, cp); }
void ref_ScreenBuffer_draw_box(ScreenBuffer *s, int x, int y, int w, int h, int f) { ScreenBuffer_draw_box(s, x, y, w, h, f); }
int ref_ScreenBuffer_draw_text(ScreenBuffer *s, int x, int y, const char *t, int m) { return ScreenBuffer_draw_text(s, x, y, t, m); }
void ref_ScreenBuffer_draw_text_pad(ScreenBuffer *s, int x, int y, const char *t, int w) { ScreenBuffer_draw_text_pad(s, x, y, t, w); }
