/* src/ui/dialog_confirm.c - ConfirmDialog subclass of Dialog (Yes/No confirmation modal)
 * (freestanding C23; replaces ConfirmDialog in dialogs_confirm.s, kept as tests/harness/dialogs_confirm_reference.s). */
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

DIALOG_VTBL(ConfirmDialog_vtbl, "ConfirmDialog", Dialog_vtbl, sizeof(ConfirmDialog),
            .base.layout = ConfirmDialog_layout, .base.render = ConfirmDialog_render);

ConfirmDialog *ConfirmDialog_new(App *app, const char *title, const char *message,
                                 const char *detail, uint32_t op_tag)
{
    ConfirmDialog *cd = DUOP_NEW(ConfirmDialog, ConfirmDialog_vtbl);
    if (!cd) return nullptr;
    Dialog_init(&cd->base, app, title, op_tag);
    (void)str_copy((char *)cd->message, message, sizeof cd->message);
    (void)str_copy((char *)cd->detail, detail, sizeof cd->detail);
    ConfirmDialog_layout(&cd->base.base, 0, 0, (int)app->term_w, (int)app->term_h);
    return cd;
}

void ConfirmDialog_layout(Widget *self, int x, int y, int w, int h)
{
    if (h <= 0) {
        w = x;
        h = y;
        x = 0;
        y = 0;
    }
    int dw = w - 6;
    if (dw > 64) dw = 64;
    if (dw < 34) dw = w;
    int dh = 9;
    if (dh > h) dh = h;
    int dx = x + ((w - dw) >> 1);
    int dy = y + ((h - dh) >> 1);

    Widget_layout(self, dx, dy, dw, dh);
    const LangStrings *ls = i18n_get();
    dlg_layout_center_buttons((Dialog *)self, ls->s[LS_dlg_btn_yes], ls->s[LS_dlg_btn_no]);
}

void ConfirmDialog_render(Widget *self, void *screen, void *theme)
{
    ConfirmDialog *cd = (ConfirmDialog *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(&cd->base, scr, th, ls->s[LS_dlg_btn_yes], ls->s[LS_dlg_btn_no]);

    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, cd->base.base.x + 3, cd->base.base.y + 2,
                                 (const char *)cd->message, cd->base.base.w - 6);

    ScreenBuffer_set_pen(scr, th->warn_fg, th->dialog_bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, cd->base.base.x + 3, cd->base.base.y + 4,
                                 (const char *)cd->detail, cd->base.base.w - 6);
}
