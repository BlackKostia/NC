/* Freestanding differential harness for src/ui/file_pane_tabs.c versus frozen x86_64 asm
 * (tests/harness/file_pane_tabs_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_classes.h"
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_ui.h"
#include "script_cli.h"

static FilePane g_fp;
static DirModel g_dm;
static intptr_t g_chdir_err;

intptr_t fake_DirModel_chdir(DirModel *m, const char *target);
intptr_t fake_DirModel_chdir(DirModel *m, const char *target)
{
    sc_put("call DirModel_chdir |"); sc_esc(target ? target : ""); sc_put("| err="); sc_num(g_chdir_err); sc_put("\n");
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

void fake_FilePane_ensure_visible(FilePane *fp);
void fake_FilePane_ensure_visible(FilePane *fp)
{
    sc_put("call ensure_visible cur="); sc_num(fp->cursor); sc_put(" scr="); sc_num(fp->scroll); sc_put("\n");
}

void fake_nav_frecency_record(const char *path);
void fake_nav_frecency_record(const char *path)
{
    sc_put("call nav_frecency_record |"); sc_esc(path); sc_put("|\n");
}

#define DirModel_chdir fake_DirModel_chdir
#define dir_du_populate fake_dir_du_populate
#define FilePane_ensure_visible fake_FilePane_ensure_visible
#define nav_frecency_record fake_nav_frecency_record
#include FPT_SRC
#undef nav_frecency_record
#undef FilePane_ensure_visible
#undef dir_du_populate
#undef DirModel_chdir

#ifdef __x86_64__
extern NavTab *ref_fp_get_active_tab(FilePane *fp);
extern intptr_t ref_FilePane_nav_to(FilePane *fp, const char *path);
extern int ref_FilePane_hist_back(FilePane *fp);
extern int ref_FilePane_hist_fwd(FilePane *fp);
extern int ref_FilePane_tab_new(FilePane *fp);
extern int ref_FilePane_tab_switch(FilePane *fp, int idx);
extern int ref_FilePane_tab_close(FilePane *fp, int idx);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
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

static void dump_state(const char *tag)
{
    sc_put(tag);
    sc_put(" act="); sc_num((int32_t)g_fp.active_tab);
    sc_put(" cnt="); sc_num((int32_t)g_fp.tab_count);
    sc_put(" cur="); sc_num((int32_t)g_fp.cursor);
    sc_put(" scr="); sc_num((int32_t)g_fp.scroll);
    sc_put(" sm="); sc_num(g_dm.sort_mode);
    sc_put(" sd="); sc_num(g_dm.sort_desc);
    sc_put(" sh="); sc_num(g_dm.show_hidden);
    sc_put(" path=|"); sc_esc(g_dm.path); sc_put("|\n");
    const NavTab *tabs = (const NavTab *)(uintptr_t)g_fp.tabs;
    for (int i = 0; tabs && i < (int32_t)g_fp.tab_count; i++) {
        sc_put("  T"); sc_num(i);
        sc_put(" p=|"); sc_esc(tabs[i].path);
        sc_put("| c="); sc_num(tabs[i].cursor);
        sc_put(" s="); sc_num(tabs[i].scroll);
        sc_put(" sm="); sc_num(tabs[i].sort_mode);
        sc_put(" sd="); sc_num(tabs[i].sort_desc);
        sc_put(" sh="); sc_num(tabs[i].show_hidden);
        sc_put(" hp="); sc_num(tabs[i].hist_pos);
        sc_put("/"); sc_num(tabs[i].hist_len);
        sc_put("\n");
    }
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';

    mem_zero(&g_fp, sizeof g_fp);
    mem_zero(&g_dm, sizeof g_dm);
    (void)str_copy(g_dm.path, "/init", PATH_MAX);
    g_fp.model = (uint64_t)(uintptr_t)&g_dm;
    NavTab *tabs = nav_tabs_alloc("/init");
    if (!tabs) return 3;
    g_fp.tabs = (uint64_t)(uintptr_t)tabs;
    g_fp.tab_count = 1;
    g_fp.active_tab = 0;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'E': g_chdir_err = (intptr_t)parse_i(&a); break;
        case 'D': g_dm.du_mode = (int32_t)parse_i(&a); break;
        case 'M': {
            g_fp.cursor = (uint32_t)parse_i(&a);
            g_fp.scroll = (uint32_t)parse_i(&a);
            g_dm.sort_mode = (int32_t)parse_i(&a);
            g_dm.sort_desc = (int32_t)parse_i(&a);
            g_dm.show_hidden = (int32_t)parse_i(&a);
            break;
        }
        case 'G': {
            int save_act = (int32_t)g_fp.active_tab;
            g_fp.active_tab = (uint32_t)parse_i(&a);
            NavTab *t = CALL(fp_get_active_tab, &g_fp);
            sc_put("G idx=");
            if (t) sc_num((int64_t)(t - tabs));
            else sc_put("null");
            sc_put("\n");
            g_fp.active_tab = (uint32_t)save_act;
            break;
        }
        case 'N': {
            while (*a == ' ') a++;
            intptr_t rc = CALL(FilePane_nav_to, &g_fp, a);
            sc_put("N rc="); sc_num(rc); sc_put("\n");
            dump_state("N");
            break;
        }
        case 'B': {
            int rc = CALL(FilePane_hist_back, &g_fp);
            sc_put("B rc="); sc_num(rc); sc_put("\n");
            dump_state("B");
            break;
        }
        case 'F': {
            int rc = CALL(FilePane_hist_fwd, &g_fp);
            sc_put("F rc="); sc_num(rc); sc_put("\n");
            dump_state("F");
            break;
        }
        case '+': {
            int rc = CALL(FilePane_tab_new, &g_fp);
            sc_put("+ rc="); sc_num(rc); sc_put("\n");
            dump_state("+");
            break;
        }
        case 'S': {
            int idx = (int)parse_i(&a);
            int rc = CALL(FilePane_tab_switch, &g_fp, idx);
            sc_put("S "); sc_num(idx); sc_put(" rc="); sc_num(rc); sc_put("\n");
            dump_state("S");
            break;
        }
        case 'X': {
            int idx = (int)parse_i(&a);
            int rc = CALL(FilePane_tab_close, &g_fp, idx);
            sc_put("X "); sc_num(idx); sc_put(" rc="); sc_num(rc); sc_put("\n");
            dump_state("X");
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    nav_tabs_free(tabs, (int)g_fp.tab_count);
    sc_flush();
    return 0;
}
