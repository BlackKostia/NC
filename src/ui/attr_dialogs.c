/* src/ui/attr_dialogs.c - ChmodDialog (clickable rwx bits, octal mode, uid:gid)
 * (freestanding C23; replaces src/ui/attr_dialogs{,_input}.s, kept as
 * tests/harness/attr_dialogs{,_input}_reference.s). */
#include "duop_classes.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void ChmodDialog_layout(Widget *self, int x, int y, int w, int h);
static void ChmodDialog_render(Widget *self, void *screen, void *theme);
static int ChmodDialog_on_key(Widget *self, void *event);
static int ChmodDialog_on_mouse(Widget *self, void *event);

DIALOG_VTBL(ChmodDialog_vtbl, "ChmodDialog", Dialog_vtbl, sizeof(ChmodDialog),
            .base.layout = ChmodDialog_layout, .base.render = ChmodDialog_render,
            .base.on_key = ChmodDialog_on_key, .base.on_mouse = ChmodDialog_on_mouse);

ChmodDialog *ChmodDialog_new(App *app, const char *path)
{
    ChmodDialog *d = DUOP_NEW(ChmodDialog, ChmodDialog_vtbl);
    if (!d) return nullptr;

    Dialog_init(&d->base, app, i18n_get()->s[LS_dlg_title_chmod], OP_CHMOD);
    (void)str_copy((char *)d->target_path, path, sizeof d->target_path);

    FileStat st;
    if (os_statat(AT_FDCWD, path, &st, 0) >= 0) {
        d->mode = st.mode & 07777U;
        d->uid = st.uid;
        d->gid = st.gid;
    } else {
        d->mode = 0644U;
    }

    uint64_t n = u64_to_dec(d->uid, (char *)d->owner_buf);
    d->owner_buf[n] = ':';
    n += 1 + u64_to_dec(d->gid, (char *)d->owner_buf + n + 1);
    d->owner_len = (uint32_t)n;

    int tw = app ? (int)app->term_w : 80;
    int th = app ? (int)app->term_h : 24;
    ChmodDialog_layout(&d->base.base, 0, 0, tw, th);
    return d;
}

static void ChmodDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 4;
    if (dw > 56) dw = 56;
    if (dw < 40) dw = 40;

    self->w = dw;
    self->h = 10;
    self->x = (w - dw) >> 1;
    self->y = (h - 10) >> 1;

    const LangStrings *ls = i18n_get();
    dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);
}

static void cd_format_octal(uint32_t mode, char out[5])
{
    out[0] = '0';
    out[1] = (char)('0' + ((mode >> 6) & 7));
    out[2] = (char)('0' + ((mode >> 3) & 7));
    out[3] = (char)('0' + (mode & 7));
    out[4] = '\0';
}

static void cd_draw_bits(const ChmodDialog *d, ScreenBuffer *scr, const Theme *th)
{
    static const char rwx[9] = "rwxrwxrwx";
    char oct[5];
    cd_format_octal(d->mode, oct);

    ScreenBuffer_set_pen(scr, th->accent, th->dialog_bg, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 35, d->base.base.y + 4, oct, 5);

    for (int i = 0; i < 9; i++) {
        int xpos = d->base.base.x + 3 + i * 2 + (i / 3) * 2;
        uint32_t ch = (d->mode & (1U << (8 - i))) ? (uint32_t)(uint8_t)rwx[i] : (uint32_t)'-';
        if (i == (int)d->cursor)
            ScreenBuffer_set_pen(scr, th->text, th->cursor_active_bg, ATTR_BOLD);
        else
            ScreenBuffer_set_pen(scr, th->text, th->surface_alt, ATTR_NONE);
        ScreenBuffer_set_cell_pen(scr, xpos, d->base.base.y + 4, ch);
    }
}

static void ChmodDialog_render(Widget *self, void *screen, void *theme)
{
    ChmodDialog *d = (ChmodDialog *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(&d->base, scr, th, ls->s[LS_dlg_btn_ok], ls->s[LS_dlg_btn_cancel]);

    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);
    const char *base = path_basename((const char *)d->target_path);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 3, d->base.base.y + 2, base, d->base.base.w - 6);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 3, d->base.base.y + 3,
                                 "Owner   Group   Other     Octal:", 36);

    cd_draw_bits(d, scr, th);

    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 3, d->base.base.y + 6, "uid:gid: ", 9);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 12, d->base.base.y + 6,
                                 (const char *)d->owner_buf, 24);

    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 2, d->base.base.y + d->base.base.h - 2,
                                 ls->s[LS_chm_hint], d->base.base.w - 24);
}

static int cd_edit_owner_key(ChmodDialog *d, uint32_t key)
{
    if (key == KEY_BACKSPACE) {
        if (d->owner_len > 0) {
            d->owner_len--;
            d->owner_buf[d->owner_len] = '\0';
            return 1;
        }
        return 0;
    }
    if (key == ':' || (key >= '0' && key <= '9')) {
        if (d->owner_len < 30) {
            d->owner_buf[d->owner_len++] = (uint8_t)key;
            d->owner_buf[d->owner_len] = '\0';
            return 1;
        }
    }
    return 0;
}

static int ChmodDialog_on_key(Widget *self, void *event)
{
    ChmodDialog *d = (ChmodDialog *)self;
    App *app = (App *)(uintptr_t)d->base.app;
    uint32_t key = ((const Event *)event)->key;

    if (key == KEY_ENTER) { Dialog_on_confirm(&d->base); return 1; }
    if (key == KEY_ESC) { Dialog_on_cancel(&d->base); return 1; }

    int redraw = 0;
    if (key == KEY_LEFT) {
        if ((int)d->cursor > 0) { d->cursor--; redraw = 1; }
    } else if (key == KEY_RIGHT) {
        if (d->cursor < 8) { d->cursor++; redraw = 1; }
    } else if (key == ' ') {
        d->mode ^= 1U << (8 - d->cursor);
        redraw = 1;
    } else if (key == 'u' || key == 'g') {
        d->edit_owner ^= 1;
        redraw = 1;
    } else if (key >= '1' && key <= '9' && !d->edit_owner) {
        uint32_t idx = key - '1';
        d->mode ^= 1U << (8 - idx);
        d->cursor = idx;
        redraw = 1;
    } else if (d->edit_owner) {
        redraw = cd_edit_owner_key(d, key);
    }

    if (redraw) app->need_redraw = 1;
    return 1;
}

static int ChmodDialog_on_mouse(Widget *self, void *event)
{
    ChmodDialog *d = (ChmodDialog *)self;
    const Event *ev = event;

    if (ev->mouse_kind == MACT_PRESS && ev->mouse_btn == MOUSE_LEFT &&
        ev->mouse_y == d->base.base.y + 4) {
        for (int i = 0; i < 9; i++) {
            int xpos = d->base.base.x + 3 + i * 2 + (i / 3) * 2;
            if (ev->mouse_x == xpos) {
                d->cursor = (uint32_t)i;
                d->mode ^= 1U << (8 - i);
                ((App *)(uintptr_t)d->base.app)->need_redraw = 1;
                return 1;
            }
        }
    }
    return Dialog_on_mouse(self, event);
}
