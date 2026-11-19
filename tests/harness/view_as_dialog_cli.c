/* Freestanding differential harness for src/ui/view_as_dialog.c versus frozen x86_64 asm
 * (tests/harness/view_as_dialog_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;

void App_close_dialog(App *app, int result)
{
    ui_log_call2("App_close_dialog", app == &g_app, result);
}

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define Object_alloc fake_object_alloc
#include VAS_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_ViewAsDialog_vtbl;
extern ViewAsDialog *ref_ViewAsDialog_new(App *app, const char *path, int fmt);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define VAS_VTBL (g_ref ? &ref_ViewAsDialog_vtbl : &ViewAsDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define VAS_VTBL (&ViewAsDialog_vtbl)
#endif

static bool g_ref;

static void dump_state(const char *tag, const ViewAsDialog *d)
{
    sc_put(tag);
    sc_put(" rect "); sc_num(d->base.base.x); sc_put(" "); sc_num(d->base.base.y);
    sc_put(" "); sc_num(d->base.base.w); sc_put(" "); sc_num(d->base.base.h);
    sc_put(" ch="); sc_num(d->choice);
    sc_put(" fmt="); sc_num(d->fmt);
    sc_put(" fb="); sc_num(d->base.focus_btn);
    const HitZone *z = (const HitZone *)d->base.btns;
    sc_put(" bc="); sc_num(d->base.btn_count);
    for (uint32_t i = 0; i < d->base.btn_count && i < 4; i++) {
        sc_put(" ["); sc_num((int16_t)z[i].x1); sc_put(".."); sc_num((int16_t)z[i].x2);
        sc_put("@"); sc_num((int16_t)z[i].y); sc_put(" id="); sc_num((int16_t)z[i].id); sc_put("]");
    }
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(80, 20);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    ViewAsDialog *d = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (d) { DUOP_DELETE(d); d = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            int fmt = (int)ui_parse_num(&a);
            g_fail_alloc = (int)ui_parse_num(&a);
            d = CALL(ViewAsDialog_new, &g_app, "/tmp/photos/sunset.png", fmt);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_v="); sc_num(Object_is_instance((const Object *)d, (const ObjectVtbl *)VAS_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(d, Dialog_vtbl));
                sc_put(" tag="); sc_num(d->base.op_tag);
                sc_put("\n");
                dump_state("G", d);
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
            dump_state("L", d);
            break;
        }
        case 'R': {
            if (!d) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(&d->base.base, render, scr, (void *)theme);
            dump_state("R", d);
            ui_dump(scr, d->base.base.y, d->base.base.h);
            break;
        }
        case 'K': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                d->base.result = 0;
                int rc = WIDGET_CALL(&d->base.base, on_key, &evt);
                ui_dump_event_res("K", rc, &g_app, &d->base);
                sc_put("  ch="); sc_num(d->choice); sc_put("\n");
            }
            break;
        }
        case 'M': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                d->base.result = 0;
                int rc = WIDGET_CALL(&d->base.base, on_mouse, &evt);
                ui_dump_event_res("M", rc, &g_app, &d->base);
                sc_put("  ch="); sc_num(d->choice); sc_put("\n");
            }
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
