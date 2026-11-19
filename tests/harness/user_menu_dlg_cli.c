/* Freestanding differential harness for src/ui/user_menu_dlg.c versus frozen x86_64 asm
 * (tests/harness/user_menu_dlg_reference.s, ref_ prefix).
 * argv[1] = ref | c (core diff) | fix_c | fix_ref (proves asm dlg_layout_right_buttons fix). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;

static const char *const g_cfg_labels[10] = {
    "Open terminal here", "Git status", "Disk usage", "Archive zip", "Compare files",
    "Count lines", "Checksum SHA256", "Edit duoprc", "Reload config", "Show mounts",
};
static PkgAction g_pkg_acts[4];
static int g_pkg_cnt;

int config_menu_count(void) { return 10; }
int config_menu_item(int idx, const char **out_label, const char **out_cmd)
{
    if (idx < 0 || idx >= 10) return 0;
    *out_label = g_cfg_labels[idx];
    if (out_cmd) *out_cmd = "true";
    return 1;
}

int pkg_menu_refresh(char **envp)
{
    (void)envp;
    mem_zero(g_pkg_acts, sizeof g_pkg_acts);
    (void)str_copy(g_pkg_acts[0].menu, "Pkg: Format", sizeof g_pkg_acts[0].menu);
    (void)str_copy(g_pkg_acts[1].menu, "Pkg: Lint", sizeof g_pkg_acts[1].menu);
    (void)str_copy(g_pkg_acts[2].menu, "Pkg: Bench", sizeof g_pkg_acts[2].menu);
    (void)str_copy(g_pkg_acts[3].menu, "Pkg: Deploy", sizeof g_pkg_acts[3].menu);
    g_pkg_cnt = 4;
    return g_pkg_cnt;
}
int pkg_menu_count(void) { return g_pkg_cnt; }
PkgAction *pkg_menu_get(int idx) { return (idx >= 0 && idx < g_pkg_cnt) ? &g_pkg_acts[idx] : nullptr; }

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
#include UM_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_UserMenuDialog_vtbl;
extern UserMenuDialog *ref_UserMenuDialog_new(App *app);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define UM_VTBL (g_ref ? &ref_UserMenuDialog_vtbl : &UserMenuDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define UM_VTBL (&UserMenuDialog_vtbl)
#endif

static bool g_ref;

static void dump_state(const char *tag, const UserMenuDialog *d, int with_btns)
{
    sc_put(tag);
    sc_put(" rect "); sc_num(d->base.base.x); sc_put(" "); sc_num(d->base.base.y);
    sc_put(" "); sc_num(d->base.base.w); sc_put(" "); sc_num(d->base.base.h);
    sc_put(" cur="); sc_num(d->cursor);
    sc_put(" scr="); sc_num(d->scroll);
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
    UserMenuDialog *d = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (d) { DUOP_DELETE(d); d = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            g_fail_alloc = (int)ui_parse_num(&a);
            d = CALL(UserMenuDialog_new, &g_app);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_u="); sc_num(Object_is_instance((const Object *)d, (const ObjectVtbl *)UM_VTBL));
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
        default: continue;
        }
        sc_flush();
    }
    if (d) DUOP_DELETE(d);
    sc_flush();
    return 0;
}
