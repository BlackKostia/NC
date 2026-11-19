/* Freestanding differential harness for src/ui/search_dialog.c versus frozen x86_64 asm
 * (tests/harness/search_dialog{,_input}_reference.s, ref_ prefix).
 * argv[1] = ref | c (core diff) | fix_c | fix_ref (proves asm dlg_layout_right_buttons fix). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static FilePane g_pane;
static DirModel g_model;
static int g_fail_alloc;

void App_close_dialog(App *app, int result)
{
    ui_log_call2("App_close_dialog", app == &g_app, result);
}

int arc_nav_up(FilePane *fp)
{
    sc_put("call arc_nav_up "); sc_num(fp == &g_pane); sc_put("\n");
    return 7;
}

int DirModel_reload(DirModel *self)
{
    sc_put("call DirModel_reload "); sc_num(self == &g_model); sc_put("\n");
    return 0;
}

void FilePane_ensure_visible(FilePane *self)
{
    sc_put("call FilePane_ensure_visible "); sc_num(self == &g_pane); sc_put("\n");
}

void fp_draw_du_badge(FilePane *fp, ScreenBuffer *sb)
{
    ui_log_call2("fp_draw_du_badge", fp == &g_pane, sb != nullptr);
}

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define Object_alloc fake_object_alloc
#include SD_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_SearchDialog_vtbl;
extern SearchDialog *ref_SearchDialog_new(App *app);
extern int ref_fp_exit_virtual(FilePane *pane);
extern void ref_fp_draw_search_badge(FilePane *pane, ScreenBuffer *scr);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#define SD_VTBL (g_ref ? &ref_SearchDialog_vtbl : &SearchDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#define SD_VTBL (&SearchDialog_vtbl)
#endif

static bool g_ref;

static void dump_state(const char *tag, const SearchDialog *d, int with_btns)
{
    sc_put(tag);
    sc_put(" rect "); sc_num(d->base.base.x); sc_put(" "); sc_num(d->base.base.y);
    sc_put(" "); sc_num(d->base.base.w); sc_put(" "); sc_num(d->base.base.h);
    sc_put(" ff="); sc_num(d->focus_field);
    sc_put(" nl="); sc_num(d->name_len);
    sc_put(" gl="); sc_num(d->grep_len);
    sc_put(" n="); sc_esc((const char *)d->name_buf);
    sc_put(" g="); sc_esc((const char *)d->grep_buf);
    if (with_btns) {
        const HitZone *z = (const HitZone *)d->base.btns;
        sc_put(" bc="); sc_num(d->base.btn_count);
        for (uint32_t i = 0; i < d->base.btn_count && i < 4; i++) {
            sc_put(" ["); sc_num((int16_t)z[i].x1); sc_put(".."); sc_num((int16_t)z[i].x2);
            sc_put("@"); sc_num((int16_t)z[i].y); sc_put("]");
        }
    }
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    bool fix_mode = (argv[1][0] == 'f');
    g_ref = fix_mode ? (argv[1][4] == 'r') : (argv[1][0] == 'r');
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(80, 24);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    mem_zero(&g_pane, sizeof g_pane);
    mem_zero(&g_model, sizeof g_model);
    g_pane.model = (uintptr_t)&g_model;
    g_pane.base.x = 2; g_pane.base.y = 1; g_pane.base.w = 40; g_pane.base.h = 10;

    SearchDialog *d = nullptr;
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (d) { DUOP_DELETE(d); d = nullptr; }
            int null_app = (int)ui_parse_num(&a);
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            g_fail_alloc = (int)ui_parse_num(&a);
            d = CALL(SearchDialog_new, null_app ? nullptr : &g_app);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_s="); sc_num(Object_is_instance((const Object *)d, (const ObjectVtbl *)SD_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(d, Dialog_vtbl));
                sc_put(" tag="); sc_num(d->base.op_tag);
                sc_put("\n");
                dump_state("G", d, fix_mode);
            } else {
                sc_put("\n");
            }
            break;
        }
        case 'L': {
            if (!d) break;
            int x = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
            int w = (int)ui_parse_num(&a), h = (int)ui_parse_num(&a);
            WIDGET_CALL(&d->base.base, layout, x, y, w, h);
            dump_state("L", d, fix_mode);
            break;
        }
        case 'R': {
            if (!d) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(&d->base.base, render, scr, (void *)theme);
            sc_put("R\n");
            if (fix_mode) {
                ui_dump(scr, d->base.base.y, d->base.base.h);
            } else {
                /* Skip row y+h-2 in diff mode (asm dlg_layout_right_buttons bug) */
                ui_dump(scr, d->base.base.y, d->base.base.h - 2);
                ui_dump(scr, d->base.base.y + d->base.base.h - 1, 1);
            }
            break;
        }
        case 'K': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                d->base.result = 0;
                (void)WIDGET_CALL(&d->base.base, on_key, &evt);
                sc_put("K redr="); sc_num(g_app.need_redraw);
                sc_put(" res="); sc_num(d->base.result);
                sc_put(" "); dump_state("S", d, 0);
            }
            break;
        }
        case 'M': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                d->base.result = 0;
                (void)WIDGET_CALL(&d->base.base, on_mouse, &evt);
                sc_put("M redr="); sc_num(g_app.need_redraw);
                sc_put(" res="); sc_num(d->base.result);
                sc_put(" "); dump_state("S", d, 0);
            }
            break;
        }
        case 'V': { /* V <virtual_mode> -> test fp_exit_virtual + fp_draw_search_badge */
            g_model.virtual_mode = (uint32_t)ui_parse_num(&a);
            g_pane.cursor = 5; g_pane.scroll = 3;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            ScreenBuffer_set_pen(scr, theme->accent, theme->bg, ATTR_BOLD);
            CALLV(fp_draw_search_badge, &g_pane, scr);
            ui_dump(scr, g_pane.base.y, 1);
            int rc = CALL(fp_exit_virtual, &g_pane);
            sc_put("V rc="); sc_num(rc);
            sc_put(" vm="); sc_num(g_model.virtual_mode);
            sc_put(" cur="); sc_num(g_pane.cursor);
            sc_put(" scr="); sc_num(g_pane.scroll);
            sc_put("\n");
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    if (d) DUOP_DELETE(d);
    sc_flush();
    return 0;
}
