/* src/app/app_choosedir.c - --choosedir output writer and hover broadcast across widgets
 * (freestanding C23; replaces src/app/app_choosedir.s,
 * kept as tests/harness/app_choosedir_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"

void App_write_choosedir(App *app, const char *out_path)
{
    if (!out_path || !out_path[0]) return;
    FilePane *fp = (FilePane *)(uintptr_t)app->active_pane;
    if (!fp) return;
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    if (!m) return;

    /* safe-overwrite: user explicitly passed --choosedir=out_path; O_NOFOLLOW prevents symlink clobber */
    intptr_t fd = os_openat(AT_FDCWD, out_path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0644);
    if (fd < 0) return;

    (void)sys_write_all((int)fd, m->path, str_len(m->path));
    char nl = '\n';
    (void)sys_write_all((int)fd, &nl, 1);
    (void)os_close((int)fd);
}

void app_mouse_hover(App *app, Event *evt)
{
    WIDGET_CALL((Widget *)(uintptr_t)app->header_bar, on_mouse, evt);
    WIDGET_CALL((Widget *)(uintptr_t)app->func_bar, on_mouse, evt);
    WIDGET_CALL((Widget *)(uintptr_t)app->left_pane, on_mouse, evt);
    if (app->right_mode != RIGHT_MODE_PREVIEW)
        WIDGET_CALL((Widget *)(uintptr_t)app->right_pane, on_mouse, evt);
}
