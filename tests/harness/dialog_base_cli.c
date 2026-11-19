/* Freestanding differential harness for src/ui/{dialog,dialog_confirm}.c versus frozen x86_64 asm
 * (tests/harness/dialogs{,_confirm}_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   N <tw> <th> <op_tag> <fail_alloc>    ConfirmDialog_new + instanceof checks + layout dump
 *   L <x> <y> <w> <h>                    WIDGET_CALL(cd, layout, x, y, w, h) + rect/btns dump
 *   R                                    WIDGET_CALL(cd, render, scr, theme) + ui_dump
 *   K <key> <mods> [lat]                 WIDGET_CALL(cd, on_key, &evt) + state dump
 *   M <kind> <btn> <x> <y> [mods]        WIDGET_CALL(cd, on_mouse, &evt) + state dump
 *   B <one_btn>                          dlg_layout_right_buttons (1 or 2 btns) + Dialog_draw_frame + dump
 *   D                                    test base Dialog_init / Dialog_layout / Dialog_render / Dialog_dtor */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;

void fake_close_dialog(App *app, int result);
void fake_close_dialog(App *app, int result)
{
    ui_log_call2("App_close_dialog", app == &g_app, result);
}

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define App_close_dialog fake_close_dialog
#include DLG_SRC
#undef App_close_dialog

#define Object_alloc fake_object_alloc
#include CNF_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_Dialog_vtbl;
extern const DialogVtbl ref_ConfirmDialog_vtbl;
extern ConfirmDialog *ref_ConfirmDialog_new(App *app, const char *title, const char *msg, const char *det, uint32_t op_tag);
extern void ref_Dialog_init(Dialog *self, App *app, const char *title, uint32_t op_tag);
extern void ref_Dialog_layout(Widget *self, int x, int y, int w, int h);
extern void ref_Dialog_render(Widget *self, void *scr, void *th);
extern void ref_Dialog_dtor(Widget *self);
extern void ref_Dialog_draw_frame(Dialog *self, ScreenBuffer *scr, const Theme *th, const char *b0, const char *b1);
extern void ref_dlg_layout_right_buttons(Dialog *self, const char *b0, const char *b1);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#define DLG_VTBL (g_ref ? &ref_Dialog_vtbl : &Dialog_vtbl)
#define CNF_VTBL (g_ref ? &ref_ConfirmDialog_vtbl : &ConfirmDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#define DLG_VTBL (&Dialog_vtbl)
#define CNF_VTBL (&ConfirmDialog_vtbl)
#endif

static bool g_ref;

static void dump_btns(const Dialog *d)
{
    sc_put("rect "); sc_num(d->base.x); sc_put(" "); sc_num(d->base.y);
    sc_put(" "); sc_num(d->base.w); sc_put(" "); sc_num(d->base.h);
    sc_put(" n="); sc_num(d->btn_count);
    const HitZone *z = (const HitZone *)d->btns;
    uint32_t n = d->btn_count <= 4 ? d->btn_count : 4;
    for (uint32_t i = 0; i < n; i++) {
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
    ScreenBuffer *scr = ScreenBuffer_new(80, 16);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    ConfirmDialog *cd = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (cd) { DUOP_DELETE(cd); cd = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            uint32_t tag = (uint32_t)ui_parse_num(&a);
            g_fail_alloc = (int)ui_parse_num(&a);
            cd = CALL(ConfirmDialog_new, &g_app, " Delete Привіт ", "Delete 3 items?", "/tmp/target", tag);
            sc_put("N ok="); sc_num(cd != nullptr);
            if (cd) {
                sc_put(" is_cd="); sc_num(Object_is_instance((const Object *)cd, (const ObjectVtbl *)CNF_VTBL));
                sc_put(" is_d="); sc_num(Object_is_instance((const Object *)cd, (const ObjectVtbl *)DLG_VTBL));
                sc_put(" is_w="); sc_num(Object_is_instance((const Object *)cd, (const ObjectVtbl *)&Widget_vtbl));
                sc_put(" tag="); sc_num(cd->base.op_tag);
                sc_put(" hov="); sc_num((int32_t)cd->base.hovered_btn);
                sc_put("\n");
                dump_btns(&cd->base);
            } else {
                sc_put("\n");
            }
            break;
        }
        case 'L': {
            if (!cd) break;
            int x = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
            int w = (int)ui_parse_num(&a), h = (int)ui_parse_num(&a);
            WIDGET_CALL(&cd->base.base, layout, x, y, w, h);
            dump_btns(&cd->base);
            break;
        }
        case 'R': {
            if (!cd) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(&cd->base.base, render, scr, (void *)theme);
            sc_put("R\n");
            ui_dump(scr, cd->base.base.y, cd->base.base.h);
            break;
        }
        case 'K': {
            if (!cd) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL(&cd->base.base, on_key, &evt);
                ui_dump_event_res("K", rc, &g_app, &cd->base);
            }
            break;
        }
        case 'M': {
            if (!cd) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL(&cd->base.base, on_mouse, &evt);
                ui_dump_event_res("M", rc, &g_app, &cd->base);
            }
            break;
        }
        case 'B': {
            if (!cd) break;
            int one = (int)ui_parse_num(&a);
            CALLV(dlg_layout_right_buttons, &cd->base, "[ OK ]", one ? nullptr : "[ Cancel ]");
            dump_btns(&cd->base);
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALLV(Dialog_draw_frame, &cd->base, scr, theme, "[ OK ]", one ? nullptr : "[ Cancel ]");
            sc_put("B\n");
            ui_dump(scr, cd->base.base.y, cd->base.base.h);
            break;
        }
        case 'D': {
            Dialog d;
            mem_zero(&d, sizeof d);
            d.base.base.vptr = (const ObjectVtbl *)DLG_VTBL;
            CALLV(Dialog_init, &d, &g_app, "Base", 9);
            CALLV(Dialog_layout, &d.base, 2, 3, 20, 6);
            CALLV(Dialog_render, &d.base, scr, (void *)theme);
            CALLV(Dialog_dtor, &d.base);
            sc_put("D "); dump_btns(&d);
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    if (cd) DUOP_DELETE(cd);
    sc_flush();
    return 0;
}
