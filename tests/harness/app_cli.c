/* tests/harness/app_cli.c - differential harness for src/app/app.c vs app_reference.s (A3.4). */
#include "duop_abi.h"
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"
#include "script_cli.h"

static int64_t parse_i64(const char **pp) {
    const char *p = *pp;
    while (*p == ' ') p++;
    int neg = 0;
    if (*p == '-') { neg = 1; p++; }
    uint64_t v = 0;
    p = sc_dec(p, &v);
    *pp = p;
    return neg ? -(int64_t)v : (int64_t)v;
}

static void parse_tok(const char **pp, char *dst, size_t cap) {
    const char *p = *pp;
    while (*p == ' ') p++;
    size_t n = 0;
    while (*p && *p != ' ' && n + 1 < cap) dst[n++] = *p++;
    dst[n] = 0;
    while (*p && *p != ' ') p++;
    *pp = p;
}

const ObjectVtbl Object_vtbl = { nullptr, "Object", sizeof(Object), nullptr };

int g_git_defer;
int32_t g_cfg_warn;
static Config g_cfg;
static Theme g_theme;
static LangStrings g_lang;
static char g_trunc_msg[] = "CFG_TRUNCATED";

static int g_fail_mask;
static int g_find_ret;
static int g_detect_ret;
static int g_lang_idx;
static int g_win_w, g_win_h;
static char *g_fake_envp[2] = { "LANG=en_US.UTF-8", nullptr };

typedef struct {
    Object base;
    const char *tag;
} StubObj;

static void stub_obj_dtor(Object *o) {
    StubObj *s = (StubObj *)o;
    sc_put("dtor "); sc_put(s->tag); sc_put("\n");
}
static const ObjectVtbl g_stub_vtbl = { &Object_vtbl, "Stub", sizeof(StubObj), stub_obj_dtor };

static StubObj g_screen, g_hdr, g_fbar, g_sbar, g_prev, g_dlg;
static FilePane g_lpane, g_rpane;
static DirModel g_lmodel, g_rmodel;
static App g_app_slot;

static void init_stub_obj(StubObj *o, const char *tag) {
    o->base.vptr = &g_stub_vtbl;
    o->tag = tag;
}

static void init_pane(FilePane *p, DirModel *m, int id) {
    mem_zero(p, sizeof(*p));
    mem_zero(m, sizeof(*m));
    p->base.base.vptr = &g_stub_vtbl;
    p->base.id = id;
    p->model = (uint64_t)(uintptr_t)m;
    m->show_hidden = 9;
    m->sort_mode = 9;
}

static const char *obj_tag(Object *o) {
    if (!o) return "null";
    if (o == (Object *)&g_app_slot) return "App";
    if (o == (Object *)&g_screen) return "screen";
    if (o == (Object *)&g_hdr) return "header";
    if (o == (Object *)&g_fbar) return "fbar";
    if (o == (Object *)&g_sbar) return "sbar";
    if (o == (Object *)&g_lpane) return "lpane";
    if (o == (Object *)&g_rpane) return "rpane";
    if (o == (Object *)&g_prev) return "preview";
    if (o == (Object *)&g_dlg) return "dialog";
    return "other";
}

void *Object_alloc(const ObjectVtbl *vtbl, size_t size) {
    sc_put("Object_alloc sz="); sc_num((int64_t)size);
    sc_put(" cls="); sc_put(vtbl->class_name); sc_put("\n");
    if (g_fail_mask & 1) return nullptr;
    mem_zero(&g_app_slot, sizeof(g_app_slot));
    g_app_slot.base.vptr = vtbl;
    return &g_app_slot;
}

void Object_free(Object *o) {
    if (!o) return;
    sc_put("Object_free "); sc_put(obj_tag(o)); sc_put("\n");
    if (o == (Object *)&g_app_slot && o->vptr && o->vptr->dtor) o->vptr->dtor(o);
}

void config_load(char **envp) { sc_put("config_load env="); sc_num(envp == g_fake_envp); sc_put("\n"); }
Config *config_get(void) { sc_put("config_get\n"); return &g_cfg; }
void kbd_layout_load(char **envp) { sc_put("kbd_layout_load env="); sc_num(envp == g_fake_envp); sc_put("\n"); }
void App_du_init(App *a) { sc_put("App_du_init app="); sc_num(a == &g_app_slot); sc_put("\n"); }
void DirModel_init_env(char **envp) { sc_put("DirModel_init_env env="); sc_num(envp == g_fake_envp); sc_put("\n"); }
void nav_state_init(const char *const *envp) { sc_put("nav_state_init env="); sc_num((char **)envp == g_fake_envp); sc_put("\n"); }

int i18n_find(const char *id) {
    sc_put("i18n_find id="); sc_put(id); sc_put(" -> "); sc_num(g_find_ret); sc_put("\n");
    return g_find_ret;
}
int i18n_detect_env(char **envp) {
    sc_put("i18n_detect_env env="); sc_num(envp == g_fake_envp);
    sc_put(" -> "); sc_num(g_detect_ret); sc_put("\n");
    return g_detect_ret;
}
const LangStrings *i18n_set_lang(int idx) {
    sc_put("i18n_set_lang "); sc_num(idx); sc_put("\n");
    g_lang_idx = idx;
    return &g_lang;
}
const LangStrings *i18n_get(void) { sc_put("i18n_get\n"); return &g_lang; }
int i18n_get_idx(void) { return g_lang_idx; }
const Theme *theme_get(int idx) { sc_put("theme_get "); sc_num(idx); sc_put("\n"); return &g_theme; }

void sys_get_winsize(int *w, int *h) {
    *w = g_win_w;
    *h = g_win_h;
    sc_put("sys_get_winsize "); sc_num(g_win_w); sc_put("x"); sc_num(g_win_h); sc_put("\n");
}

ScreenBuffer *ScreenBuffer_new(int w, int h) {
    sc_put("ScreenBuffer_new "); sc_num(w); sc_put("x"); sc_num(h); sc_put("\n");
    if (g_fail_mask & 2) return nullptr;
    init_stub_obj(&g_screen, "screen");
    return (ScreenBuffer *)&g_screen;
}
HeaderBar *HeaderBar_new(App *a) {
    sc_put("HeaderBar_new "); sc_num(a == &g_app_slot); sc_put("\n");
    if (g_fail_mask & 4) return nullptr;
    init_stub_obj(&g_hdr, "header");
    return (HeaderBar *)&g_hdr;
}
FunctionBar *FunctionBar_new(App *a) {
    sc_put("FunctionBar_new "); sc_num(a == &g_app_slot); sc_put("\n");
    if (g_fail_mask & 8) return nullptr;
    init_stub_obj(&g_fbar, "fbar");
    return (FunctionBar *)&g_fbar;
}
StatusBar *StatusBar_new(App *a) {
    sc_put("StatusBar_new "); sc_num(a == &g_app_slot); sc_put("\n");
    if (g_fail_mask & 16) return nullptr;
    init_stub_obj(&g_sbar, "sbar");
    return (StatusBar *)&g_sbar;
}
FilePane *FilePane_new(App *a, const char *path, int id) {
    sc_put("FilePane_new "); sc_num(a == &g_app_slot);
    sc_put(" id="); sc_num(id); sc_put(" p="); sc_put(path ? path : "null"); sc_put("\n");
    if (id == 1) {
        if (g_fail_mask & 32) return nullptr;
        init_pane(&g_lpane, &g_lmodel, 1);
        return &g_lpane;
    }
    if (g_fail_mask & 64) return nullptr;
    init_pane(&g_rpane, &g_rmodel, 2);
    return &g_rpane;
}
PreviewPane *PreviewPane_new(App *a) {
    sc_put("PreviewPane_new "); sc_num(a == &g_app_slot); sc_put("\n");
    if (g_fail_mask & 128) return nullptr;
    init_stub_obj(&g_prev, "preview");
    return (PreviewPane *)&g_prev;
}

void DirModel_apply_filter(DirModel *m) {
    sc_put("DirModel_apply_filter "); sc_put(m == &g_lmodel ? "L" : "R");
    sc_put(" h="); sc_num(m->show_hidden); sc_put("\n");
}
void DirModel_sort(DirModel *m) {
    sc_put("DirModel_sort "); sc_put(m == &g_lmodel ? "L" : "R");
    sc_put(" s="); sc_num(m->sort_mode); sc_put("\n");
}
void App_set_active_pane(App *a, FilePane *p) {
    sc_put("App_set_active_pane "); sc_num(a == &g_app_slot);
    sc_put(" "); sc_put(obj_tag((Object *)p)); sc_put("\n");
    a->active_pane = (uint64_t)(uintptr_t)p;
}
void App_layout(App *a) { sc_put("App_layout "); sc_num(a == &g_app_slot); sc_put("\n"); }
void App_set_status(App *a, const char *msg, int kind) {
    sc_put("App_set_status "); sc_num(a == &g_app_slot);
    sc_put(" k="); sc_num(kind); sc_put(" m="); sc_put(msg ? msg : "null"); sc_put("\n");
}
void dirwatch_cleanup(void) { sc_put("dirwatch_cleanup\n"); }
void nav_state_cleanup(void) { sc_put("nav_state_cleanup\n"); }
void du_cache_cleanup(void) { sc_put("du_cache_cleanup\n"); }
void du_links_cleanup(void) { sc_put("du_links_cleanup\n"); }

/* Include the C implementation under test directly (allows mutant injection). */
#include APP_SRC

#ifdef __x86_64__
extern const ObjectVtbl ref_App_vtbl;
extern App *ref_App_new(const char *left, const char *right, char **envp, int lang_override);
extern void ref_App_dtor(App *a);
#endif

static void run_vtbl(int use_ref) {
    const ObjectVtbl *v = &App_vtbl;
    void (*dtor)(App *) = App_dtor;
#ifdef __x86_64__
    if (use_ref) { v = &ref_App_vtbl; dtor = ref_App_dtor; }
#else
    (void)use_ref;
#endif
    sc_put("VTBL cls="); sc_put(v->class_name);
    sc_put(" sup="); sc_num(v->super == &Object_vtbl);
    sc_put(" sz="); sc_num((int64_t)v->inst_size);
    sc_put(" dtor="); sc_num((void *)v->dtor == (void *)dtor);
    sc_put("\n");
}

static void run_new(int use_ref, const char *p) {
    g_fail_mask = (int)parse_i64(&p);
    mem_zero(&g_cfg, sizeof(g_cfg));
    g_cfg.theme = (int32_t)parse_i64(&p);
    g_find_ret = (int)parse_i64(&p);
    g_detect_ret = (int)parse_i64(&p);
    int lang_ovr = (int)parse_i64(&p);
    g_cfg.hidden = (int32_t)parse_i64(&p);
    g_cfg.sort = (int32_t)parse_i64(&p);
    g_cfg_warn = (int32_t)parse_i64(&p);
    g_win_w = (int)parse_i64(&p);
    g_win_h = (int)parse_i64(&p);
    int has_dlg = (int)parse_i64(&p);
    char lang_id[16], left[32], right[32];
    parse_tok(&p, lang_id, sizeof(lang_id));
    parse_tok(&p, left, sizeof(left));
    parse_tok(&p, right, sizeof(right));
    str_copy(g_cfg.lang_id, lang_id, sizeof(g_cfg.lang_id));
    g_lang.s[LS_cfg_truncated] = g_trunc_msg;
    g_git_defer = 0;

    const char *lp = !str_cmp(left, "-") ? nullptr : left;
    const char *rp = !str_cmp(right, "-") ? nullptr : right;
    App *a = nullptr;
#ifdef __x86_64__
    a = use_ref ? ref_App_new(lp, rp, g_fake_envp, lang_ovr)
                : App_new(lp, rp, g_fake_envp, lang_ovr);
#else
    (void)use_ref;
    a = App_new(lp, rp, g_fake_envp, lang_ovr);
#endif
    if (!a) {
        sc_put("RES NULL gd="); sc_num(g_git_defer); sc_put("\n");
        return;
    }
    FilePane *lpane = (FilePane *)(uintptr_t)a->left_pane;
    FilePane *rpane = (FilePane *)(uintptr_t)a->right_pane;
    DirModel *lm = (DirModel *)(uintptr_t)lpane->model;
    DirModel *rm = (DirModel *)(uintptr_t)rpane->model;
    sc_put("RES OK gd="); sc_num(g_git_defer);
    sc_put(" run="); sc_num(a->running);
    sc_put(" red="); sc_num(a->need_redraw);
    sc_put(" th="); sc_num(a->theme_idx);
    sc_put(" li="); sc_num(a->lang_idx);
    sc_put(" rm="); sc_num(a->right_mode);
    sc_put(" wh="); sc_num(a->term_w); sc_put("x"); sc_num(a->term_h);
    sc_put(" lh="); sc_num(lm->show_hidden);
    sc_put(" rh="); sc_num(rm->show_hidden);
    sc_put(" ls="); sc_num(lm->sort_mode);
    sc_put(" rs="); sc_num(rm->sort_mode);
    sc_put(" ptrs=");
    sc_num((char **)(uintptr_t)a->envp == g_fake_envp);
    sc_num((const Theme *)(uintptr_t)a->theme == &g_theme);
    sc_num((const LangStrings *)(uintptr_t)a->lang == &g_lang);
    sc_num(a->active_pane == a->left_pane);
    sc_put("\n");
    if (has_dlg) {
        init_stub_obj(&g_dlg, "dialog");
        a->active_dialog = (uint64_t)(uintptr_t)&g_dlg;
    }
    Object_free((Object *)a);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv) {
    (void)envp; (void)auxv;
    int use_ref = argc >= 2 && argv[1][0] == 'r';
    char *cur = sc_read_all();
    char *line;
    while ((line = sc_next_line(&cur)) != nullptr) {
        if (!line[0] || line[0] == '#') continue;
        sc_put("--- "); sc_put(line); sc_put("\n");
        if (line[0] == 'V') run_vtbl(use_ref);
        else if (line[0] == 'N') run_new(use_ref, line + 1);
    }
    sc_flush();
    return 0;
}
