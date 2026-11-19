/* Freestanding differential harness for src/ui/fuzzy_dialog.c versus frozen x86_64 asm
 * (tests/harness/fuzzy_dialog_reference.s, ref_ prefix).
 * argv[1] = ref | c (state/sort/keys/selection diff)
 *         | render_c (proves C fixes Dialog_draw_frame + theme + ScreenBuffer_set_cell_pen)
 *         | oom (proves C handles OOM on struct/items/matches without crash or leak). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;
static int g_live_allocs;

static PkgAction g_pkg_acts[2];
static int g_pkg_cnt;

int pkg_menu_refresh(char **envp)
{
    (void)envp;
    mem_zero(g_pkg_acts, sizeof g_pkg_acts);
    (void)str_copy(g_pkg_acts[0].menu, "Plugin: Format Code", sizeof g_pkg_acts[0].menu);
    (void)str_copy(g_pkg_acts[1].menu, "Plugin: Deploy App", sizeof g_pkg_acts[1].menu);
    g_pkg_cnt = 2;
    return g_pkg_cnt;
}
int pkg_menu_count(void) { return g_pkg_cnt; }
PkgAction *pkg_menu_get(int idx) { return (idx >= 0 && idx < g_pkg_cnt) ? &g_pkg_acts[idx] : nullptr; }

void App_close_dialog(App *app, int result)
{
    ui_log_call2("App_close_dialog", app == &g_app, result);
}

const Theme *theme_get(int idx)
{
    (void)idx;
    return ui_theme();
}

void *fake_mem_alloc(size_t size);
void *fake_mem_alloc(size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    void *p = mem_alloc(size);
    if (p) g_live_allocs++;
    return p;
}

void fake_mem_free(void *ptr);
void fake_mem_free(void *ptr)
{
    if (ptr) g_live_allocs--;
    mem_free(ptr);
}

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define mem_alloc fake_mem_alloc
#define mem_free fake_mem_free
#define Object_alloc fake_object_alloc
#include FZ_SRC
#undef mem_alloc
#undef mem_free
#undef Object_alloc

#ifdef __x86_64__
extern FuzzyDialog *ref_FuzzyDialog_new(App *app, int mode, const char *base_path);
extern uintptr_t ref_FuzzyDialog_get_selected(FuzzyDialog *self);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

static void dump_state(const char *tag, FuzzyDialog *d)
{
    uintptr_t sel = CALL(FuzzyDialog_get_selected, d);
    sc_put(tag);
    sc_put(" m="); sc_num(d->mode);
    sc_put(" tot="); sc_num(d->total_cnt);
    sc_put(" mc="); sc_num(d->match_cnt);
    sc_put(" cur="); sc_num(d->cursor);
    sc_put(" scr="); sc_num(d->scroll);
    sc_put(" q="); sc_esc((const char *)d->query_buf);
    if (d->mode == 0) {
        sc_put(" sel="); sc_num((int64_t)sel);
    } else {
        sc_put(" sel="); sc_esc(sel ? (const char *)sel : "<null>");
    }
    sc_put("\n");
}

static int run_oom_checks(void)
{
    ui_app_reset(&g_app);
    g_app.term_w = 80;
    g_app.term_h = 24;
    for (int k = 1; k <= 3; k++) {
        g_live_allocs = 0;
        g_fail_alloc = k;
        FuzzyDialog *d = FuzzyDialog_new(&g_app, 0, nullptr);
        sc_put("OOM k="); sc_num(k);
        sc_put(" null="); sc_num(d == nullptr);
        sc_put(" live="); sc_num(g_live_allocs);
        sc_put("\n");
        if (d || g_live_allocs != 0) { sc_flush(); return 1; }
    }
    sc_flush();
    return 0;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    if (argv[1][0] == 'o') return run_oom_checks();
    bool render_only = (argv[1][0] == 'R');
    g_ref = argv[1][0] == 'r';

    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(80, 24);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    g_app.term_w = 80;
    g_app.term_h = 24;
    FuzzyDialog *d = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'N': {
            if (d) { DUOP_DELETE(d); d = nullptr; }
            int mode = (int)ui_parse_num(&a);
            while (*a == ' ') a++;
            d = CALL(FuzzyDialog_new, &g_app, mode, mode ? a : nullptr);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(d, Dialog_vtbl));
                sc_put(" tag="); sc_num(d->base.op_tag);
                sc_put(" rect "); sc_num(d->base.base.x); sc_put(" "); sc_num(d->base.base.y);
                sc_put(" "); sc_num(d->base.base.w); sc_put(" "); sc_num(d->base.base.h);
                sc_put("\n");
                dump_state("G", d);
            } else {
                sc_put("\n");
            }
            break;
        }
        case 'R': {
            if (!d || !render_only) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(&d->base.base, render, scr, (void *)theme);
            sc_put("R\n");
            ui_dump(scr, d->base.base.y, d->base.base.h);
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
                sc_put(" "); dump_state("S", d);
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
