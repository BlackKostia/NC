/* src/app/app_toggles.c - Global UI toggles (preview, hidden, theme, language), quit
 * guard, and F1..F10 action dispatch (freestanding C23; replaces src/app/app_toggles.s,
 * kept as tests/harness/app_toggles_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

void App_cmd_toggle_preview(App *app)
{
    app->right_mode ^= 1;
    if (app->right_mode == RIGHT_MODE_PREVIEW) {
        App_set_active_pane(app, (FilePane *)(uintptr_t)app->left_pane);
        App_sync_preview(app);
    }
    app->need_redraw = 1;
}

void App_cmd_toggle_hidden(App *app)
{
    FilePane *lp = (FilePane *)(uintptr_t)app->left_pane;
    FilePane *rp = (FilePane *)(uintptr_t)app->right_pane;
    DirModel *lm = (DirModel *)(uintptr_t)lp->model;
    DirModel *rm = (DirModel *)(uintptr_t)rp->model;

    lm->show_hidden ^= 1;
    rm->show_hidden = lm->show_hidden;

    DirModel_apply_filter(lm);
    FilePane_ensure_visible(lp);
    DirModel_apply_filter(rm);
    FilePane_ensure_visible(rp);

    App_sync_preview(app);
    app->need_redraw = 1;
}

void App_cmd_cycle_theme(App *app)
{
    app->theme_idx++;
    app->theme = (uint64_t)(uintptr_t)theme_get((int)app->theme_idx);
    ((ScreenBuffer *)(uintptr_t)app->screen)->force_full = 1;
    app->need_redraw = 1;
}

void App_cmd_toggle_lang(App *app)
{
    int cnt = i18n_count();
    uint32_t next = app->lang_idx + 1u;
    if (next >= (uint32_t)cnt) next = 0;
    app->lang_idx = next;

    const LangStrings *ls = i18n_set_lang((int)next);
    app->lang = (uint64_t)(uintptr_t)ls;
    App_layout(app);
    App_set_status(app, ls->s[LS_msg_lang_switched], MSG_INFO);
    ((ScreenBuffer *)(uintptr_t)app->screen)->force_full = 1;
    app->need_redraw = 1;
}

void App_cmd_quit(App *app)
{
    if (app->task_active) { App_task_confirm_quit(app); return; }
    app->running = 0;
}

void App_dispatch_f_action(App *app, int idx)
{
    switch (idx) {
    case 0: App_cmd_help(app); break;
    case 1: App_cmd_rename(app); break;
    case 2: App_cmd_view(app); break;
    case 3: App_cmd_edit(app); break;
    case 4: App_cmd_copy(app); break;
    case 5: App_cmd_move(app); break;
    case 6: App_cmd_mkdir(app); break;
    case 7: App_cmd_delete(app); break;
    case 8: App_cmd_toggle_preview(app); break;
    case 9: App_cmd_quit(app); break;
    default: break;
    }
}
