/* src/ui/search_dialog.c - Recursive search dialog (name mask + content grep) & virtual pane helpers
 * (freestanding C23; replaces src/ui/search_dialog{,_input}.s, kept as
 * tests/harness/search_dialog{,_input}_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void SearchDialog_layout(Widget *self, int x, int y, int w, int h);
static void SearchDialog_render(Widget *self, void *screen, void *theme);
static int SearchDialog_on_key(Widget *self, void *event);
static int SearchDialog_on_mouse(Widget *self, void *event);

DIALOG_VTBL(SearchDialog_vtbl, "SearchDialog", Dialog_vtbl, sizeof(SearchDialog),
            .base.layout = SearchDialog_layout, .base.render = SearchDialog_render,
            .base.on_key = SearchDialog_on_key, .base.on_mouse = SearchDialog_on_mouse);

SearchDialog *SearchDialog_new(App *app)
{
    SearchDialog *d = DUOP_NEW(SearchDialog, SearchDialog_vtbl);
    if (!d) return nullptr;

    Dialog_init(&d->base, app, i18n_get()->s[LS_dlg_title_search], OP_SEARCH);
    int tw = app ? (int)app->term_w : 80;
    int th = app ? (int)app->term_h : 24;
    SearchDialog_layout(&d->base.base, 0, 0, tw, th);
    return d;
}

int fp_exit_virtual(FilePane *pane)
{
    DirModel *dm = (DirModel *)(uintptr_t)pane->model;
    if (dm->virtual_mode == 2) return arc_nav_up(pane);
    if (dm->virtual_mode == 0) return 0;

    dm->virtual_mode = 0;
    (void)DirModel_reload(dm);
    pane->cursor = 0;
    pane->scroll = 0;
    FilePane_ensure_visible(pane);
    return 1;
}

void fp_draw_search_badge(FilePane *pane, ScreenBuffer *scr)
{
    const DirModel *dm = (const DirModel *)(uintptr_t)pane->model;
    if (dm->virtual_mode == 0) { fp_draw_du_badge(pane, scr); return; }

    (void)ScreenBuffer_draw_text(scr, pane->base.x + pane->base.w - 12, pane->base.y,
                                 i18n_get()->s[LS_fp_search_badge], 10);
}

static void SearchDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 4;
    if (dw > 62) dw = 62;
    if (dw < 36) dw = 36;

    self->w = dw;
    self->h = 11;
    self->x = (w - dw) >> 1;
    self->y = (h - 11) >> 1;

    const LangStrings *ls = i18n_get();
    dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);
}

static void sd_draw_field(const SearchDialog *d, ScreenBuffer *scr, const Theme *th,
                          int field_idx, const char *lbl)
{
    int x = d->base.base.x;
    int y = d->base.base.y + (field_idx ? 5 : 2);
    int w = d->base.base.w;
    const char *val = (const char *)(field_idx ? d->grep_buf : d->name_buf);

    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, x + 2, y, lbl, w - 4);

    if ((int)d->focus_field == field_idx)
        ScreenBuffer_set_pen(scr, th->text, th->cursor_active_bg, ATTR_BOLD);
    else
        ScreenBuffer_set_pen(scr, th->text, th->surface_alt, ATTR_NONE);

    ScreenBuffer_draw_hline(scr, x + 2, y + 1, w - 4, ' ');
    (void)ScreenBuffer_draw_text(scr, x + 3, y + 1, val, w - 6);
}

static void SearchDialog_render(Widget *self, void *screen, void *theme)
{
    SearchDialog *d = (SearchDialog *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(&d->base, scr, th, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);

    sd_draw_field(d, scr, th, 0, ls->s[LS_srch_lbl_name]);
    sd_draw_field(d, scr, th, 1, ls->s[LS_srch_lbl_grep]);

    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    int hw = d->base.base.w - 26;
    if (hw < 8) hw = 8;
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 2, d->base.base.y + d->base.base.h - 2,
                                 ls->s[LS_srch_hint], hw);
}

static void sd_edit_char(SearchDialog *d, uint32_t key, int is_bs)
{
    uint8_t *buf = d->focus_field == 0 ? d->name_buf : d->grep_buf;
    uint32_t *len_p = d->focus_field == 0 ? &d->name_len : &d->grep_len;
    uint32_t len = *len_p;

    if (is_bs) {
        if (len == 0) return;
        len--;
        while (len > 0 && (buf[len] & 0xC0U) == 0x80U) len--;
        buf[len] = '\0';
        *len_p = len;
        return;
    }

    if (key < 0x80U) {
        if (len >= 126) return;
        buf[len++] = (uint8_t)key;
    } else if (key < 0x800U) {
        if (len >= 125) return;
        buf[len++] = (uint8_t)(0xC0U | (key >> 6));
        buf[len++] = (uint8_t)(0x80U | (key & 0x3FU));
    } else if (key < 0x10000U) {
        if (len >= 124) return;
        buf[len++] = (uint8_t)(0xE0U | (key >> 12));
        buf[len++] = (uint8_t)(0x80U | ((key >> 6) & 0x3FU));
        buf[len++] = (uint8_t)(0x80U | (key & 0x3FU));
    } else {
        return;
    }
    buf[len] = '\0';
    *len_p = len;
}

static int SearchDialog_on_key(Widget *self, void *event)
{
    SearchDialog *d = (SearchDialog *)self;
    App *app = (App *)(uintptr_t)d->base.app;
    const Event *ev = event;
    uint32_t key = ev->key;

    if (key == KEY_TAB || key == KEY_UP || key == KEY_DOWN) {
        d->focus_field ^= 1;
        app->need_redraw = 1;
    } else if (key == KEY_ENTER) {
        Dialog_on_confirm(&d->base);
    } else if (key == KEY_ESC) {
        Dialog_on_cancel(&d->base);
    } else if (key == KEY_BACKSPACE || key == 8) {
        sd_edit_char(d, 0, 1);
        app->need_redraw = 1;
    } else if ((ev->mods & (MOD_CTRL | MOD_ALT)) == 0 && (int)key >= 32) {
        sd_edit_char(d, key, 0);
        app->need_redraw = 1;
    }
    return 1;
}

static int SearchDialog_on_mouse(Widget *self, void *event)
{
    SearchDialog *d = (SearchDialog *)self;
    const Event *ev = event;

    if (ev->mouse_kind == MACT_PRESS && ev->mouse_btn == MOUSE_LEFT) {
        int rel = ev->mouse_y - d->base.base.y;
        if (rel == 3) {
            d->focus_field = 0;
            ((App *)(uintptr_t)d->base.app)->need_redraw = 1;
            return 1;
        } else if (rel == 6) {
            d->focus_field = 1;
            ((App *)(uintptr_t)d->base.app)->need_redraw = 1;
            return 1;
        }
    }
    return Dialog_on_mouse(self, event);
}
