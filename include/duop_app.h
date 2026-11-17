/* include/duop_app.h - the one door from src/ui (and src/fs callbacks) to the application controller (src/app).
 *
 * Widgets and dialogs never reach into `App` itself: they call these entry points, each a plain System V function whose
 * first argument is the App. While src/app is assembly the symbols are the `App_` functions of src/app; when it moves to C the
 * declarations stay and only the definitions change. tests/test_c_app_api.py keeps this list equal to the `App_*` symbols
 * the UI really calls and to the signatures in the assembly comments. Opaque types: the layouts come with gen_abi (E3). */
#pragma once
#include <stdint.h>

typedef struct App App;
typedef struct FilePane FilePane;
typedef struct PkgAction PkgAction;

/* ---- status line, focus, preview ---- */
void App_set_status(App *app, const char *msg, int kind);        /* kind = StatusBar message kind; shown ~3.5 s */
void App_set_active_pane(App *app, FilePane *pane);
void App_sync_preview(App *app);                                  /* debounced: schedules the preview refresh */
void App_open_selected_entry(App *app, FilePane *pane);           /* Enter / double-click on the cursor entry */

/* ---- dialogs ---- */
void App_close_dialog(App *app, int result);                      /* pops the modal dialog; result = DLG_* code */
void App_run_pkg_action(App *app, PkgAction *action);

/* ---- commands (function bar, header buttons, palette, keys) ---- */
void App_dispatch_f_action(App *app, int idx_0_to_9);             /* F1..F10 */
void App_cmd_view(App *app);
void App_cmd_copy(App *app);
void App_cmd_move(App *app);
void App_cmd_delete(App *app);
void App_cmd_help(App *app);
void App_cmd_quit(App *app);
void App_cmd_cycle_theme(App *app);
void App_cmd_toggle_preview(App *app);
void App_cmd_toggle_hidden(App *app);
void App_cmd_toggle_lang(App *app);

/* ---- background task (progress dialog buttons) ---- */
void App_task_hide(App *app);                                     /* the task keeps running in the background */
void App_task_toggle_pause(App *app);
void App_task_cancel(App *app);
