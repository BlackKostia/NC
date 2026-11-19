/* src/ui/dialog.c - Modal Dialog base class (Dialog_vtbl, frame/button rendering, key/mouse dispatch,
 * button layout helpers; freestanding C23; replaces dialogs.s + Dialog_vtbl/dlg_layout_* from dialogs_confirm.s). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"

DIALOG_VTBL(Dialog_vtbl, "Dialog", Widget_vtbl, sizeof(Dialog), .on_cancel = Dialog_on_cancel);

void Dialog_init(Dialog *self, App *app, const char *title, uint32_t op_tag)
{
    Widget_init(&self->base, app, 200);
    self->app = (uint64_t)(uintptr_t)app;
    self->title = (uint64_t)(uintptr_t)title;
    self->op_tag = op_tag;
    self->hovered_btn = (uint32_t)-1;
}

void Dialog_dtor(Widget *self) { (void)self; }

void Dialog_layout(Widget *self, int x, int y, int w, int h)
{
    Widget_layout(self, x, y, w, h);
}

void Dialog_render(Widget *self, void *screen, void *theme)
{
    (void)self; (void)screen; (void)theme;
}

void Dialog_on_confirm(Dialog *self)
{
    self->result = DLG_OK;
    App_close_dialog((App *)(uintptr_t)self->app, DLG_OK);
}

void Dialog_on_cancel(Dialog *self)
{
    self->result = DLG_CANCEL;
    App_close_dialog((App *)(uintptr_t)self->app, DLG_CANCEL);
}

void Dialog_draw_frame(Dialog *self, ScreenBuffer *scr, const Theme *theme,
                       const char *b0_lbl, const char *b1_lbl)
{
    ScreenBuffer_set_pen(scr, theme->dialog_border, theme->dialog_bg, ATTR_BOLD);
    ScreenBuffer_draw_box(scr, self->base.x, self->base.y, self->base.w, self->base.h, 1);

    ScreenBuffer_set_pen(scr, theme->accent_fg, theme->dialog_border, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, self->base.x + 3, self->base.y,
                                 (const char *)(uintptr_t)self->title, self->base.w - 6);

    const HitZone *zones = (const HitZone *)self->btns;
    int32_t cnt = (int32_t)self->btn_count;
    for (int32_t i = 0; i < cnt; i++) {
        int bx = (int16_t)zones[i].x1;
        int by = (int16_t)zones[i].y;
        int bw = (int16_t)zones[i].x2 - bx;

        uint32_t fg = theme->badge_fg, bg = theme->badge_bg, attr = ATTR_NONE;
        if ((uint32_t)i == self->focus_btn) {
            fg = theme->accent_fg; bg = theme->accent; attr = ATTR_BOLD;
        } else if ((uint32_t)i == self->hovered_btn) {
            bg = theme->badge_hover_bg; attr = ATTR_BOLD;
        }
        ScreenBuffer_set_pen(scr, fg, bg, attr);

        const char *lbl = (i == 0) ? b0_lbl : b1_lbl;
        if (lbl) ScreenBuffer_draw_text_pad(scr, bx, by, lbl, bw);
    }
}

int Dialog_on_key(Widget *self, void *event)
{
    Dialog *d = (Dialog *)self;
    const Event *e = (const Event *)event;
    int key = e->key;
    if (key == KEY_ESC) {
        DIALOG_CALL(d, on_cancel);
    } else if (key == KEY_ENTER) {
        if (d->focus_btn == 0) DIALOG_CALL(d, on_confirm);
        else DIALOG_CALL(d, on_cancel);
    } else if (key == KEY_TAB || key == KEY_LEFT || key == KEY_RIGHT) {
        if ((int32_t)d->btn_count > 1) {
            d->focus_btn ^= 1;
            ((App *)(uintptr_t)d->app)->need_redraw = 1;
        }
    }
    return 1;
}

int Dialog_on_mouse(Widget *self, void *event)
{
    Dialog *d = (Dialog *)self;
    const Event *e = (const Event *)event;
    const HitZone *z = (const HitZone *)d->btns;
    int32_t cnt = (int32_t)d->btn_count;
    int32_t hit = -1;
    for (int32_t i = 0; i < cnt; i++) {
        if (e->mouse_y == (int16_t)z[i].y &&
            e->mouse_x >= (int16_t)z[i].x1 &&
            e->mouse_x < (int16_t)z[i].x2) {
            hit = (int16_t)z[i].id;
            break;
        }
    }
    if (e->mouse_kind == MACT_MOVE) {
        if ((uint32_t)hit != d->hovered_btn) {
            d->hovered_btn = (uint32_t)hit;
            ((App *)(uintptr_t)d->app)->need_redraw = 1;
        }
    } else if (e->mouse_kind == MACT_PRESS && e->mouse_btn == MOUSE_LEFT) {
        if (hit == 0) DIALOG_CALL(d, on_confirm);
        else if (hit == 1) DIALOG_CALL(d, on_cancel);
    }
    return 1;
}

void dlg_layout_center_buttons(Dialog *self, const char *btn0, const char *btn1)
{
    int w0 = utf8_display_width(btn0);
    int w1 = utf8_display_width(btn1);
    int half_tot = (w0 + 2 + w1) >> 1;
    int x0 = self->base.x + (int)((uint32_t)self->base.w >> 1) - half_tot;
    int by = self->base.y + self->base.h - 3;

    self->btn_count = 2;
    HitZone *z = (HitZone *)self->btns;
    z[0] = (HitZone){(uint16_t)x0, (uint16_t)(x0 + w0), (uint16_t)by, 0};
    int x1 = x0 + w0 + 2;
    z[1] = (HitZone){(uint16_t)x1, (uint16_t)(x1 + w1), (uint16_t)by, 1};
}

void dlg_layout_right_buttons(Dialog *self, const char *btn0, const char *btn1)
{
    int w0 = utf8_display_width(btn0);
    int by = self->base.y + self->base.h - 2;
    int rx = self->base.x + self->base.w - 2;
    HitZone *z = (HitZone *)self->btns;

    if (btn1 != nullptr) {
        int w1 = utf8_display_width(btn1);
        self->btn_count = 2;
        int b1x = rx - w1;
        z[1] = (HitZone){(uint16_t)b1x, (uint16_t)rx, (uint16_t)by, 1};
        int b0r = b1x - 2;
        z[0] = (HitZone){(uint16_t)(b0r - w0), (uint16_t)b0r, (uint16_t)by, 0};
    } else {
        self->btn_count = 1;
        z[0] = (HitZone){(uint16_t)(rx - w0), (uint16_t)rx, (uint16_t)by, 0};
    }
}
