/* src/ui/bookmark_dlg.c - Bookmarks (Hotlist) & Frecency (z) Dialog
 * (freestanding C23; replaces src/ui/bookmark_dlg{,_input}.s, kept as
 * tests/harness/bookmark_dlg{,_input}_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void BookmarkDialog_layout(Widget *self, int x, int y, int w, int h);
static void BookmarkDialog_render(Widget *self, void *screen, void *theme);
static int BookmarkDialog_handle_key(Widget *self, void *event);
static int BookmarkDialog_handle_mouse(Widget *self, void *event);

DIALOG_VTBL(BookmarkDialog_vtbl, "BookmarkDialog", Dialog_vtbl, sizeof(BookmarkDialog),
            .base.layout = BookmarkDialog_layout, .base.render = BookmarkDialog_render,
            .base.on_key = BookmarkDialog_handle_key, .base.on_mouse = BookmarkDialog_handle_mouse);

static void bmd_refresh_matches(BookmarkDialog *d)
{
    if (d->mode == 1)
        d->match_cnt = (uint32_t)nav_frecency_match((const char *)d->filter, (int *)d->matches, 128);
    else
        d->match_cnt = (uint32_t)nav_bookmarks_count();

    if (d->match_cnt == 0) {
        d->cursor = 0;
        d->scroll = 0;
    } else if ((int)d->cursor >= (int)d->match_cnt) {
        d->cursor = d->match_cnt - 1;
    }
}

BookmarkDialog *BookmarkDialog_new(App *app, int mode)
{
    BookmarkDialog *d = DUOP_NEW(BookmarkDialog, BookmarkDialog_vtbl);
    if (!d) return nullptr;

    const LangStrings *ls = i18n_get();
    const char *title = mode ? ls->s[LS_dlg_title_frecency] : ls->s[LS_dlg_title_bookmarks];
    uint32_t tag = mode ? OP_FRECENCY : OP_BOOKMARKS;
    Dialog_init(&d->base, app, title, tag);

    d->mode = (uint32_t)mode;
    d->base.base.w = 68;
    d->base.base.h = 18;
    bmd_refresh_matches(d);

    BookmarkDialog_layout(&d->base.base, 0, 0, (int)app->term_w, (int)app->term_h);
    return d;
}

static void BookmarkDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 4;
    if (dw > 68) dw = 68;
    if (dw < 36) dw = 36;

    int dh = 18;
    if (dh > h - 2) dh = h - 2;

    self->w = dw;
    self->h = dh;
    self->x = (w - dw) >> 1;
    self->y = (h - dh) >> 1;
}

const char *BookmarkDialog_get_selected(BookmarkDialog *self)
{
    int cur = (int)self->cursor;
    if (cur < 0 || cur >= (int)self->match_cnt) return nullptr;
    if (self->mode == 1) return nav_frecency_get(((const int *)self->matches)[cur]);
    return nav_bookmarks_get(cur);
}

static void bmd_render_rows(BookmarkDialog *d, ScreenBuffer *scr, const Theme *th, int y0, int vis)
{
    if ((int)d->cursor < (int)d->scroll) d->scroll = d->cursor;
    if ((int)d->cursor >= (int)d->scroll + vis)
        d->scroll = (uint32_t)((int)d->cursor - vis + 1);

    for (int r = 0; r < vis; r++) {
        int idx = (int)d->scroll + r;
        if (idx >= (int)d->match_cnt) break;

        if (idx == (int)d->cursor)
            ScreenBuffer_set_pen(scr, th->accent_fg, th->accent, ATTR_BOLD);
        else
            ScreenBuffer_set_pen(scr, th->text, th->surface, ATTR_NONE);

        const char *s = d->mode == 1 ? nav_frecency_get(((const int *)d->matches)[idx])
                                     : nav_bookmarks_get(idx);
        if (s)
            (void)ScreenBuffer_draw_text(scr, d->base.base.x + 2, y0 + r, s, 64);
    }
}

static void BookmarkDialog_render(Widget *self, void *screen, void *theme)
{
    (void)theme;
    BookmarkDialog *d = (BookmarkDialog *)self;
    ScreenBuffer *scr = screen;
    const App *app = (const App *)(uintptr_t)d->base.app;
    const Theme *th = (const Theme *)(uintptr_t)app->theme;

    Dialog_draw_frame(&d->base, scr, th, nullptr, nullptr);

    int y0 = d->base.base.y + 2;
    int vis = 13;
    if (d->mode == 1) {
        ScreenBuffer_set_pen(scr, th->accent, th->surface_alt, ATTR_BOLD);
        (void)ScreenBuffer_draw_text(scr, d->base.base.x + 2, y0, "> ", 64);
        (void)ScreenBuffer_draw_text(scr, d->base.base.x + 4, y0, (const char *)d->filter, 60);
        y0++;
        vis--;
    }

    if (d->match_cnt == 0) {
        ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
        (void)ScreenBuffer_draw_text(scr, d->base.base.x + 3, y0, "(empty)", 40);
    } else {
        bmd_render_rows(d, scr, th, y0, vis);
    }

    const LangStrings *ls = i18n_get();
    const char *hint = d->mode == 1 ? ls->s[LS_fre_hint] : ls->s[LS_bm_hint];
    ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 2,
                                 d->base.base.y + d->base.base.h - 2, hint, 64);
}

static int bmd_frecency_key(BookmarkDialog *d, uint32_t key)
{
    if (key == KEY_BACKSPACE) {
        if (d->filter_len == 0) return 0;
        d->filter[--d->filter_len] = '\0';
        d->cursor = 0;
        bmd_refresh_matches(d);
        return 1;
    }
    if (key < 32 || key > 126 || d->filter_len >= 62) return 0;
    d->filter[d->filter_len++] = (uint8_t)key;
    d->filter[d->filter_len] = '\0';
    d->cursor = 0;
    bmd_refresh_matches(d);
    return 1;
}

static int BookmarkDialog_handle_key(Widget *self, void *event)
{
    BookmarkDialog *d = (BookmarkDialog *)self;
    App *app = (App *)(uintptr_t)d->base.app;
    const Event *ev = event;
    uint32_t key = ev->key;

    if (key == KEY_ESC) {
        Dialog_on_cancel(&d->base);
    } else if (key == KEY_ENTER) {
        Dialog_on_confirm(&d->base);
    } else if (key == KEY_UP) {
        if ((int)d->cursor > 0) d->cursor--;
    } else if (key == KEY_DOWN) {
        if ((int)d->cursor + 1 < (int)d->match_cnt) d->cursor++;
    } else if (d->mode == 1) {
        if (!bmd_frecency_key(d, key)) return 0;
    } else {
        switch (ev->lat) {
        case 'k': if ((int)d->cursor > 0) d->cursor--; break;
        case 'j': if ((int)d->cursor + 1 < (int)d->match_cnt) d->cursor++; break;
        case 'a': {
            const FilePane *fp = (const FilePane *)(uintptr_t)app->active_pane;
            const DirModel *dm = (const DirModel *)(uintptr_t)fp->model;
            (void)nav_bookmarks_add((const char *)dm->path);
            bmd_refresh_matches(d);
            break;
        }
        case 'd':
            if ((int)d->match_cnt > 0) {
                nav_bookmarks_remove((int)d->cursor);
                bmd_refresh_matches(d);
            }
            break;
        default: return 0;
        }
    }
    app->need_redraw = 1;
    return 1;
}

static int BookmarkDialog_handle_mouse(Widget *self, void *event)
{
    BookmarkDialog *d = (BookmarkDialog *)self;
    const Event *ev = event;
    if (ev->mouse_kind != MACT_PRESS) return 0;

    int base_y = d->base.base.y + 2 + (d->mode == 1 ? 1 : 0);
    int row = ev->mouse_y - base_y;
    if (row < 0) return 0;

    int idx = row + (int)d->scroll;
    if (idx >= (int)d->match_cnt) return 0;

    d->cursor = (uint32_t)idx;
    Dialog_on_confirm(&d->base);
    return 1;
}
