/* Freestanding differential harness for src/ui/header_bar.c versus frozen x86_64 asm
 * (tests/harness/header_bar_reference.s + header_bar_render_reference.s, ref_ prefix).
 * argv[1] = ref | c. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static FilePane g_fp;
static DirModel g_dm;
static int g_fail_alloc;

void hdr_draw_git_badge(void *hdr, void *scr, const void *theme, int x, int y)
{
    (void)hdr; (void)scr; (void)theme;
    sc_put("call hdr_draw_git_badge x="); sc_num(x); sc_put(" y="); sc_num(y); sc_put("\n");
}

void App_cmd_cycle_theme(App *app)    { sc_put("call App_cmd_cycle_theme "); sc_num(app == &g_app); sc_put("\n"); }
void App_cmd_toggle_preview(App *app) { sc_put("call App_cmd_toggle_preview "); sc_num(app == &g_app); sc_put("\n"); }
void App_cmd_toggle_hidden(App *app)  { sc_put("call App_cmd_toggle_hidden "); sc_num(app == &g_app); sc_put("\n"); }
void App_cmd_toggle_lang(App *app)    { sc_put("call App_cmd_toggle_lang "); sc_num(app == &g_app); sc_put("\n"); }
void App_cmd_help(App *app)           { sc_put("call App_cmd_help "); sc_num(app == &g_app); sc_put("\n"); }
void App_cmd_quit(App *app)           { sc_put("call App_cmd_quit "); sc_num(app == &g_app); sc_put("\n"); }

void *fake_Object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_Object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define Object_alloc fake_Object_alloc
#include HB_SRC
#undef Object_alloc

#ifdef __x86_64__
extern HeaderBar *ref_HeaderBar_new(App *app);
#define NEW_HB(app) (g_ref ? ref_HeaderBar_new(app) : HeaderBar_new(app))
#else
#define NEW_HB(app) HeaderBar_new(app)
#endif

static bool g_ref;

static void dump_zones(const HeaderBar *hb)
{
    sc_put("Z cnt="); sc_num(hb->zone_count); sc_put(" hov="); sc_num((int32_t)hb->hovered_id);
    const HitZone *zs = (const HitZone *)hb->zones;
    for (uint32_t i = 0; i < hb->zone_count && i < 8; i++) {
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
    ScreenBuffer *scr = ScreenBuffer_new(140, 4);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    mem_zero(&g_fp, sizeof g_fp);
    mem_zero(&g_dm, sizeof g_dm);
    g_fp.model = (uint64_t)(uintptr_t)&g_dm;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_fp;
    g_app.theme = (uintptr_t)theme;

    g_fail_alloc = 1;
    HeaderBar *oom = NEW_HB(&g_app);
    sc_put("OOM="); sc_num(oom == nullptr); sc_put("\n");

    HeaderBar *hb = NEW_HB(&g_app);
    if (!hb) return 4;
    sc_put("NEW id="); sc_num(hb->base.id);
    sc_put(" app="); sc_num(hb->app == (uint64_t)(uintptr_t)&g_app);
    sc_put(" hov="); sc_num((int32_t)hb->hovered_id);
    sc_put(" cls="); sc_put(((const ObjectVtbl *)hb->base.base.vptr)->class_name);
    sc_put("\n");

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'S': {
            g_app.right_mode = (uint32_t)ui_parse_num(&a);
            g_dm.show_hidden = (uint32_t)ui_parse_num(&a);
            break;
        }
        case 'L': {
            int x = (int)ui_parse_num(&a);
            int y = (int)ui_parse_num(&a);
            int w = (int)ui_parse_num(&a);
            int h = (int)ui_parse_num(&a);
            WIDGET_CALL(hb, layout, x, y, w, h);
            dump_zones(hb);
            break;
        }
        case 'R': {
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(hb, render, scr, (void *)theme);
            ui_dump(scr, (int)hb->base.y, 1);
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
            int rc = WIDGET_CALL(hb, on_mouse, &ev);
            sc_put("M rc="); sc_num(rc);
            sc_put(" hov="); sc_num((int32_t)hb->hovered_id);
            sc_put(" rd="); sc_num(g_app.need_redraw);
            sc_put("\n");
            break;
        }
        case 'C':
        case 'X': {
            /* C: x1 (inclusive), X: x2 (exclusive right edge) of zone idx */
            int idx = (int)ui_parse_num(&a);
            int kind = (int)ui_parse_num(&a);
            int btn = (int)ui_parse_num(&a);
            const HitZone *zs = (const HitZone *)hb->zones;
            if (idx >= 0 && idx < (int)hb->zone_count) {
                Event ev;
                mem_zero(&ev, sizeof ev);
                ev.type = EVT_MOUSE;
                ev.mouse_kind = kind;
                ev.mouse_btn = btn;
                ev.mouse_x = line[0] == 'X' ? (int16_t)zs[idx].x2 : (int16_t)zs[idx].x1;
                ev.mouse_y = (int16_t)zs[idx].y;
                g_app.need_redraw = 0;
                int rc = WIDGET_CALL(hb, on_mouse, &ev);
                sc_put(line[0] == 'X' ? "X idx=" : "C idx="); sc_num(idx); sc_put(" rc="); sc_num(rc);
                sc_put(" hov="); sc_num((int32_t)hb->hovered_id);
                sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            }
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    DUOP_DELETE(hb);
    sc_flush();
    return 0;
}
