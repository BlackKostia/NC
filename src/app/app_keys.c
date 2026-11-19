/* src/app/app_keys.c - App top-level keyboard routing
 * (freestanding C23; replaces src/app/app_keys.s, kept as tests/harness/app_keys_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_fs.h"
#include "duop_keys.h"
#include "duop_oop.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void open_bookmarks(App *app, int mode)
{
    app->active_dialog = (uint64_t)(uintptr_t)BookmarkDialog_new(app, mode);
    app->need_redraw = 1;
}

static void cancel_stream(App *app, DirModel *m)
{
    DirModel_cancel_load(m);
    App_set_status(app, i18n_get()->s[LS_app_load_aborted], MSG_INFO);
    FilePane_ensure_visible((FilePane *)(uintptr_t)app->active_pane);
    App_sync_preview(app);
    app->need_redraw = 1;
}

static void handle_esc(App *app)
{
    FilePane *act = (FilePane *)(uintptr_t)app->active_pane;
    DirModel *am = (DirModel *)(uintptr_t)act->model;
    if (am->is_loading) { cancel_stream(app, am); return; }
    DirModel *lm = (DirModel *)(uintptr_t)((FilePane *)(uintptr_t)app->left_pane)->model;
    if (lm->is_loading) { cancel_stream(app, lm); return; }
    DirModel *rm = (DirModel *)(uintptr_t)((FilePane *)(uintptr_t)app->right_pane)->model;
    if (rm->is_loading) { cancel_stream(app, rm); return; }
    if (am->filter[0] == '\0') return;
    am->filter[0] = '\0';
    DirModel_apply_filter(am);
    act->cursor = 0;
    act->scroll = 0;
    FilePane_ensure_visible(act);
    App_sync_preview(app);
    app->need_redraw = 1;
}

static int handle_ctrl_key(App *app, int key)
{
    FilePane *pane = (FilePane *)(uintptr_t)app->active_pane;
    switch (key) {
    case 'c': case 'q': App_cmd_quit(app); return 1;
    case 'p': App_cmd_toggle_preview(app); return 1;
    case 'h': App_cmd_toggle_hidden(app); return 1;
    case 'r': reload_both_panes(app, nullptr);
        App_set_status(app, i18n_get()->s[LS_app_ok_refresh], MSG_INFO); return 1;
    case 'n': App_cmd_newfile(app); return 1;
    case 'g': App_cmd_goto(app); return 1;
    case 'o': App_cmd_shell(app); return 1;
    case 't': (void)FilePane_tab_new(pane); app->need_redraw = 1; return 1;
    case 'w':
        if (!FilePane_tab_close(pane, -1)) {
            App_set_status(app, i18n_get()->s[LS_msg_tab_last], MSG_WARN);
            return 1;
        }
        App_sync_preview(app);
        app->need_redraw = 1;
        return 1;
    case 'd': open_bookmarks(app, 0); return 1;
    default: return 0;
    }
}

static int handle_alt_key(App *app, int key)
{
    switch (key | 0x20) {
    case 't': App_cmd_cycle_theme(app); return 1;
    case 'l': App_cmd_toggle_lang(app); return 1;
    case 'j': App_task_show(app); return 1;
    case 'u': App_cmd_usermenu(app); return 1;
    default: return 0;
    }
}

static int handle_plain_key(App *app, int key)
{
    if (key >= KEY_F1 && key <= KEY_F10) {
        App_dispatch_f_action(app, key - KEY_F1);
        return 1;
    }
    switch (key) {
    case KEY_TAB: case KEY_BTAB:
        if (app->right_mode != RIGHT_MODE_PREVIEW)
            App_set_active_pane(app, get_inactive_pane(app));
        return 1;
    case 'q': case 'Q': App_cmd_quit(app); return 1;
    case '/': App_cmd_start_filter(app); return 1;
    case '.': App_cmd_toggle_hidden(app); return 1;
    case 'z': open_bookmarks(app, 1); return 1;
    case KEY_DELETE: App_cmd_trash(app); return 1;
    case KEY_ESC: handle_esc(app); return 1;
    default: return 0;
    }
}

void handle_key(App *app, Event *evt)
{
    if (app->active_dialog) {
        (void)WIDGET_CALL((Widget *)(uintptr_t)app->active_dialog, on_key, evt);
        return;
    }
    int key = evt->lat;
    int mods = evt->mods;
    int act = config_lookup_bind(key, mods);
    if (act >= 0) { App_dispatch_action(app, act); return; }

    int tr = term_on_key(app, evt);
    if (tr == 2) { App_layout(app); return; }
    if (tr != 0) return;
    if (app_handle_ext_key(app, key, mods)) return;

    int handled;
    if (mods & MOD_CTRL) handled = handle_ctrl_key(app, key);
    else if (mods & MOD_ALT) handled = handle_alt_key(app, key);
    else handled = handle_plain_key(app, key);

    if (!handled)
        (void)WIDGET_CALL((Widget *)(uintptr_t)app->active_pane, on_key, evt);
}
