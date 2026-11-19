/* tests/harness/app_keys_cli.c - A3.1 differential harness for src/app/app_keys.c. */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_fs.h"
#include "duop_keys.h"
#include "duop_oop.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "script_cli.h"

static void sc_nl(void) { sc_put("\n"); }

static int64_t sc_tok_i64(char **pp)
{
    char *p = *pp;
    while (*p == ' ') p++;
    int neg = (*p == '-');
    if (neg) p++;
    int64_t v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (*p++ - '0');
    *pp = p;
    return neg ? -v : v;
}

typedef struct SpyPane {
    FilePane fp;
    int tag;
} SpyPane;

static int spy_on_key(Widget *self, void *evt)
{
    Event *e = (Event *)evt;
    sc_put("vcall on_key id="); sc_num(self->id); sc_put(" k="); sc_num(e->key); sc_nl();
    return 1;
}

static const WidgetVtbl g_spy_vtbl = {
    .base = { .super = nullptr, .class_name = "SpyKey", .inst_size = sizeof(SpyPane), .dtor = nullptr },
    .on_key = spy_on_key,
};

static App g_app;
static SpyPane g_lp, g_rp;
static Widget g_dlg;
static DirModel g_lm, g_rm;

static int g_bind_rc;
static int g_term_rc;
static int g_ext_rc;
static int g_tab_close_rc;

const LangStrings *i18n_get(void) { return &lang_en_table; }

FilePane *get_inactive_pane(App *app)
{
    return (FilePane *)(uintptr_t)app->active_pane == &g_lp.fp ? &g_rp.fp : &g_lp.fp;
}

#define STUB0(fn) void fn(App *app) { sc_put("call " #fn " "); sc_num(app != nullptr); sc_nl(); }
STUB0(App_layout)
STUB0(App_cmd_quit)
STUB0(App_cmd_toggle_preview)
STUB0(App_cmd_toggle_hidden)
STUB0(App_cmd_cycle_theme)
STUB0(App_cmd_toggle_lang)
STUB0(App_cmd_start_filter)
STUB0(App_cmd_newfile)
STUB0(App_cmd_goto)
STUB0(App_cmd_shell)
STUB0(App_cmd_trash)
STUB0(App_task_show)
STUB0(App_cmd_usermenu)
STUB0(App_sync_preview)

void App_dispatch_action(App *app, int act) { sc_put("call App_dispatch_action "); sc_num(app != nullptr); sc_put(" a="); sc_num(act); sc_nl(); }
void App_dispatch_f_action(App *app, int idx) { sc_put("call App_dispatch_f_action "); sc_num(app != nullptr); sc_put(" i="); sc_num(idx); sc_nl(); }
void App_set_active_pane(App *app, FilePane *p) { sc_put("call App_set_active_pane "); sc_num(app != nullptr); sc_put(" p="); sc_num(p == &g_rp.fp ? 2 : 1); sc_nl(); }
void reload_both_panes(App *app, const char *f) { sc_put("call reload_both_panes "); sc_num(app != nullptr); sc_put(" f="); sc_num(f != nullptr); sc_nl(); }
void App_set_status(App *app, const char *m, int k)
{
    sc_put("call App_set_status "); sc_num(app != nullptr); sc_put(" k="); sc_num(k);
    sc_put(" m=|"); sc_put(m ? m : "-"); sc_put("|\n");
}
int app_handle_ext_key(App *app, int key, int mods)
{
    sc_put("call app_handle_ext_key "); sc_num(app != nullptr); sc_put(" k="); sc_num(key); sc_put(" m="); sc_num(mods); sc_nl();
    return g_ext_rc;
}
BookmarkDialog *BookmarkDialog_new(App *app, int mode)
{
    sc_put("call BookmarkDialog_new "); sc_num(app != nullptr); sc_put(" m="); sc_num(mode); sc_nl();
    return (BookmarkDialog *)(uintptr_t)(0x9000 + mode);
}

int fake_config_lookup_bind(int key, int mods) { (void)key; (void)mods; return g_bind_rc; }
int fake_term_on_key(void *app, void *evt) { (void)app; (void)evt; return g_term_rc; }
int fake_FilePane_tab_new(FilePane *p) { sc_put("call FilePane_tab_new "); sc_num(p != nullptr); sc_nl(); return 1; }
int fake_FilePane_tab_close(FilePane *p, int idx)
{
    sc_put("call FilePane_tab_close "); sc_num(p != nullptr); sc_put(" i="); sc_num(idx); sc_nl();
    return g_tab_close_rc;
}
void fake_FilePane_ensure_visible(FilePane *p) { sc_put("call FilePane_ensure_visible "); sc_num(p != nullptr); sc_nl(); }
void fake_DirModel_apply_filter(DirModel *m) { sc_put("call DirModel_apply_filter f=|"); sc_put(m->filter); sc_put("|\n"); }
void fake_DirModel_cancel_load(DirModel *m) { sc_put("call DirModel_cancel_load m="); sc_num(m == &g_lm ? 1 : 2); sc_nl(); }

#define config_lookup_bind fake_config_lookup_bind
#define term_on_key fake_term_on_key
#define FilePane_tab_new fake_FilePane_tab_new
#define FilePane_tab_close fake_FilePane_tab_close
#define FilePane_ensure_visible fake_FilePane_ensure_visible
#define DirModel_apply_filter fake_DirModel_apply_filter
#define DirModel_cancel_load fake_DirModel_cancel_load
#include KEYS_SRC
#undef config_lookup_bind
#undef term_on_key
#undef FilePane_tab_new
#undef FilePane_tab_close
#undef FilePane_ensure_visible
#undef DirModel_apply_filter
#undef DirModel_cancel_load

#ifdef __x86_64__
void ref_handle_key(App *app, Event *evt);
#endif

static int g_use_ref;
#ifdef __x86_64__
#define CALL(fn, ...) (g_use_ref ? ref_##fn(__VA_ARGS__) : fn(__VA_ARGS__))
#else
#define CALL(fn, ...) fn(__VA_ARGS__)
#endif

static void init_state(void)
{
    mem_zero(&g_app, sizeof g_app);
    mem_zero(&g_lp, sizeof g_lp);
    mem_zero(&g_rp, sizeof g_rp);
    mem_zero(&g_dlg, sizeof g_dlg);
    mem_zero(&g_lm, sizeof g_lm);
    mem_zero(&g_rm, sizeof g_rm);
    g_lp.fp.base.base.vptr = &g_spy_vtbl.base; g_lp.fp.base.id = 1;
    g_rp.fp.base.base.vptr = &g_spy_vtbl.base; g_rp.fp.base.id = 2;
    g_dlg.base.vptr = &g_spy_vtbl.base; g_dlg.id = 99;
    g_lp.fp.model = (uint64_t)(uintptr_t)&g_lm;
    g_rp.fp.model = (uint64_t)(uintptr_t)&g_rm;
    g_app.left_pane = (uint64_t)(uintptr_t)&g_lp.fp;
    g_app.right_pane = (uint64_t)(uintptr_t)&g_rp.fp;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_lp.fp;
    g_bind_rc = -1; g_term_rc = 0; g_ext_rc = 0; g_tab_close_rc = 1;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    g_use_ref = (argc >= 2 && argv[1][0] == 'r');
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *p = line;
        char tag = *p++;
        init_state();
        if (tag == 'K') {
            /* K <lat> <mods> <has_dlg> <bind> <term> <ext> <rmode> <load_mask> <has_flt> <tc_rc> */
            Event ev; mem_zero(&ev, sizeof ev);
            ev.lat = (int32_t)sc_tok_i64(&p);
            ev.key = ev.lat;
            ev.mods = (int32_t)sc_tok_i64(&p);
            if (sc_tok_i64(&p)) g_app.active_dialog = (uint64_t)(uintptr_t)&g_dlg;
            g_bind_rc = (int)sc_tok_i64(&p);
            g_term_rc = (int)sc_tok_i64(&p);
            g_ext_rc = (int)sc_tok_i64(&p);
            g_app.right_mode = (uint32_t)sc_tok_i64(&p);
            int lm = (int)sc_tok_i64(&p);
            g_lm.is_loading = (lm & 1) ? 1u : 0u;
            g_rm.is_loading = (lm & 2) ? 1u : 0u;
            if (sc_tok_i64(&p)) (void)str_copy(g_lm.filter, "*.c", sizeof g_lm.filter);
            g_tab_close_rc = (int)sc_tok_i64(&p);
            g_lp.fp.cursor = 4; g_lp.fp.scroll = 2;
            CALL(handle_key, &g_app, &ev);
            sc_put("HK ad="); sc_num(g_app.active_dialog == (uint64_t)(uintptr_t)&g_dlg ? -1 : (int64_t)g_app.active_dialog);
            sc_put(" nr="); sc_num(g_app.need_redraw);
            sc_put(" cur="); sc_num(g_lp.fp.cursor); sc_put(" scr="); sc_num(g_lp.fp.scroll); sc_nl();
        }
    }
    sc_flush();
    return 0;
}
