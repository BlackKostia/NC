/* tests/harness/app_du_cmd_cli.c - A1.2 differential harness for app_du.c and app_cmdline.c. */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_config_expand.h"
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
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

static void sc_tok_str(char **pp, char *dst, size_t cap)
{
    char *p = *pp;
    while (*p == ' ') p++;
    size_t i = 0;
    while (*p && *p != ' ') {
        if (i + 1 < cap) dst[i++] = *p;
        p++;
    }
    dst[i] = '\0';
    *pp = p;
}

/* ---- shared fakes / logs ---- */
static const char *g_env_val;
static int64_t g_now_ms;
static int (*g_du_cb)(void *, DuProgress *);
static void *g_du_ctx;

static Event g_evts[8];
static int g_evt_cnt, g_evt_pos;
static int g_win_w = 100, g_win_h = 30;
static int g_dlg_oom;

static int g_oom_fail_at;   /* 1-based mem_alloc call to fail, 0 = never */
static int g_alloc_n;

static uint32_t g_sel_mode; /* 0 = none, 1 = 3 mixed, 2 = overflow 60000B */
static FileEntry g_fe[700];
static char g_big_name[128];

static const LangStrings *fake_i18n_get(void) { return &lang_en_table; }
const LangStrings *i18n_get(void) { return fake_i18n_get(); }

uint64_t parse_uint(const char *p)
{
    uint32_t v = 0, d;
    while ((d = (uint32_t)(uint8_t)*p - '0') <= 9u) { v = v * 10u + d; p++; }
    return (uint64_t)v;
}

const char *fake_cfg_getenv(char **envp, const char *key_eq)
{
    sc_put("call cfg_getenv env="); sc_num(envp != nullptr); sc_put(" k="); sc_put(key_eq); sc_nl();
    return g_env_val;
}

void fake_du_set_progress(int (*cb)(void *, DuProgress *), void *ctx)
{
    g_du_cb = cb; g_du_ctx = ctx;
    sc_put("call du_set_progress cb="); sc_num(cb != nullptr); sc_put(" ctx="); sc_num(ctx != nullptr); sc_nl();
}

int fake_input_poll_event(Event *evt, int timeout_ms)
{
    if (g_evt_pos >= g_evt_cnt) return 0;
    *evt = g_evts[g_evt_pos++];
    sc_put("call input_poll_event t="); sc_num(evt->type); sc_put(" k="); sc_num(evt->key);
    sc_put(" to="); sc_num(timeout_ms); sc_nl();
    return 1;
}

int64_t fake_os_clock_ms(void) { return g_now_ms; }

int fake_os_poll_in(int fd, int timeout_ms)
{
    sc_put("call os_poll_in fd="); sc_num(fd); sc_put(" ms="); sc_num(timeout_ms); sc_nl();
    return 0;
}

void fake_sys_get_winsize(int *w, int *h) { *w = g_win_w; *h = g_win_h; sc_put("call sys_get_winsize\n"); }

void fake_term_caps_refresh(int w, int h)
{
    sc_put("call term_caps_refresh "); sc_num(w); sc_put("x"); sc_num(h); sc_nl();
}

void App_layout(App *app) { sc_put("call App_layout "); sc_num(app != nullptr); sc_nl(); }
void App_render(App *app) { sc_put("call App_render "); sc_num(app != nullptr); sc_nl(); }

void App_set_status(App *app, const char *msg, int kind)
{
    sc_put("call App_set_status "); sc_num(app != nullptr); sc_put(" k="); sc_num(kind);
    sc_put(" m=|"); sc_put(msg ? msg : "(null)"); sc_put("|\n");
}

static void fake_dlg_dtor(Object *self) { sc_put("call fake_dlg_dtor "); sc_num(self != nullptr); sc_nl(); }
static const ObjectVtbl g_fake_dlg_vtbl = { .super = nullptr, .class_name = "FakeDuDlg", .inst_size = sizeof(Object), .dtor = fake_dlg_dtor };

Dialog *DuProgressDialog_new(App *app)
{
    sc_put("call DuProgressDialog_new "); sc_num(app != nullptr); sc_put(" oom="); sc_num(g_dlg_oom); sc_nl();
    if (g_dlg_oom) return nullptr;
    return (Dialog *)Object_alloc(&g_fake_dlg_vtbl, sizeof(Object));
}

void DuProgressDialog_layout(Widget *self, int x, int y, int w, int h)
{
    sc_put("call DuProgressDialog_layout "); sc_num(self != nullptr); sc_put(" ");
    sc_num(x); sc_put(","); sc_num(y); sc_put(","); sc_num(w); sc_put(","); sc_num(h); sc_nl();
}

int dir_du_populate(DirModel *m) { sc_put("call dir_du_populate "); sc_num(m != nullptr); sc_nl(); return 1; }
void du_leave(DirModel *m) { sc_put("call du_leave "); sc_num(m != nullptr); sc_nl(); }

/* ---- app_cmdline fakes ---- */
static FilePane g_lp, g_rp;
static DirModel g_lm, g_rm;
static ScreenBuffer g_scr;
static App g_app;

void *fake_mem_alloc(size_t n)
{
    g_alloc_n++;
    if (g_oom_fail_at > 0 && g_alloc_n == g_oom_fail_at) return nullptr;
    return mem_alloc(n);
}

FilePane *get_inactive_pane(App *app)
{
    return (FilePane *)(uintptr_t)app->active_pane == &g_lp ? &g_rp : &g_lp;
}

FileEntry *fake_DirModel_get_entry(DirModel *m, intptr_t idx)
{
    (void)m;
    if (idx < 0 || idx >= 700) return nullptr;
    return &g_fe[idx];
}

const char *fake_DirModel_entry_name(const DirModel *m, const FileEntry *e)
{
    (void)m;
    if (g_sel_mode >= 2) return g_big_name;
    intptr_t idx = e - g_fe;
    if (idx == 0) return "alpha.txt";
    if (idx == 1) return "skip.bin";
    return "beta space.c";
}

int fake_sys_exec_sh_arg(const char *script, const char *arg1, char **envp)
{
    char cwd[PATH_MAX];
    if (os_getcwd(cwd, sizeof cwd) < 0) cwd[0] = '\0';
    sc_put("call sys_exec_sh_arg cmd=|"); sc_put(script ? script : "(null)");
    sc_put("| arg1=|"); sc_put(arg1 ? arg1 : "(null)");
    sc_put("| env="); sc_num(envp != nullptr);
    sc_put(" in_active="); sc_num(str_cmp(cwd, g_lm.path) == 0); sc_nl();
    return 0;
}

void App_reload_panes(App *app, int keep_cursor)
{
    sc_put("call App_reload_panes "); sc_num(app != nullptr); sc_put(" keep="); sc_num(keep_cursor); sc_nl();
}

const char *fs_errno_message(int neg_errno)
{
    if (neg_errno == -ENOMEM) return "ERR_NOMEM";
    if (neg_errno == -ENOENT) return "ERR_NOENT";
    return "ERR_OTHER";
}

/* ---- include C modules under test with redirected fakes ---- */
#define cfg_getenv fake_cfg_getenv
#define du_set_progress fake_du_set_progress
#define input_poll_event fake_input_poll_event
#define os_clock_ms fake_os_clock_ms
#define os_poll_in fake_os_poll_in
#define sys_get_winsize fake_sys_get_winsize
#define term_caps_refresh fake_term_caps_refresh
#include DU_SRC
#undef cfg_getenv
#undef du_set_progress
#undef input_poll_event
#undef os_clock_ms
#undef os_poll_in
#undef sys_get_winsize
#undef term_caps_refresh

#define mem_alloc fake_mem_alloc
#define DirModel_get_entry fake_DirModel_get_entry
#define DirModel_entry_name fake_DirModel_entry_name
#define sys_exec_sh_arg fake_sys_exec_sh_arg
#include CMD_SRC
#undef mem_alloc
#undef DirModel_get_entry
#undef DirModel_entry_name
#undef sys_exec_sh_arg

#ifdef __x86_64__
void ref_App_du_init(App *app);
void ref_du_toggle(App *app);
void ref_App_run_expanded_cmd(App *app, const char *tmpl, const char *cur_name, const char *cur_path);
#endif

static int g_use_ref;
#ifdef __x86_64__
#define CALL(fn, ...) (g_use_ref ? ref_##fn(__VA_ARGS__) : fn(__VA_ARGS__))
#else
#define CALL(fn, ...) fn(__VA_ARGS__)
#endif

static void init_app(void)
{
    mem_zero(&g_app, sizeof g_app);
    mem_zero(&g_lp, sizeof g_lp);
    mem_zero(&g_rp, sizeof g_rp);
    mem_zero(&g_lm, sizeof g_lm);
    mem_zero(&g_rm, sizeof g_rm);
    mem_zero(&g_scr, sizeof g_scr);
    static char *fake_env[] = { "HOME=/tmp", nullptr };
    g_app.envp = (uint64_t)(uintptr_t)fake_env;
    g_app.left_pane = (uint64_t)(uintptr_t)&g_lp;
    g_app.right_pane = (uint64_t)(uintptr_t)&g_rp;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_lp;
    g_app.screen = (uint64_t)(uintptr_t)&g_scr;
    g_lp.model = (uint64_t)(uintptr_t)&g_lm;
    g_rp.model = (uint64_t)(uintptr_t)&g_rm;
    g_app.term_w = 80;
    g_app.term_h = 24;
    for (int i = 0; i < 119; i++) g_big_name[i] = 'x';
    g_big_name[119] = '\0';
}

static void handle_du_cmd(char *p)
{
    int sub = (int)sc_tok_i64(&p);
    if (sub == 0) {
        /* D 0 <env_mode: 0=NULL, 1=empty, 2=num> [val] */
        int em = (int)sc_tok_i64(&p);
        char buf[32];
        if (em == 0) g_env_val = nullptr;
        else if (em == 1) g_env_val = "";
        else { sc_tok_str(&p, buf, sizeof buf); g_env_val = buf; }
        g_du_cb = nullptr; g_du_ctx = nullptr;
        CALL(App_du_init, &g_app);
    } else if (sub == 1) {
        /* D 1 <phase> <start_ms> <now_ms> <other_dlg> <dlg_oom> <evt_kind: 0=none, 1=resize, 2=other+esc, 3=other_only> */
        DuProgress dp; mem_zero(&dp, sizeof dp);
        dp.phase = (int32_t)sc_tok_i64(&p);
        dp.start_ms = sc_tok_i64(&p);
        g_now_ms = sc_tok_i64(&p);
        int other = (int)sc_tok_i64(&p);
        g_dlg_oom = (int)sc_tok_i64(&p);
        int ek = (int)sc_tok_i64(&p);
        if (other && g_app.active_dialog == 0) g_app.active_dialog = 0x1234;
        if (!other && g_app.active_dialog == 0x1234) g_app.active_dialog = 0;
        g_app.need_redraw = 0;
        g_evt_cnt = 0; g_evt_pos = 0;
        if (ek == 1) {
            g_evts[0] = (Event){ .type = EVT_RESIZE };
            g_evt_cnt = 1;
        } else if (ek == 2) {
            g_evts[0] = (Event){ .type = EVT_KEY, .key = 'a' };
            g_evts[1] = (Event){ .type = EVT_KEY, .key = KEY_ESC };
            g_evt_cnt = 2;
        } else if (ek == 3) {
            g_evts[0] = (Event){ .type = EVT_MOUSE };
            g_evts[1] = (Event){ .type = EVT_KEY, .key = 'x' };
            g_evt_cnt = 2;
        }
        int rc = g_du_cb ? g_du_cb(g_du_ctx, &dp) : -9;
        sc_put("DP rc="); sc_num(rc); sc_put(" ad="); sc_num(g_app.active_dialog != 0);
        sc_put(" rd="); sc_num(g_app.need_redraw); sc_put(" w="); sc_num(g_app.term_w); sc_nl();
    } else if (sub == 2) {
        /* D 2 <du_mode> */
        g_lm.du_mode = (uint32_t)sc_tok_i64(&p);
        g_app.need_redraw = 0;
        CALL(du_toggle, &g_app);
        sc_put("DT rd="); sc_num(g_app.need_redraw); sc_nl();
    }
}

static void handle_cmd_cmd(char *p)
{
    /* C <sel_mode> <oom_at> <dir> <inact_dir> <cur_name_or_-> <cur_path_or_-> <tmpl> */
    g_sel_mode = (uint32_t)sc_tok_i64(&p);
    g_oom_fail_at = (int)sc_tok_i64(&p);
    g_alloc_n = 0;
    char dir[256], idir[256], cname[64], cpath[128], tmpl[256];
    sc_tok_str(&p, dir, sizeof dir);
    sc_tok_str(&p, idir, sizeof idir);
    sc_tok_str(&p, cname, sizeof cname);
    sc_tok_str(&p, cpath, sizeof cpath);
    sc_tok_str(&p, tmpl, sizeof tmpl);
    (void)str_copy(g_lm.path, dir, sizeof g_lm.path);
    (void)str_copy(g_rm.path, idir, sizeof g_rm.path);
    mem_zero(g_fe, sizeof g_fe);
    if (g_sel_mode == 0) {
        g_lm.count = 0;
    } else if (g_sel_mode == 1) {
        g_lm.count = 3;
        g_fe[0].flags = FE_SELECTED;
        g_fe[1].flags = 0;
        g_fe[2].flags = FE_SELECTED;
    } else {
        uint64_t cnt = (g_sel_mode == 2) ? 600 : (g_sel_mode == 4) ? 500 : 450;
        g_lm.count = cnt;
        for (uint64_t i = 0; i < cnt; i++) g_fe[i].flags = FE_SELECTED;
    }
    g_scr.force_full = 0;
    char before[PATH_MAX], after[PATH_MAX];
    if (os_getcwd(before, sizeof before) < 0) before[0] = '\0';
    const char *cn = (cname[0] == '-' && cname[1] == '\0') ? nullptr : cname;
    const char *cp = (cpath[0] == '-' && cpath[1] == '\0') ? nullptr : cpath;
    CALL(App_run_expanded_cmd, &g_app, tmpl, cn, cp);
    if (os_getcwd(after, sizeof after) < 0) after[0] = '\0';
    sc_put("AC ff="); sc_num(g_scr.force_full);
    sc_put(" cwd_restored="); sc_num(str_cmp(before, after) == 0); sc_nl();
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp;
    (void)auxv;
    g_use_ref = (argc >= 2 && argv[1][0] == 'r');
    init_app();
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *p = line;
        char tag = *p++;
        if (tag == 'D') handle_du_cmd(p);
        else if (tag == 'C') handle_cmd_cmd(p);
    }
    sc_flush();
    return 0;
}
