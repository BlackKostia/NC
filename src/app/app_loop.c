/* src/app/app_loop.c - Main application event loop and mouse routing
 * (freestanding C23; replaces src/app/app_loop.s, kept as tests/harness/app_loop_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_keys.h"
#include "duop_oop.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"

static void handle_mouse(App *app, Event *evt)
{
    app->mouse_x = (uint32_t)evt->mouse_x;
    app->mouse_y = (uint32_t)evt->mouse_y;

    if (app->active_dialog) {
        (void)WIDGET_CALL((Widget *)(uintptr_t)app->active_dialog, on_mouse, evt);
        return;
    }
    FilePane *lp = (FilePane *)(uintptr_t)app->left_pane;
    if (lp->dragging_scroll) {
        (void)WIDGET_CALL((Widget *)lp, on_mouse, evt);
        return;
    }
    FilePane *rp = (FilePane *)(uintptr_t)app->right_pane;
    if (rp->dragging_scroll) {
        (void)WIDGET_CALL((Widget *)rp, on_mouse, evt);
        return;
    }
    if (pane_mouse_ext(app, evt)) return;
    if (evt->mouse_kind == MACT_MOVE) { app_mouse_hover(app, evt); return; }

    StatusBar *sb = (StatusBar *)(uintptr_t)app->status_bar;
    if (app->task_active && evt->mouse_kind == MACT_PRESS && sb->base.y == evt->mouse_y) {
        App_task_show(app);
        return;
    }

    Widget *hdr = (Widget *)(uintptr_t)app->header_bar;
    if (WIDGET_CALL(hdr, hit_test, evt->mouse_x, evt->mouse_y) && WIDGET_CALL(hdr, on_mouse, evt)) return;
    Widget *fb = (Widget *)(uintptr_t)app->func_bar;
    if (WIDGET_CALL(fb, hit_test, evt->mouse_x, evt->mouse_y) && WIDGET_CALL(fb, on_mouse, evt)) return;
    if (WIDGET_CALL((Widget *)lp, hit_test, evt->mouse_x, evt->mouse_y)) {
        (void)WIDGET_CALL((Widget *)lp, on_mouse, evt);
        return;
    }
    Widget *rw = (Widget *)(uintptr_t)(app->right_mode == RIGHT_MODE_PREVIEW ? app->preview_pane : app->right_pane);
    if (WIDGET_CALL(rw, hit_test, evt->mouse_x, evt->mouse_y))
        (void)WIDGET_CALL(rw, on_mouse, evt);
}

static void handle_resize(App *app)
{
    int tw = 0, th = 0;
    sys_get_winsize(&tw, &th);
    app->term_w = (uint32_t)tw;
    app->term_h = (uint32_t)th;
    term_caps_refresh(tw, th);
    App_layout(app);
    App_sync_preview(app);
    app->need_redraw = 1;
}

static void drain_queued_events(App *app)
{
    Event evt;
    for (int i = 0; i < 16 && app->running; i++) {
        int r = input_next_event(&evt, 0);
        if (r == 0) break;
        if (r < 0) { app->running = 0; break; }
        if (evt.type == EVT_KEY) handle_key(app, &evt);
        else if (evt.type == EVT_MOUSE) handle_mouse(app, &evt);
        else break;
    }
}

static void stream_step(App *app, uint64_t *last_ms)
{
    App_task_tick(app);
    App_events_tick(app);

    DirModel *lm = (DirModel *)(uintptr_t)((FilePane *)(uintptr_t)app->left_pane)->model;
    DirModel *rm = (DirModel *)(uintptr_t)((FilePane *)(uintptr_t)app->right_pane)->model;
    DirModel *target = nullptr;
    if (lm->is_loading && rm->is_loading) {
        app->stream_turn ^= 1;
        target = (app->stream_turn == 0) ? lm : rm;
    } else if (lm->is_loading) {
        target = lm;
    } else if (rm->is_loading) {
        target = rm;
    }
    if (!target) return;

    intptr_t rc = DirModel_step_load(target, 0);
    if (rc <= 0) {
        if (rc < 0) task_status_errno(app, rc);
        App_sync_preview(app);
        app->need_redraw = 1;
        return;
    }
    uint64_t now = (uint64_t)sys_clock_ms();
    if (now - *last_ms >= 33) {
        *last_ms = now;
        app->need_redraw = 1;
    }
}

void App_run(App *app)
{
    uint64_t last_stream_ms = 0;
    App_events_init(app);
    App_render(app);

    g_git_defer = 0;
    DirModel *lm = (DirModel *)(uintptr_t)((FilePane *)(uintptr_t)app->left_pane)->model;
    DirModel *rm = (DirModel *)(uintptr_t)((FilePane *)(uintptr_t)app->right_pane)->model;
    (void)git_refresh(lm);
    (void)git_refresh(rm);
    if (lm->git_ctx || rm->git_ctx) App_render(app);

    while (app->running && !g_sigterm) {
        int to = (lm->is_loading || rm->is_loading) ? 0 : App_events_timeout(app);
        Event evt;
        int er = input_next_event(&evt, to);

        StatusBar *sb = (StatusBar *)(uintptr_t)app->status_bar;
        if (sb->msg_expire_ms && (uint64_t)sys_clock_ms() >= sb->msg_expire_ms) {
            sb->msg_expire_ms = 0;
            app->need_redraw = 1;
        }
        if (er < 0) { app->running = 0; }
        else if (er > 0) {
            if (evt.type == EVT_RESIZE) handle_resize(app);
            else if (evt.type == EVT_KEY) handle_key(app, &evt);
            else if (evt.type == EVT_MOUSE) handle_mouse(app, &evt);
        }
        drain_queued_events(app);
        if (!app->running) break;
        stream_step(app, &last_stream_ms);
        if (app->need_redraw) App_render(app);
    }

    App_task_shutdown(app);
    App_events_shutdown(app);
}
