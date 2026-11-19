/* Freestanding differential harness for A1.1 app leaf modules:
 * src/app/{app_choosedir,app_arc,app_view,app_toggles}.c versus frozen x86_64 asm.
 * argv[1] = ref | c. */
#include "duop_app.h"
#include "duop_app_int.h"
#include "duop_arc.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_img.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static FilePane g_left, g_right;
static DirModel g_dm_l, g_dm_r;
static HeaderBar g_hdr;
static FunctionBar g_fbar;
static PreviewPane g_prev;
static ScreenBuffer g_scr;
static FileEntry g_ent;
static ViewAsDialog g_vad;
static ViewerDialog g_vd;

static int g_arc_up_rc = -1;
static int g_arc_enter_rc = 0;
static int g_arc_ext_rc = 0;
static int g_img_fmt = 0;
static int g_vd_oom = 0;
static int g_lang_cnt = 3;
static Theme g_themes[3];

static int stub_on_mouse(Widget *w, void *ev)
{
    (void)ev;
    sc_put("call on_mouse id="); sc_num(w->id); sc_put("\n");
    return 0;
}
WIDGET_VTBL(StubW_vtbl, "StubW", Widget_vtbl, sizeof(Widget), .on_mouse = stub_on_mouse);

/* App_* stubs */
void App_set_status(App *app, const char *msg, int kind)
{
    sc_put("call App_set_status "); sc_num(app == &g_app); sc_put(" k="); sc_num(kind);
    sc_put(" |"); sc_esc(msg ? msg : ""); sc_put("|\n");
}
void App_set_active_pane(App *app, FilePane *pane)
{
    app->active_pane = (uint64_t)(uintptr_t)pane;
    sc_put("call App_set_active_pane "); sc_put(pane == &g_left ? "L" : "R"); sc_put("\n");
}
void App_sync_preview(App *app) { sc_put("call App_sync_preview "); sc_num(app == &g_app); sc_put("\n"); }
void App_layout(App *app)       { sc_put("call App_layout "); sc_num(app == &g_app); sc_put("\n"); }
void App_task_confirm_quit(App *app) { sc_put("call App_task_confirm_quit "); sc_num(app == &g_app); sc_put("\n"); }
void App_cmd_help(App *app)     { (void)app; sc_put("call App_cmd_help\n"); }
void App_cmd_rename(App *app)   { (void)app; sc_put("call App_cmd_rename\n"); }
void App_cmd_view(App *app)     { (void)app; sc_put("call App_cmd_view\n"); }
void App_cmd_edit(App *app)     { (void)app; sc_put("call App_cmd_edit\n"); }
void App_cmd_copy(App *app)     { (void)app; sc_put("call App_cmd_copy\n"); }
void App_cmd_move(App *app)     { (void)app; sc_put("call App_cmd_move\n"); }
void App_cmd_mkdir(App *app)    { (void)app; sc_put("call App_cmd_mkdir\n"); }
void App_cmd_delete(App *app)   { (void)app; sc_put("call App_cmd_delete\n"); }

/* External collaborators */
int fake_arc_nav_up_model(DirModel *m);
int fake_arc_nav_up_model(DirModel *m) { sc_put("call arc_nav_up_model "); sc_num(m == &g_dm_l); sc_put("\n"); return g_arc_up_rc; }
int fake_arc_enter_model(DirModel *m, const FileEntry *e);
int fake_arc_enter_model(DirModel *m, const FileEntry *e)
{
    sc_put("call arc_enter_model "); sc_num(m == &g_dm_l); sc_put(" "); sc_num(e == &g_ent); sc_put("\n");
    return g_arc_enter_rc;
}
int fake_arc_extract_entry(DirModel *m, const FileEntry *e, char *out);
int fake_arc_extract_entry(DirModel *m, const FileEntry *e, char *out)
{
    sc_put("call arc_extract_entry "); sc_num(m == &g_dm_l); sc_put(" "); sc_num(e == &g_ent); sc_put("\n");
    if (g_arc_ext_rc == 0) (void)str_copy(out, "/tmp/extracted", 64);
    return g_arc_ext_rc;
}
FileEntry *fake_FilePane_get_selected_entry(FilePane *fp);
FileEntry *fake_FilePane_get_selected_entry(FilePane *fp) { (void)fp; return &g_ent; }
void fake_FilePane_ensure_visible(FilePane *fp);
void fake_FilePane_ensure_visible(FilePane *fp)
{
    sc_put("call ensure_visible id="); sc_num(fp->base.id); sc_put(" cur="); sc_num((int32_t)fp->cursor); sc_put("\n");
}
void fake_DirModel_apply_filter(DirModel *m);
void fake_DirModel_apply_filter(DirModel *m)
{
    sc_put("call apply_filter "); sc_put(m == &g_dm_l ? "L" : "R"); sc_put(" hid="); sc_num(m->show_hidden); sc_put("\n");
}
intptr_t fake_fs_read_file_head(const char *p, void *b, size_t mx, size_t *out);
intptr_t fake_fs_read_file_head(const char *p, void *b, size_t mx, size_t *out)
{
    (void)p; (void)b; (void)mx;
    *out = 16;
    return 0;
}
int fake_img_detect(const uint8_t *d, size_t n, const char *p);
int fake_img_detect(const uint8_t *d, size_t n, const char *p)
{
    (void)d;
    sc_put("call img_detect n="); sc_num((int64_t)n); sc_put(" |"); sc_esc(p); sc_put("|\n");
    return g_img_fmt;
}
ViewAsDialog *fake_ViewAsDialog_new(App *a, const char *p, int fmt);
ViewAsDialog *fake_ViewAsDialog_new(App *a, const char *p, int fmt)
{
    sc_put("call ViewAsDialog_new "); sc_num(a == &g_app); sc_put(" fmt="); sc_num(fmt);
    sc_put(" |"); sc_esc(p); sc_put("|\n");
    return &g_vad;
}
ViewerDialog *fake_ViewerDialog_new(App *a, const char *p);
ViewerDialog *fake_ViewerDialog_new(App *a, const char *p)
{
    sc_put("call ViewerDialog_new "); sc_num(a == &g_app); sc_put(" |"); sc_esc(p); sc_put("|\n");
    return g_vd_oom ? nullptr : &g_vd;
}
void fake_ViewerDialog_set_mode(ViewerDialog *v, int mode);
void fake_ViewerDialog_set_mode(ViewerDialog *v, int mode)
{
    sc_put("call ViewerDialog_set_mode "); sc_num(v == &g_vd); sc_put(" m="); sc_num(mode); sc_put("\n");
}
void fake_PreviewPane_cycle_mode(PreviewPane *pv);
void fake_PreviewPane_cycle_mode(PreviewPane *pv)
{
    sc_put("call PreviewPane_cycle_mode "); sc_num(pv == &g_prev); sc_put("\n");
}
const Theme *fake_theme_get(int idx);
const Theme *fake_theme_get(int idx)
{
    sc_put("call theme_get idx="); sc_num(idx); sc_put("\n");
    return &g_themes[idx % 3];
}
int fake_i18n_count(void);
int fake_i18n_count(void) { return g_lang_cnt; }
const LangStrings *fake_i18n_set_lang(int idx);
const LangStrings *fake_i18n_set_lang(int idx)
{
    sc_put("call i18n_set_lang idx="); sc_num(idx); sc_put("\n");
    return i18n_get();
}

#define arc_nav_up_model fake_arc_nav_up_model
#define arc_enter_model fake_arc_enter_model
#define arc_extract_entry fake_arc_extract_entry
#define FilePane_get_selected_entry fake_FilePane_get_selected_entry
#define FilePane_ensure_visible fake_FilePane_ensure_visible
#define DirModel_apply_filter fake_DirModel_apply_filter
#define fs_read_file_head fake_fs_read_file_head
#define img_detect fake_img_detect
#define ViewAsDialog_new fake_ViewAsDialog_new
#define ViewerDialog_new fake_ViewerDialog_new
#define ViewerDialog_set_mode fake_ViewerDialog_set_mode
#define PreviewPane_cycle_mode fake_PreviewPane_cycle_mode
#define theme_get fake_theme_get
#define i18n_count fake_i18n_count
#define i18n_set_lang fake_i18n_set_lang
#include CD_SRC
#include ARC_SRC
#include VW_SRC
#include TG_SRC
#undef i18n_set_lang
#undef i18n_count
#undef theme_get
#undef PreviewPane_cycle_mode
#undef ViewerDialog_set_mode
#undef ViewerDialog_new
#undef ViewAsDialog_new
#undef img_detect
#undef fs_read_file_head
#undef DirModel_apply_filter
#undef FilePane_ensure_visible
#undef FilePane_get_selected_entry
#undef arc_extract_entry
#undef arc_enter_model
#undef arc_nav_up_model

#ifdef __x86_64__
extern void ref_App_write_choosedir(App *, const char *);
extern void ref_app_mouse_hover(App *, Event *);
extern int ref_arc_nav_up(FilePane *);
extern int ref_arc_handle_enter(App *);
extern int ref_arc_extract_selected(FilePane *, char *);
extern void ref_App_open_viewer(App *, const char *);
extern void ref_App_view_as_done(App *, ViewAsDialog *);
extern int ref_App_cmd_view_mode(App *);
extern void ref_App_cmd_toggle_preview(App *);
extern void ref_App_cmd_toggle_hidden(App *);
extern void ref_App_cmd_cycle_theme(App *);
extern void ref_App_cmd_toggle_lang(App *);
extern void ref_App_cmd_quit(App *);
extern void ref_App_dispatch_f_action(App *, int);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

static void init_state(void)
{
    ui_app_reset(&g_app);
    mem_zero(&g_left, sizeof g_left); mem_zero(&g_right, sizeof g_right);
    mem_zero(&g_dm_l, sizeof g_dm_l); mem_zero(&g_dm_r, sizeof g_dm_r);
    mem_zero(&g_hdr, sizeof g_hdr); mem_zero(&g_fbar, sizeof g_fbar);
    mem_zero(&g_prev, sizeof g_prev); mem_zero(&g_scr, sizeof g_scr);

    g_hdr.base.base.vptr = DUOP_OBJ_VTBL(StubW_vtbl); g_hdr.base.id = 100;
    g_fbar.base.base.vptr = DUOP_OBJ_VTBL(StubW_vtbl); g_fbar.base.id = 101;
    g_left.base.base.vptr = DUOP_OBJ_VTBL(StubW_vtbl); g_left.base.id = 1;
    g_right.base.base.vptr = DUOP_OBJ_VTBL(StubW_vtbl); g_right.base.id = 2;

    g_left.model = (uint64_t)(uintptr_t)&g_dm_l;
    g_right.model = (uint64_t)(uintptr_t)&g_dm_r;
    (void)str_copy(g_dm_l.path, "/chosen/dir", PATH_MAX);
    (void)str_copy(g_dm_r.path, "/other/dir", PATH_MAX);

    g_app.header_bar = (uint64_t)(uintptr_t)&g_hdr;
    g_app.func_bar = (uint64_t)(uintptr_t)&g_fbar;
    g_app.left_pane = (uint64_t)(uintptr_t)&g_left;
    g_app.right_pane = (uint64_t)(uintptr_t)&g_right;
    g_app.preview_pane = (uint64_t)(uintptr_t)&g_prev;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_left;
    g_app.screen = (uint64_t)(uintptr_t)&g_scr;
    g_app.running = 1;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    init_state();

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'W': {
            while (*a == ' ') a++;
            const char *p = (a[0] == '-' && !a[1]) ? nullptr : (a[0] == '!' && !a[1] ? "" : a);
            CALL(App_write_choosedir, &g_app, p);
            if (p && p[0]) {
                intptr_t fd = os_openat(AT_FDCWD, p, O_RDONLY, 0);
                if (fd >= 0) {
                    char buf[64];
                    intptr_t n = os_read((int)fd, buf, sizeof buf - 1);
                    (void)os_close((int)fd);
                    buf[n > 0 ? n : 0] = 0;
                    sc_put("W file=|"); sc_esc(buf); sc_put("|\n");
                }
            }
            break;
        }
        case 'H': {
            g_app.right_mode = (uint32_t)ui_parse_num(&a);
            Event ev; mem_zero(&ev, sizeof ev);
            CALL(app_mouse_hover, &g_app, &ev);
            break;
        }
        case 'A': {
            int sub = (int)ui_parse_num(&a);
            if (sub == 0) {
                g_arc_up_rc = (int)ui_parse_num(&a);
                g_left.cursor = 9; g_left.scroll = 4;
                int rc = CALL(arc_nav_up, &g_left);
                sc_put("AU rc="); sc_num(rc); sc_put(" cur="); sc_num(g_left.cursor);
                sc_put(" scr="); sc_num(g_left.scroll); sc_put("\n");
            } else if (sub == 1) {
                g_arc_enter_rc = (int)ui_parse_num(&a);
                g_arc_up_rc = (int)ui_parse_num(&a);
                g_left.cursor = 5; g_left.scroll = 2; g_app.need_redraw = 0;
                int rc = CALL(arc_handle_enter, &g_app);
                sc_put("AE rc="); sc_num(rc); sc_put(" cur="); sc_num(g_left.cursor);
                sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            } else {
                g_arc_ext_rc = (int)ui_parse_num(&a);
                char tmp[64] = "";
                int rc = CALL(arc_extract_selected, &g_left, tmp);
                sc_put("AX rc="); sc_num(rc); sc_put(" p=|"); sc_esc(tmp); sc_put("|\n");
            }
            break;
        }
        case 'V': {
            int sub = (int)ui_parse_num(&a);
            if (sub == 0) {
                g_img_fmt = (int)ui_parse_num(&a);
                g_vd_oom = 0;
                g_app.active_dialog = 0; g_app.need_redraw = 0;
                CALL(App_open_viewer, &g_app, "/pic.png");
                sc_put("VO is_va="); sc_num(g_app.active_dialog == (uint64_t)(uintptr_t)&g_vad);
                sc_put(" is_vd="); sc_num(g_app.active_dialog == (uint64_t)(uintptr_t)&g_vd);
                sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            } else if (sub == 1) {
                g_vd_oom = (int)ui_parse_num(&a);
                g_vad.choice = (uint32_t)ui_parse_num(&a);
                (void)str_copy((char *)g_vad.path, "/img.jpg", sizeof g_vad.path);
                g_app.active_dialog = 0; g_app.need_redraw = 0;
                CALL(App_view_as_done, &g_app, &g_vad);
                sc_put("VD ok="); sc_num(g_app.active_dialog == (uint64_t)(uintptr_t)&g_vd);
                sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            } else {
                g_app.right_mode = (uint32_t)ui_parse_num(&a);
                int rc = CALL(App_cmd_view_mode, &g_app);
                sc_put("VM rc="); sc_num(rc); sc_put("\n");
            }
            break;
        }
        case 'T': {
            int sub = (int)ui_parse_num(&a);
            g_app.need_redraw = 0; g_scr.force_full = 0;
            if (sub == 0) {
                CALL(App_cmd_toggle_preview, &g_app);
                sc_put("TP rm="); sc_num(g_app.right_mode); sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            } else if (sub == 1) {
                CALL(App_cmd_toggle_hidden, &g_app);
                sc_put("TH l="); sc_num(g_dm_l.show_hidden); sc_put(" r="); sc_num(g_dm_r.show_hidden);
                sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            } else if (sub == 2) {
                CALL(App_cmd_cycle_theme, &g_app);
                sc_put("TT idx="); sc_num(g_app.theme_idx); sc_put(" ff="); sc_num(g_scr.force_full);
                sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            } else if (sub == 3) {
                CALL(App_cmd_toggle_lang, &g_app);
                sc_put("TL idx="); sc_num(g_app.lang_idx); sc_put(" ff="); sc_num(g_scr.force_full);
                sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            } else if (sub == 4) {
                g_app.task_active = (uint32_t)ui_parse_num(&a);
                g_app.running = 1;
                CALL(App_cmd_quit, &g_app);
                sc_put("TQ run="); sc_num(g_app.running); sc_put("\n");
            } else if (sub == 5) {
                int idx = (int)ui_parse_num(&a);
                CALL(App_dispatch_f_action, &g_app, idx);
            }
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
