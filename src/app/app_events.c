/* src/app/app_events.c - Event sources: exact poll timeouts, debounced preview,
 * async preview replies and inotify-driven auto-refresh of both panes
 * (freestanding C23; replaces src/app/app_events.s, kept as tests/harness/app_events_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_preview.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"

#define TASK_TICK_MS 100
#define WATCH_DEBOUNCE_MS 150
#define WATCH_MIN_GAP_MS 500

static inline uint64_t *watch_due(App *app) { return (uint64_t *)(void *)app->watch_due; }
static inline uint64_t *watch_last(App *app) { return (uint64_t *)(void *)app->watch_last; }
static inline uint32_t *watch_kind(App *app) { return (uint32_t *)(void *)&app->watch_kind; }

void App_events_init(App *app)
{
    term_caps_init((char **)(uintptr_t)app->envp);
    term_caps_query();
    term_caps_refresh((int)app->term_w, (int)app->term_h);
    (void)dirwatch_init();
    input_set_aux_fd(1, dirwatch_fd());
}

void App_events_shutdown(App *app)
{
    (void)app;
    term_shutdown();
    fs_preview_stop();
}

static int ev_min_deadline(int cur, uint64_t deadline, uint64_t now)
{
    if (deadline == 0) return cur;
    int64_t diff = (int64_t)(deadline - now);
    if (diff < 0) diff = 0;
    if (diff > 0x7FFFFFFFll) diff = 0x7FFFFFFFll;
    if (cur < 0 || (uint32_t)diff < (uint32_t)cur) return (int)diff;
    return cur;
}

int App_events_timeout(App *app)
{
    uint64_t now = (uint64_t)sys_clock_ms();
    int to = app->task_active ? TASK_TICK_MS : -1;
    StatusBar *sb = (StatusBar *)(uintptr_t)app->status_bar;
    to = ev_min_deadline(to, sb->msg_expire_ms, now);
    to = ev_min_deadline(to, app->preview_due, now);
    to = ev_min_deadline(to, watch_due(app)[0], now);
    to = ev_min_deadline(to, watch_due(app)[1], now);
    return to;
}

static void ev_schedule_watch(App *app, int slot, uint32_t kind, uint64_t now)
{
    watch_kind(app)[slot] |= kind;
    if (watch_due(app)[slot] != 0) return;
    uint64_t d1 = now + WATCH_DEBOUNCE_MS;
    uint64_t d2 = watch_last(app)[slot] + WATCH_MIN_GAP_MS;
    watch_due(app)[slot] = (d1 >= d2) ? d1 : d2;
}

static void ev_refresh_pane(App *app, int slot, uint64_t now)
{
    FilePane *pane = (FilePane *)(uintptr_t)(slot == 0 ? app->left_pane : app->right_pane);
    DirModel *m = (DirModel *)(uintptr_t)pane->model;
    if (m->is_loading) { watch_due(app)[slot] = now + WATCH_DEBOUNCE_MS; return; }
    watch_due(app)[slot] = 0;
    watch_last(app)[slot] = now;
    uint32_t kind = watch_kind(app)[slot];
    watch_kind(app)[slot] = 0;
    if ((kind & 1u) && !m->huge_mode && DirModel_count_selected(m, nullptr) == 0)
        FilePane_reload_keep_cursor(pane, nullptr);
    else
        DirModel_invalidate_stats(m);
    if ((uint64_t)(uintptr_t)pane == app->active_pane) App_sync_preview(app);
    app->need_redraw = 1;
}

static void ev_drain_preview(App *app, uint64_t now)
{
    if (app->preview_due && now >= app->preview_due) App_preview_fire(app);
    term_poll_read(app);
    input_set_aux_fd(2, fs_preview_fd());
    PreviewPane *pv = (PreviewPane *)(uintptr_t)app->preview_pane;
    uint32_t seq = 0;
    size_t len = 0, tlen = 0;
    while (fs_preview_receive((void *)(uintptr_t)pv->buf, PREVIEW_BUF_SIZE, &seq, &len, &tlen)) {
        if (seq == app->preview_seq && pv->pending) {
            PreviewPane_accept(pv, len, tlen, fs_preview_shm_slot(seq));
            app->need_redraw = 1;
        }
    }
    input_set_aux_fd(2, fs_preview_fd());
}

void App_events_tick(App *app)
{
    uint64_t now = (uint64_t)sys_clock_ms();
    ev_drain_preview(app, now);

    DirModel *lm = (DirModel *)(uintptr_t)((FilePane *)(uintptr_t)app->left_pane)->model;
    DirModel *rm = (DirModel *)(uintptr_t)((FilePane *)(uintptr_t)app->right_pane)->model;
    dirwatch_set(0, lm->path);
    dirwatch_set(1, rm->path);
    uint32_t ev = dirwatch_poll();
    if (ev & 3u) ev_schedule_watch(app, 0, ev & 3u, now);
    if (ev & 12u) ev_schedule_watch(app, 1, (ev >> 2) & 3u, now);
    for (int i = 0; i < 2; i++) {
        if (watch_due(app)[i] && now >= watch_due(app)[i])
            ev_refresh_pane(app, i, now);
    }
    if (term_caps_changed()) App_sync_preview(app);
}
