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
