/* Freestanding differential harness for src/ui/conflict_dialog.c versus frozen x86_64 asm
 * (tests/harness/conflict_dialog{,_input}_reference.s, ref_ prefix). argv[1] = ref | c | oom. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_task.h"
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
#include CD_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_ConflictDialog_vtbl;
extern ConflictDialog *ref_ConflictDialog_new(App *app, const char *name, uint64_t src_sz, uint64_t dst_sz);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CD_VTBL (g_ref ? &ref_ConflictDialog_vtbl : &ConflictDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CD_VTBL (&ConflictDialog_vtbl)
#endif

static bool g_ref;

static void dump_state(const char *tag, const ConflictDialog *cd)
{
    const Dialog *d = &cd->base;
    sc_put(tag);
    sc_put(" rect "); sc_num(d->base.x); sc_put(" "); sc_num(d->base.y);
    sc_put(" "); sc_num(d->base.w); sc_put(" "); sc_num(d->base.h);
    sc_put(" fb="); sc_num(d->focus_btn);
    sc_put(" act="); sc_num(cd->action);
    sc_put(" all="); sc_num(cd->for_all);
    sc_put(" sz="); sc_num((int64_t)cd->src_size); sc_put("/"); sc_num((int64_t)cd->dst_size);
    const HitZone *z = (const HitZone *)d->btns;
    sc_put(" n="); sc_num(d->btn_count);
    for (uint32_t i = 0; i < d->btn_count && i < 4; i++) {
        sc_put(" ["); sc_num((int16_t)z[i].x1); sc_put(".."); sc_num((int16_t)z[i].x2);
        sc_put("@"); sc_num((int16_t)z[i].y); sc_put(" id="); sc_num((int16_t)z[i].id); sc_put("]");
    }
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    if (argv[1][0] == 'o') {
        /* C-only OOM regression test (asm ConflictDialog_new dereferenced NULL) */
        ui_app_reset(&g_app);
        g_app.term_w = 80;
        g_app.term_h = 24;
        g_fail_alloc = 1;
        ConflictDialog *cd = ConflictDialog_new(&g_app, "foo.txt", 10, 20);
        sc_put("OOM ok="); sc_num(cd == nullptr); sc_put("\n");
        sc_flush();
        return cd == nullptr ? 0 : 1;
    }
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(80, 20);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    ConflictDialog *cd = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (cd) { DUOP_DELETE(cd); cd = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            uint64_t ssz = (uint64_t)ui_parse_num(&a);
            uint64_t dsz = (uint64_t)ui_parse_num(&a);
            cd = CALL(ConflictDialog_new, &g_app, "report_2026.tar.gz", ssz, dsz);
            sc_put("N ok="); sc_num(cd != nullptr);
            if (cd) {
                sc_put(" is_cd="); sc_num(Object_is_instance((const Object *)cd, (const ObjectVtbl *)CD_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(cd, Dialog_vtbl));
                sc_put(" tag="); sc_num(cd->base.op_tag);
                sc_put(" name="); sc_esc((const char *)cd->name);
                sc_put("\n");
                dump_state("G", cd);
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
            dump_state("L", cd);
            break;
        }
        case 'R': {
            if (!cd) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(&cd->base.base, render, scr, (void *)theme);
            dump_state("R", cd);
            ui_dump(scr, cd->base.base.y, cd->base.base.h);
            break;
        }
        case 'K': {
            if (!cd) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL(&cd->base.base, on_key, &evt);
                ui_dump_event_res("K", rc, &g_app, &cd->base);
                sc_put("  act="); sc_num(cd->action); sc_put(" all="); sc_num(cd->for_all); sc_put("\n");
            }
            break;
        }
        case 'M': {
            if (!cd) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL(&cd->base.base, on_mouse, &evt);
                ui_dump_event_res("M", rc, &g_app, &cd->base);
                sc_put("  act="); sc_num(cd->action); sc_put(" all="); sc_num(cd->for_all); sc_put("\n");
            }
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
