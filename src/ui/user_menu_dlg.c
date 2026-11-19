/* src/ui/user_menu_dlg.c - User Menu Dialog (duoprc `menu` items + installed package actions)
 * (freestanding C23; replaces src/ui/user_menu_dlg.s, kept as tests/harness/user_menu_dlg_reference.s). */
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void UserMenuDialog_layout(Widget *self, int x, int y, int w, int h);
static void UserMenuDialog_render(Widget *self, void *screen, void *theme);
static int UserMenuDialog_on_key(Widget *self, void *event);
static int UserMenuDialog_on_mouse(Widget *self, void *event);

DIALOG_VTBL(UserMenuDialog_vtbl, "UserMenuDialog", Dialog_vtbl, sizeof(UserMenuDialog),
            .base.layout = UserMenuDialog_layout, .base.render = UserMenuDialog_render,
            .base.on_key = UserMenuDialog_on_key, .base.on_mouse = UserMenuDialog_on_mouse);

static int um_total_count(void)
{
    return config_menu_count() + pkg_menu_count();
}

static int um_get_label(int idx, const char **out_label)
{
    int cc = config_menu_count();
    if (idx < cc) {
        const char *cmd = nullptr;
        return config_menu_item(idx, out_label, &cmd);
    }
    PkgAction *a = pkg_menu_get(idx - cc);
    if (!a) return 0;
    *out_label = a->menu;
    return 1;
}

UserMenuDialog *UserMenuDialog_new(App *app)
{
    UserMenuDialog *d = DUOP_NEW(UserMenuDialog, UserMenuDialog_vtbl);
    if (!d) return nullptr;

    Dialog_init(&d->base, app, i18n_get()->s[LS_dlg_title_usermenu], OP_USERMENU);
    d->cursor = 0;
    d->scroll = 0;
    (void)pkg_menu_refresh((char **)(uintptr_t)app->envp);

    UserMenuDialog_layout(&d->base.base, 0, 0, (int)app->term_w, (int)app->term_h);
    return d;
}

static void UserMenuDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 4;
    if (dw > 68) dw = 68;
    if (dw < 36) dw = 36;

    int dh = h - 4;
    if (dh > 16) dh = 16;
    if (dh < 10) dh = 10;

    self->w = dw;
    self->h = dh;
    self->x = (w - dw) >> 1;
    self->y = (h - dh) >> 1;

    const LangStrings *ls = i18n_get();
    dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);
}

static void UserMenuDialog_render(Widget *self, void *screen, void *theme)
{
    UserMenuDialog *d = (UserMenuDialog *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(&d->base, scr, th, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);

    int total = um_total_count();
    int vis = d->base.base.h - 5;
    if (vis < 1) vis = 1;

    for (int r = 0; r < vis; r++) {
        uint32_t idx = d->scroll + (uint32_t)r;
        if ((int)idx >= total) break;
        const char *lbl = nullptr;
        if (!um_get_label((int)idx, &lbl)) break;

        if (idx == d->cursor)
            ScreenBuffer_set_pen(scr, th->text, th->cursor_active_bg, ATTR_BOLD);
        else
            ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);

        int ry = d->base.base.y + 2 + r;
        ScreenBuffer_draw_hline(scr, d->base.base.x + 2, ry, d->base.base.w - 4, ' ');
        (void)ScreenBuffer_draw_text(scr, d->base.base.x + 3, ry, lbl, d->base.base.w - 6);
    }

    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    int hw = d->base.base.w - 26;
    if (hw < 8) hw = 8;
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 2, d->base.base.y + d->base.base.h - 2,
                                 ls->s[LS_um_hint], hw);
}

static int UserMenuDialog_on_key(Widget *self, void *event)
{
    UserMenuDialog *d = (UserMenuDialog *)self;
    App *app = (App *)(uintptr_t)d->base.app;
    uint32_t lat = ((const Event *)event)->lat;

    if (lat == KEY_UP || lat == 'k') {
        if ((int)d->cursor > 0) {
            d->cursor--;
            if (d->cursor < d->scroll) d->scroll = d->cursor;
            app->need_redraw = 1;
        }
    } else if (lat == KEY_DOWN || lat == 'j') {
        int total = um_total_count();
        if ((int)d->cursor + 1 < total) {
            d->cursor++;
            int vis = d->base.base.h - 5;
            if (vis < 1) vis = 1;
            if (d->cursor >= d->scroll + (uint32_t)vis)
                d->scroll = d->cursor - (uint32_t)vis + 1;
            app->need_redraw = 1;
        }
    } else if (lat == KEY_ENTER) {
        Dialog_on_confirm(&d->base);
    } else if (lat == KEY_ESC || lat == 'q') {
        Dialog_on_cancel(&d->base);
    } else {
        return Dialog_on_key(self, event);
    }
    return 1;
}

static int UserMenuDialog_on_mouse(Widget *self, void *event)
{
    UserMenuDialog *d = (UserMenuDialog *)self;
    const Event *ev = event;

    if (ev->mouse_kind == MACT_PRESS && ev->mouse_btn == MOUSE_LEFT &&
        ev->mouse_y >= d->base.base.y + 2 &&
        ev->mouse_y < d->base.base.y + d->base.base.h - 3) {
        uint32_t idx = (uint32_t)(ev->mouse_y - (d->base.base.y + 2)) + d->scroll;
        if ((int)idx < um_total_count()) {
            d->cursor = idx;
            Dialog_on_confirm(&d->base);
            return 1;
        }
    }
    return Dialog_on_mouse(self, event);
}
