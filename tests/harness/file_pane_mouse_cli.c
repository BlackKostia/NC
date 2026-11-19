/* Freestanding differential harness for src/ui/file_pane_mouse.c versus frozen x86_64 asm
 * (tests/harness/file_pane_mouse_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "script_cli.h"

static App g_app;
static FilePane g_fp;
static DirModel g_dm;
static int g_list_h = 10;
static int64_t g_clock = 1000;

int64_t fake_clock(void);
int64_t fake_clock(void) { return g_clock; }

int fake_get_list_h(FilePane *fp);
int fake_get_list_h(FilePane *fp) { (void)fp; return g_list_h; }

void fake_scrub_scrollbar(FilePane *fp, int my);
void fake_scrub_scrollbar(FilePane *fp, int my)
{
    (void)fp;
    sc_put("call scrub_scrollbar my="); sc_num(my); sc_put("\n");
}

void fake_FilePane_ensure_visible(FilePane *fp);
void fake_FilePane_ensure_visible(FilePane *fp)
{
    sc_put("call ensure_visible cur="); sc_num((int32_t)fp->cursor); sc_put("\n");
}

int fake_FilePane_tab_switch(FilePane *fp, int idx);
int fake_FilePane_tab_switch(FilePane *fp, int idx)
{
    (void)fp;
    sc_put("call tab_switch idx="); sc_num(idx); sc_put("\n");
    return 1;
}

int fake_FilePane_tab_close(FilePane *fp, int idx);
int fake_FilePane_tab_close(FilePane *fp, int idx)
{
    (void)fp;
    sc_put("call tab_close idx="); sc_num(idx); sc_put("\n");
    return 1;
}

void fake_DirModel_sort(DirModel *m);
void fake_DirModel_sort(DirModel *m)
{
    sc_put("call DirModel_sort sm="); sc_num(m->sort_mode); sc_put(" sd="); sc_num(m->sort_desc); sc_put("\n");
}

void fake_DirModel_toggle_select(DirModel *m, intptr_t idx);
void fake_DirModel_toggle_select(DirModel *m, intptr_t idx)
{
    sc_put("call toggle_select "); sc_num(m == &g_dm); sc_put(" idx="); sc_num(idx); sc_put("\n");
}

void App_set_active_pane(App *app, FilePane *pane)
{
    sc_put("call set_active_pane "); sc_num(app == &g_app); sc_put(" "); sc_num(pane == &g_fp); sc_put("\n");
}

void App_sync_preview(App *app)
{
    sc_put("call sync_preview "); sc_num(app == &g_app); sc_put("\n");
}

void App_open_selected_entry(App *app, FilePane *pane)
{
    sc_put("call open_selected "); sc_num(app == &g_app); sc_put(" cur="); sc_num((int32_t)pane->cursor); sc_put("\n");
}

#define sys_clock_ms fake_clock
#define get_list_h fake_get_list_h
#define scrub_scrollbar fake_scrub_scrollbar
#define FilePane_ensure_visible fake_FilePane_ensure_visible
#define FilePane_tab_switch fake_FilePane_tab_switch
#define FilePane_tab_close fake_FilePane_tab_close
#define DirModel_sort fake_DirModel_sort
#define DirModel_toggle_select fake_DirModel_toggle_select
#include FPM_SRC
#undef DirModel_toggle_select
#undef DirModel_sort
#undef FilePane_tab_close
#undef FilePane_tab_switch
#undef FilePane_ensure_visible
#undef scrub_scrollbar
#undef get_list_h
#undef sys_clock_ms

#ifdef __x86_64__
extern int ref_FilePane_on_mouse(Widget *self, void *event);
#define CALL_MOUSE(fp, ev) (g_ref ? ref_FilePane_on_mouse((Widget *)(fp), (ev)) : FilePane_on_mouse((Widget *)(fp), (ev)))
#else
#define CALL_MOUSE(fp, ev) FilePane_on_mouse((Widget *)(fp), (ev))
#endif

static bool g_ref;

static int64_t parse_i(const char **p)
{
    while (**p == ' ') (*p)++;
    int neg = 0;
    if (**p == '-') { neg = 1; (*p)++; }
    int64_t v = 0;
    while (**p >= '0' && **p <= '9') { v = v * 10 + (**p - '0'); (*p)++; }
    return neg ? -v : v;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';

    mem_zero(&g_app, sizeof g_app);
    mem_zero(&g_fp, sizeof g_fp);
    mem_zero(&g_dm, sizeof g_dm);
    g_fp.app = (uint64_t)(uintptr_t)&g_app;
    g_fp.model = (uint64_t)(uintptr_t)&g_dm;
    g_fp.base.x = 5;
    g_fp.base.y = 2;
    g_fp.base.w = 40; /* right border / scrollbar at x = 44 */
    g_fp.base.h = 15; /* list_h = 10, list rows y = 5..14 */
    g_fp.last_click_idx = (uint32_t)-1;
    g_fp.hovered_row = (uint32_t)-1;
    g_fp.hovered_col_hdr = (uint32_t)-1;
    g_fp.tab_count = 2;
    g_fp.tab_zone_count = 2;
    HitZone *tz = (HitZone *)g_fp.tab_zones;
    tz[0] = (HitZone){.x1 = 6, .x2 = 16, .y = 2, .id = 0};
    tz[1] = (HitZone){.x1 = 17, .x2 = 27, .y = 2, .id = 1};
    g_fp.hdr_zone_count = 3;
    HitZone *hz = (HitZone *)g_fp.hdr_zones;
    hz[0] = (HitZone){.x1 = 6, .x2 = 25, .y = 3, .id = 0};
    hz[1] = (HitZone){.x1 = 25, .x2 = 34, .y = 3, .id = 1};
    hz[2] = (HitZone){.x1 = 34, .x2 = 44, .y = 3, .id = 2};
    g_dm.count = 30;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'T': g_clock = parse_i(&a); break;
        case 'S': {
            g_dm.count = (uint64_t)parse_i(&a);
            g_dm.is_unsorted = (int32_t)parse_i(&a);
            g_fp.tab_count = (uint32_t)parse_i(&a);
            g_fp.scroll = (uint32_t)parse_i(&a);
            break;
        }
        case 'M': {
            Event ev;
            mem_zero(&ev, sizeof ev);
            ev.type = EVT_MOUSE;
            ev.mouse_kind = (int32_t)parse_i(&a);
            ev.mouse_btn = (int32_t)parse_i(&a);
            ev.mouse_x = (int32_t)parse_i(&a);
            ev.mouse_y = (int32_t)parse_i(&a);
            g_app.need_redraw = 0;
            int rc = CALL_MOUSE(&g_fp, &ev);
            sc_put("M rc="); sc_num(rc);
            sc_put(" cur="); sc_num((int32_t)g_fp.cursor);
            sc_put(" scr="); sc_num((int32_t)g_fp.scroll);
            sc_put(" drg="); sc_num((int32_t)g_fp.dragging_scroll);
            sc_put(" hh="); sc_num((int32_t)g_fp.hovered_col_hdr);
            sc_put(" hr="); sc_num((int32_t)g_fp.hovered_row);
            sc_put(" lc="); sc_num((int32_t)g_fp.last_click_idx);
            sc_put(" sm="); sc_num(g_dm.sort_mode);
            sc_put(" sd="); sc_num(g_dm.sort_desc);
            sc_put(" rd="); sc_num(g_app.need_redraw);
            sc_put("\n");
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
