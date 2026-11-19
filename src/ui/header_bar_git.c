/* src/ui/header_bar_git.c - HeaderBar mode pill and git badge dispatch (freestanding C23; replaces
 * src/ui/header_bar_git.s, kept as tests/harness/header_bar_git_reference.s). */
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

void hdr_draw_git_badge(void *hdr, void *scr, const void *theme, int x, int y);

void hdr_draw_mode_and_git(void *hdr, void *scr, const void *theme, const void *ls)
{
    HeaderBar *hb = hdr;
    ScreenBuffer *s = scr;
    const Theme *t = theme;
    const LangStrings *l = ls;
    int x = hb->base.x + utf8_display_width(l->s[LS_hdr_brand]) + 1;
    if (hb->base.w < 30) return;
    ScreenBuffer_set_pen(s, t->header_fg, t->surface_alt, ATTR_NONE);
    const App *app = (const App *)(uintptr_t)hb->app;
    const char *mode = app->right_mode == RIGHT_MODE_PREVIEW ? l->s[LS_hdr_mode_prev] : l->s[LS_hdr_mode_dual];
    int mw = utf8_display_width(mode);
    (void)ScreenBuffer_draw_text(s, x, hb->base.y, mode, mw);
    hdr_draw_git_badge(hb, s, t, x + mw + 1, hb->base.y);
}
