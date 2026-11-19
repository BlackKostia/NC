/* Freestanding differential harness for src/ui/bookmark_dlg.c versus frozen x86_64 asm
 * (tests/harness/bookmark_dlg{,_input}_reference.s, ref_ prefix). argv[1] = ref | c | oom. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static FilePane g_pane;
static DirModel g_model;
static int g_fail_alloc;

/* Deterministic in-memory bookmark / frecency tables shared by both C and ref asm */
static char g_bm[32][64];
static int g_bm_cnt;
static const char *const g_fre[16] = {
    "/home/user/projects/duop", "/home/user/projects/alpha", "/var/log/syslog",
    "/etc/nginx", "/tmp/work/build", "/opt/tools/bin", "/usr/local/share",
    "/home/user/docs/notes", "/home/user/music", "/home/user/videos",
    "/srv/www/app", "/var/cache/pkg", "/home/user/downloads",
    "/home/user/projects/beta", "/tmp/scratch", "/etc/systemd",
};
static int g_fre_cnt;

int nav_bookmarks_count(void) { return g_bm_cnt; }
const char *nav_bookmarks_get(int idx) { return (idx >= 0 && idx < g_bm_cnt) ? g_bm[idx] : nullptr; }
int nav_bookmarks_add(const char *path)
{
    if (g_bm_cnt >= 32) return 0;
    (void)str_copy(g_bm[g_bm_cnt++], path, 64);
    return 1;
}
void nav_bookmarks_remove(int idx)
{
    if (idx < 0 || idx >= g_bm_cnt) return;
    for (int i = idx; i + 1 < g_bm_cnt; i++) (void)str_copy(g_bm[i], g_bm[i + 1], 64);
    g_bm_cnt--;
}
const char *nav_frecency_get(int idx) { return (idx >= 0 && idx < g_fre_cnt) ? g_fre[idx] : nullptr; }
int nav_frecency_match(const char *substr, int *out_indices, int max_out)
{
    int n = 0;
    for (int i = 0; i < g_fre_cnt && n < max_out; i++) {
        if (!substr[0] || str_contains_ci(g_fre[i], substr)) out_indices[n++] = i;
    }
    return n;
}

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
#include BM_SRC
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_BookmarkDialog_vtbl;
extern BookmarkDialog *ref_BookmarkDialog_new(App *app, int mode);
extern const char *ref_BookmarkDialog_get_selected(BookmarkDialog *self);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define BM_VTBL (g_ref ? &ref_BookmarkDialog_vtbl : &BookmarkDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define BM_VTBL (&BookmarkDialog_vtbl)
#endif

static bool g_ref;

static void dump_state(const char *tag, BookmarkDialog *d)
{
    const char *sel = CALL(BookmarkDialog_get_selected, d);
    sc_put(tag);
    sc_put(" rect "); sc_num(d->base.base.x); sc_put(" "); sc_num(d->base.base.y);
    sc_put(" "); sc_num(d->base.base.w); sc_put(" "); sc_num(d->base.base.h);
    sc_put(" m="); sc_num(d->mode);
    sc_put(" cur="); sc_num(d->cursor);
    sc_put(" scr="); sc_num(d->scroll);
    sc_put(" cnt="); sc_num(d->match_cnt);
    sc_put(" flt="); sc_esc((const char *)d->filter);
    sc_put(" sel="); sc_esc(sel ? sel : "<null>");
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
        BookmarkDialog *d = BookmarkDialog_new(&g_app, 0);
        sc_put("OOM ok="); sc_num(d == nullptr); sc_put("\n");
        sc_flush();
        return d == nullptr ? 0 : 1;
    }
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(80, 24);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    mem_zero(&g_pane, sizeof g_pane);
    mem_zero(&g_model, sizeof g_model);
    (void)str_copy((char *)g_model.path, "/added/from/pane", sizeof g_model.path);
    g_pane.model = (uintptr_t)&g_model;
    g_app.active_pane = (uintptr_t)&g_pane;
    g_app.theme = (uintptr_t)theme;

    BookmarkDialog *d = nullptr;
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'S': { /* Seed counts: S <bm_cnt> <fre_cnt> */
            int bc = (int)ui_parse_num(&a), fc = (int)ui_parse_num(&a);
            g_bm_cnt = 0;
            for (int i = 0; i < bc && i < 20; i++) {
                char tmp[64];
                (void)str_copy(tmp, "/bm/dir_", sizeof tmp);
                (void)u64_to_dec((uint64_t)i, tmp + 8);
                (void)nav_bookmarks_add(tmp);
            }
            g_fre_cnt = fc;
            break;
        }
        case 'N': {
            if (d) { DUOP_DELETE(d); d = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            int mode = (int)ui_parse_num(&a);
            d = CALL(BookmarkDialog_new, &g_app, mode);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_b="); sc_num(Object_is_instance((const Object *)d, (const ObjectVtbl *)BM_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(d, Dialog_vtbl));
                sc_put(" tag="); sc_num(d->base.op_tag);
                sc_put("\n");
                dump_state("G", d);
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
                d->base.result = 0;
                int rc = WIDGET_CALL(&d->base.base, on_key, &evt);
                ui_dump_event_res("K", rc, &g_app, &d->base);
                dump_state(" ", d);
            }
            break;
        }
        case 'M': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                d->base.result = 0;
                int rc = WIDGET_CALL(&d->base.base, on_mouse, &evt);
                ui_dump_event_res("M", rc, &g_app, &d->base);
                dump_state(" ", d);
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
