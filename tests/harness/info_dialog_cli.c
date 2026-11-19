/* Freestanding differential harness for src/ui/info_dialog.c versus frozen x86_64 asm
 * (tests/harness/info_dialog_reference.s, ref_ prefix).
 * argv[1] = ref | c (core state/layout/key/content diff)
 *         | fix_c | fix_ref (proves asm dlg_layout_right_buttons bug fixed in C). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_hash.h"
#include "duop_pal.h"
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
#include INF_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_InfoDialog_vtbl;
extern InfoDialog *ref_InfoDialog_new(App *app, const char *path);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define INF_VTBL (g_ref ? &ref_InfoDialog_vtbl : &InfoDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define INF_VTBL (&InfoDialog_vtbl)
#endif

static bool g_ref;

static inline void *unpacked(const InfoDialog *d)
{
    return (void *)(uintptr_t)d;
}

static void dump_state(const char *tag, const InfoDialog *d, int with_btns)
{
    const Dialog *dlg = unpacked(d);
    sc_put(tag);
    sc_put(" rect "); sc_num(dlg->base.x); sc_put(" "); sc_num(dlg->base.y);
    sc_put(" "); sc_num(dlg->base.w); sc_put(" "); sc_num(dlg->base.h);
    sc_put(" hok="); sc_num(d->hash_ok);
    sc_put(" crc="); sc_num((int64_t)d->crc32);
    if (d->hash_ok) {
        sc_put(" sha="); sc_esc((const char *)d->sha_hex);
    }
    if (with_btns) {
        const HitZone *z = (const HitZone *)dlg->btns;
        sc_put(" bc="); sc_num(dlg->btn_count);
        for (uint32_t i = 0; i < dlg->btn_count && i < 4; i++) {
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
    InfoDialog *d = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (d) { DUOP_DELETE(unpacked(d)); d = nullptr; }
            int null_app = (int)ui_parse_num(&a);
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            g_fail_alloc = (int)ui_parse_num(&a);
            while (*a == ' ') a++;
            d = CALL(InfoDialog_new, null_app ? nullptr : &g_app, a);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_id="); sc_num(Object_is_instance((const Object *)unpacked(d), (const ObjectVtbl *)INF_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(unpacked(d), Dialog_vtbl));
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
            WIDGET_CALL((Widget *)unpacked(d), layout, x, y, w, h);
            dump_state("L", d, fix_mode);
            break;
        }
        case 'R': {
            if (!d) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL((Widget *)unpacked(d), render, scr, (void *)theme);
            sc_put("R\n");
            if (fix_mode) {
                ui_dump(scr, d->base.base.y, d->base.base.h);
            } else {
                /* Skip button row y+h-2 in diff mode (asm dlg_layout_right_buttons bug) */
                ui_dump(scr, d->base.base.y, d->base.base.h - 2);
                ui_dump(scr, d->base.base.y + d->base.base.h - 1, 1);
            }
            break;
        }
        case 'K': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                d->base.result = 0;
                (void)WIDGET_CALL((Widget *)unpacked(d), on_key, &evt);
                sc_put("K res="); sc_num(d->base.result); sc_put("\n");
            }
            break;
        }
        case 'M': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                d->base.result = 0;
                (void)WIDGET_CALL((Widget *)unpacked(d), on_mouse, &evt);
                sc_put("M res="); sc_num(d->base.result); sc_put("\n");
            }
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    if (d) DUOP_DELETE(unpacked(d));
    sc_flush();
    return 0;
}
