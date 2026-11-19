/* Freestanding differential harness for src/ui/dialog_help.c versus frozen x86_64 asm
 * (tests/harness/dialogs_help{,_input}_reference.s, ref_ prefix). argv[1] = ref | c | oom. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_keys.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;

void App_close_dialog(App *app, int result) { ui_log_call2("App_close_dialog", app == &g_app, result); }

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define Object_alloc fake_object_alloc
#include HD_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_HelpDialog_vtbl;
extern HelpDialog *ref_HelpDialog_new(App *app);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define HD_VTBL (g_ref ? &ref_HelpDialog_vtbl : &HelpDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define HD_VTBL (&HelpDialog_vtbl)
#endif

static bool g_ref;

static void dump_state(const char *tag, const HelpDialog *d)
{
    const Dialog *b = &d->base;
    const HitZone *tz = (const HitZone *)(const void *)d->tab_zones;
    const HitZone *bz = (const HitZone *)(const void *)b->btns;
    sc_put(tag);
    sc_put(" rect="); sc_num(b->base.x); sc_put(","); sc_num(b->base.y);
    sc_put(","); sc_num(b->base.w); sc_put(","); sc_num(b->base.h);
    sc_put(" tab="); sc_num(d->tab);
    sc_put(" sc="); sc_num(d->scroll);
    sc_put(" rd="); sc_num(g_app.need_redraw);
    for (int i = 0; i < 2; i++) {
        sc_put(" t"); sc_num(i); sc_put("=["); sc_num((int16_t)tz[i].x1);
        sc_put(".."); sc_num((int16_t)tz[i].x2); sc_put("@"); sc_num((int16_t)tz[i].y); sc_put("]");
    }
    if (b->btn_count > 0) {
        sc_put(" b0=["); sc_num((int16_t)bz[0].x1); sc_put(".."); sc_num((int16_t)bz[0].x2);
        sc_put("@"); sc_num((int16_t)bz[0].y); sc_put("]");
    }
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    if (argv[1][0] == 'o') {
        ui_app_reset(&g_app);
        g_app.term_w = 80;
        g_app.term_h = 24;
        g_fail_alloc = 1;
        HelpDialog *d = HelpDialog_new(&g_app);
        sc_put("OOM ok="); sc_num(d == nullptr); sc_put("\n");
        sc_flush();
        return d == nullptr ? 0 : 1;
    }
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(100, 32);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    HelpDialog *d = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (d) { DUOP_DELETE(d); d = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            g_app.need_redraw = 0;
            d = CALL(HelpDialog_new, &g_app);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_hd="); sc_num(Object_is_instance((const Object *)d, (const ObjectVtbl *)HD_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(d, Dialog_vtbl));
            }
            sc_put("\n");
            if (d) dump_state("N", d);
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
                int rc = WIDGET_CALL(&d->base.base, on_key, &evt);
                sc_put("K rc="); sc_num(rc); sc_put(" ");
                dump_state("K", d);
            }
            break;
        }
        case 'M': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL(&d->base.base, on_mouse, &evt);
                sc_put("M rc="); sc_num(rc); sc_put(" ");
                dump_state("M", d);
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
