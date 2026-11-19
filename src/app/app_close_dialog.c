/* src/app/app_close_dialog.c - Modal dialog close handler + Help/Mkdir triggers
 * (freestanding C23; replaces src/app/app_close_dialog.s,
 * kept as tests/harness/app_close_dialog_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_task.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

typedef struct RenameBuf {
    char old_p[PATH_MAX];
    char new_p[PATH_MAX];
} RenameBuf;

static intptr_t cd_mkdir(App *app, DirModel *m, const char *buf)
{
    if (buf[0] == '\0') return 0;
    char full[PATH_MAX];
    intptr_t rc = path_join(full, m->path, buf, PATH_MAX);
    if (rc < 0) return rc;
    rc = fs_mkdir(full);
    if (rc < 0) return rc;
    reload_both_panes(app, buf);
    App_set_status(app, i18n_get()->s[LS_app_ok_mkdir], MSG_OK);
    return 0;
}

static intptr_t cd_newfile(App *app, DirModel *m, const char *buf)
{
    if (buf[0] == '\0') return 0;
    char full[PATH_MAX];
    intptr_t rc = path_join(full, m->path, buf, PATH_MAX);
    if (rc < 0) return rc;
    rc = fs_touch(full);
    if (rc < 0) return rc;
    reload_both_panes(app, buf);
    App_set_status(app, i18n_get()->s[LS_app_ok_newfile], MSG_OK);
    return 0;
}

static intptr_t cd_rename(App *app, FilePane *pane, const char *buf)
{
    if (buf[0] == '\0') return 0;
    FileEntry *fe = FilePane_get_selected_entry(pane);
    if (!fe) return 0;
    RenameBuf *rb = mem_alloc(sizeof *rb);
    if (!rb) return -ENOMEM;
    DirModel *m = (DirModel *)(uintptr_t)pane->model;
    intptr_t rc = path_join(rb->old_p, m->path, DirModel_entry_name(m, fe), PATH_MAX);
    if (rc >= 0) {
        if (buf[0] == '/') (void)str_copy(rb->new_p, buf, PATH_MAX);
        else rc = path_join(rb->new_p, m->path, buf, PATH_MAX);
    }
    if (rc >= 0) rc = fs_rename_noreplace(rb->old_p, rb->new_p);
    if (rc >= 0) {
        undo_push(UNDO_RENAME, rb->old_p, rb->new_p, nullptr);
        reload_both_panes(app, path_basename(buf));
        App_set_status(app, i18n_get()->s[LS_app_ok_rename], MSG_OK);
    }
    mem_free(rb);
    return rc;
}

static void cd_filter(App *app, FilePane *pane, DirModel *m, const char *buf)
{
    StatusBar *sb = (StatusBar *)(uintptr_t)app->status_bar;
    sb->msg_expire_ms = 0;
    (void)str_copy(m->filter, buf, FILTER_MAX);
    DirModel_apply_filter(m);
    pane->cursor = 0; pane->scroll = 0;
    FilePane_ensure_visible(pane);
    App_sync_preview(app);
}

static intptr_t cd_goto(App *app, FilePane *pane, DirModel *m, const char *buf)
{
    if (buf[0] == '\0') return 0;
    StatusBar *sb = (StatusBar *)(uintptr_t)app->status_bar;
    sb->msg_expire_ms = 0;
    if (pkg_vfs_load_dir((char **)(uintptr_t)app->envp, m, buf) != 0) {
        intptr_t rc = DirModel_chdir((DirModel *)(uintptr_t)pane->model, buf);
        if (rc < 0) return rc;
    }
    pane->cursor = 0; pane->scroll = 0;
    FilePane_ensure_visible(pane);
    App_sync_preview(app);
    return 0;
}

static intptr_t cd_dispatch_ok(App *app, Dialog *dlg, int result)
{
    FilePane *pane = (FilePane *)(uintptr_t)app->active_pane;
    DirModel *m = (DirModel *)(uintptr_t)pane->model;
    InputDialog *idlg = (InputDialog *)dlg;
    const char *buf = (const char *)idlg->buf;
    switch (dlg->op_tag) {
    case OP_MKDIR: return cd_mkdir(app, m, buf);
    case OP_NEWFILE: return cd_newfile(app, m, buf);
    case OP_RENAME: return cd_rename(app, pane, buf);
    case OP_COPY: App_task_start(app, TASK_OP_COPY, buf); break;
    case OP_MOVE: App_task_start(app, TASK_OP_MOVE, buf); break;
    case OP_DELETE: App_task_start(app, TASK_OP_DELETE, nullptr); break;
    case OP_QUIT: app->running = 0; break;
    case 25: App_pkg_install_confirm(app, idlg); break;
    case OP_FILTER: cd_filter(app, pane, m, buf); break;
    case OP_GOTO: return cd_goto(app, pane, m, buf);
    default: return App_close_dialog_ext(app, dlg, pane, m, result);
    }
    return 0;
}

void App_close_dialog(App *app, int result)
{
    Dialog *dlg = (Dialog *)(uintptr_t)app->active_dialog;
    if (!dlg) return;
    app->active_dialog = 0;
    app->need_redraw = 1;

    if (result == DLG_OK) {
        intptr_t err = cd_dispatch_ok(app, dlg, result);
        if (err < 0) {
            reload_both_panes(app, nullptr);
            App_set_status(app, fs_errno_message((int)err), MSG_ERR);
        }
    }
    Object_free((Object *)dlg);
}

void App_cmd_help(App *app)
{
    app->active_dialog = (uint64_t)(uintptr_t)HelpDialog_new(app);
    app->need_redraw = 1;
}

void App_cmd_mkdir(App *app)
{
    const LangStrings *lang = i18n_get();
    app->active_dialog = (uint64_t)(uintptr_t)InputDialog_new(
        app, lang->s[LS_app_title_mkdir], lang->s[LS_app_prm_mkdir], nullptr, OP_MKDIR);
    app->need_redraw = 1;
}
