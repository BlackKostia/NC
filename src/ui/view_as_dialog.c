/* src/ui/view_as_dialog.c - "Open as" dialog shown by F3 on an image: [ Image ] [ Hex ] [ Text ]
 * (freestanding C23; replaces src/ui/view_as_dialog.s, kept as tests/harness/view_as_dialog_reference.s). */
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void ViewAsDialog_layout(Widget *self, int x, int y, int w, int h);
static void ViewAsDialog_render(Widget *self, void *screen, void *theme);
static int ViewAsDialog_on_key(Widget *self, void *event);
static int ViewAsDialog_on_mouse(Widget *self, void *event);

DIALOG_VTBL(ViewAsDialog_vtbl, "ViewAsDialog", Dialog_vtbl, sizeof(ViewAsDialog),
            .base.layout = ViewAsDialog_layout, .base.render = ViewAsDialog_render,
            .base.on_key = ViewAsDialog_on_key, .base.on_mouse = ViewAsDialog_on_mouse);

ViewAsDialog *ViewAsDialog_new(App *app, const char *path, int fmt)
{
    ViewAsDialog *d = DUOP_NEW(ViewAsDialog, ViewAsDialog_vtbl);
    if (!d) return nullptr;

    Dialog_init(&d->base, app, i18n_get()->s[LS_dlg_title_viewas], OP_VIEWAS);
    d->fmt = (uint32_t)fmt;
    d->choice = PV_MODE_IMAGE;
    d->base.focus_btn = 0;
    d->base.btn_count = 3;
    (void)str_copy((char *)d->path, path, sizeof d->path);

    ViewAsDialog_layout(&d->base.base, 0, 0, (int)app->term_w, (int)app->term_h);
    return d;
}

static void ViewAsDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 4;
    if (dw > 60) dw = 60;
    if (dw < 44) dw = 44;

    self->w = dw;
    self->h = 9;
    self->x = (w - dw) >> 1;
    self->y = (h - 9) >> 1;
}

static void vas_buttons(ViewAsDialog *d, ScreenBuffer *scr, const Theme *th)
{
    const LangStrings *ls = i18n_get();
    const char *labels[3] = {
        ls->s[LS_vas_image],
        ls->s[LS_vas_hex],
        ls->s[LS_vas_text],
    };
    int bx = d->base.base.x + 3;
    int by = d->base.base.y + 4;
    HitZone *z = (HitZone *)d->base.btns;

    for (int i = 0; i < 3; i++) {
        if (i == (int)d->base.focus_btn)
            ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_BOLD);
        else
            ScreenBuffer_set_pen(scr, th->text, th->surface_alt, ATTR_NONE);

        int bw = (int)utf8_display_width(labels[i]) + 2;
        z[i].x1 = (int16_t)bx;
        z[i].x2 = (int16_t)(bx + bw);
        z[i].y = (int16_t)by;
        z[i].id = (int16_t)i;

        (void)ScreenBuffer_draw_text(scr, bx, by, " ", 1);
        (void)ScreenBuffer_draw_text(scr, bx + 1, by, labels[i], 24);
        (void)ScreenBuffer_draw_text(scr, bx + bw - 1, by, " ", 1);
        bx += bw + 2;
    }
}

static void ViewAsDialog_render(Widget *self, void *screen, void *theme)
{
    (void)theme;
    ViewAsDialog *d = (ViewAsDialog *)self;
    ScreenBuffer *scr = screen;
    const App *app = (const App *)(uintptr_t)d->base.app;
    const Theme *th = (const Theme *)(uintptr_t)app->theme;

    Dialog_draw_frame(&d->base, scr, th, nullptr, nullptr);

    const char *base = path_basename((const char *)d->path);
    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 3, d->base.base.y + 2,
                                 base, d->base.base.w - 6);

    vas_buttons(d, scr, th);

    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 3, d->base.base.y + 6,
                                 i18n_get()->s[LS_vas_hint], d->base.base.w - 6);
}

static int ViewAsDialog_on_key(Widget *self, void *event)
{
    ViewAsDialog *d = (ViewAsDialog *)self;
    App *app = (App *)(uintptr_t)d->base.app;
    const Event *ev = event;

    if (ev->lat == KEY_ESC) {
        Dialog_on_cancel(&d->base);
        return 1;
    }
    uint32_t low = ev->lat | 0x20U;
    if (low == 'i') {
        d->choice = PV_MODE_IMAGE;
        Dialog_on_confirm(&d->base);
        return 1;
    }
    if (low == 'h') {
        d->choice = PV_MODE_HEX;
        Dialog_on_confirm(&d->base);
        return 1;
    }
    if (low == 't') {
        d->choice = PV_MODE_TEXT;
        Dialog_on_confirm(&d->base);
        return 1;
    }

    if (ev->key == KEY_LEFT) {
        d->base.focus_btn = (d->base.focus_btn + 2U) % 3U;
        app->need_redraw = 1;
        return 1;
    }
    if (ev->key == KEY_RIGHT || ev->key == KEY_TAB) {
        d->base.focus_btn = (d->base.focus_btn + 1U) % 3U;
        app->need_redraw = 1;
        return 1;
    }
    if (ev->key == KEY_ENTER) {
        d->choice = d->base.focus_btn + 1U;
        Dialog_on_confirm(&d->base);
        return 1;
    }
    return 0;
}

static int ViewAsDialog_on_mouse(Widget *self, void *event)
{
    ViewAsDialog *d = (ViewAsDialog *)self;
    const Event *ev = event;
    if (ev->mouse_kind != MACT_PRESS) return 0;

    const HitZone *z = (const HitZone *)d->base.btns;
    for (int i = 0; i < 3; i++) {
        if (ev->mouse_y == (int16_t)z[i].y &&
            ev->mouse_x >= (int16_t)z[i].x1 &&
            ev->mouse_x < (int16_t)z[i].x2) {
            d->choice = (uint32_t)(i + 1);
            Dialog_on_confirm(&d->base);
            return 1;
        }
    }
    return 0;
}
