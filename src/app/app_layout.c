/* src/app/app_layout.c - App layout, composite render, status, pane focus & preview dispatch
 * (freestanding C23; replaces src/app/app_layout.s, kept as tests/harness/app_layout_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_preview.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"

#define PREVIEW_DEBOUNCE_MS 25

void App_layout(App *app)
{
    int w = (int)app->term_w;
    int h = (int)app->term_h;
    (void)ScreenBuffer_resize((ScreenBuffer *)(uintptr_t)app->screen, w, h);

    int main_h = h - 3 - term_height(h - 3);
    if (main_h < 6) main_h = 6;
    int left_w = (int)((uint32_t)w >> 1);
    int right_w = w - left_w;

    WIDGET_CALL((Widget *)(uintptr_t)app->header_bar, layout, 0, 0, w, 1);
    WIDGET_CALL((Widget *)(uintptr_t)app->left_pane, layout, 0, 1, left_w, main_h);
    WIDGET_CALL((Widget *)(uintptr_t)app->right_pane, layout, left_w, 1, right_w, main_h);
    WIDGET_CALL((Widget *)(uintptr_t)app->preview_pane, layout, left_w, 1, right_w, main_h);
    WIDGET_CALL((Widget *)(uintptr_t)app->status_bar, layout, 0, h - 2, w, 1);
    WIDGET_CALL((Widget *)(uintptr_t)app->func_bar, layout, 0, h - 1, w, 1);
    if (app->active_dialog)
        WIDGET_CALL((Widget *)(uintptr_t)app->active_dialog, layout, 0, 0, w, h);
}

void App_render(App *app)
{
    ScreenBuffer *scr = (ScreenBuffer *)(uintptr_t)app->screen;
    Theme *th = (Theme *)(uintptr_t)app->theme;
    ScreenBuffer_clear(scr, th->text, th->bg);

    WIDGET_CALL((Widget *)(uintptr_t)app->header_bar, render, scr, th);
    WIDGET_CALL((Widget *)(uintptr_t)app->left_pane, render, scr, th);
    Widget *right = (Widget *)(uintptr_t)(app->right_mode == RIGHT_MODE_PREVIEW ? app->preview_pane : app->right_pane);
    WIDGET_CALL(right, render, scr, th);
    WIDGET_CALL((Widget *)(uintptr_t)app->status_bar, render, scr, th);
    WIDGET_CALL((Widget *)(uintptr_t)app->func_bar, render, scr, th);
    term_render(app, scr, th);
    if (app->active_dialog)
        WIDGET_CALL((Widget *)(uintptr_t)app->active_dialog, render, scr, th);

    img_preview_pre_flush(app);
    ScreenBuffer_flush(scr);
    img_preview_post_flush(app);
    app->need_redraw = 0;
}

void App_set_status(App *app, const char *msg, int kind)
{
    StatusBar_set_message((StatusBar *)(uintptr_t)app->status_bar, msg, kind, 3500);
    app->need_redraw = 1;
}

void App_set_active_pane(App *app, FilePane *pane)
{
    if ((uint64_t)(uintptr_t)pane == app->active_pane) return;
    WIDGET_CALL((Widget *)(uintptr_t)app->left_pane, on_focus, 0);
    WIDGET_CALL((Widget *)(uintptr_t)app->right_pane, on_focus, 0);
    app->active_pane = (uint64_t)(uintptr_t)pane;
    WIDGET_CALL((Widget *)pane, on_focus, 1);
    App_sync_preview(app);
    app->need_redraw = 1;
}

FilePane *get_inactive_pane(App *app)
{
    if (app->left_pane != app->active_pane) return (FilePane *)(uintptr_t)app->left_pane;
    return (FilePane *)(uintptr_t)app->right_pane;
}

void App_sync_preview(App *app)
{
    if (app->right_mode != RIGHT_MODE_PREVIEW) return;
    app->preview_due = (uint64_t)(sys_clock_ms() + PREVIEW_DEBOUNCE_MS);
}

void App_preview_fire(App *app)
{
    app->preview_due = 0;
    if (app->right_mode != RIGHT_MODE_PREVIEW) return;

    FilePane *pane = (FilePane *)(uintptr_t)app->active_pane;
    PreviewPane *pv = (PreviewPane *)(uintptr_t)app->preview_pane;
    FileEntry *fe = FilePane_get_selected_entry(pane);
    if (!fe) {
        (void)PreviewPane_load(pv, nullptr, nullptr);
        app->need_redraw = 1;
        return;
    }

    char full[PATH_MAX];
    DirModel *m = (DirModel *)(uintptr_t)pane->model;
    if (path_join(full, m->path, DirModel_entry_name(m, fe), PATH_MAX) < 0) {
        (void)PreviewPane_load(pv, nullptr, nullptr);
        app->need_redraw = 1;
        return;
    }
    if (PreviewPane_load(pv, full, fe)) {
        PvThumbReq req;
        uint32_t dims = PreviewPane_thumb_req(pv, &req);
        uint32_t mode = (uint32_t)req.proto | ((uint32_t)req.cols << 8);
        int seq = fs_preview_request(full, dims, mode, req.bg);
        if (seq > 0) app->preview_seq = (uint32_t)seq;
        else PreviewPane_read_sync(pv);
    }
    app->need_redraw = 1;
}
