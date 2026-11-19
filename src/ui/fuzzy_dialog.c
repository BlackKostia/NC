/* src/ui/fuzzy_dialog.c - Command Palette (Ctrl+K) & Fuzzy Finder (Ctrl+P)
 * (freestanding C23; replaces src/ui/fuzzy_dialog.s, kept as tests/harness/fuzzy_dialog_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

typedef struct { uint64_t cp, len; } Utf8Dec;
Utf8Dec utf8_decode(const char *s);

enum {
    FUZ_MAX_ITEMS = 1024,
    FUZ_POOL_CAP  = 65536,
    FUZ_VIS_ROWS  = 14,
    FUZ_DLG_W     = 74,
    FUZ_DLG_H     = 21,
};

typedef struct FuzMatch {
    uint32_t item_idx;
    int32_t  score;
    uint64_t mask;
} FuzMatch;

static const struct { uint16_t act; uint16_t slot; } fuz_palette_cmds[19] = {
    {ACT_THEME, LS_pal_theme},     {ACT_LANG, LS_pal_lang},       {ACT_PREVIEW, LS_pal_preview},
    {ACT_HIDDEN, LS_pal_hidden},   {ACT_HELP, LS_pal_help},       {ACT_RENAME, LS_pal_rename},
    {ACT_VIEW, LS_pal_view},       {ACT_EDIT, LS_pal_edit},       {ACT_COPY, LS_pal_copy},
    {ACT_MOVE, LS_pal_move},       {ACT_MKDIR, LS_pal_mkdir},     {ACT_DELETE, LS_pal_delete},
    {ACT_NEWFILE, LS_pal_newfile}, {ACT_FILTER, LS_pal_filter},   {ACT_GOTO, LS_pal_goto},
    {ACT_REFRESH, LS_pal_refresh}, {ACT_USERMENU, LS_pal_usermenu}, {ACT_SHELL, LS_pal_shell},
    {ACT_QUIT, LS_pal_quit},
};

static void FuzzyDialog_dtor(Object *self);
static void FuzzyDialog_render(Widget *self, void *screen, void *theme);
static int FuzzyDialog_handle_key(Widget *self, void *event);

DIALOG_VTBL(FuzzyDialog_vtbl, "FuzzyDialog", Dialog_vtbl, sizeof(FuzzyDialog),
            .base.base.dtor = FuzzyDialog_dtor,
            .base.render = FuzzyDialog_render,
            .base.on_key = FuzzyDialog_handle_key);

static void fuz_refilter(FuzzyDialog *d)
{
    d->match_cnt = 0;
    d->cursor = 0;
    d->scroll = 0;
    const FuzzyItem *items = (const FuzzyItem *)(uintptr_t)d->items_ptr;
    FuzMatch *matches = (FuzMatch *)(uintptr_t)d->matches_ptr;
    if (!items || !matches) return;

    for (uint32_t i = 0; i < d->total_cnt; i++) {
        uint64_t mask = 0;
        int sc = fuzzy_score((const char *)d->query_buf, items[i].path, &mask);
        if (sc < 0) continue;
        if (d->match_cnt >= FUZ_MAX_ITEMS) break;
        matches[d->match_cnt++] = (FuzMatch){i, sc, mask};
    }

    if (d->query_buf[0] == '\0') return;
    for (int i = 1; i < (int)d->match_cnt; i++) {
        FuzMatch key = matches[i];
        int j = i - 1;
        while (j >= 0 && matches[j].score < key.score) {
            matches[j + 1] = matches[j];
            j--;
        }
        matches[j + 1] = key;
    }
}

static void fuz_populate_palette(FuzzyDialog *d, App *app)
{
    const LangStrings *ls = i18n_get();
    FuzzyItem *items = (FuzzyItem *)(uintptr_t)d->items_ptr;
    for (uint32_t i = 0; i < 19; i++) {
        items[i].path = ls->s[fuz_palette_cmds[i].slot];
        items[i].is_dir = 0;
        items[i].pad = (int32_t)fuz_palette_cmds[i].act;
    }
    d->total_cnt = 19;

    (void)pkg_menu_refresh((char **)(uintptr_t)app->envp);
    int pc = pkg_menu_count();
    for (int i = 0; i < pc && d->total_cnt < FUZ_MAX_ITEMS; i++) {
        PkgAction *act = pkg_menu_get(i);
        if (!act) break;
        items[d->total_cnt].path = act->menu;
        items[d->total_cnt].is_dir = 0;
        items[d->total_cnt].pad = (int32_t)(0x1000 + i);
        d->total_cnt++;
    }
}

FuzzyDialog *FuzzyDialog_new(App *app, int mode, const char *base_path)
{
    FuzzyDialog *d = DUOP_NEW(FuzzyDialog, FuzzyDialog_vtbl);
    if (!d) return nullptr;

    d->mode = (uint32_t)mode;
    const LangStrings *ls = i18n_get();
    const char *title = mode ? ls->s[LS_dlg_title_fuzzy] : ls->s[LS_dlg_title_palette];
    Dialog_init(&d->base, app, title, mode ? OP_FUZZY : OP_PALETTE);
    d->base.base.w = FUZ_DLG_W;
    d->base.base.h = FUZ_DLG_H;
    Dialog_layout(&d->base.base, 0, 0, (int)app->term_w, (int)app->term_h);

    void *items = mem_alloc(FUZ_MAX_ITEMS * sizeof(FuzzyItem));
    void *matches = mem_alloc(FUZ_MAX_ITEMS * sizeof(FuzMatch));
    d->items_ptr = (uintptr_t)items;
    d->matches_ptr = (uintptr_t)matches;
    if (!items || !matches) {
        DUOP_DELETE(d);
        return nullptr;
    }

    if (mode == 0) {
        fuz_populate_palette(d, app);
    } else {
        (void)str_copy((char *)d->base_path, base_path, sizeof d->base_path);
        void *pool = mem_alloc(FUZ_POOL_CAP);
        d->pool_ptr = (uintptr_t)pool;
        if (pool) {
            d->total_cnt = (uint32_t)dir_fuzzy_collect(
                base_path, pool, FUZ_POOL_CAP, items, FUZ_MAX_ITEMS);
        }
    }

    fuz_refilter(d);
    return d;
}

static void FuzzyDialog_dtor(Object *self)
{
    FuzzyDialog *d = (FuzzyDialog *)self;
    if (d->items_ptr) mem_free((void *)(uintptr_t)d->items_ptr);
    if (d->pool_ptr) mem_free((void *)(uintptr_t)d->pool_ptr);
    if (d->matches_ptr) mem_free((void *)(uintptr_t)d->matches_ptr);
    Dialog_dtor(&d->base.base);
}

static void fuz_draw_row(const FuzzyDialog *d, ScreenBuffer *scr, const Theme *th, int row)
{
    uint32_t idx = d->scroll + (uint32_t)row;
    const FuzMatch *m = &((const FuzMatch *)(uintptr_t)d->matches_ptr)[idx];
    const FuzzyItem *it = &((const FuzzyItem *)(uintptr_t)d->items_ptr)[m->item_idx];
    int selected = (idx == d->cursor);
    int y = d->base.base.y + 4 + row;

    uint32_t bg = selected ? th->cursor_active_bg : th->dialog_bg;
    ScreenBuffer_set_pen(scr, th->text, bg, ATTR_NONE);
    ScreenBuffer_fill_rect(scr, d->base.base.x + 2, y, FUZ_DLG_W - 4, 1, ' ');

    const char *p = it->path;
    uint64_t mask = m->mask;
    int x = d->base.base.x + 3;
    int xmax = x + FUZ_DLG_W - 6;
    for (int ch_idx = 0; x < xmax && *p != '\0'; ch_idx++, x++) {
        Utf8Dec dec = utf8_decode(p);
        p += dec.len ? dec.len : 1;
        uint32_t fg = th->text, cbg = th->dialog_bg, attr = ATTR_NONE;
        if (selected) {
            fg = th->accent_fg;
            cbg = th->cursor_active_bg;
        }
        if (ch_idx < 64 && (mask & (1ULL << ch_idx))) {
            fg = th->accent;
            attr = ATTR_BOLD;
        }
        ScreenBuffer_set_pen(scr, fg, cbg, attr);
        ScreenBuffer_set_cell_pen(scr, x, y, (uint32_t)dec.cp);
    }
}

static void FuzzyDialog_render(Widget *self, void *screen, void *theme)
{
    FuzzyDialog *d = (FuzzyDialog *)self;
    ScreenBuffer *scr = screen;
    const App *app = (const App *)(uintptr_t)d->base.app;
    const Theme *th = theme ? (const Theme *)theme : theme_get((int)app->theme_idx);

    Dialog_draw_frame(&d->base, scr, th, nullptr, nullptr);

    int x = d->base.base.x, y = d->base.base.y;
    ScreenBuffer_set_pen(scr, th->text, th->surface_alt, ATTR_NONE);
    ScreenBuffer_fill_rect(scr, x + 2, y + 2, FUZ_DLG_W - 4, 1, ' ');
    ScreenBuffer_set_pen(scr, th->accent, th->surface_alt, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, x + 3, y + 2, "> ", 2);
    ScreenBuffer_set_pen(scr, th->text, th->surface_alt, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, x + 5, y + 2, (const char *)d->query_buf, FUZ_DLG_W - 8);

    for (int row = 0; row < FUZ_VIS_ROWS; row++) {
        if (d->scroll + (uint32_t)row >= d->match_cnt) break;
        fuz_draw_row(d, scr, th, row);
    }

    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, x + 2, y + FUZ_DLG_H - 2,
                                 i18n_get()->s[LS_fuz_hint], FUZ_DLG_W - 4);
}

static int FuzzyDialog_handle_key(Widget *self, void *event)
{
    FuzzyDialog *d = (FuzzyDialog *)self;
    uint32_t key = ((const Event *)event)->key;

    if (key == KEY_ESC) { Dialog_on_cancel(&d->base); return 1; }
    if (key == KEY_ENTER) { Dialog_on_confirm(&d->base); return 1; }

    if (key == KEY_UP) {
        if ((int)d->cursor > 0) {
            int c = (int)d->cursor - 1;
            d->cursor = (uint32_t)c;
            if (c < (int)d->scroll) d->scroll = (uint32_t)c;
        }
    } else if (key == KEY_DOWN) {
        int c = (int)d->cursor + 1;
        if (c < (int)d->match_cnt) {
            d->cursor = (uint32_t)c;
            if (c >= (int)d->scroll + FUZ_VIS_ROWS)
                d->scroll = (uint32_t)(c - (FUZ_VIS_ROWS - 1));
        }
    } else if (key == KEY_BACKSPACE) {
        if (d->query_len > 0) {
            d->query_buf[--d->query_len] = '\0';
            fuz_refilter(d);
        }
    } else if (key >= 32 && key <= 126) {
        if (d->query_len < 126) {
            d->query_buf[d->query_len++] = (uint8_t)key;
            d->query_buf[d->query_len] = '\0';
            fuz_refilter(d);
        }
    } else {
        return Dialog_on_key(self, event);
    }

    ((App *)(uintptr_t)d->base.app)->need_redraw = 1;
    return 1;
}

uintptr_t FuzzyDialog_get_selected(FuzzyDialog *self)
{
    if ((int)self->match_cnt <= 0 || self->cursor >= self->match_cnt) return 0;
    const FuzMatch *m = &((const FuzMatch *)(uintptr_t)self->matches_ptr)[self->cursor];
    const FuzzyItem *it = &((const FuzzyItem *)(uintptr_t)self->items_ptr)[m->item_idx];
    if (self->mode == 0) return (uintptr_t)(uint32_t)it->pad;
    return (uintptr_t)it->path;
}
