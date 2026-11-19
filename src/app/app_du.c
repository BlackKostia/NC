/* src/app/app_du.c - App side of Disk Usage progress callback & toggle
 * (freestanding C23; replaces src/app/app_du.s, kept as tests/harness/app_du_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_du.h"
#include "duop_oop.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define DU_PROGRESS_MS 300

static Dialog *g_du_dlg;
static uint64_t g_du_delay;

static void adu_close(App *app)
{
    if (!g_du_dlg) return;
    Dialog *d = g_du_dlg;
    g_du_dlg = nullptr;
    app->active_dialog = 0;
    Object_free((Object *)d);
    app->need_redraw = 1;
}

static void adu_event(App *app, const Event *evt, int *canceled)
{
    if (evt->type == EVT_RESIZE) {
        int tw = 0, th = 0;
        sys_get_winsize(&tw, &th);
        app->term_w = (uint32_t)tw;
        app->term_h = (uint32_t)th;
        term_caps_refresh(tw, th);
        App_layout(app);
        app->need_redraw = 1;
        if (g_du_dlg) DuProgressDialog_layout((Widget *)g_du_dlg, 0, 0, tw, th);
    } else if (evt->type == EVT_KEY) {
        if (evt->key == KEY_ESC) *canceled = 1;
    }
}

static void adu_maybe_render(App *app, const DuProgress *p)
{
    int64_t elapsed = os_clock_ms() - p->start_ms;
    if (elapsed < (int64_t)g_du_delay) return;
    if (!g_du_dlg) {
        if (app->active_dialog) return;
        Dialog *d = DuProgressDialog_new(app);
        if (!d) return;
        g_du_dlg = d;
        app->active_dialog = (uint64_t)(uintptr_t)d;
    }
    App_render(app);
}

static int App_du_progress(void *ctx, DuProgress *p)
{
    App *app = (App *)ctx;
    if (p->phase == DU_PHASE_DONE) {
        adu_close(app);
        return 0;
    }
    int canceled = 0;
    Event evt;
    while (input_poll_event(&evt, 0)) adu_event(app, &evt, &canceled);
    if (canceled) {
        App_set_status(app, i18n_get()->s[LS_msg_du_canceled], MSG_INFO);
        return 1;
    }
    adu_maybe_render(app, p);
    (void)os_poll_in(STDIN_FD, 100);
    return 0;
}

void App_du_init(App *app)
{
    g_du_delay = DU_PROGRESS_MS;
    const char *v = cfg_getenv((char **)(uintptr_t)app->envp, "DUOP_DU_PROGRESS_MS=");
    if (v && v[0] != '\0') g_du_delay = parse_uint(v);
    du_set_progress(App_du_progress, app);
}

void du_toggle(App *app)
{
    FilePane *fp = (FilePane *)(uintptr_t)app->active_pane;
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    if (m->du_mode == 0) (void)dir_du_populate(m);
    else du_leave(m);
    app->need_redraw = 1;
}
