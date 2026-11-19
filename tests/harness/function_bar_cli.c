/* Freestanding differential harness for src/ui/function_bar.c versus frozen x86_64 asm
 * (tests/harness/function_bar_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;

void App_dispatch_f_action(App *app, int idx)
{
    sc_put("call App_dispatch_f_action ");
    sc_num(app == &g_app);
    sc_put(" idx=");
    sc_num(idx);
    sc_put("\n");
}

void *fake_Object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_Object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define Object_alloc fake_Object_alloc
#include FB_SRC
#undef Object_alloc

#ifdef __x86_64__
extern FunctionBar *ref_FunctionBar_new(App *app);
#define NEW_FB(app) (g_ref ? ref_FunctionBar_new(app) : FunctionBar_new(app))
#else
#define NEW_FB(app) FunctionBar_new(app)
#endif

static bool g_ref;

static void dump_zones(const FunctionBar *fb)
{
    sc_put("Z cnt="); sc_num(fb->zone_count); sc_put(" hov="); sc_num((int32_t)fb->hovered_id);
    const HitZone *zs = (const HitZone *)fb->zones;
    for (uint32_t i = 0; i < fb->zone_count && i < 10; i++) {
        sc_put(" ["); sc_num((int16_t)zs[i].x1); sc_put(","); sc_num((int16_t)zs[i].x2);
        sc_put("@"); sc_num((int16_t)zs[i].y); sc_put("#"); sc_num((int16_t)zs[i].id); sc_put("]");
    }
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(120, 4);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;

    /* Test OOM on FunctionBar_new */
    g_fail_alloc = 1;
    FunctionBar *oom_fb = NEW_FB(&g_app);
    sc_put("OOM="); sc_num(oom_fb == nullptr); sc_put("\n");

    FunctionBar *fb = NEW_FB(&g_app);
    if (!fb) return 4;
    sc_put("NEW id="); sc_num(fb->base.id);
    sc_put(" app="); sc_num(fb->app == (uint64_t)(uintptr_t)&g_app);
    sc_put(" hov="); sc_num((int32_t)fb->hovered_id);
    sc_put(" cls="); sc_put(((const ObjectVtbl *)fb->base.base.vptr)->class_name);
    sc_put("\n");

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'L': {
            int x = (int)ui_parse_num(&a);
            int y = (int)ui_parse_num(&a);
            int w = (int)ui_parse_num(&a);
            int h = (int)ui_parse_num(&a);
            WIDGET_CALL(fb, layout, x, y, w, h);
            dump_zones(fb);
            break;
        }
        case 'R': {
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(fb, render, scr, (void *)theme);
            ui_dump(scr, (int)fb->base.y, 1);
            break;
        }
        case 'M': {
            Event ev;
            mem_zero(&ev, sizeof ev);
            ev.type = EVT_MOUSE;
            ev.mouse_kind = (int32_t)ui_parse_num(&a);
            ev.mouse_btn = (int32_t)ui_parse_num(&a);
            ev.mouse_x = (int32_t)ui_parse_num(&a);
            ev.mouse_y = (int32_t)ui_parse_num(&a);
            g_app.need_redraw = 0;
            int rc = WIDGET_CALL(fb, on_mouse, &ev);
            sc_put("M rc="); sc_num(rc);
            sc_put(" hov="); sc_num((int32_t)fb->hovered_id);
            sc_put(" rd="); sc_num(g_app.need_redraw);
            sc_put("\n");
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    DUOP_DELETE(fb);
    sc_flush();
    return 0;
}
