/* Freestanding differential harness for src/ui/viewer_dialog{,_render}.c versus frozen x86_64 asm
 * (tests/harness/viewer_dialog{,_end,_render,_input}_reference.s, ref_ prefix). argv[1] = ref | c | oom. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_keys.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;
static int g_hex_key_ret;
static int g_mode_key_ret;
static int g_zoom_key_ret;
static int g_zoom_mouse_ret;

void App_close_dialog(App *app, int result) { ui_log_call2("App_close_dialog", app == &g_app, result); }
void App_set_status(App *app, const char *msg, int kind)
{
    sc_put("call App_set_status "); sc_num(app == &g_app); sc_put(" k="); sc_num(kind);
    sc_put(" |"); sc_esc(msg ? msg : ""); sc_put("|\n");
}

void fake_viewer_img_free(ViewerDialog *v);
void fake_viewer_img_free(ViewerDialog *v) { (void)v; sc_put("call viewer_img_free\n"); }
void fake_hex_edit_free(ViewerDialog *v);
void fake_hex_edit_free(ViewerDialog *v) { (void)v; sc_put("call hex_edit_free\n"); }
int fake_hex_edit_on_key(ViewerDialog *v, Event *e);
int fake_hex_edit_on_key(ViewerDialog *v, Event *e) { (void)v; (void)e; return g_hex_key_ret; }
int fake_viewer_mode_key(ViewerDialog *v, Event *e);
int fake_viewer_mode_key(ViewerDialog *v, Event *e) { (void)v; (void)e; return g_mode_key_ret; }
int fake_vim_zoom_key(ViewerDialog *v, Event *e);
int fake_vim_zoom_key(ViewerDialog *v, Event *e) { (void)v; (void)e; return g_zoom_key_ret; }
int fake_vim_zoom_mouse(ViewerDialog *v, Event *e);
int fake_vim_zoom_mouse(ViewerDialog *v, Event *e) { (void)v; (void)e; return g_zoom_mouse_ret; }
void fake_ViewerDialog_render_image(ViewerDialog *v, ScreenBuffer *scr);
void fake_ViewerDialog_render_image(ViewerDialog *v, ScreenBuffer *scr)
{
    (void)scr;
    sc_put("call ViewerDialog_render_image im="); sc_num(v->img_mode); sc_put("\n");
}

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define Object_alloc fake_object_alloc
#define viewer_img_free fake_viewer_img_free
#define hex_edit_free fake_hex_edit_free
#define hex_edit_on_key fake_hex_edit_on_key
#define viewer_mode_key fake_viewer_mode_key
#define vim_zoom_key fake_vim_zoom_key
#define vim_zoom_mouse fake_vim_zoom_mouse
#define ViewerDialog_render_image fake_ViewerDialog_render_image
#include VDR_SRC
#include VD_SRC
#undef ViewerDialog_render_image
#undef vim_zoom_mouse
#undef vim_zoom_key
#undef viewer_mode_key
#undef hex_edit_on_key
#undef hex_edit_free
#undef viewer_img_free
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_ViewerDialog_vtbl;
extern ViewerDialog *ref_ViewerDialog_new(App *app, const char *path);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define VD_VTBL (g_ref ? &ref_ViewerDialog_vtbl : &ViewerDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define VD_VTBL (&ViewerDialog_vtbl)
#endif

static bool g_ref;

static void *as_ptr(ViewerDialog *v)
{
    uintptr_t a = (uintptr_t)v;
    return (void *)a;
}

static void dump_state(const char *tag, const ViewerDialog *v)
{
    sc_put(tag);
    sc_put(" rect="); sc_num(v->base.base.x); sc_put(","); sc_num(v->base.base.y);
    sc_put(","); sc_num(v->base.base.w); sc_put(","); sc_num(v->base.base.h);
    sc_put(" vr="); sc_num((int32_t)v->vis_rows);
    sc_put(" hex="); sc_num(v->hex_mode);
    sc_put(" off="); sc_num((int64_t)v->top_off);
    sc_put(" ln="); sc_num((int64_t)v->top_line);
    sc_put(" tot="); sc_num((int64_t)v->total_lines);
    sc_put(" hr="); sc_num((int64_t)v->hex_row);
    sc_put(" dl="); sc_num((int64_t)v->data_len);
    sc_put(" ml="); sc_num((int64_t)v->map_len);
    sc_put(" rd="); sc_num(g_app.need_redraw);
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    if (argv[1][0] == 'o') {
        ui_app_reset(&g_app);
        g_app.term_w = 80; g_app.term_h = 24;
        g_fail_alloc = 1;
        ViewerDialog *v = ViewerDialog_new(&g_app, "/nonexistent");
        sc_put("OOM ok="); sc_num(v == nullptr); sc_put("\n");
        sc_flush();
        return v == nullptr ? 0 : 1;
    }
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(90, 24);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    ViewerDialog *v = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (v) { DUOP_DELETE((Object *)as_ptr(v)); v = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            while (*a == ' ') a++;
            g_app.need_redraw = 0;
            v = CALL(ViewerDialog_new, &g_app, a);
            sc_put("N ok="); sc_num(v != nullptr);
            if (v) {
                sc_put(" is_vd="); sc_num(Object_is_instance((const Object *)as_ptr(v), (const ObjectVtbl *)VD_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE((const Object *)as_ptr(v), Dialog_vtbl));
            }
            sc_put("\n");
            if (v) dump_state("N", v);
            break;
        }
        case 'H': {
            g_hex_key_ret = (int)ui_parse_num(&a);
            g_mode_key_ret = (int)ui_parse_num(&a);
            g_zoom_key_ret = (int)ui_parse_num(&a);
            g_zoom_mouse_ret = (int)ui_parse_num(&a);
            break;
        }
        case 'I': {
            if (v) v->img_mode = (uint32_t)ui_parse_num(&a);
            break;
        }
        case 'L': {
            if (!v) break;
            int x = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
            int w = (int)ui_parse_num(&a), h = (int)ui_parse_num(&a);
            WIDGET_CALL((Widget *)as_ptr(v), layout, x, y, w, h);
            dump_state("L", v);
            break;
        }
        case 'R': {
            if (!v) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL((Widget *)as_ptr(v), render, scr, (void *)theme);
            dump_state("R", v);
            ui_dump(scr, v->base.base.y, v->base.base.h);
            break;
        }
        case 'K': {
            if (!v) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL((Widget *)as_ptr(v), on_key, &evt);
                sc_put("K rc="); sc_num(rc); sc_put(" ");
                dump_state("K", v);
            }
            break;
        }
        case 'M': {
            if (!v) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL((Widget *)as_ptr(v), on_mouse, &evt);
                sc_put("M rc="); sc_num(rc); sc_put(" ");
                dump_state("M", v);
            }
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    if (v) DUOP_DELETE((Object *)as_ptr(v));
    sc_flush();
    return 0;
}
