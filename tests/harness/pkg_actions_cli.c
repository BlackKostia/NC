/* Freestanding harness: the frozen asm package actions (pkg_actions_reference.s, x86_64, ref_ prefix) or src/fs/pkg_actions.c
 * (compiled into this unit, path in PKA_SRC), with the real package manager below. argv[1] = ref | c; the root comes from the
 * environment. Script on stdin (one command per line, '|' separates the fields of B):
 *   P <file>    pkg_action_parse of a manifest file          F <name>   pkg_action_find
 *   S <max>     pkg_actions_scan                             M          pkg_menu_refresh, then pkg_menu_get(-1 .. count)
 *   B <exec>|<dir>|<cap>|<max>|<args>   pkg_action_build_argv with a fixed context (path unset), canaries after both buffers */
#include "script_cli.h"
#include "duop_pkg.h"
#include "duop_config.h"

#include PKA_SRC

#ifdef __x86_64__
extern void ref_pkg_action_parse(const char *, int, PkgAction *);
extern int ref_pkg_action_find(char **, const char *, PkgAction *), ref_pkg_actions_scan(char **, PkgAction *, int);
extern int ref_pkg_action_build_argv(PkgAction *, const char **, char *, int, char **, int);
extern int ref_pkg_menu_refresh(char **), ref_pkg_menu_count(void);
extern PkgAction *ref_pkg_menu_get(int);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#define CALL0(f) (g_ref ? ref_##f() : f())
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#define CALL0(f) f()
#endif

static bool g_ref;
static char **g_env;
static char g_file[8192];
static PkgAction g_acts[40];
static const char *g_tree;

static void put_path(const char *s)
{
    if (g_tree && str_starts_with(s, g_tree)) { sc_put("<T>"); sc_esc(s + str_len(g_tree)); } else sc_esc(s);
}

static void put_act(const PkgAction *a)
{
    const char *f[] = {a->name, a->exec, a->menu, a->args, a->scope, a->mode, a->ext};
    sc_put(" [");
    for (int i = 0; i < 7; i++) { sc_esc(f[i]); sc_put("|"); }
    put_path(a->dir);
    sc_put("]");
}

static int64_t num(const char *s) { int64_t v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0'); return v; }

static void cmd_build(char *spec)
{
    char *fld[5] = {""};
    int k = 0;
    fld[k++] = spec;
    for (char *p = spec; *p && k < 5; p++) if (*p == '|') { *p = 0; fld[k++] = p + 1; }
    if (k < 5) return;
    PkgAction act;
    mem_zero(&act, sizeof act);
    (void)str_copy(act.exec, fld[0], sizeof act.exec);
    (void)str_copy(act.dir, fld[1], sizeof act.dir);
    (void)str_copy(act.args, fld[4], sizeof act.args);
    static const char *ctx[5] = {"/the/dir", "/other dir", "file name.txt", nullptr, "/tmp/marked.lst"};
    static char buf[2048];
    static char *argv[80];
    int cap = (int)num(fld[2]), max = (int)num(fld[3]);
    for (size_t i = 0; i < sizeof buf; i++) buf[i] = '#';
    for (size_t i = 0; i < 80; i++) argv[i] = (char *)1;
    int n = CALL(pkg_action_build_argv, &act, ctx, buf, cap, argv, max);
    sc_put("B n="); sc_num(n);
    for (int i = 0; n > 0 && i <= n; i++) {
        sc_put(" ");
        if (!argv[i]) { sc_put("NULL"); break; }
        int c = -1;
        for (int j = 0; j < 5; j++) if (argv[i] == ctx[j]) c = j;
        if (!argv[i][0] && (argv[i] < buf || argv[i] >= buf + sizeof buf)) { sc_put("<unset>"); continue; }
        if (c >= 0) { sc_put("ctx"); sc_num(c); continue; }
        sc_put("'"); sc_esc(argv[i]); sc_put("'@"); sc_num(argv[i] - buf);
    }
    if (n < 0) { sc_put(" argv0="); sc_put(argv[0] ? "set" : "NULL"); }
    int over = 0, tail = 0;
    for (int i = cap > 0 ? cap : 0; i < (int)sizeof buf; i++) over += buf[i] != '#';
    for (int i = max > 0 ? max : 0; i < 80; i++) tail += argv[i] != (char *)1;
    sc_put(" over="); sc_num(over); sc_put(" tail="); sc_num(tail);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    g_env = envp;
    g_tree = cfg_getenv(envp, "TREE=");
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char cmd = line[0];
        char *arg = line[0] && line[1] == ' ' ? line + 2 : line + 1;
        switch (cmd) {
        case 'P': {
            size_t got = 0;
            if (fs_read_file_head(arg, g_file, sizeof g_file, &got) < 0) { sc_put("P noread"); break; }
            for (size_t i = 0; i < sizeof g_acts[0]; i++) ((uint8_t *)&g_acts[0])[i] = 0xA5;
            CALLV(pkg_action_parse, g_file, (int)got, &g_acts[0]);
            sc_put("P"); put_act(&g_acts[0]);
            break;
        }
        case 'F': {
            mem_zero(&g_acts[0], sizeof g_acts[0]);
            int r = CALL(pkg_action_find, g_env, arg, &g_acts[0]);
            sc_put("F r="); sc_num(r); if (!r) put_act(&g_acts[0]);
            break;
        }
        case 'S': {
            int n = CALL(pkg_actions_scan, g_env, g_acts, (int)num(arg));
            sc_put("S n="); sc_num(n);
            for (int i = 0; i < n; i++) put_act(&g_acts[i]);
            break;
        }
        case 'M': {
            int n = CALL(pkg_menu_refresh, g_env);
            sc_put("M n="); sc_num(n); sc_put(" count="); sc_num(CALL0(pkg_menu_count));
            for (int i = -1; i <= n; i++) { PkgAction *a = CALL(pkg_menu_get, i); if (!a) sc_put(" null"); else put_act(a); }
            break;
        }
        case 'B': cmd_build(arg); break;
        default: continue;
        }
        sc_put("\n");
        sc_flush();
    }
    sc_flush();
    return 0;
}
