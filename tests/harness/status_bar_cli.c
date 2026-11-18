/* Freestanding harness: the frozen asm StatusBar (status_bar_reference.s + status_bar_render_reference.s, x86_64, ref_ prefix) or
 * src/ui/status_bar.c (compiled into this unit, path in SB_SRC), rendered through its vtable into a ScreenBuffer and dumped with
 * ui_render.h. The clock is scripted, ProgressDialog_format_summary is a stand-in. argv[1] = ref | c. Script on stdin:
 *   D <dir>  a DirModel of a real directory      C <cursor>   P <0|1> active pane set      K <0|1> <c>  task active, its snapshot
 *   F <filter|->  the model's filter text        L <x> <w>  layout          T <ms>  the clock
 *   M <kind> <ttl> <text>  StatusBar_set_message     H <text>  the right-hand key hint (LS_sb_hint_right)   R  render, dump */
#include "ui_render.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_ui.h"

#include "i18n_slots.h"

static LangStrings g_ls;                                                  /* the English table, its key hint replaceable */
static char g_hint[256];
const LangStrings *i18n_get(void);
const LangStrings *i18n_get(void)
{
    if (!g_ls.s[0]) g_ls = lang_en_table;
    return &g_ls;
}

int git_refresh(DirModel *m) { (void)m; return 0; }
void git_free_ctx(DirModel *m) { m->git_ctx = nullptr; }

static int64_t g_now;
int64_t fake_clock(void);
int64_t fake_clock(void) { return g_now; }

void ProgressDialog_format_summary(const void *snap, char *buf);
void ProgressDialog_format_summary(const void *snap, char *buf)
{
    (void)str_copy(buf, " ⟳ Copying 42%  ·  task ", 64);
    char t[2] = {*(const char *)snap ? *(const char *)snap : '0', 0};
    (void)str_cat(buf, t, 64);
}

#define sys_clock_ms fake_clock
#include SB_SRC
#undef sys_clock_ms

#ifdef __x86_64__
extern StatusBar *ref_StatusBar_new(App *);
extern void ref_StatusBar_set_message(StatusBar *, const char *, int, int);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static App g_app;
static FilePane g_fp;

static int64_t num(const char **p)
{
    while (**p == ' ') (*p)++;
    int64_t v = 0, sign = 1;
    if (**p == '-') { sign = -1; (*p)++; }
    while (**p >= '0' && **p <= '9') v = v * 10 + (*(*p)++ - '0');
    if (**p == ' ') (*p)++;
    return sign * v;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(200, 1);
    StatusBar *sb = CALL(StatusBar_new, &g_app);
    if (!scr || !sb) return 3;
    sc_put("new id="); sc_num(sb->base.id); sc_put(" flags="); sc_num(sb->base.flags); sc_put(" class="); sc_put(Object_get_class_name(&sb->base.base));
    sc_put(" app="); sc_num(sb->app == (uint64_t)(uintptr_t)&g_app); sc_put("\n");
    DirModel *m = nullptr;
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'D':
            if (m) Object_free(&m->base);
            while (*a == ' ') a++;
            m = DirModel_new(a);
            while (m && m->is_loading) (void)DirModel_step_load(m, 0);
            g_fp.model = (uint64_t)(uintptr_t)m;
            sc_put("D n="); sc_num(m ? (int64_t)m->count : -1); sc_put("\n");
            break;
        case 'C': g_fp.cursor = (uint32_t)num(&a); break;
        case 'P': g_app.active_pane = num(&a) ? (uint64_t)(uintptr_t)&g_fp : 0; break;
        case 'K': g_app.task_active = (uint32_t)num(&a); g_app.task_snap[0] = (uint8_t)*a; break;
        case 'F': if (m) { while (*a == ' ') a++; (void)str_copy(m->filter, *a == '-' ? "" : a, sizeof m->filter); } break;
        case 'L': { int x = (int)num(&a), w = (int)num(&a); WIDGET_CALL(sb, layout, x, 0, w, 1); break; }
        case 'T': g_now = num(&a); break;
        case 'H': while (*a == ' ') a++; (void)str_copy(g_hint, a, sizeof g_hint); (void)i18n_get(); g_ls.s[LS_sb_hint_right] = g_hint; break;
        case 'M': { int k = (int)num(&a), ttl = (int)num(&a); CALLV(StatusBar_set_message, sb, a, k, ttl);
                    sc_put("M kind="); sc_num(sb->msg_kind); sc_put(" exp="); sc_num((int64_t)sb->msg_expire_ms); sc_put("\n"); break; }
        case 'R':
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL(sb, render, scr, (void *)theme);
            sc_put("R exp="); sc_num((int64_t)sb->msg_expire_ms); sc_put("\n");
            ui_dump(scr, 0, 1);
            break;
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
