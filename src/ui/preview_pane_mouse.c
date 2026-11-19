/* src/ui/preview_pane_mouse.c - PreviewPane mouse wheel scrolling (freestanding C23; replaces
 * src/ui/preview_pane_mouse.s, kept as tests/harness/preview_pane_mouse_reference.s). */
#include "duop_classes.h"
#include "duop_tui.h"
#include "duop_ui.h"

int PreviewPane_on_mouse(Widget *self, void *evt)
{
    PreviewPane *p = (PreviewPane *)self;
    const Event *e = evt;
    if (e->mouse_kind != MACT_WHEEL) return 0;
    int scroll = (int)p->scroll;
    if (e->mouse_btn == MOUSE_WHEEL_UP) {
        scroll -= 3;
        if (scroll < 0) scroll = 0;
    } else {
        scroll += 3;
        int max = p->is_binary ? (int)(p->buf_len >> 3) : (int)p->total_lines;
        max--;
        if (max < 0) max = 0;
        if (scroll > max) scroll = max;
    }
    p->scroll = (uint32_t)scroll;
    ((App *)(uintptr_t)p->app)->need_redraw = 1;
    return 1;
}
