/* src/app/app_menu.c - User Menu, Action Dispatch & Package Action Runner
 * (freestanding C23; replaces src/app/app_menu.s, kept as tests/harness/app_menu_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

typedef struct PkgRunBuf {
    char cur_path[PATH_MAX];
    char cwd[PATH_MAX];
    char str_buf[1024];
    char *argv[32];
    char tmp_marked[128];
} PkgRunBuf;

void App_cmd_usermenu(App *app)
{
    app->active_dialog = (uint64_t)(uintptr_t)UserMenuDialog_new(app);
    app->need_redraw = 1;
}

void App_dispatch_action(App *app, int act_id)
{
    switch (act_id) {
    case ACT_QUIT: App_cmd_quit(app); break;
    case ACT_HELP: App_cmd_help(app); break;
    case ACT_RENAME: App_cmd_rename(app); break;
    case ACT_VIEW: App_cmd_view(app); break;
    case ACT_EDIT: App_cmd_edit(app); break;
    case ACT_COPY: App_cmd_copy(app); break;
    case ACT_MOVE: App_cmd_move(app); break;
    case ACT_MKDIR: App_cmd_mkdir(app); break;
    case ACT_DELETE: App_cmd_delete(app); break;
    case ACT_PREVIEW: App_cmd_toggle_preview(app); break;
    case ACT_HIDDEN: App_cmd_toggle_hidden(app); break;
    case ACT_THEME: App_cmd_cycle_theme(app); break;
    case ACT_LANG: App_cmd_toggle_lang(app); break;
    case ACT_FILTER: App_cmd_start_filter(app); break;
    case ACT_GOTO: App_cmd_goto(app); break;
    case ACT_NEWFILE: App_cmd_newfile(app); break;
    case ACT_SHELL: App_cmd_shell(app); break;
    case ACT_REFRESH: App_reload_panes(app, nullptr); break;
    case ACT_USERMENU: App_cmd_usermenu(app); break;
    default: break;
    }
}

static void am_err_status(App *app, int neg_errno)
{
    App_set_status(app, fs_errno_message(neg_errno), MSG_ERR);
}

void App_exec_menu_tmpl(App *app, const char *tmpl)
{
    char full[PATH_MAX];
    full[0] = '\0';
    const char *name = nullptr;
    FilePane *pane = (FilePane *)(uintptr_t)app->active_pane;
    FileEntry *fe = FilePane_get_selected_entry(pane);
    if (fe) {
        DirModel *m = (DirModel *)(uintptr_t)pane->model;
        name = DirModel_entry_name(m, fe);
        if (path_join(full, m->path, name, PATH_MAX) < 0) return;
    }
    App_run_expanded_cmd(app, tmpl, name, full);
}

static void am_pkg_exec_cwd(App *app, PkgAction *act, const char *dir, char **argv, char *cwd)
{
    if (pkg_ensure_exec(argv[0]) < 0) {
        App_set_status(app, i18n_get()->s[LS_pkg_err], MSG_ERR);
        return;
    }
    if (os_getcwd(cwd, PATH_MAX) < 0) cwd[0] = '\0';
    intptr_t rc = os_chdir(dir);
    if (rc < 0) {
        am_err_status(app, (int)rc);
        return;
    }
    char **envp = (char **)(uintptr_t)app->envp;
    if (act->mode[0] == 'b' && act->mode[1] == 'g' && act->mode[2] == '\0') {
        int r = sys_exec_argv_bg(argv[0], argv, envp);
        if (cwd[0] != '\0') (void)os_chdir(cwd);
        if (r != 0) {
            App_set_status(app, i18n_get()->s[LS_pkg_err], MSG_ERR);
            return;
        }
        const char *lbl = act->menu[0] ? act->menu : act->name;
        App_set_status(app, lbl, MSG_OK);
        return;
    }
    (void)sys_exec_argv(argv[0], argv, envp);
    if (cwd[0] != '\0') (void)os_chdir(cwd);
}

void App_run_pkg_action(App *app, PkgAction *act)
{
    PkgRunBuf *buf = mem_alloc(sizeof *buf);
    if (!buf) {
        am_err_status(app, -ENOMEM);
        return;
    }
    buf->cur_path[0] = '\0';
    buf->tmp_marked[0] = '\0';

    FilePane *act_pane = (FilePane *)(uintptr_t)app->active_pane;
    DirModel *am = (DirModel *)(uintptr_t)act_pane->model;
    FilePane *inact = get_inactive_pane(app);
    DirModel *im = (DirModel *)(uintptr_t)inact->model;
    const char *ctx[5] = { am->path, im->path, nullptr, buf->cur_path, nullptr };

    FileEntry *fe = FilePane_get_selected_entry(act_pane);
    if (fe) {
        ctx[2] = DirModel_entry_name(am, fe);
        if (path_join(buf->cur_path, ctx[0], ctx[2], PATH_MAX) < 0) {
            mem_free(buf);
            return;
        }
    }
    if (pkg_action_has_marked(act) &&
        pkg_write_marked_list(am, buf->cur_path, buf->tmp_marked, sizeof buf->tmp_marked) == 0) {
        ctx[4] = buf->tmp_marked;
    }
    if (pkg_action_build_argv(act, ctx, buf->str_buf, sizeof buf->str_buf, buf->argv, 32) > 0)
        am_pkg_exec_cwd(app, act, ctx[0], buf->argv, buf->cwd);

    if (buf->tmp_marked[0] != '\0') (void)os_unlinkat(AT_FDCWD, buf->tmp_marked, 0);
    ScreenBuffer *scr = (ScreenBuffer *)(uintptr_t)app->screen;
    scr->force_full = 1;
    App_reload_panes(app, nullptr);
    mem_free(buf);
}
