/* src/app/app_cmdline.c - run a User Menu / open-rule command template safely
 * (freestanding C23; replaces src/app/app_cmdline.s, kept as tests/harness/app_cmdline_reference.s). */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_config_expand.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define AC_SEL_CAP 60000
#define AC_CMD_CAP 120000

typedef struct AcFrame {
    ConfigExpandCtx ctx;
    char *sel;
    char *cmd;
    App *app;
    const char *tmpl;
} AcFrame;

static intptr_t ac_list_add(char *buf, size_t i, size_t max, const char *name)
{
    for (;;) {
        uint8_t ch = (uint8_t)*name++;
        if (i >= max) return -1;
        buf[i++] = (char)ch;
        if (ch == 0) return (intptr_t)i;
    }
}

static int am_collect_selected(App *app, const char *cur_name, char *buf, size_t cap)
{
    FilePane *fp = (FilePane *)(uintptr_t)app->active_pane;
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    size_t max = cap - 1;
    size_t pos = 0;
    uint32_t added = 0;
    for (uint64_t idx = 0; idx < m->count; idx++) {
        FileEntry *fe = DirModel_get_entry(m, (intptr_t)idx);
        if (!fe || !(fe->flags & FE_SELECTED)) continue;
        const char *name = DirModel_entry_name(m, fe);
        intptr_t next = ac_list_add(buf, pos, max, name);
        if (next < 0) return -ENAMETOOLONG;
        pos = (size_t)next;
        added++;
    }
    if (added == 0 && cur_name) {
        intptr_t next = ac_list_add(buf, pos, max, cur_name);
        if (next < 0) return -ENAMETOOLONG;
        pos = (size_t)next;
    }
    buf[pos] = '\0';
    return 0;
}

static int ac_expand(AcFrame *f)
{
    char *sel = mem_alloc(AC_SEL_CAP);
    if (!sel) return -ENOMEM;
    f->sel = sel;
    char *cmd = mem_alloc(AC_CMD_CAP);
    if (!cmd) return -ENOMEM;
    f->cmd = cmd;
    int rc = am_collect_selected(f->app, f->ctx.cur_name, sel, AC_SEL_CAP);
    if (rc < 0) return rc;
    f->ctx.selection = sel;
    FilePane *act = (FilePane *)(uintptr_t)f->app->active_pane;
    DirModel *am = (DirModel *)(uintptr_t)act->model;
    f->ctx.active_dir = am->path;
    FilePane *inact = get_inactive_pane(f->app);
    DirModel *im = (DirModel *)(uintptr_t)inact->model;
    f->ctx.inactive_dir = im->path;
    return (int)config_expand_cmd(f->tmpl, cmd, AC_CMD_CAP, &f->ctx);
}

static int ac_run(AcFrame *f)
{
    char cwd[PATH_MAX];
    if (os_getcwd(cwd, PATH_MAX) < 0) cwd[0] = '\0';
    FilePane *act = (FilePane *)(uintptr_t)f->app->active_pane;
    DirModel *am = (DirModel *)(uintptr_t)act->model;
    intptr_t rc = os_chdir(am->path);
    if (rc < 0) return (int)rc;
    (void)sys_exec_sh_arg(f->cmd, f->ctx.cur_path, (char **)(uintptr_t)f->app->envp);
    if (cwd[0] != '\0') (void)os_chdir(cwd);
    ScreenBuffer *scr = (ScreenBuffer *)(uintptr_t)f->app->screen;
    scr->force_full = 1;
    App_reload_panes(f->app, nullptr);
    return 0;
}

static void ac_report(App *app, int neg_errno)
{
    const char *msg;
    if (neg_errno == -ENAMETOOLONG) msg = i18n_get()->s[LS_err_cmd_long];
    else msg = fs_errno_message(neg_errno);
    App_set_status(app, msg, MSG_ERR);
}

void App_run_expanded_cmd(App *app, const char *tmpl, const char *cur_name, const char *cur_path)
{
    AcFrame f = {
        .ctx = { .cur_name = cur_name, .cur_path = cur_path },
        .sel = nullptr,
        .cmd = nullptr,
        .app = app,
        .tmpl = tmpl,
    };
    int rc = ac_expand(&f);
    if (rc >= 0) rc = ac_run(&f);
    if (rc < 0) ac_report(app, rc);
    mem_free(f.sel);
    mem_free(f.cmd);
}
