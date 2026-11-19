/* Freestanding differential harness for src/ui/popup_menu.c versus frozen x86_64 asm
 * (tests/harness/popup_menu_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_pkg.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static FilePane g_left, g_right;
static DirModel g_dm_l, g_dm_r;
static FileEntry g_ents[2];
static uint32_t g_ord[2] = {0, 1};
static char g_pool[] = "alpha.txt\0subdir\0";
static int g_pkg_cnt;
static int g_fail_alloc;
static PkgAction g_pkg_acts[2];

static void stub_on_focus(Widget *w, int gained)
{
    sc_put("call on_focus ");
    sc_put(w == &g_left.base ? "L" : (w == &g_right.base ? "R" : "?"));
    sc_put(" g="); sc_num(gained); sc_put("\n");
    Widget_on_focus(w, gained);
}

WIDGET_VTBL(StubPane_vtbl, "StubPane", Widget_vtbl, sizeof(FilePane), .on_focus = stub_on_focus);

void App_close_dialog(App *app, int result)
{
    sc_put("call App_close_dialog "); sc_num(app == &g_app); sc_put(" res="); sc_num(result); sc_put("\n");
    if (app->active_dialog) {
        DUOP_DELETE((Object *)(uintptr_t)app->active_dialog);
        app->active_dialog = 0;
    }
}
void App_cmd_view(App *app)   { sc_put("call App_cmd_view "); sc_num(app == &g_app); sc_put("\n"); }
void App_cmd_copy(App *app)   { sc_put("call App_cmd_copy "); sc_num(app == &g_app); sc_put("\n"); }
void App_cmd_move(App *app)   { sc_put("call App_cmd_move "); sc_num(app == &g_app); sc_put("\n"); }
void App_cmd_delete(App *app) { sc_put("call App_cmd_delete "); sc_num(app == &g_app); sc_put("\n"); }
void App_set_status(App *app, const char *msg, int kind)
{
    sc_put("call App_set_status "); sc_num(app == &g_app); sc_put(" k="); sc_num(kind);
    sc_put(" |"); sc_esc(msg ? msg : ""); sc_put("|\n");
}
void App_run_pkg_action(App *app, PkgAction *act)
{
    sc_put("call App_run_pkg_action "); sc_num(app == &g_app);
    sc_put(" idx="); sc_num(act ? (int64_t)(act - g_pkg_acts) : -1); sc_put("\n");
}

void fake_osc52_copy_text(const char *s);
void fake_osc52_copy_text(const char *s)
{
    sc_put("call osc52_copy_text |"); sc_esc(s ? s : ""); sc_put("|\n");
}

FileEntry *fake_FilePane_get_selected_entry(FilePane *fp);
FileEntry *fake_FilePane_get_selected_entry(FilePane *fp)
{
    DirModel *m = (DirModel *)(uintptr_t)fp->model;
    if ((uint64_t)fp->cursor >= m->count) return nullptr;
    return &m->entries[m->order[fp->cursor]];
}

const char *fake_DirModel_entry_name(DirModel *m, FileEntry *e);
const char *fake_DirModel_entry_name(DirModel *m, FileEntry *e)
{
    return m->name_pool + e->name_off;
}

int fake_pkg_popup_refresh(char **envp, int is_dir, const char *name);
int fake_pkg_popup_refresh(char **envp, int is_dir, const char *name)
{
    (void)envp;
    sc_put("call pkg_popup_refresh dir="); sc_num(is_dir);
    sc_put(" name=|"); sc_esc(name ? name : ""); sc_put("| cnt="); sc_num(g_pkg_cnt); sc_put("\n");
    return g_pkg_cnt;
}

int fake_pkg_popup_count(void);
int fake_pkg_popup_count(void) { return g_pkg_cnt; }

const char *fake_pkg_popup_label(int idx);
const char *fake_pkg_popup_label(int idx)
{
    return idx == 0 ? "Pkg: Checksum" : (idx == 1 ? "Pkg: Extract" : "");
}

PkgAction *fake_pkg_popup_get(int idx);
PkgAction *fake_pkg_popup_get(int idx)
{
    return (idx >= 0 && idx < g_pkg_cnt && idx < 2) ? &g_pkg_acts[idx] : nullptr;
}

void *fake_Object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_Object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define osc52_copy_text fake_osc52_copy_text
#define FilePane_get_selected_entry fake_FilePane_get_selected_entry
#define DirModel_entry_name fake_DirModel_entry_name
#define pkg_popup_refresh fake_pkg_popup_refresh
#define pkg_popup_count fake_pkg_popup_count
#define pkg_popup_label fake_pkg_popup_label
#define pkg_popup_get fake_pkg_popup_get
#define Object_alloc fake_Object_alloc
#include PM_SRC
#undef Object_alloc
#undef pkg_popup_get
#undef pkg_popup_label
#undef pkg_popup_count
#undef pkg_popup_refresh
#undef DirModel_entry_name
#undef FilePane_get_selected_entry
#undef osc52_copy_text

#ifdef __x86_64__
extern PopupMenuDialog *ref_PopupMenu_new(App *app, int x, int y);
extern int ref_pane_mouse_ext(App *app, Event *evt);
#define NEW_PM(a, x, y) (g_ref ? ref_PopupMenu_new((a), (x), (y)) : PopupMenu_new((a), (x), (y)))
#define EXT_MOUSE(a, e) (g_ref ? ref_pane_mouse_ext((a), (e)) : pane_mouse_ext((a), (e)))
#else
#define NEW_PM(a, x, y) PopupMenu_new((a), (x), (y))
#define EXT_MOUSE(a, e) pane_mouse_ext((a), (e))
#endif

static bool g_ref;

static void init_panes(ScreenBuffer *scr, const Theme *theme)
{
    ui_app_reset(&g_app);
    mem_zero(&g_left, sizeof g_left);
    mem_zero(&g_right, sizeof g_right);
    mem_zero(&g_dm_l, sizeof g_dm_l);
    mem_zero(&g_dm_r, sizeof g_dm_r);

    g_ents[0] = (FileEntry){.flags = 0, .name_off = 0, .name_len = 9};
    g_ents[1] = (FileEntry){.flags = FE_IS_DIR, .name_off = 10, .name_len = 6};

    g_dm_l.entries = g_ents; g_dm_l.order = g_ord; g_dm_l.name_pool = g_pool; g_dm_l.count = 2;
    (void)str_copy(g_dm_l.path, "/work/left", PATH_MAX);
    g_dm_r.entries = g_ents; g_dm_r.order = g_ord; g_dm_r.name_pool = g_pool; g_dm_r.count = 2;
    (void)str_copy(g_dm_r.path, "/work/right", PATH_MAX);

    g_left.base.base.vptr = DUOP_OBJ_VTBL(StubPane_vtbl);
    g_left.base.x = 0; g_left.base.y = 1; g_left.base.w = 35; g_left.base.h = 15;
    g_left.model = (uint64_t)(uintptr_t)&g_dm_l; g_left.app = (uint64_t)(uintptr_t)&g_app;

    g_right.base.base.vptr = DUOP_OBJ_VTBL(StubPane_vtbl);
    g_right.base.x = 35; g_right.base.y = 1; g_right.base.w = 35; g_right.base.h = 15;
    g_right.model = (uint64_t)(uintptr_t)&g_dm_r; g_right.app = (uint64_t)(uintptr_t)&g_app;

    g_app.screen = (uint64_t)(uintptr_t)scr;
    g_app.theme = (uint64_t)(uintptr_t)theme;
    g_app.left_pane = (uint64_t)(uintptr_t)&g_left;
    g_app.right_pane = (uint64_t)(uintptr_t)&g_right;
    g_app.active_pane = (uint64_t)(uintptr_t)&g_left;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(70, 20);
    if (!scr) return 3;
    init_panes(scr, theme);

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'O': {
            /* C-only OOM check (asm popup_menu.s crashes on NULL mem_alloc) */
            g_fail_alloc = 1;
            PopupMenuDialog *oom = PopupMenu_new(&g_app, 5, 5);
            sc_put("OOM="); sc_num(oom == nullptr); sc_put("\n");
            break;
        }
        case 'S': {
            g_pkg_cnt = (int)ui_parse_num(&a);
            g_app.right_mode = (uint32_t)ui_parse_num(&a);
            g_left.cursor = (uint32_t)ui_parse_num(&a);
            break;
        }
        case 'N': {
            int x = (int)ui_parse_num(&a);
            int y = (int)ui_parse_num(&a);
            PopupMenuDialog *d = NEW_PM(&g_app, x, y);
            sc_put("N xywh="); sc_num(d->base.base.x); sc_put(","); sc_num(d->base.base.y);
            sc_put(","); sc_num(d->base.base.w); sc_put(","); sc_num(d->base.base.h); sc_put("\n");
            break;
        }
        case 'R': {
            if (!g_app.active_dialog) { sc_put("R none\n"); break; }
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            Widget *w = (Widget *)(uintptr_t)g_app.active_dialog;
            WIDGET_CALL(w, render, scr, (void *)theme);
            ui_dump(scr, w->y, w->h);
            break;
        }
        case 'K': {
            Event ev; mem_zero(&ev, sizeof ev);
            ev.type = EVT_KEY;
            ev.key = (int32_t)ui_parse_num(&a);
            ev.lat = ev.key;
            g_app.need_redraw = 0;
            Widget *w = (Widget *)(uintptr_t)g_app.active_dialog;
            int rc = WIDGET_CALL(w, on_key, &ev);
            sc_put("K rc="); sc_num(rc); sc_put(" open="); sc_num(g_app.active_dialog != 0);
            sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            break;
        }
        case 'M': {
            Event ev; mem_zero(&ev, sizeof ev);
            ev.type = EVT_MOUSE;
            ev.mouse_kind = (int32_t)ui_parse_num(&a);
            ev.mouse_btn = (int32_t)ui_parse_num(&a);
            ev.mouse_x = (int32_t)ui_parse_num(&a);
            ev.mouse_y = (int32_t)ui_parse_num(&a);
            Widget *w = (Widget *)(uintptr_t)g_app.active_dialog;
            int rc = WIDGET_CALL(w, on_mouse, &ev);
            sc_put("M rc="); sc_num(rc); sc_put(" open="); sc_num(g_app.active_dialog != 0); sc_put("\n");
            break;
        }
        case 'E': {
            Event ev; mem_zero(&ev, sizeof ev);
            ev.type = EVT_MOUSE;
            ev.mouse_kind = (int32_t)ui_parse_num(&a);
            ev.mouse_btn = (int32_t)ui_parse_num(&a);
            ev.mouse_x = (int32_t)ui_parse_num(&a);
            ev.mouse_y = (int32_t)ui_parse_num(&a);
            int rc = EXT_MOUSE(&g_app, &ev);
            sc_put("E rc="); sc_num(rc);
            sc_put(" act="); sc_put(g_app.active_pane == (uint64_t)(uintptr_t)&g_left ? "L" : "R");
            sc_put(" lcur="); sc_num((int32_t)g_left.cursor);
            sc_put(" rcur="); sc_num((int32_t)g_right.cursor);
            sc_put(" dlg="); sc_num(g_app.active_dialog != 0);
            sc_put("\n");
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    if (g_app.active_dialog) App_close_dialog(&g_app, DLG_CANCEL);
    sc_flush();
    return 0;
}
