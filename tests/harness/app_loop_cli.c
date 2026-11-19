/* tests/harness/app_loop_cli.c - A3.3 differential harness for src/app/app_loop.c. */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_keys.h"
#include "duop_oop.h"
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

typedef struct SpyW {
    Widget w;
    int hit_y;
    int mouse_ret;
} SpyW;

static int spy_hit(Widget *self, int mx, int my)
{
    SpyW *s = (SpyW *)self;
    (void)mx;
    int ok = (my == s->hit_y);
    sc_put("vcall hit id="); sc_num(self->id); sc_put(" -> "); sc_num(ok); sc_nl();
    return ok;
}

static int spy_mouse(Widget *self, void *evt)
{
    SpyW *s = (SpyW *)self;
    Event *e = (Event *)evt;
    sc_put("vcall on_mouse id="); sc_num(self->id); sc_put(" k="); sc_num(e->mouse_kind);
    sc_put(" xy="); sc_num(e->mouse_x); sc_put(","); sc_num(e->mouse_y); sc_nl();
    return s->mouse_ret;
}

static const WidgetVtbl g_spy_vtbl = {
    .base = { .super = nullptr, .class_name = "SpyLoop", .inst_size = sizeof(SpyW), .dtor = nullptr },
    .on_mouse = spy_mouse,
    .hit_test = spy_hit,
};

/* Globals referenced directly by app_loop */
int g_git_defer;
volatile int32_t g_sigterm;

static App g_app;
static FilePane g_lp, g_rp;
static DirModel g_lm, g_rm;
static StatusBar g_sb;
static SpyW g_hdr, g_fb, g_pv, g_dlg;
static int g_lp_hit_y, g_rp_hit_y;

static int64_t g_now_ms;
static int g_ev_to = 500;
static int g_git_ctx_on;
static int g_pane_ext_rc;
static intptr_t g_step_rc[5];
static int g_step_idx;

typedef struct FakeEv { int ret; Event ev; int64_t set_clock; } FakeEv;
static FakeEv g_q[32];
static int g_q_cnt, g_q_pos;

static int fp_hit(Widget *self, int mx, int my)
{
    (void)mx;
    int ok = (my == (self->id == 1 ? g_lp_hit_y : g_rp_hit_y));
    sc_put("vcall hit id="); sc_num(self->id); sc_put(" -> "); sc_num(ok); sc_nl();
    return ok;
}

static int fp_mouse(Widget *self, void *evt)
{
    Event *e = (Event *)evt;
    sc_put("vcall on_mouse id="); sc_num(self->id); sc_put(" k="); sc_num(e->mouse_kind);
    sc_put(" xy="); sc_num(e->mouse_x); sc_put(","); sc_num(e->mouse_y); sc_nl();
    return 1;
}

static const WidgetVtbl g_fp_vtbl = {
    .base = { .super = nullptr, .class_name = "SpyFP", .inst_size = sizeof(FilePane), .dtor = nullptr },
    .on_mouse = fp_mouse,
    .hit_test = fp_hit,
};

void App_events_init(App *a) { sc_put("call App_events_init "); sc_num(a != nullptr); sc_nl(); }
void App_events_shutdown(App *a) { sc_put("call App_events_shutdown "); sc_num(a != nullptr); sc_nl(); }
void App_task_shutdown(App *a) { sc_put("call App_task_shutdown "); sc_num(a != nullptr); sc_nl(); }
void App_task_tick(App *a) { sc_put("call App_task_tick "); sc_num(a != nullptr); sc_nl(); }
void App_events_tick(App *a) { sc_put("call App_events_tick "); sc_num(a != nullptr); sc_nl(); }
void App_task_show(App *a) { sc_put("call App_task_show "); sc_num(a != nullptr); sc_nl(); }
void App_render(App *a) { a->need_redraw = 0; sc_put("call App_render\n"); }
void App_layout(App *a) { sc_put("call App_layout "); sc_num(a->term_w); sc_put("x"); sc_num(a->term_h); sc_nl(); }
void App_sync_preview(App *a) { sc_put("call App_sync_preview "); sc_num(a != nullptr); sc_nl(); }
void app_mouse_hover(App *a, Event *e) { sc_put("call app_mouse_hover "); sc_num(a != nullptr); sc_put(" "); sc_num(e->mouse_x); sc_put(","); sc_num(e->mouse_y); sc_nl(); }
void task_status_errno(App *a, int64_t err) { sc_put("call task_status_errno "); sc_num(a != nullptr); sc_put(" e="); sc_num(err); sc_nl(); }

int App_events_timeout(App *a) { (void)a; return g_ev_to; }

void handle_key(App *a, Event *e)
{
    sc_put("call handle_key k="); sc_num(e->key); sc_nl();
    if (e->key == 'q') a->running = 0;
}

int fake_pane_mouse_ext(App *a, Event *e) { (void)a; (void)e; return g_pane_ext_rc; }

int fake_git_refresh(DirModel *m)
{
    sc_put("call git_refresh m="); sc_num(m == &g_lm ? 1 : 2); sc_put(" def="); sc_num(g_git_defer); sc_nl();
    if (g_git_ctx_on && m == &g_lm) m->git_ctx = (void *)(uintptr_t)0x1;
    return 0;
}

int fake_input_next_event(Event *ev, int timeout_ms)
{
    sc_put("call input_next_event to="); sc_num(timeout_ms); sc_nl();
    if (g_q_pos >= g_q_cnt) return -2;
    FakeEv *f = &g_q[g_q_pos++];
    if (f->set_clock) g_now_ms = f->set_clock;
    *ev = f->ev;
    return f->ret;
}

int64_t fake_sys_clock_ms(void) { return g_now_ms; }

void fake_sys_get_winsize(int *w, int *h) { *w = 120; *h = 40; sc_put("call sys_get_winsize\n"); }
void fake_term_caps_refresh(int w, int h) { sc_put("call term_caps_refresh "); sc_num(w); sc_put("x"); sc_num(h); sc_nl(); }

intptr_t fake_DirModel_step_load(DirModel *m, size_t max_e)
{
    intptr_t rc = g_step_rc[g_step_idx < 5 ? g_step_idx++ : 4];
    sc_put("call DirModel_step_load m="); sc_num(m == &g_lm ? 1 : 2); sc_put(" max="); sc_num((int64_t)max_e);
    sc_put(" -> "); sc_num(rc); sc_nl();
    if (rc <= 0) m->is_loading = 0;
    return rc;
}

#define pane_mouse_ext fake_pane_mouse_ext
#define git_refresh fake_git_refresh
#define input_next_event fake_input_next_event
#define sys_clock_ms fake_sys_clock_ms
#define sys_get_winsize fake_sys_get_winsize
#define term_caps_refresh fake_term_caps_refresh
#define DirModel_step_load fake_DirModel_step_load
#include LOOP_SRC
#undef pane_mouse_ext
#undef git_refresh
#undef input_next_event
#undef sys_clock_ms
#undef sys_get_winsize
#undef term_caps_refresh
#undef DirModel_step_load

#ifdef __x86_64__
void ref_App_run(App *app);
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
    mem_zero(&g_lm, sizeof g_lm);
    mem_zero(&g_rm, sizeof g_rm);
    mem_zero(&g_sb, sizeof g_sb);
    mem_zero(&g_hdr, sizeof g_hdr);
    mem_zero(&g_fb, sizeof g_fb);
    mem_zero(&g_pv, sizeof g_pv);
    mem_zero(&g_dlg, sizeof g_dlg);
    g_lp.base.base.vptr = &g_fp_vtbl.base; g_lp.base.id = 1;
    g_rp.base.base.vptr = &g_fp_vtbl.base; g_rp.base.id = 2;
    g_hdr.w.base.vptr = &g_spy_vtbl.base; g_hdr.w.id = 10; g_hdr.hit_y = 0; g_hdr.mouse_ret = 1;
    g_fb.w.base.vptr = &g_spy_vtbl.base; g_fb.w.id = 11; g_fb.hit_y = 23; g_fb.mouse_ret = 1;
    g_pv.w.base.vptr = &g_spy_vtbl.base; g_pv.w.id = 12; g_pv.hit_y = 5; g_pv.mouse_ret = 1;
    g_dlg.w.base.vptr = &g_spy_vtbl.base; g_dlg.w.id = 99; g_dlg.hit_y = -1; g_dlg.mouse_ret = 1;
    g_sb.base.y = 22;
    g_lp_hit_y = 4; g_rp_hit_y = 5;
    g_lp.model = (uint64_t)(uintptr_t)&g_lm;
    g_rp.model = (uint64_t)(uintptr_t)&g_rm;
    g_app.left_pane = (uint64_t)(uintptr_t)&g_lp;
    g_app.right_pane = (uint64_t)(uintptr_t)&g_rp;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_lp;
    g_app.header_bar = (uint64_t)(uintptr_t)&g_hdr;
    g_app.func_bar = (uint64_t)(uintptr_t)&g_fb;
    g_app.status_bar = (uint64_t)(uintptr_t)&g_sb;
    g_app.preview_pane = (uint64_t)(uintptr_t)&g_pv;
    g_app.running = 1;
    g_git_defer = 1;
    g_sigterm = 0;
    g_now_ms = 1000;
    g_git_ctx_on = 0;
    g_pane_ext_rc = 0;
    g_q_cnt = 0; g_q_pos = 0;
    g_step_idx = 0;
    for (int i = 0; i < 4; i++) g_step_rc[i] = 0;
}

static void push_ev(int ret, int type, int key, int mk, int mx, int my, int64_t clk)
{
    if (g_q_cnt < 32) {
        FakeEv *f = &g_q[g_q_cnt++];
        mem_zero(f, sizeof *f);
        f->ret = ret; f->set_clock = clk;
        f->ev.type = type; f->ev.key = key; f->ev.mouse_kind = mk; f->ev.mouse_x = mx; f->ev.mouse_y = my;
    }
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    g_use_ref = (argc >= 2 && argv[1][0] == 'r');
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *p = line;
        int scen = (int)sc_tok_i64(&p);
        init_state();
        sc_put("=== SCEN "); sc_num(scen); sc_put(" ===\n");
        if (scen == 1) {
            /* sigterm set before loop + git_ctx triggers 2nd render */
            g_git_ctx_on = 1; g_sigterm = 1;
        } else if (scen == 2) {
            /* resize + status expire + EOF exit */
            g_sb.msg_expire_ms = 1000;
            push_ev(1, EVT_RESIZE, 0, 0, 0, 0, 1000);
            push_ev(0, 0, 0, 0, 0, 0, 0);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        } else if (scen == 3) {
            /* key + queued burst drain + quit */
            push_ev(1, EVT_KEY, 'a', 0, 0, 0, 0);
            push_ev(1, EVT_KEY, 'b', 0, 0, 0, 0);
            push_ev(1, EVT_MOUSE, 0, MACT_MOVE, 3, 4, 0);
            push_ev(1, EVT_KEY, 'q', 0, 0, 0, 0);
        } else if (scen == 4) {
            /* mouse routes: dialog, drag left, drag right, pane_mouse_ext, status task click, hdr/fb/lp/rp/pv */
            g_app.active_dialog = (uint64_t)(uintptr_t)&g_dlg;
            push_ev(1, EVT_MOUSE, 0, MACT_PRESS, 1, 1, 0);
            push_ev(0, 0, 0, 0, 0, 0, 0);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        } else if (scen == 5) {
            /* drag scroll left & right */
            g_lp.dragging_scroll = 1;
            push_ev(1, EVT_MOUSE, 0, MACT_DRAG, 2, 3, 0);
            push_ev(0, 0, 0, 0, 0, 0, 0);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        } else if (scen == 6) {
            g_rp.dragging_scroll = 1;
            push_ev(1, EVT_MOUSE, 0, MACT_DRAG, 2, 3, 0);
            push_ev(0, 0, 0, 0, 0, 0, 0);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        } else if (scen == 7) {
            /* task_active status-bar click + hdr + fb + lp + rp (dual) */
            g_app.task_active = 1;
            push_ev(1, EVT_MOUSE, 0, MACT_PRESS, 5, 22, 0);
            push_ev(1, EVT_MOUSE, 0, MACT_PRESS, 5, 0, 0);
            push_ev(1, EVT_MOUSE, 0, MACT_PRESS, 5, 23, 0);
            push_ev(1, EVT_MOUSE, 0, MACT_PRESS, 5, 4, 0);
            push_ev(1, EVT_MOUSE, 0, MACT_PRESS, 5, 5, 0);
            push_ev(0, 0, 0, 0, 0, 0, 0);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        } else if (scen == 8) {
            /* preview mode hit right -> preview_pane; also pane_mouse_ext intercept */
            g_app.right_mode = RIGHT_MODE_PREVIEW;
            push_ev(1, EVT_MOUSE, 0, MACT_PRESS, 5, 5, 0);
            push_ev(0, 0, 0, 0, 0, 0, 0);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        } else if (scen == 9) {
            g_pane_ext_rc = 1;
            push_ev(1, EVT_MOUSE, 0, MACT_PRESS, 5, 5, 0);
            push_ev(0, 0, 0, 0, 0, 0, 0);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        } else if (scen == 10) {
            /* concurrent streaming: both loading, alternate turn, throttle 33ms, error, finish */
            g_lm.is_loading = 1; g_rm.is_loading = 1;
            g_step_rc[0] = 1; g_step_rc[1] = 1; g_step_rc[2] = 1; g_step_rc[3] = -5; g_step_rc[4] = 0;
            push_ev(0, 0, 0, 0, 0, 0, 1000);
            push_ev(0, 0, 0, 0, 0, 0, 1000);
            push_ev(0, 0, 0, 0, 0, 0, 1010);
            push_ev(0, 0, 0, 0, 0, 0, 1010);
            push_ev(0, 0, 0, 0, 0, 0, 1040);
            push_ev(0, 0, 0, 0, 0, 0, 1040);
            push_ev(0, 0, 0, 0, 0, 0, 1050);
            push_ev(0, 0, 0, 0, 0, 0, 1050);
            push_ev(0, 0, 0, 0, 0, 0, 1060);
            push_ev(0, 0, 0, 0, 0, 0, 1060);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        } else if (scen == 11) {
            /* drain cap: 18 queued keys -> only 16 drained before tick/render */
            for (int i = 0; i < 18; i++) push_ev(1, EVT_KEY, 'a' + (i % 10), 0, 0, 0, 0);
            push_ev(0, 0, 0, 0, 0, 0, 0);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        } else if (scen == 12) {
            /* mid-burst EOF during drain_queued_events */
            push_ev(1, EVT_KEY, 'a', 0, 0, 0, 0);
            push_ev(-2, 0, 0, 0, 0, 0, 0);
        }
        CALL(App_run, &g_app);
        sc_put("END run="); sc_num(g_app.running); sc_put(" exp="); sc_num((int64_t)g_sb.msg_expire_ms);
        sc_put(" mx="); sc_num(g_app.mouse_x); sc_put(" my="); sc_num(g_app.mouse_y); sc_nl();
    }
    sc_flush();
    return 0;
}
