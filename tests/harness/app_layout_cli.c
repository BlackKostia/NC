/* tests/harness/app_layout_cli.c - A2.6 differential harness for src/app/app_layout.c. */
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

typedef struct SpyWidget {
    Widget base;
    int tag;
} SpyWidget;

static void spy_layout(Widget *self, int x, int y, int w, int h)
{
    SpyWidget *s = (SpyWidget *)self;
    sc_put("vcall layout t="); sc_num(s->tag); sc_put(" "); sc_num(x); sc_put(","); sc_num(y);
    sc_put(","); sc_num(w); sc_put(","); sc_num(h); sc_nl();
}

static void spy_render(Widget *self, void *scr, void *th)
{
    SpyWidget *s = (SpyWidget *)self;
    sc_put("vcall render t="); sc_num(s->tag); sc_put(" s="); sc_num(scr != nullptr);
    sc_put(" th="); sc_num(th != nullptr); sc_nl();
}

static void spy_focus(Widget *self, int gained)
{
    SpyWidget *s = (SpyWidget *)self;
    sc_put("vcall on_focus t="); sc_num(s->tag); sc_put(" g="); sc_num(gained); sc_nl();
}

static const WidgetVtbl g_spy_vtbl = {
    .base = { .super = nullptr, .class_name = "Spy", .inst_size = sizeof(SpyWidget), .dtor = nullptr },
    .layout = spy_layout,
    .render = spy_render,
    .on_focus = spy_focus,
};

static App g_app;
static SpyWidget g_hdr, g_lp, g_rp, g_pv, g_sb, g_fb, g_dlg;
static FilePane g_fp_l, g_fp_r;
static DirModel g_lm;
static ScreenBuffer g_scr;
static Theme g_theme;
static FileEntry g_fe;

static int g_term_h;
static int64_t g_clock_ms = 5000;
static int g_has_fe;
static int g_pv_load_rc;
static int g_pv_req_rc;

intptr_t fake_ScreenBuffer_resize(ScreenBuffer *s, int w, int h)
{
    sc_put("call ScreenBuffer_resize "); sc_num(s != nullptr); sc_put(" "); sc_num(w); sc_put("x"); sc_num(h); sc_nl();
    return 0;
}

void fake_ScreenBuffer_clear(ScreenBuffer *s, uint32_t fg, uint32_t bg)
{
    sc_put("call ScreenBuffer_clear "); sc_num(s != nullptr); sc_put(" fg="); sc_num(fg); sc_put(" bg="); sc_num(bg); sc_nl();
}

void fake_ScreenBuffer_flush(ScreenBuffer *s) { sc_put("call ScreenBuffer_flush "); sc_num(s != nullptr); sc_nl(); }

int fake_term_height(int main_h)
{
    sc_put("call term_height "); sc_num(main_h); sc_nl();
    return g_term_h;
}

void fake_term_render(App *app, ScreenBuffer *s, const Theme *th)
{
    sc_put("call term_render "); sc_num(app != nullptr && s != nullptr && th != nullptr); sc_nl();
}

void fake_img_preview_pre_flush(App *app) { sc_put("call img_preview_pre_flush "); sc_num(app != nullptr); sc_nl(); }
void fake_img_preview_post_flush(App *app) { sc_put("call img_preview_post_flush "); sc_num(app != nullptr); sc_nl(); }

void fake_StatusBar_set_message(StatusBar *sb, const char *msg, int kind, int ttl)
{
    sc_put("call StatusBar_set_message "); sc_num(sb != nullptr); sc_put(" m=|"); sc_put(msg ? msg : "-");
    sc_put("| k="); sc_num(kind); sc_put(" ttl="); sc_num(ttl); sc_nl();
}

int64_t fake_sys_clock_ms(void) { return g_clock_ms; }

FileEntry *fake_FilePane_get_selected_entry(FilePane *fp) { (void)fp; return g_has_fe ? &g_fe : nullptr; }
const char *fake_DirModel_entry_name(const DirModel *m, const FileEntry *e) { (void)m; (void)e; return "pic.png"; }

int fake_PreviewPane_load(PreviewPane *pv, const char *full, const FileEntry *fe)
{
    sc_put("call PreviewPane_load "); sc_num(pv != nullptr); sc_put(" p=|"); sc_put(full ? full : "-");
    sc_put("| fe="); sc_num(fe != nullptr); sc_nl();
    return g_pv_load_rc;
}

uint32_t fake_PreviewPane_thumb_req(PreviewPane *pv, PvThumbReq *out)
{
    (void)pv;
    out->w = 80; out->h = 40; out->proto = 2; out->cols = 30; out->pad[0] = 0; out->pad[1] = 0; out->bg = 0x112233;
    return ((uint32_t)40 << 16) | 80u;
}

int fake_fs_preview_request(const char *path, uint32_t dims, uint32_t mode, uint32_t bg)
{
    sc_put("call fs_preview_request |"); sc_put(path); sc_put("| d="); sc_num(dims);
    sc_put(" m="); sc_num(mode); sc_put(" bg="); sc_num(bg); sc_nl();
    return g_pv_req_rc;
}

void fake_PreviewPane_read_sync(PreviewPane *pv) { sc_put("call PreviewPane_read_sync "); sc_num(pv != nullptr); sc_nl(); }

#define ScreenBuffer_resize fake_ScreenBuffer_resize
#define ScreenBuffer_clear fake_ScreenBuffer_clear
#define ScreenBuffer_flush fake_ScreenBuffer_flush
#define term_height fake_term_height
#define term_render fake_term_render
#define img_preview_pre_flush fake_img_preview_pre_flush
#define img_preview_post_flush fake_img_preview_post_flush
#define StatusBar_set_message fake_StatusBar_set_message
#define sys_clock_ms fake_sys_clock_ms
#define FilePane_get_selected_entry fake_FilePane_get_selected_entry
#define DirModel_entry_name fake_DirModel_entry_name
#define PreviewPane_load fake_PreviewPane_load
#define PreviewPane_thumb_req fake_PreviewPane_thumb_req
#define fs_preview_request fake_fs_preview_request
#define PreviewPane_read_sync fake_PreviewPane_read_sync
#include LAYOUT_SRC
#undef ScreenBuffer_resize
#undef ScreenBuffer_clear
#undef ScreenBuffer_flush
#undef term_height
#undef term_render
#undef img_preview_pre_flush
#undef img_preview_post_flush
#undef StatusBar_set_message
#undef sys_clock_ms
#undef FilePane_get_selected_entry
#undef DirModel_entry_name
#undef PreviewPane_load
#undef PreviewPane_thumb_req
#undef fs_preview_request
#undef PreviewPane_read_sync

#ifdef __x86_64__
void ref_App_layout(App *app);
void ref_App_render(App *app);
void ref_App_set_status(App *app, const char *msg, int kind);
void ref_App_set_active_pane(App *app, FilePane *pane);
FilePane *ref_get_inactive_pane(App *app);
void ref_App_sync_preview(App *app);
void ref_App_preview_fire(App *app);
#endif

static int g_use_ref;
#ifdef __x86_64__
#define CALL(fn, ...) (g_use_ref ? ref_##fn(__VA_ARGS__) : fn(__VA_ARGS__))
#else
#define CALL(fn, ...) fn(__VA_ARGS__)
#endif

static void init_spy(SpyWidget *s, int tag)
{
    mem_zero(s, sizeof *s);
    s->base.base.vptr = &g_spy_vtbl.base;
    s->tag = tag;
}

static void init_state(void)
{
    mem_zero(&g_app, sizeof g_app);
    mem_zero(&g_fp_l, sizeof g_fp_l);
    mem_zero(&g_fp_r, sizeof g_fp_r);
    mem_zero(&g_lm, sizeof g_lm);
    mem_zero(&g_scr, sizeof g_scr);
    mem_zero(&g_theme, sizeof g_theme);
    init_spy(&g_hdr, 1); init_spy(&g_lp, 2); init_spy(&g_rp, 3);
    init_spy(&g_pv, 4); init_spy(&g_sb, 5); init_spy(&g_fb, 6); init_spy(&g_dlg, 7);
    g_fp_l.base.base.vptr = &g_spy_vtbl.base;
    g_fp_r.base.base.vptr = &g_spy_vtbl.base;
    g_fp_l.model = (uint64_t)(uintptr_t)&g_lm;
    (void)str_copy(g_lm.path, "/imgs", sizeof g_lm.path);
    g_theme.text = 0x101; g_theme.bg = 0x202;
    g_app.screen = (uint64_t)(uintptr_t)&g_scr;
    g_app.theme = (uint64_t)(uintptr_t)&g_theme;
    g_app.header_bar = (uint64_t)(uintptr_t)&g_hdr;
    g_app.left_pane = (uint64_t)(uintptr_t)&g_lp;
    g_app.right_pane = (uint64_t)(uintptr_t)&g_rp;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_lp;
    g_app.preview_pane = (uint64_t)(uintptr_t)&g_pv;
    g_app.status_bar = (uint64_t)(uintptr_t)&g_sb;
    g_app.func_bar = (uint64_t)(uintptr_t)&g_fb;
    g_app.term_w = 81; g_app.term_h = 25;
    g_term_h = 0; g_has_fe = 1; g_pv_load_rc = 1; g_pv_req_rc = 7;
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
        if (tag == 'L') {
            g_app.term_w = (uint32_t)sc_tok_i64(&p);
            g_app.term_h = (uint32_t)sc_tok_i64(&p);
            g_term_h = (int)sc_tok_i64(&p);
            if (sc_tok_i64(&p)) g_app.active_dialog = (uint64_t)(uintptr_t)&g_dlg;
            CALL(App_layout, &g_app);
        } else if (tag == 'R') {
            g_app.right_mode = (uint32_t)sc_tok_i64(&p);
            if (sc_tok_i64(&p)) g_app.active_dialog = (uint64_t)(uintptr_t)&g_dlg;
            g_app.need_redraw = 1;
            CALL(App_render, &g_app);
            sc_put("RD nr="); sc_num(g_app.need_redraw); sc_nl();
        } else if (tag == 'S') {
            CALL(App_set_status, &g_app, "hello_msg", (int)sc_tok_i64(&p));
            sc_put("SS nr="); sc_num(g_app.need_redraw); sc_nl();
        } else if (tag == 'A') {
            int to_right = (int)sc_tok_i64(&p);
            g_app.right_mode = (uint32_t)sc_tok_i64(&p);
            FilePane *dst = to_right ? (FilePane *)&g_rp : (FilePane *)&g_lp;
            CALL(App_set_active_pane, &g_app, dst);
            FilePane *inact = CALL(get_inactive_pane, &g_app);
            sc_put("AP act="); sc_num(g_app.active_pane == (uint64_t)(uintptr_t)&g_rp ? 2 : 1);
            sc_put(" inact="); sc_num((void *)inact == (void *)&g_rp ? 2 : 1);
            sc_put(" due="); sc_num((int64_t)g_app.preview_due);
            sc_put(" nr="); sc_num(g_app.need_redraw); sc_nl();
        } else if (tag == 'P') {
            g_app.active_pane = (uint64_t)(uintptr_t)&g_fp_l;
            g_app.right_mode = (uint32_t)sc_tok_i64(&p);
            g_has_fe = (int)sc_tok_i64(&p);
            g_pv_load_rc = (int)sc_tok_i64(&p);
            g_pv_req_rc = (int)sc_tok_i64(&p);
            g_app.preview_due = 9999;
            CALL(App_preview_fire, &g_app);
            sc_put("PF due="); sc_num((int64_t)g_app.preview_due);
            sc_put(" seq="); sc_num(g_app.preview_seq);
            sc_put(" nr="); sc_num(g_app.need_redraw); sc_nl();
        }
    }
    sc_flush();
    return 0;
}
