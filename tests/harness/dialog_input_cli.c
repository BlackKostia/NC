/* Freestanding differential harness for src/ui/dialog_input.c versus frozen x86_64 asm
 * (tests/harness/dialogs_input_reference.s, ref_ prefix). argv[1] = ref | c. */
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
#include DI_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_InputDialog_vtbl;
extern InputDialog *ref_InputDialog_new(App *app, const char *title, const char *prompt,
                                        const char *initial_text, uint32_t op_tag);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define ID_VTBL (g_ref ? &ref_InputDialog_vtbl : &InputDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define ID_VTBL (&InputDialog_vtbl)
#endif

static bool g_ref;

static void dump_geom(const InputDialog *id)
{
    const Dialog *d = &id->base;
    sc_put("G rect "); sc_num(d->base.x); sc_put(" "); sc_num(d->base.y);
    sc_put(" "); sc_num(d->base.w); sc_put(" "); sc_num(d->base.h);
    sc_put(" n="); sc_num(d->btn_count);
    const HitZone *z = (const HitZone *)d->btns;
    uint32_t n = d->btn_count <= 4 ? d->btn_count : 4;
    for (uint32_t i = 0; i < n; i++) {
        sc_put(" ["); sc_num((int16_t)z[i].x1); sc_put(".."); sc_num((int16_t)z[i].x2);
        sc_put("@"); sc_num((int16_t)z[i].y); sc_put("]");
    }
    sc_put(" len="); sc_num(id->len);
    sc_put(" cur="); sc_num(id->cursor);
    sc_put(" scr="); sc_num(id->scroll);
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
    g_app.theme = (uintptr_t)theme;
    InputDialog *id = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (id) { DUOP_DELETE(id); id = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            uint32_t tag = (uint32_t)ui_parse_num(&a);
            g_fail_alloc = (int)ui_parse_num(&a);
            int mode = (int)ui_parse_num(&a);
            const char *init_txt = nullptr;
            if (mode == 1) init_txt = "hello.txt";
            else if (mode == 2) init_txt = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
            id = CALL(InputDialog_new, &g_app, "Rename", "New name:", init_txt, tag);
            sc_put("N ok="); sc_num(id != nullptr);
            if (id) {
                sc_put(" is_id="); sc_num(Object_is_instance((const Object *)id, (const ObjectVtbl *)ID_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(id, Dialog_vtbl));
                sc_put(" tag="); sc_num(id->base.op_tag);
                sc_put(" prompt="); sc_esc((const char *)id->prompt);
                sc_put(" buf="); sc_esc((const char *)id->buf);
                sc_put("\n");
                dump_geom(id);
            } else {
                sc_put("\n");
            }
            break;
        }
        case 'L': {
            if (!id) break;
            int x = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
            int w = (int)ui_parse_num(&a), h = (int)ui_parse_num(&a);
            WIDGET_CALL(&id->base.base, layout, x, y, w, h);
            dump_geom(id);
            break;
        }
        case 'R': {
            if (!id) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(&id->base.base, render, scr, (void *)theme);
            sc_put("R scr="); sc_num(id->scroll); sc_put(" cur="); sc_num(id->cursor); sc_put("\n");
            ui_dump(scr, id->base.base.y, id->base.base.h);
            break;
        }
        case 'C': {
            if (!id) break;
            int cur = (int)ui_parse_num(&a);
            int scroll = (int)ui_parse_num(&a);
            id->cursor = (uint32_t)cur;
            if (scroll >= 0) id->scroll = (uint32_t)scroll;
            break;
        }
        case 'K': {
            if (!id) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL(&id->base.base, on_key, &evt);
                ui_dump_event_res("K", rc, &g_app, &id->base);
                sc_put("  buf="); sc_esc((const char *)id->buf);
                sc_put(" len="); sc_num(id->len);
                sc_put(" cur="); sc_num(id->cursor); sc_put("\n");
            }
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    if (id) DUOP_DELETE(id);
    sc_flush();
    return 0;
}
