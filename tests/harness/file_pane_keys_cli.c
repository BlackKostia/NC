/* Freestanding differential harness for src/ui/file_pane_keys.c versus frozen x86_64 asm
 * (tests/harness/file_pane_keys_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_du.h"
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
static intptr_t g_chdir_err;
static char *g_env_home[] = {"FOO=1", "HOME=/home/tester", nullptr};
static char *g_env_none[] = {"FOO=1", nullptr};

int fake_get_list_h(FilePane *fp);
int fake_get_list_h(FilePane *fp)
{
    (void)fp;
    return g_list_h;
}

void fake_FilePane_ensure_visible(FilePane *fp);
void fake_FilePane_ensure_visible(FilePane *fp)
{
    sc_put("call ensure_visible cur="); sc_num((int32_t)fp->cursor);
    sc_put(" scr="); sc_num((int32_t)fp->scroll); sc_put("\n");
}

void fake_FilePane_enter_parent(FilePane *fp);
void fake_FilePane_enter_parent(FilePane *fp)
{
    sc_put("call enter_parent "); sc_num(fp == &g_fp); sc_put("\n");
}

void fake_DirModel_toggle_select(DirModel *m, intptr_t idx);
void fake_DirModel_toggle_select(DirModel *m, intptr_t idx)
{
    sc_put("call toggle_select "); sc_num(m == &g_dm); sc_put(" idx="); sc_num(idx); sc_put("\n");
}

void fake_DirModel_select_all_toggle(DirModel *m);
void fake_DirModel_select_all_toggle(DirModel *m)
{
    sc_put("call select_all_toggle "); sc_num(m == &g_dm); sc_put("\n");
}

intptr_t fake_DirModel_chdir(DirModel *m, const char *target);
intptr_t fake_DirModel_chdir(DirModel *m, const char *target)
{
    sc_put("call chdir |"); sc_esc(target ? target : ""); sc_put("| err="); sc_num(g_chdir_err); sc_put("\n");
    if (g_chdir_err < 0) return g_chdir_err;
    (void)str_copy(m->path, target, PATH_MAX);
    return 0;
}

int fake_dir_du_populate(DirModel *m);
int fake_dir_du_populate(DirModel *m)
{
    sc_put("call dir_du_populate "); sc_num(m == &g_dm); sc_put("\n");
    return 1;
}

void App_open_selected_entry(App *app, FilePane *pane)
{
    sc_put("call open_selected "); sc_num(app == &g_app); sc_put(" "); sc_num(pane == &g_fp); sc_put("\n");
}

void App_sync_preview(App *app)
{
    sc_put("call sync_preview "); sc_num(app == &g_app); sc_put("\n");
}

#define get_list_h fake_get_list_h
#define FilePane_ensure_visible fake_FilePane_ensure_visible
#define FilePane_enter_parent fake_FilePane_enter_parent
#define DirModel_toggle_select fake_DirModel_toggle_select
#define DirModel_select_all_toggle fake_DirModel_select_all_toggle
#define DirModel_chdir fake_DirModel_chdir
#define dir_du_populate fake_dir_du_populate
#include FPK_SRC
#undef dir_du_populate
#undef DirModel_chdir
#undef DirModel_select_all_toggle
#undef DirModel_toggle_select
#undef FilePane_enter_parent
#undef FilePane_ensure_visible
#undef get_list_h

#ifdef __x86_64__
extern int ref_FilePane_on_key(Widget *self, void *event);
extern void ref_scrub_scrollbar(FilePane *self, int my);
#define CALL_KEY(fp, ev) (g_ref ? ref_FilePane_on_key((Widget *)(fp), (ev)) : FilePane_on_key((Widget *)(fp), (ev)))
#define CALL_SCRUB(fp, my) (g_ref ? ref_scrub_scrollbar((fp), (my)) : scrub_scrollbar((fp), (my)))
#else
#define CALL_KEY(fp, ev) FilePane_on_key((Widget *)(fp), (ev))
#define CALL_SCRUB(fp, my) scrub_scrollbar((fp), (my))
#endif

static bool g_ref;

static int64_t parse_i(const char **p)
{
    while (**p == ' ') (*p)++;
    int neg = 0;
    if (**p == '-') { neg = 1; (*p)++; }
    int64_t v = 0;
    if ((*p)[0] == '0' && ((*p)[1] == 'x' || (*p)[1] == 'X')) {
        *p += 2;
        for (;;) {
            char c = **p;
            if (c >= '0' && c <= '9') v = (v << 4) + (c - '0');
            else if (c >= 'a' && c <= 'f') v = (v << 4) + (c - 'a' + 10);
            else if (c >= 'A' && c <= 'F') v = (v << 4) + (c - 'A' + 10);
            else break;
            (*p)++;
        }
        return neg ? -v : v;
    }
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
    g_fp.base.y = 2;
    g_dm.count = 50;
    g_app.envp = (uint64_t)(uintptr_t)g_env_home;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'C': {
            g_fp.cursor = (uint32_t)parse_i(&a);
            g_fp.scroll = (uint32_t)parse_i(&a);
            g_dm.count = (uint64_t)parse_i(&a);
            g_list_h = (int)parse_i(&a);
            break;
        }
        case 'H': {
            int has_home = (int)parse_i(&a);
            g_chdir_err = (intptr_t)parse_i(&a);
            g_dm.du_mode = (int32_t)parse_i(&a);
            g_app.envp = (uint64_t)(uintptr_t)(has_home ? g_env_home : g_env_none);
            break;
        }
        case 'K': {
            Event ev;
            mem_zero(&ev, sizeof ev);
            ev.type = EVT_KEY;
            ev.mods = (int32_t)parse_i(&a);
            ev.lat = (int32_t)parse_i(&a);
            ev.key = ev.lat;
            g_app.need_redraw = 0;
            int rc = CALL_KEY(&g_fp, &ev);
            sc_put("K rc="); sc_num(rc);
            sc_put(" cur="); sc_num((int32_t)g_fp.cursor);
            sc_put(" scr="); sc_num((int32_t)g_fp.scroll);
            sc_put(" rd="); sc_num(g_app.need_redraw);
            sc_put("\n");
            break;
        }
        case 'S': {
            int my = (int)parse_i(&a);
            CALL_SCRUB(&g_fp, my);
            sc_put("S my="); sc_num(my); sc_put(" scr="); sc_num((int32_t)g_fp.scroll); sc_put("\n");
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
