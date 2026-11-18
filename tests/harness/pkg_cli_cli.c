/* Freestanding harness: the frozen asm `duop pkg` dispatcher (pkg_cli_reference.s, x86_64, ref_ prefix) or src/fs/pkg_cli.c
 * (compiled into this unit, path in PKC_SRC). The package functions are stand-ins that print their calls: names containing "fail"
 * fail, the registry knows "known" (and "multi"), the list returns 3 packages, the registry 66 entries. argv[1] = ref | c. Script on
 * stdin: one `duop pkg ...` command line per line (the words after "duop pkg"); the exit code follows the output. */
#include "script_cli.h"
#include "duop_pkg.h"

static char **g_argv;
static int g_argc;

static void out(const char *s) { (void)sys_write_all(1, s, str_len(s)); }
static void outn(int64_t v) { char t[24]; if (v < 0) { out("-"); v = -v; } t[u64_to_dec((uint64_t)v, t)] = 0; out(t); }
static bool has(const char *s, const char *w) { for (; s && *s; s++) if (str_starts_with(s, w)) return true; return false; }

static void arg(const char *p)                                           /* which argv word a pointer is, never its bytes */
{
    if (!p) { out("null"); return; }
    for (int i = 0; i < g_argc; i++) if (p == g_argv[i]) { out("argv["); outn(i); out("]"); return; }
    out(str_starts_with(p, "reg-") ? p : "other");
}

static void fill(char *dst, const char *s) { (void)str_copy(dst, s, 64); }

int pkg_list(char **envp, PkgEntry *o, int max)
{
    (void)envp;
    out("  pkg_list max="); outn(max); out("\n");
    static const char *rows[3][4] = {{"alpha", "1.0", "theme", "Alpha theme"}, {"beta", "", "", ""}, {"g\xc3\xa9", "2", "lang", "Unicode"}};
    for (int i = 0; i < 3 && i < max; i++) { fill(o[i].name, rows[i][0]); fill(o[i].version, rows[i][1]); fill(o[i].kind, rows[i][2]); fill(o[i].desc, rows[i][3]); }
    return max < 3 ? max : 3;
}

int pkg_registry_list(char **envp, PkgRegEntry *o, int max)
{
    (void)envp;
    out("  registry_list max="); outn(max); out("\n");
    int n = 0;
    for (; n < 66 && n < max; n++) {
        char nm[32] = "pk";
        nm[2 + u64_to_dec((uint64_t)n, nm + 2)] = 0;
        fill(o[n].name, n == 3 ? "AlphaTool" : n == 5 ? "beta-alpha" : nm);
        fill(o[n].version, "1.0"); fill(o[n].kind, n % 2 ? "plugin" : "theme"); fill(o[n].desc, n == 7 ? "" : "desc");
    }
    return n;
}

int pkg_registry_find(char **envp, const char *name, PkgRegEntry *o)
{
    (void)envp;
    out("  registry_find "); out(name); out("\n");
    if (str_cmp(name, "known") && str_cmp(name, "multi-fail")) return -1;
    fill(o->url, !str_cmp(name, "known") ? "reg-url" : "reg-url-fail");
    fill(o->sha256, "reg-sha");
    return 0;
}

int pkg_install_archive(char **envp, const char *what, const char *sha)
{
    (void)envp;
    out("  install "); arg(what); out(" sha="); arg(sha); out("\n");
    return has(what, "fail") || has(what, "known") || (sha && has(sha, "bad")) ? -1 : 0;
}

int pkg_remove(char **envp, const char *name) { (void)envp; out("  remove "); arg(name); out("\n"); return has(name, "fail") ? -1 : 0; }
int pkg_verify(char **envp, const char *name) { (void)envp; out("  verify "); arg(name); out("\n"); return has(name, "fail") ? -1 : 0; }
int pkg_registry_update(char **envp) { (void)envp; out("  registry_update\n"); return has(g_argv[g_argc - 1], "fail") ? -1 : 0; }
int pkg_registry_upgrade(char **envp) { (void)envp; out("  registry_upgrade\n"); return has(g_argv[g_argc - 1], "fail") ? -1 : 0; }
int pkg_vfs_list_stdout(char **envp, const char *uri) { (void)envp; out("  vfs_list "); arg(uri); out("\n"); return has(uri, "fail") ? -1 : 0; }

#include PKC_SRC

#ifdef __x86_64__
extern int ref_pkg_cli_dispatch(int, char **, char **);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *words[16] = {"duop", "pkg"};
        int n = 2;
        while (*line && n < 16) {
            while (*line == ' ') *line++ = 0;
            if (!*line) break;
            words[n++] = line;
            while (*line && *line != ' ') line++;
        }
        if (n == 3 && !str_cmp(words[2], "-")) n = 2;                    /* "-": no subcommand at all */
        g_argv = words;
        g_argc = n;
        out("$");
        for (int i = 2; i < n; i++) { out(" "); out(words[i]); }
        out("\n");
        int code = CALL(pkg_cli_dispatch, n, words, envp);
        out("exit="); outn(code); out("\n");
    }
    return 0;
}
