/* Freestanding differential harness for src/ui/bulk_rename.c versus frozen x86_64 asm
 * (tests/harness/bulk_rename{,_ui}_reference.s, ref_ prefix). argv[1] = ref | c. */
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
static FilePane g_pane;
static DirModel g_model;
static FileEntry g_entries[8];
static uint32_t g_order[8];
static char g_name_pool[1024];
static int g_fail_alloc;
static int g_sel_idx;

void App_close_dialog(App *app, int result)
{
    ui_log_call2("App_close_dialog", app == &g_app, result);
}

int DirModel_reload(DirModel *self)
{
    sc_put("call DirModel_reload "); sc_num(self == &g_model); sc_put("\n");
    return 0;
}

FileEntry *FilePane_get_selected_entry(FilePane *self)
{
    (void)self;
    if (g_sel_idx < 0 || g_sel_idx >= (int)g_model.count) return nullptr;
    return &g_entries[g_order[g_sel_idx]];
}

const char *DirModel_entry_name(const DirModel *m, const FileEntry *e)
{
    if (!m || !e) return nullptr;
    return (const char *)(uintptr_t)m->name_pool + e->name_off;
}

void *fake_mem_alloc(size_t size);
void *fake_mem_alloc(size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return mem_alloc(size);
}

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define mem_alloc fake_mem_alloc
#define Object_alloc fake_object_alloc
#include BR_SRC
#undef mem_alloc
#undef Object_alloc

#ifdef __x86_64__
extern const DialogVtbl ref_BulkRenameDialog_vtbl;
extern BulkRenameDialog *ref_BulkRenameDialog_new(App *app, FilePane *pane);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define BR_VTBL (g_ref ? &ref_BulkRenameDialog_vtbl : &BulkRenameDialog_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define BR_VTBL (&BulkRenameDialog_vtbl)
#endif

static bool g_ref;

static void seed_entries(const char *dir, int mode)
{
    /* mode 0: only ".." ; mode 1: unmarked files (cursor on idx 1) ; mode 2: 4 marked files + ".." */
    static const char *const names[5] = {"..", "photo_01.jpg", "a.b.txt", "README", ".dotfile"};
    mem_zero(&g_pane, sizeof g_pane);
    mem_zero(&g_model, sizeof g_model);
    mem_zero(g_entries, sizeof g_entries);
    (void)str_copy((char *)g_model.path, dir, sizeof g_model.path);
    g_model.entries = g_entries;
    g_model.order = g_order;
    g_model.name_pool = g_name_pool;
    g_pane.model = (uintptr_t)&g_model;

    int cnt = (mode == 0) ? 1 : 5;
    g_model.count = (uint32_t)cnt;
    uint32_t off = 0;
    for (int i = 0; i < cnt; i++) {
        g_order[i] = (uint32_t)i;
        g_entries[i].name_off = off;
        uint64_t n = str_copy(g_name_pool + off, names[i], sizeof g_name_pool - off);
        off += (uint32_t)n + 1;
        g_entries[i].flags = (i == 0) ? FE_IS_PARENT : ((mode == 2) ? FE_SELECTED : 0U);
    }
    g_sel_idx = (mode == 0) ? 0 : 1;
}

static void dump_state(const char *tag, const BulkRenameDialog *d)
{
    sc_put(tag);
    sc_put(" rect "); sc_num(d->base.base.x); sc_put(" "); sc_num(d->base.base.y);
    sc_put(" "); sc_num(d->base.base.w); sc_put(" "); sc_num(d->base.base.h);
    sc_put(" cnt="); sc_num(d->count);
    sc_put(" foc="); sc_num(d->focus);
    sc_put(" t="); sc_esc((const char *)d->tmpl);
    sc_put(" f="); sc_esc((const char *)d->find);
    sc_put(" r="); sc_esc((const char *)d->repl);
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(80, 24);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    BulkRenameDialog *d = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'S': { /* S <mode> <dir> */
            int mode = (int)ui_parse_num(&a);
            while (*a == ' ') a++;
            seed_entries(a, mode);
            break;
        }
        case 'N': { /* N <tw> <th> <fail_alloc> */
            if (d) { DUOP_DELETE(d); d = nullptr; }
            g_app.term_w = (uint32_t)ui_parse_num(&a);
            g_app.term_h = (uint32_t)ui_parse_num(&a);
            g_fail_alloc = (int)ui_parse_num(&a);
            d = CALL(BulkRenameDialog_new, &g_app, &g_pane);
            sc_put("N ok="); sc_num(d != nullptr);
            if (d) {
                sc_put(" is_b="); sc_num(Object_is_instance((const Object *)d, (const ObjectVtbl *)BR_VTBL));
                sc_put(" is_d="); sc_num(DUOP_IS_INSTANCE(d, Dialog_vtbl));
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
            sc_put("R\n");
            ui_dump(scr, d->base.base.y, d->base.base.h);
            break;
        }
        case 'T': { /* Type string into currently focused field: T <text> */
            if (!d) break;
            while (*a == ' ') a++;
            for (; *a; a++) {
                evt = ui_evt_key((int32_t)(uint8_t)*a, 0, (int32_t)(uint8_t)*a);
                (void)WIDGET_CALL(&d->base.base, on_key, &evt);
            }
            dump_state("T", d);
            break;
        }
        case 'K': {
            if (!d) break;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                d->base.result = 0;
                int rc = WIDGET_CALL(&d->base.base, on_key, &evt);
                sc_put("K rc="); sc_num(rc);
                sc_put(" redr="); sc_num(g_app.need_redraw);
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
