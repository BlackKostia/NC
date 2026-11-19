/* src/app/app_attr.c - App commands for File Info, Chmod/Chown, Symlink/Hardlink, Trash & Undo
 * (freestanding C23; replaces src/app/app_attr.s, kept as tests/harness/app_attr_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

typedef struct TrashBuf {
    char src[PATH_MAX];
    char trash[PATH_MAX];
    char info[PATH_MAX];
} TrashBuf;

static int aa_get_selected_path(App *app, char *out_path, int allow_dotdot)
{
    FilePane *pane = (FilePane *)(uintptr_t)app->active_pane;
    FileEntry *fe = FilePane_get_selected_entry(pane);
    if (!fe) return 0;
    if (!allow_dotdot && (fe->flags & FE_IS_PARENT)) return 0;
    DirModel *m = (DirModel *)(uintptr_t)pane->model;
    const char *name = DirModel_entry_name(m, fe);
    if (path_join(out_path, m->path, name, PATH_MAX) < 0) return 0;
    return 1;
}

static void aa_err_status(App *app, int neg_errno)
{
    App_set_status(app, fs_errno_message(neg_errno), MSG_ERR);
}

static void aa_open_sel_dlg(App *app, void *(*ctor)(App *, const char *))
{
    char full[PATH_MAX];
    if (!aa_get_selected_path(app, full, 0)) return;
    void *dlg = ctor(app, full);
    if (!dlg) return;
    app->active_dialog = (uint64_t)(uintptr_t)dlg;
    app->need_redraw = 1;
}

static void *aa_info_ctor(App *app, const char *p) { return InfoDialog_new(app, p); }
static void *aa_chmod_ctor(App *app, const char *p) { return ChmodDialog_new(app, p); }

void App_cmd_info(App *app) { aa_open_sel_dlg(app, aa_info_ctor); }
void App_cmd_chmod(App *app) { aa_open_sel_dlg(app, aa_chmod_ctor); }

void App_cmd_link(App *app, int is_hard)
{
    FilePane *pane = (FilePane *)(uintptr_t)app->active_pane;
    FileEntry *fe = FilePane_get_selected_entry(pane);
    if (!fe || (fe->flags & FE_IS_PARENT)) return;

    DirModel *m = (DirModel *)(uintptr_t)pane->model;
    const char *name = DirModel_entry_name(m, fe);
    FilePane *inact = get_inactive_pane(app);
    DirModel *im = (DirModel *)(uintptr_t)inact->model;

    char dst[PATH_MAX];
    if (path_join(dst, im->path, name, PATH_MAX) < 0) return;

    const LangStrings *lang = i18n_get();
    const char *title = is_hard ? lang->s[LS_dlg_title_hardlink] : lang->s[LS_dlg_title_symlink];
    uint32_t tag = is_hard ? OP_HARDLINK : OP_SYMLINK;
    InputDialog *dlg = InputDialog_new(app, title, lang->s[LS_prm_link_target], dst, tag);
    if (!dlg) return;
    app->active_dialog = (uint64_t)(uintptr_t)dlg;
    app->need_redraw = 1;
}

void App_cmd_trash(App *app)
{
    TrashBuf *tb = mem_alloc(sizeof *tb);
    if (!tb) {
        aa_err_status(app, -ENOMEM);
        return;
    }
    if (!aa_get_selected_path(app, tb->src, 0)) {
        mem_free(tb);
        return;
    }
    int rc = trash_move_file(tb->src, (const char *const *)(uintptr_t)app->envp, tb->trash, tb->info);
    if (rc < 0) {
        aa_err_status(app, rc);
        mem_free(tb);
        return;
    }
    undo_push(UNDO_TRASH, tb->src, tb->trash, tb->info);
    mem_free(tb);
    App_reload_panes(app, nullptr);
    App_sync_preview(app);
    App_set_status(app, i18n_get()->s[LS_msg_trashed], MSG_OK);
}

void App_cmd_undo(App *app)
{
    int rc = undo_pop_and_apply();
    if (rc < 0) {
        aa_err_status(app, rc);
        return;
    }
    if (rc == 0) {
        App_set_status(app, i18n_get()->s[LS_msg_undo_empty], MSG_INFO);
        return;
    }
    App_reload_panes(app, nullptr);
    App_sync_preview(app);
    App_set_status(app, i18n_get()->s[LS_msg_undone], MSG_OK);
}

static const char *aa_parse_u32(const char *s, int end_ch, uint32_t *out)
{
    uint64_t v = 0;
    int digits = 0;
    for (;;) {
        uint8_t c = (uint8_t)*s;
        if ((int)c == end_ch) break;
        if (c < '0' || c > '9') return nullptr;
        v = v * 10u + (uint64_t)(c - '0');
        if (v > 0xFFFFFFFFull) return nullptr;
        digits++;
        s++;
    }
    if (digits == 0) return nullptr;
    *out = (uint32_t)v;
    return s;
}

static int aa_parse_uid_gid(const char *s, uint32_t *uid, uint32_t *gid)
{
    const char *sep = aa_parse_u32(s, ':', uid);
    if (!sep) return -1;
    if (!aa_parse_u32(sep + 1, '\0', gid)) return -1;
    return 0;
}

void App_apply_chmod(App *app, ChmodDialog *dlg)
{
    const char *target = (const char *)dlg->target_path;
    FileStat st;
    intptr_t sr = os_statat(AT_FDCWD, target, &st, 0);
    if (sr < 0) {
        aa_err_status(app, (int)sr);
        return;
    }
    int is_lnk = ((st.mode & S_IFMT) == S_IFLNK);
    uint32_t uid = 0, gid = 0;
    if (aa_parse_uid_gid((const char *)dlg->owner_buf, &uid, &gid) < 0) {
        aa_err_status(app, -EINVAL);
        return;
    }
    if (!is_lnk) {
        intptr_t rc = os_fchmodat(AT_FDCWD, target, dlg->mode);
        if (rc < 0) {
            aa_err_status(app, (int)rc);
            return;
        }
    }
    if (uid != dlg->uid || gid != dlg->gid) {
        intptr_t rc = os_fchownat(AT_FDCWD, target, uid, gid, AT_SYMLINK_NOFOLLOW);
        if (rc < 0) {
            aa_err_status(app, (int)rc);
            return;
        }
        App_reload_panes(app, nullptr);
        return;
    }
    if (is_lnk) { aa_err_status(app, -EOPNOTSUPP); return; }
    App_reload_panes(app, nullptr);
}

void App_apply_link(App *app, InputDialog *dlg, int is_hard)
{
    char src[PATH_MAX];
    if (!aa_get_selected_path(app, src, 0)) return;
    const char *dst = (const char *)dlg->buf;
    intptr_t rc;
    rc = is_hard ? os_linkat(AT_FDCWD, src, AT_FDCWD, dst, 0) : os_symlinkat(src, AT_FDCWD, dst);
    if (rc < 0) {
        aa_err_status(app, (int)rc);
        return;
    }
    App_reload_panes(app, nullptr);
}
