/* tests/harness/app_events_cli.c - A3.2 differential harness for src/app/app_events.c. */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_preview.h"
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

static App g_app;
static FilePane g_lp, g_rp;
static DirModel g_lm, g_rm;
static StatusBar g_sb;
static PreviewPane g_pv;
static uint8_t g_pv_buf[64];
static uint8_t g_shm_slot[16];

static int64_t g_now_ms;
static int g_dw_fd = 17;
static int g_pv_fd = 19;
static uint32_t g_dw_events;
static int g_caps_chg;
static size_t g_sel_cnt;

typedef struct FakeReply { uint32_t seq; size_t len, tlen; } FakeReply;
static FakeReply g_rep[4];
static int g_rep_cnt, g_rep_pos;

void fake_term_caps_init(char **envp) { sc_put("call term_caps_init "); sc_num(envp != nullptr); sc_nl(); }
void fake_term_caps_query(void) { sc_put("call term_caps_query\n"); }
void fake_term_caps_refresh(int w, int h) { sc_put("call term_caps_refresh "); sc_num(w); sc_put("x"); sc_num(h); sc_nl(); }
int fake_term_caps_changed(void) { return g_caps_chg; }
int fake_dirwatch_init(void) { sc_put("call dirwatch_init\n"); return 0; }
int fake_dirwatch_fd(void) { return g_dw_fd; }
void fake_dirwatch_set(int slot, const char *p) { sc_put("call dirwatch_set "); sc_num(slot); sc_put(" |"); sc_put(p); sc_put("|\n"); }
uint32_t fake_dirwatch_poll(void) { return g_dw_events; }
void fake_input_set_aux_fd(int slot, int fd) { sc_put("call input_set_aux_fd "); sc_num(slot); sc_put(" "); sc_num(fd); sc_nl(); }
void fake_term_shutdown(void) { sc_put("call term_shutdown\n"); }
void fake_fs_preview_stop(void) { sc_put("call fs_preview_stop\n"); }
int64_t fake_sys_clock_ms(void) { return g_now_ms; }
void fake_term_poll_read(App *app) { sc_put("call term_poll_read "); sc_num(app != nullptr); sc_nl(); }
int fake_fs_preview_fd(void) { return g_pv_fd; }

int fake_fs_preview_receive(void *buf, size_t cap, uint32_t *seq, size_t *len, size_t *tlen)
{
    (void)buf; (void)cap;
    if (g_rep_pos >= g_rep_cnt) return 0;
    *seq = g_rep[g_rep_pos].seq;
    *len = g_rep[g_rep_pos].len;
    *tlen = g_rep[g_rep_pos].tlen;
    g_rep_pos++;
    return 1;
}

uint8_t *fake_fs_preview_shm_slot(uint32_t seq) { sc_put("call fs_preview_shm_slot "); sc_num(seq); sc_nl(); return g_shm_slot; }

void fake_PreviewPane_accept(PreviewPane *pv, size_t len, size_t tlen, const uint8_t *th)
{
    sc_put("call PreviewPane_accept "); sc_num(pv != nullptr); sc_put(" l="); sc_num((int64_t)len);
    sc_put(" tl="); sc_num((int64_t)tlen); sc_put(" th="); sc_num(th == g_shm_slot); sc_nl();
}

size_t fake_DirModel_count_selected(DirModel *m, int64_t *b) { (void)m; (void)b; return g_sel_cnt; }
void fake_FilePane_reload_keep_cursor(FilePane *p, const char *f)
{
    sc_put("call FilePane_reload_keep_cursor p="); sc_num(p == &g_lp ? 1 : 2); sc_put(" f="); sc_num(f != nullptr); sc_nl();
}
void fake_DirModel_invalidate_stats(DirModel *m) { sc_put("call DirModel_invalidate_stats m="); sc_num(m == &g_lm ? 1 : 2); sc_nl(); }

void App_sync_preview(App *app) { sc_put("call App_sync_preview "); sc_num(app != nullptr); sc_nl(); }
void App_preview_fire(App *app) { sc_put("call App_preview_fire "); sc_num(app != nullptr); sc_nl(); }

#define term_caps_init fake_term_caps_init
#define term_caps_query fake_term_caps_query
#define term_caps_refresh fake_term_caps_refresh
#define term_caps_changed fake_term_caps_changed
#define dirwatch_init fake_dirwatch_init
#define dirwatch_fd fake_dirwatch_fd
#define dirwatch_set fake_dirwatch_set
#define dirwatch_poll fake_dirwatch_poll
#define input_set_aux_fd fake_input_set_aux_fd
#define term_shutdown fake_term_shutdown
#define fs_preview_stop fake_fs_preview_stop
#define sys_clock_ms fake_sys_clock_ms
#define term_poll_read fake_term_poll_read
#define fs_preview_fd fake_fs_preview_fd
#define fs_preview_receive fake_fs_preview_receive
#define fs_preview_shm_slot fake_fs_preview_shm_slot
#define PreviewPane_accept fake_PreviewPane_accept
#define DirModel_count_selected fake_DirModel_count_selected
#define FilePane_reload_keep_cursor fake_FilePane_reload_keep_cursor
#define DirModel_invalidate_stats fake_DirModel_invalidate_stats
#include EVENTS_SRC
#undef term_caps_init
#undef term_caps_query
#undef term_caps_refresh
#undef term_caps_changed
#undef dirwatch_init
#undef dirwatch_fd
#undef dirwatch_set
#undef dirwatch_poll
#undef input_set_aux_fd
#undef term_shutdown
#undef fs_preview_stop
#undef sys_clock_ms
#undef term_poll_read
#undef fs_preview_fd
#undef fs_preview_receive
#undef fs_preview_shm_slot
#undef PreviewPane_accept
#undef DirModel_count_selected
#undef FilePane_reload_keep_cursor
#undef DirModel_invalidate_stats

#ifdef __x86_64__
void ref_App_events_init(App *app);
int ref_App_events_timeout(App *app);
void ref_App_events_tick(App *app);
void ref_App_events_shutdown(App *app);
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
    mem_zero(&g_pv, sizeof g_pv);
    static char *fake_env[] = { "TERM=xterm", nullptr };
    g_app.envp = (uint64_t)(uintptr_t)fake_env;
    g_app.left_pane = (uint64_t)(uintptr_t)&g_lp;
    g_app.right_pane = (uint64_t)(uintptr_t)&g_rp;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_lp;
    g_app.status_bar = (uint64_t)(uintptr_t)&g_sb;
    g_app.preview_pane = (uint64_t)(uintptr_t)&g_pv;
    g_app.term_w = 100; g_app.term_h = 30;
    g_lp.model = (uint64_t)(uintptr_t)&g_lm;
    g_rp.model = (uint64_t)(uintptr_t)&g_rm;
    (void)str_copy(g_lm.path, "/dirL", sizeof g_lm.path);
    (void)str_copy(g_rm.path, "/dirR", sizeof g_rm.path);
    g_pv.buf = (uint64_t)(uintptr_t)g_pv_buf;
    g_now_ms = 1000; g_dw_events = 0; g_caps_chg = 0; g_sel_cnt = 0;
    g_rep_cnt = 0; g_rep_pos = 0;
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
        if (tag == 'I') {
            CALL(App_events_init, &g_app);
        } else if (tag == 'S') {
            CALL(App_events_shutdown, &g_app);
        } else if (tag == 'O') {
            /* O <now> <task_act> <sb_exp> <pv_due> <w0_due> <w1_due> */
            g_now_ms = sc_tok_i64(&p);
            g_app.task_active = (uint32_t)sc_tok_i64(&p);
            g_sb.msg_expire_ms = (uint64_t)sc_tok_i64(&p);
            g_app.preview_due = (uint64_t)sc_tok_i64(&p);
            uint64_t *wd = (uint64_t *)(void *)g_app.watch_due;
            wd[0] = (uint64_t)sc_tok_i64(&p);
            wd[1] = (uint64_t)sc_tok_i64(&p);
            int to = CALL(App_events_timeout, &g_app);
            sc_put("TO "); sc_num(to); sc_nl();
        } else if (tag == 'T') {
            /* T <now> <pv_due> <pv_seq> <pv_pend> <rep_mode> <dw_ev> <w0_last> <w0_due> <w0_kind> <loading> <huge> <sel> <caps> */
            g_now_ms = sc_tok_i64(&p);
            g_app.preview_due = (uint64_t)sc_tok_i64(&p);
            g_app.preview_seq = (uint32_t)sc_tok_i64(&p);
            g_pv.pending = (uint32_t)sc_tok_i64(&p);
            int rm = (int)sc_tok_i64(&p);
            if (rm == 1) {
                g_rep[0] = (FakeReply){ .seq = 4, .len = 10, .tlen = 0 };   /* stale seq */
                g_rep[1] = (FakeReply){ .seq = 5, .len = 200, .tlen = 64 }; /* match */
                g_rep_cnt = 2;
            }
            g_dw_events = (uint32_t)sc_tok_i64(&p);
            uint64_t *wl = (uint64_t *)(void *)g_app.watch_last;
            uint64_t *wd = (uint64_t *)(void *)g_app.watch_due;
            uint32_t *wk = (uint32_t *)(void *)&g_app.watch_kind;
            wl[0] = (uint64_t)sc_tok_i64(&p);
            wd[0] = (uint64_t)sc_tok_i64(&p);
            wk[0] = (uint32_t)sc_tok_i64(&p);
            g_lm.is_loading = (uint32_t)sc_tok_i64(&p);
            g_lm.huge_mode = (uint32_t)sc_tok_i64(&p);
            g_sel_cnt = (size_t)sc_tok_i64(&p);
            g_caps_chg = (int)sc_tok_i64(&p);
            CALL(App_events_tick, &g_app);
            sc_put("TK wd0="); sc_num((int64_t)wd[0]); sc_put(" wd1="); sc_num((int64_t)wd[1]);
            sc_put(" wl0="); sc_num((int64_t)wl[0]); sc_put(" wk0="); sc_num(wk[0]);
            sc_put(" wk1="); sc_num(wk[1]); sc_put(" nr="); sc_num(g_app.need_redraw); sc_nl();
        }
    }
    sc_flush();
    return 0;
}
