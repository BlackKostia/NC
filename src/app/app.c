/* src/app/app.c - App controller class: vtable, constructor, and destructor (freestanding C23). */
#include "duop_abi.h"
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

const ObjectVtbl App_vtbl = {
    &Object_vtbl,
    "App",
    sizeof(App),
    (void (*)(Object *))App_dtor,
};

static bool app_init_core(App *app, char **envp, int lang_override)
{
    app->envp = (uint64_t)(uintptr_t)envp;
    config_load(envp);
    kbd_layout_load(envp);
    App_du_init(app);
    DirModel_init_env(envp);
    app->running = 1;
    app->need_redraw = 1;
    app->theme_idx = 0;
    app->right_mode = RIGHT_MODE_PANE;

    nav_state_init((const char *const *)envp);
    Config *cfg = config_get();
    if (cfg->theme >= 0) app->theme_idx = cfg->theme;

    int lang = lang_override;
    if (lang < 0) {
        lang = i18n_find(cfg->lang_id);
        if (lang < 0) lang = i18n_detect_env(envp);
    }
    app->lang = (uint64_t)(uintptr_t)i18n_set_lang(lang);
    app->lang_idx = i18n_get_idx();
    app->theme = (uint64_t)(uintptr_t)theme_get(app->theme_idx);

    sys_get_winsize((int *)&app->term_w, (int *)&app->term_h);
    ScreenBuffer *scr = ScreenBuffer_new(app->term_w, app->term_h);
    if (!scr) return false;
    app->screen = (uint64_t)(uintptr_t)scr;

    HeaderBar *hdr = HeaderBar_new(app);
    if (!hdr) return false;
    app->header_bar = (uint64_t)(uintptr_t)hdr;

    FunctionBar *fbar = FunctionBar_new(app);
    if (!fbar) return false;
    app->func_bar = (uint64_t)(uintptr_t)fbar;
    return true;
}

static bool app_init_panes(App *app, const char *left_path, const char *right_path, char **envp)
{
    StatusBar *sbar = StatusBar_new(app);
    if (!sbar) return false;
    app->status_bar = (uint64_t)(uintptr_t)sbar;

    FilePane *lp = FilePane_new(app, left_path, 1);
    if (!lp) return false;
    app->left_pane = (uint64_t)(uintptr_t)lp;

    FilePane *rp = FilePane_new(app, right_path, 2);
    if (!rp) return false;
    app->right_pane = (uint64_t)(uintptr_t)rp;

    nav_state_init((const char *const *)envp);
    Config *cfg = config_get();
    if (cfg->hidden >= 0) {
        DirModel *lm = (DirModel *)(uintptr_t)lp->model;
        DirModel *rm = (DirModel *)(uintptr_t)rp->model;
        lm->show_hidden = cfg->hidden;
        DirModel_apply_filter(lm);
        rm->show_hidden = cfg->hidden;
        DirModel_apply_filter(rm);
    }
    if (cfg->sort >= 0) {
        DirModel *lm = (DirModel *)(uintptr_t)lp->model;
        DirModel *rm = (DirModel *)(uintptr_t)rp->model;
        lm->sort_mode = cfg->sort;
        DirModel_sort(lm);
        rm->sort_mode = cfg->sort;
        DirModel_sort(rm);
    }

    PreviewPane *prv = PreviewPane_new(app);
    if (!prv) return false;
    app->preview_pane = (uint64_t)(uintptr_t)prv;
    App_set_active_pane(app, lp);
    return true;
}

App *App_new(const char *left_path, const char *right_path, char **envp, int lang_override)
{
    g_git_defer = 1;
    App *app = (App *)Object_alloc(&App_vtbl, sizeof(App));
    if (!app) return nullptr;
    if (!app_init_core(app, envp, lang_override) ||
        !app_init_panes(app, left_path, right_path, envp)) {
        Object_free((Object *)app);
        return nullptr;
    }
    App_layout(app);
    if (g_cfg_warn) {
        const LangStrings *ls = i18n_get();
        App_set_status(app, ls->s[LS_cfg_truncated], MSG_WARN);
    }
    return app;
}

void App_dtor(App *app)
{
    Object_free((Object *)(uintptr_t)app->active_dialog);
    Object_free((Object *)(uintptr_t)app->preview_pane);
    Object_free((Object *)(uintptr_t)app->right_pane);
    Object_free((Object *)(uintptr_t)app->left_pane);
    Object_free((Object *)(uintptr_t)app->status_bar);
    Object_free((Object *)(uintptr_t)app->func_bar);
    Object_free((Object *)(uintptr_t)app->header_bar);
    Object_free((Object *)(uintptr_t)app->screen);
    dirwatch_cleanup();
    nav_state_cleanup();
    du_cache_cleanup();
    du_links_cleanup();
}
