/* Freestanding harness: the frozen asm popup / preview packages (pkg_popup_reference.s + pkg_preview_reference.s, x86_64, ref_
 * prefix) or src/fs/pkg_popup.c + pkg_preview.c (compiled into this unit, paths in PKM1_SRC / PKM2_SRC), over the real package
 * actions, DirModel and package manager; previewers are real scripts. argv[1] = ref | c; TREE= masks paths. Script on stdin:
 *   R <is_dir> <name|->  pkg_popup_refresh, then count / label / get for -1 .. count    H <args>  pkg_action_has_marked
 *   N <dir>   a new DirModel     S <name>  select an entry     W <cap> <fallback|->  pkg_write_marked_list, then the file
 *   V <max> <file>  pkg_preview_try      T  files in the temp directory */
#include "script_cli.h"
#include "duop_pkg.h"
#include "duop_preview.h"
#include "duop_config.h"

int git_refresh(DirModel *m) { (void)m; return 0; }
void git_free_ctx(DirModel *m) { m->git_ctx = nullptr; }

#include PKM1_SRC
#include PKM2_SRC

#ifdef __x86_64__
extern int ref_pkg_popup_refresh(char **, int, const char *), ref_pkg_popup_count(void), ref_pkg_action_has_marked(PkgAction *);
extern const char *ref_pkg_popup_label(int);
extern PkgAction *ref_pkg_popup_get(int);
extern int ref_pkg_write_marked_list(DirModel *, const char *, char *, int), ref_pkg_preview_try(char **, const char *, char *, int);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALL0(f) (g_ref ? ref_##f() : f())
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALL0(f) f()
#endif

static bool g_ref;
static const char *g_tree;
static DirModel *g_m;
static char g_out[1 << 16];

static void put_text(const char *s)
{
    for (; *s; s++) {
        if (g_tree && str_starts_with(s, g_tree)) { sc_put("<T>"); s += str_len(g_tree) - 1; continue; }
        char c[2] = {*s, 0};
        sc_esc(c);
    }
}

static int64_t num(const char *s) { int64_t v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0'); return v; }

static int tmp_count(void)
{
    char dir[PATH_MAX];
    static uint8_t dents[8192];
    int n = 0;
    if (tmp_ensure_dir(dir, PATH_MAX) != 0) return -1;
    intptr_t fd = os_openat(AT_FDCWD, dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    for (intptr_t got; !os_is_err(fd) && (got = os_dir_read((int)fd, dents, sizeof dents)) > 0;) {
        size_t pos = 0;
        uint8_t type;
        for (const char *nm; (nm = os_dir_next_ex(dents, (size_t)got, &pos, &type));) n += nm[0] != '.';
    }
    if (!os_is_err(fd)) (void)os_close((int)fd);
    return n;
}

static char *word(char **p)                                              /* the next space-separated word */
{
    while (**p == ' ') (*p)++;
    char *w = *p;
    while (**p && **p != ' ') (*p)++;
    if (**p) *(*p)++ = 0;
    return w;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    g_tree = cfg_getenv(envp, "TREE=");
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char cmd = line[0];
        char *arg = line[0] ? line + 1 : line;
        switch (cmd) {
        case 'R': {
            int is_dir = (int)num(word(&arg));
            char *nm = word(&arg);
            int n = CALL(pkg_popup_refresh, envp, is_dir, nm[0] == '-' && !nm[1] ? nullptr : nm);
            sc_put("R n="); sc_num(n); sc_put(" count="); sc_num(CALL0(pkg_popup_count));
            for (int i = -1; i <= n; i++) {
                const char *l = CALL(pkg_popup_label, i);
                PkgAction *a = CALL(pkg_popup_get, i);
                sc_put(" ["); if (l) sc_esc(l); else sc_put("null");
                if (a) { sc_put("|"); sc_esc(a->name); sc_put("|"); sc_put(l == a->menu ? "same" : "other"); }
                sc_put("]");
            }
            break;
        }
        case 'H': {
            PkgAction a;
            mem_zero(&a, sizeof a);
            (void)str_copy(a.args, arg[0] == ' ' ? arg + 1 : arg, sizeof a.args);
            sc_put("H "); sc_num(CALL(pkg_action_has_marked, &a));
            break;
        }
        case 'N':
            if (g_m) Object_free(&g_m->base);
            g_m = DirModel_new(word(&arg));
            while (g_m && g_m->is_loading) (void)DirModel_step_load(g_m, 0);
            sc_put("N"); if (g_m) { sc_put(" n="); sc_num((int64_t)g_m->count); }
            break;
        case 'S': {
            if (!g_m) continue;
            intptr_t i = DirModel_find_by_name(g_m, word(&arg));
            FileEntry *e = i >= 0 ? DirModel_get_entry(g_m, i) : nullptr;
            if (e) e->flags |= FE_SELECTED;
            sc_put("S "); sc_num(e != nullptr);
            break;
        }
        case 'W': {
            if (!g_m) continue;
            int cap = (int)num(word(&arg));
            char *fb = word(&arg);
            static char path[PATH_MAX + 64];
            mem_zero(path, sizeof path);
            int r = CALL(pkg_write_marked_list, g_m, fb[0] == '-' && !fb[1] ? nullptr : fb, path, cap);
            sc_put("W r="); sc_num(r);
            size_t got = 0;
            if (path[0] && fs_read_file_head(path, g_out, sizeof g_out - 1, &got) >= 0) {
                g_out[got] = 0;
                sc_put(" file=\""); put_text(g_out); sc_put("\"");
                (void)os_unlinkat(AT_FDCWD, path, 0);
            } else sc_put(path[0] ? " nofile" : " nopath");
            break;
        }
        case 'V': {
            int max = (int)num(word(&arg));
            char *f = word(&arg);
            mem_zero(g_out, sizeof g_out);
            sc_flush();
            int64_t t0 = os_clock_ms();
            int r = CALL(pkg_preview_try, envp, f, g_out, max);
            sc_put("V r="); sc_num(r); sc_put(" ms="); sc_num((os_clock_ms() - t0) / 1000 * 1000);
            if (r > 0) { g_out[r < (int)sizeof g_out ? r : (int)sizeof g_out - 1] = 0; sc_put(" out=\""); put_text(g_out); sc_put("\""); }
            break;
        }
        case 'T': sc_put("T files="); sc_num(tmp_count()); break;
        default: continue;
        }
        sc_put("\n");
        sc_flush();
    }
    if (g_m) Object_free(&g_m->base);
    sc_flush();
    return 0;
}
