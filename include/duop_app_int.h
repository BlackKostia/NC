/* include/duop_app_int.h - Internal declarations shared across src/app C modules
 * (and between migrated C modules and remaining src/app asm modules during Phase A).
 * UI -> App entry points remain in include/duop_app.h (checked by test_c_app_api.py). */
#pragma once
#include <stdint.h>

typedef struct App App;
typedef struct Event Event;
typedef struct FilePane FilePane;
typedef struct ViewAsDialog ViewAsDialog;

/* app_choosedir.c */
void App_write_choosedir(App *app, const char *out_path);
void app_mouse_hover(App *app, Event *evt);

/* app_arc.c */
int arc_nav_up(FilePane *fp);
int arc_handle_enter(App *app);
int arc_extract_selected(FilePane *fp, char *out_tmp_path);

/* app_view.c */
void App_open_viewer(App *app, const char *path);
void App_view_as_done(App *app, ViewAsDialog *dlg);
int App_cmd_view_mode(App *app);

/* app_toggles.c / app_cmds.s / app_layout.s / app_task_tick.s */
void App_layout(App *app);
void App_task_confirm_quit(App *app);
void App_cmd_rename(App *app);
void App_cmd_edit(App *app);
void App_cmd_mkdir(App *app);

/* app_du.c & app_cmdline.c & app_layout.s / app_cmds.s */
void App_render(App *app);
void App_reload_panes(App *app, const char *focus_name);
void reload_both_panes(App *app, const char *focus_name);
FilePane *get_inactive_pane(App *app);
void App_du_init(App *app);
void du_toggle(App *app);
void App_run_expanded_cmd(App *app, const char *tmpl, const char *cur_name, const char *cur_path);

/* app_task.c */
typedef struct ConflictDialog ConflictDialog;
void task_status_errno(App *app, int64_t neg_errno);
void App_task_start(App *app, int op, const char *dst_input);
void App_task_tick(App *app);
void App_task_show(App *app);
void App_task_shutdown(App *app);
void App_task_conflict_done(App *app, int result, ConflictDialog *dlg);

/* app_menu.c, app_open.c & remaining app_* commands */
void App_cmd_usermenu(App *app);
void App_dispatch_action(App *app, int act_id);
void App_exec_menu_tmpl(App *app, const char *tmpl);
void App_cmd_start_filter(App *app);
void App_cmd_goto(App *app);
void App_cmd_newfile(App *app);
void App_cmd_shell(App *app);
void app_jump_virtual_entry(App *app, FilePane *pane, const char *full_path);

/* app_attr.c */
typedef struct ChmodDialog ChmodDialog;
typedef struct InputDialog InputDialog;
void App_cmd_info(App *app);
void App_cmd_chmod(App *app);
void App_cmd_link(App *app, int is_hard);
void App_cmd_trash(App *app);
void App_cmd_undo(App *app);
void App_apply_chmod(App *app, ChmodDialog *dlg);
void App_apply_link(App *app, InputDialog *dlg, int is_hard);

/* app_ext.c */
typedef struct Dialog Dialog;
typedef struct DirModel DirModel;
intptr_t App_close_dialog_ext(App *app, Dialog *dlg, FilePane *pane, DirModel *model, int dlg_res);
int app_handle_ext_key(App *app, int key, int mods);
