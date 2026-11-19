/* src/ui/popup_menu.c - Context popup menu dialog and cross-pane mouse drag-and-drop
 * (freestanding C23; replaces src/ui/popup_menu.s,
 * kept as tests/harness/popup_menu_reference.s). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

struct PopupMenuDialog {
    Dialog base;
    uint32_t cursor;
    uint32_t pad;
};

static void PopupMenu_layout(Widget *self, int x, int y, int w, int h);
static void PopupMenu_render(Widget *self, void *screen, void *theme);
static int PopupMenu_on_key(Widget *self, void *event);
static int PopupMenu_on_mouse(Widget *self, void *event);

static const uint16_t popup_slots[5] = {
    LS_ctx_view, LS_ctx_copy, LS_ctx_move, LS_ctx_copy_path, LS_ctx_delete,
};

DIALOG_VTBL(PopupMenuDialog_vtbl, "PopupMenuDialog", Dialog_vtbl, sizeof(PopupMenuDialog),
            .base.layout = PopupMenu_layout, .base.render = PopupMenu_render,
            .base.on_key = PopupMenu_on_key, .base.on_mouse = PopupMenu_on_mouse);

static int32_t g_dnd_active;
static FilePane *g_dnd_src_pane;

PopupMenuDialog *PopupMenu_new(App *app, int x, int y)
{
    PopupMenuDialog *d = DUOP_NEW(PopupMenuDialog, PopupMenuDialog_vtbl);
    if (!d) return nullptr;
    d->base.app = (uint64_t)(uintptr_t)app;
    d->cursor = 0;

    FilePane *ap = (FilePane *)(uintptr_t)app->active_pane;
    FileEntry *e = FilePane_get_selected_entry(ap);
    int is_dir = 0;
    const char *name = nullptr;
    if (e) {
        is_dir = (e->flags & FE_IS_DIR) ? 1 : 0;
        name = DirModel_entry_name((DirModel *)(uintptr_t)ap->model, e);
    }
    int n = pkg_popup_refresh((char **)(uintptr_t)app->envp, is_dir, name);
    d->base.base.h = n + 7;
    d->base.base.w = (n == 0) ? 24 : 30;
    d->base.base.x = x;
    d->base.base.y = y;
    PopupMenu_layout(&d->base.base, 0, 0, 0, 0);
    app->active_dialog = (uint64_t)(uintptr_t)d;
    app->need_redraw = 1;
    return d;
}

static void PopupMenu_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x; (void)y; (void)w; (void)h;
    const App *app = (const App *)(uintptr_t)((Dialog *)self)->app;
    const ScreenBuffer *scr = (const ScreenBuffer *)(uintptr_t)app->screen;
    int max_x = scr->width - self->w;
    int max_y = scr->height - self->h;
    if (self->x > max_x) self->x = max_x;
    if (self->x < 0) self->x = 0;
    if (self->y > max_y) self->y = max_y;
    if (self->y < 0) self->y = 0;
}

static void PopupMenu_render(Widget *self, void *screen, void *theme)
{
    PopupMenuDialog *d = (PopupMenuDialog *)self;
    ScreenBuffer *scr = (ScreenBuffer *)screen;
    const Theme *th = (const Theme *)theme;

    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);
    ScreenBuffer_fill_rect(scr, self->x, self->y, self->w, self->h, ' ');
    ScreenBuffer_set_pen(scr, th->dialog_border, th->dialog_bg, ATTR_NONE);
    ScreenBuffer_draw_box(scr, self->x, self->y, self->w, self->h, 1);

    int tot = pkg_popup_count() + 5;
    for (int i = 0; i < tot; i++) {
        int row_y = self->y + i + 1;
        bool sel = (uint32_t)i == d->cursor;
        ScreenBuffer_set_pen(scr, sel ? th->accent_fg : th->text,
                             sel ? th->cursor_active_bg : th->dialog_bg, ATTR_NONE);
        ScreenBuffer_fill_rect(scr, self->x + 1, row_y, self->w - 2, 1, ' ');
        const char *lbl = i < 5 ? i18n_get()->s[popup_slots[i]] : pkg_popup_label(i - 5);
        (void)ScreenBuffer_draw_text(scr, self->x + 2, row_y, lbl, self->w - 4);
    }
}

static void popup_copy_cur_path(App *app)
{
    FilePane *ap = (FilePane *)(uintptr_t)app->active_pane;
    DirModel *m = (DirModel *)(uintptr_t)ap->model;
    if ((uint64_t)ap->cursor >= m->count) return;
    const char *name = m->name_pool + m->entries[m->order[ap->cursor]].name_off;
    char *buf = mem_alloc(PATH_MAX);
    if (!buf) return;
    if (path_join(buf, m->path, name, PATH_MAX) >= 0) {
        osc52_copy_text(buf);
        App_set_status(app, i18n_get()->s[LS_msg_copied_path], MSG_INFO);
        app->need_redraw = 1;
    }
    mem_free(buf);
}

static void popup_exec_item(PopupMenuDialog *d)
{
    App *app = (App *)(uintptr_t)d->base.app;
    int cur = (int32_t)d->cursor;
    App_close_dialog(app, DLG_CANCEL);
    switch (cur) {
    case 0: App_cmd_view(app); break;
    case 1: App_cmd_copy(app); break;
    case 2: App_cmd_move(app); break;
    case 3: popup_copy_cur_path(app); break;
    case 4: App_cmd_delete(app); break;
    default:
        if (cur >= 5) {
            PkgAction *a = pkg_popup_get(cur - 5);
            if (a) App_run_pkg_action(app, a);
        }
        break;
    }
}

static int PopupMenu_on_key(Widget *self, void *event)
{
    PopupMenuDialog *d = (PopupMenuDialog *)self;
    const Event *ev = (const Event *)event;
    App *app = (App *)(uintptr_t)d->base.app;

    if (ev->key == KEY_ESC) { App_close_dialog(app, DLG_CANCEL); return 1; }
    if (ev->key == KEY_UP) {
        uint32_t tot = (uint32_t)(pkg_popup_count() + 5);
        d->cursor = (d->cursor + tot - 1u) % tot;
        app->need_redraw = 1;
        return 1;
    }
    if (ev->key == KEY_DOWN) {
        uint32_t tot = (uint32_t)(pkg_popup_count() + 5);
        d->cursor = (d->cursor + 1u) % tot;
        app->need_redraw = 1;
        return 1;
    }
    if (ev->key == KEY_ENTER) { popup_exec_item(d); return 1; }
    return 0;
}

static int PopupMenu_on_mouse(Widget *self, void *event)
{
    PopupMenuDialog *d = (PopupMenuDialog *)self;
    const Event *ev = (const Event *)event;
    if (ev->mouse_kind != MACT_PRESS || ev->mouse_btn != MOUSE_LEFT) return 1;

    int mx = ev->mouse_x, my = ev->mouse_y;
    int tot = pkg_popup_count() + 5;
    if (mx >= self->x && mx < self->x + self->w && my >= self->y + 1 && my < self->y + 1 + tot) {
        d->cursor = (uint32_t)(my - self->y - 1);
        popup_exec_item(d);
    } else {
        App_close_dialog((App *)(uintptr_t)d->base.app, DLG_CANCEL);
    }
    return 1;
}

static int pane_contains_xy(const FilePane *p, int x, int y)
{
    return x >= p->base.x && x < p->base.x + p->base.w - 1 &&
           y >= p->base.y + 3 && y < p->base.y + p->base.h - 2;
}

static FilePane *pane_at_xy(const App *app, int x, int y)
{
    FilePane *lp = (FilePane *)(uintptr_t)app->left_pane;
    if (pane_contains_xy(lp, x, y)) return lp;
    if (app->right_mode == RIGHT_MODE_PREVIEW) return nullptr;
    FilePane *rp = (FilePane *)(uintptr_t)app->right_pane;
    return pane_contains_xy(rp, x, y) ? rp : nullptr;
}

static void focus_pane(App *app, FilePane *target)
{
    FilePane *lp = (FilePane *)(uintptr_t)app->left_pane;
    FilePane *rp = (FilePane *)(uintptr_t)app->right_pane;
    WIDGET_CALL(lp, on_focus, lp == target ? 1 : 0);
    WIDGET_CALL(rp, on_focus, rp == target ? 1 : 0);
    app->active_pane = (uint64_t)(uintptr_t)target;
}

int pane_mouse_ext(App *app, Event *evt)
{
    FilePane *p = pane_at_xy(app, evt->mouse_x, evt->mouse_y);
    if (evt->mouse_kind == MACT_PRESS) {
        if (evt->mouse_btn == MOUSE_RIGHT) {
            if (!p) return 0;
            focus_pane(app, p);
            uint64_t idx = (uint64_t)(uint32_t)(evt->mouse_y - p->base.y - 3) + p->scroll;
            const DirModel *m = (const DirModel *)(uintptr_t)p->model;
            if (m->count > 0) {
                uint64_t max = m->count - 1;
                if (idx > max) idx = max;
                p->cursor = (uint32_t)idx;
            }
            (void)PopupMenu_new(app, evt->mouse_x, evt->mouse_y);
            return 1;
        }
        if (evt->mouse_btn == MOUSE_LEFT && p) {
            g_dnd_src_pane = p;
            g_dnd_active = 1;
        }
        return 0;
    }
    if (evt->mouse_kind == MACT_RELEASE && g_dnd_active) {
        g_dnd_active = 0;
        FilePane *src = g_dnd_src_pane;
        if (!p || p == src) return 0;
        focus_pane(app, src);
        App_cmd_copy(app);
        return 1;
    }
    return 0;
}
