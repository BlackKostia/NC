/* src/ui/pkg_dialog.c - PkgDialog (Inherits from Dialog): TUI Package Manager Dialog (Alt+K)
 * with Installed / Available tabs, verify / run / install / upgrade / remove actions
 * (freestanding C23; replaces src/ui/pkg_dialog.s, kept as tests/harness/pkg_dialog_reference.s). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_keys.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define PKG_MAX_UI 32

struct PkgDialog {
    Dialog base;
    PkgEntry *entries;
    int32_t count;
    int32_t cursor;
    int32_t scroll;
    int32_t tab;
};
_Static_assert(sizeof(PkgDialog) == sizeof(Dialog) + 24 && offsetof(PkgDialog, entries) == sizeof(Dialog) &&
               offsetof(PkgDialog, count) == sizeof(Dialog) + 8 && offsetof(PkgDialog, cursor) == sizeof(Dialog) + 12 &&
               offsetof(PkgDialog, scroll) == sizeof(Dialog) + 16 && offsetof(PkgDialog, tab) == sizeof(Dialog) + 20,
               "PkgDialog layout differs from the assembler");

static void PkgDialog_dtor(Object *self);
static void PkgDialog_layout(Widget *self, int x, int y, int w, int h);
static void PkgDialog_render(Widget *self, void *screen, void *theme);
static int PkgDialog_handle_key(Widget *self, void *event);
static int PkgDialog_handle_mouse(Widget *self, void *event);

DIALOG_VTBL(PkgDialog_vtbl, "PkgDialog", Dialog_vtbl, sizeof(PkgDialog),
            .base.base.dtor = PkgDialog_dtor, .base.layout = PkgDialog_layout,
            .base.render = PkgDialog_render, .base.on_key = PkgDialog_handle_key,
            .base.on_mouse = PkgDialog_handle_mouse);

static void pkd_refresh(PkgDialog *d)
{
    if (!d->entries) {
        d->count = 0;
        d->cursor = 0;
        return;
    }
    App *app = (App *)(uintptr_t)d->base.app;
    char **envp = (char **)(uintptr_t)app->envp;
    int cnt = 0;
    if (d->tab == 0) {
        cnt = pkg_list(envp, d->entries, PKG_MAX_UI);
    } else {
        PkgRegEntry *tmp = mem_alloc(PKG_MAX_UI * sizeof(PkgRegEntry));
        if (tmp) {
            cnt = pkg_registry_list(envp, tmp, PKG_MAX_UI);
            for (int i = 0; i < cnt; i++) {
                (void)str_copy(d->entries[i].name, tmp[i].name, sizeof d->entries[i].name);
                (void)str_copy(d->entries[i].version, tmp[i].version, sizeof d->entries[i].version);
                (void)str_copy(d->entries[i].kind, tmp[i].kind, sizeof d->entries[i].kind);
                (void)str_copy(d->entries[i].desc, tmp[i].desc, sizeof d->entries[i].desc);
            }
            mem_free(tmp);
        }
    }
    d->count = cnt;
    if (d->cursor >= cnt) d->cursor = cnt > 0 ? cnt - 1 : 0;
}

PkgDialog *PkgDialog_new(App *app)
{
    PkgDialog *d = DUOP_NEW(PkgDialog, PkgDialog_vtbl);
    if (!d) return nullptr;
    Dialog_init(&d->base, app, i18n_get()->s[LS_pkg_title], 0);
    d->entries = mem_alloc(PKG_MAX_UI * sizeof(PkgEntry));
    d->base.base.w = 70;
    d->base.base.h = 18;
    if (d->entries) pkd_refresh(d);
    PkgDialog_layout(&d->base.base, 0, 0, (int)app->term_w, (int)app->term_h);
    return d;
}

static void PkgDialog_dtor(Object *self)
{
    PkgDialog *d = (PkgDialog *)self;
    if (d->entries) {
        mem_free(d->entries);
        d->entries = nullptr;
    }
    Dialog_dtor((Widget *)self);
}

static void PkgDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 6;
    if (dw > 70) dw = 70;
    if (dw < 30) dw = 30;
    int dh = h - 4;
    if (dh > 18) dh = 18;
    if (dh < 8) dh = 8;
    self->w = dw;
    self->h = dh;
    self->x = (w - dw) >> 1;
    self->y = (h - dh) >> 1;
}

static void pkd_draw_rows(const PkgDialog *d, ScreenBuffer *scr, const Theme *th)
{
    const Widget *w = &d->base.base;
    int vis = w->h - 5;
    char line[160];
    for (int r = 0; r < vis; r++) {
        int idx = d->scroll + r;
        if (idx >= d->count) break;
        const PkgEntry *e = &d->entries[idx];
        (void)str_copy(line, e->name, sizeof line);
        (void)str_cat(line, "  ", sizeof line);
        (void)str_cat(line, e->version, sizeof line);
        (void)str_cat(line, "  ", sizeof line);
        (void)str_cat(line, e->kind, sizeof line);
        (void)str_cat(line, "  ", sizeof line);
        (void)str_cat(line, e->desc, sizeof line);
        if (idx == d->cursor) {
            ScreenBuffer_set_pen(scr, th->selected_fg, th->selected_bg, ATTR_NONE);
            ScreenBuffer_fill_rect(scr, w->x + 2, w->y + 2 + r, w->w - 4, 1, ' ');
        } else {
            ScreenBuffer_set_pen(scr, th->text, th->surface, ATTR_NONE);
        }
        (void)ScreenBuffer_draw_text(scr, w->x + 3, w->y + 2 + r, line, w->w - 6);
    }
}

static void PkgDialog_render(Widget *self, void *screen, void *theme)
{
    PkgDialog *d = (PkgDialog *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame(&d->base, scr, th, nullptr, nullptr);

    uint32_t fg0 = d->tab == 0 ? th->accent_fg : th->muted;
    uint32_t bg0 = d->tab == 0 ? th->accent : th->surface;
    ScreenBuffer_set_pen(scr, fg0, bg0, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, self->x + 3, self->y + 1, ls->s[LS_pkg_tab_inst], 18);

    uint32_t fg1 = d->tab == 1 ? th->accent_fg : th->muted;
    uint32_t bg1 = d->tab == 1 ? th->accent : th->surface;
    ScreenBuffer_set_pen(scr, fg1, bg1, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, self->x + 22, self->y + 1, ls->s[LS_pkg_tab_avail], 18);

    if (d->count == 0) {
        ScreenBuffer_set_pen(scr, th->text, th->surface, ATTR_NONE);
        (void)ScreenBuffer_draw_text(scr, self->x + 3, self->y + 3, ls->s[LS_pkg_empty], self->w - 6);
    } else {
        pkd_draw_rows(d, scr, th);
    }

    ScreenBuffer_set_pen(scr, th->muted, th->surface, ATTR_NONE);
    (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y + self->h - 2, ls->s[LS_pkg_hint], self->w - 4);
}

static int pkd_install_avail(PkgDialog *d)
{
    App *app = (App *)(uintptr_t)d->base.app;
    char **envp = (char **)(uintptr_t)app->envp;
    PkgRegEntry reg;
    if (pkg_registry_find(envp, d->entries[d->cursor].name, &reg) != 0) return -1;
    return pkg_install_archive(envp, reg.url, reg.sha256);
}

/* Returns 0 when an action was found and executed (dialog is already closed & freed!), else -1. */
static int pkd_run_selected(PkgDialog *d)
{
    App *app = (App *)(uintptr_t)d->base.app;
    char **envp = (char **)(uintptr_t)app->envp;
    PkgAction act;
    if (pkg_action_find(envp, d->entries[d->cursor].name, &act) != 0) return -1;
    App_close_dialog(app, 0);
    App_run_pkg_action(app, &act);
    return 0;
}

static int pkd_do_verify(PkgDialog *d)
{
    App *app = (App *)(uintptr_t)d->base.app;
    char **envp = (char **)(uintptr_t)app->envp;
    if (pkg_verify(envp, d->entries[d->cursor].name) != 0) return -1;
    App_set_status(app, i18n_get()->s[LS_pkg_verified], MSG_OK);
    return 0;
}

/* Returns 1 if dialog was closed (caller must NOT touch d), 0 if ok, -1 on error. */
static int pkd_do_enter(PkgDialog *d)
{
    if (d->tab == 0) {
        if (pkd_run_selected(d) == 0) return 1;
        return pkd_do_verify(d);
    }
    if (pkd_install_avail(d) != 0) return -1;
    d->tab = 0;
    pkd_refresh(d);
    App_set_status((App *)(uintptr_t)d->base.app, i18n_get()->s[LS_pkg_installed], MSG_OK);
    return 0;
}

static int pkd_do_upg(PkgDialog *d)
{
    App *app = (App *)(uintptr_t)d->base.app;
    char **envp = (char **)(uintptr_t)app->envp;
    return d->tab == 0 ? pkg_registry_upgrade(envp) : pkg_registry_update(envp);
}

static void pkd_open_install_prompt(PkgDialog *d)
{
    App *app = (App *)(uintptr_t)d->base.app;
    App_close_dialog(app, 0);
    const LangStrings *ls = i18n_get();
    InputDialog *id = InputDialog_new(app, ls->s[LS_pkg_title], ls->s[LS_pkg_install_prompt], nullptr, 25);
    if (!id) return;
    app->active_dialog = (uint64_t)(uintptr_t)id;
    app->need_redraw = 1;
}

static int pkd_key_action(PkgDialog *d, uint32_t key)
{
    App *app = (App *)(uintptr_t)d->base.app;
    const LangStrings *ls = i18n_get();
    if (key == 'v') {
        if (d->count <= 0) return 1;
        if (pkd_do_verify(d) != 0) App_set_status(app, ls->s[LS_pkg_err], MSG_ERR);
        app->need_redraw = 1;
        return 1;
    }
    if (key == KEY_ENTER) {
        if (d->count <= 0) return 1;
        int r = pkd_do_enter(d);
        if (r == 1) return 1;
        if (r != 0) App_set_status(app, ls->s[LS_pkg_err], MSG_ERR);
        app->need_redraw = 1;
        return 1;
    }
    if (key == 'r') {
        if (d->count <= 0) return 1;
        if (pkd_run_selected(d) != 0) {
            App_set_status(app, ls->s[LS_pkg_err], MSG_ERR);
            app->need_redraw = 1;
        }
        return 1;
    }
    if (key == 'u') {
        if (pkd_do_upg(d) == 0) {
            pkd_refresh(d);
            App_set_status(app, ls->s[LS_pkg_verified], MSG_OK);
        } else {
            App_set_status(app, ls->s[LS_pkg_err], MSG_ERR);
        }
        app->need_redraw = 1;
        return 1;
    }
    if (key == 'd' || key == KEY_DELETE) {
        if (d->count <= 0) return 1;
        if (pkg_remove((char **)(uintptr_t)app->envp, d->entries[d->cursor].name) == 0) {
            pkd_refresh(d);
            App_set_status(app, ls->s[LS_pkg_removed], MSG_OK);
        } else {
            App_set_status(app, ls->s[LS_pkg_err], MSG_ERR);
        }
        app->need_redraw = 1;
        return 1;
    }
    return 0;
}

static int PkgDialog_handle_key(Widget *self, void *event)
{
    PkgDialog *d = (PkgDialog *)self;
    App *app = (App *)(uintptr_t)d->base.app;
    uint32_t key = ((const Event *)event)->key;
    switch (key) {
    case KEY_ESC: case 'q':
        App_close_dialog(app, 0);
        return 1;
    case KEY_UP: case 'k':
        if (d->cursor > 0) { d->cursor--; app->need_redraw = 1; }
        return 1;
    case KEY_DOWN: case 'j':
        if (d->cursor + 1 < d->count) { d->cursor++; app->need_redraw = 1; }
        return 1;
    case KEY_TAB:
        d->tab ^= 1;
        d->cursor = 0;
        d->scroll = 0;
        pkd_refresh(d);
        app->need_redraw = 1;
        return 1;
    case 'i':
        pkd_open_install_prompt(d);
        return 1;
    default:
        return pkd_key_action(d, key);
    }
}

static int PkgDialog_handle_mouse(Widget *self, void *event)
{
    PkgDialog *d = (PkgDialog *)self;
    const Event *ev = event;
    if (ev->mouse_btn == MOUSE_RIGHT) App_close_dialog((App *)(uintptr_t)d->base.app, 0);
    return 1;
}

int App_cmd_packages(App *app)
{
    PkgDialog *d = PkgDialog_new(app);
    if (!d) return 0;
    app->active_dialog = (uint64_t)(uintptr_t)d;
    app->need_redraw = 1;
    return 1;
}

void App_pkg_install_confirm(App *app, InputDialog *dlg)
{
    if (!dlg->buf[0]) return;
    const LangStrings *ls = i18n_get();
    if (pkg_install_archive((char **)(uintptr_t)app->envp, (const char *)dlg->buf, nullptr) == 0)
        App_set_status(app, ls->s[LS_pkg_installed], MSG_OK);
    else
        App_set_status(app, ls->s[LS_pkg_err], MSG_ERR);
}
