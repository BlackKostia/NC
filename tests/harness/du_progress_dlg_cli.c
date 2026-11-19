/* Freestanding differential harness for src/ui/du_progress_dlg.c versus frozen x86_64 asm
 * (tests/harness/du_progress_dlg_reference.s, ref_ prefix). argv[1] = ref | c | oom. */
#include "duop_classes.h"
#include "duop_du.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static DuProgress g_dp;
static int g_fail_alloc;

DuProgress *du_progress(void) { return &g_dp; }
void App_close_dialog(App *app, int result) { ui_log_call2("App_close_dialog", app == &g_app, result); }

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define Object_alloc fake_object_alloc
#include DPD_SRC
#undef Object_alloc

#ifdef __x86_64__
extern Dialog *ref_DuProgressDialog_new(App *app);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

static void dump_rect(const char *tag, const Dialog *d)
{
    sc_put(tag);
    sc_put(" rect="); sc_num(d->base.x); sc_put(","); sc_num(d->base.y);
    sc_put(","); sc_num(d->base.w); sc_put(","); sc_num(d->base.h);
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
        Dialog *d = DuProgressDialog_new(&g_app);
        sc_put("OOM ok="); sc_num(d == nullptr); sc_put("\n");
        sc_flush();
        return d == nullptr ? 0 : 1;
    }
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(100, 30);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    Dialog *d = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'N': {
            if (d) { DUOP_DELETE(d); d = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            d = CALL(DuProgressDialog_new, &g_app);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(d, Dialog_vtbl));
                sc_put(" title="); sc_esc((const char *)(uintptr_t)d->title);
            }
            sc_put("\n");
            if (d) dump_rect("N", d);
            break;
        }
        case 'P': {
            mem_zero(&g_dp, sizeof g_dp);
            g_dp.done = (int32_t)ui_parse_num(&a);
            g_dp.total = (int32_t)ui_parse_num(&a);
            g_dp.dirs = (uint64_t)ui_parse_num(&a);
            g_dp.files = (uint64_t)ui_parse_num(&a);
            g_dp.bytes = (uint64_t)ui_parse_num(&a);
            break;
        }
        case 'L': {
            if (!d) break;
            int x = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
            int w = (int)ui_parse_num(&a), h = (int)ui_parse_num(&a);
            WIDGET_CALL(&d->base, layout, x, y, w, h);
            dump_rect("L", d);
            break;
        }
        case 'R': {
            if (!d) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(&d->base, render, scr, nullptr);
            dump_rect("R", d);
            ui_dump(scr, d->base.y, d->base.h);
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
