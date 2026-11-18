/* Freestanding harness: the frozen asm package manager (pkg_manager_reference.s, x86_64, ref_ prefix) or src/fs/pkg_manager.c
 * (compiled into this unit, path in PKM_SRC), over the real archive, hash and delete modules. pkg_fetch_url is a stand-in: the URL's
 * last component is copied from $FETCH_DIR; a URL containing "fail" leaves a partial file and fails. argv[1] = ref | c; the
 * environment is the one of the process. Script on stdin:
 *   R  pkg_get_root            L <max>  pkg_list            I <path|url> <sha|->  pkg_install_archive      D <name>  pkg_remove
 *   S <s>  pkm_safe_name and pkm_safe_relpath             T  files left in the temp directory */
#include "script_cli.h"
#include "duop_pkg.h"
#include "duop_config.h"
#include "duop_pal.h"

static char **g_cli_envp;
static uint8_t g_fbuf[1 << 23];

int pkg_fetch_url(char **envp, const char *url, const char *dest)
{
    (void)envp;
    const char *dir = cfg_getenv(g_cli_envp, "FETCH_DIR=");
    char src[PATH_MAX];
    size_t got = 0;
    bool fail = false;
    for (const char *p = url; *p; p++) if (str_starts_with(p, "fail")) fail = true;
    sc_put("  fetch "); sc_esc(url); sc_put(" -> "); sc_esc(path_basename(dest) + str_len(path_basename(dest)) - 4); sc_put("\n");
    if (fail) return pkg_write_file(dest, "partial", 7) == 0 ? -1 : -1;
    if (!dir || path_join(src, dir, path_basename(url), PATH_MAX) < 0 || fs_read_file_head(src, g_fbuf, sizeof g_fbuf, &got) < 0) return -1;
    return pkg_write_file(dest, g_fbuf, got);
}

#include PKM_SRC

#ifdef __x86_64__
extern void ref_pkg_get_root(char **, char *, int);
extern int ref_pkg_list(char **, PkgEntry *, int), ref_pkg_install_archive(char **, const char *, const char *);
extern int ref_pkg_remove(char **, const char *), ref_pkm_safe_name(const char *);
extern const char *ref_pkm_safe_relpath(const char *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static PkgEntry g_list[400];
static char g_root[PATH_MAX + 64];

static int sc_split(char *line, char **f, int max)
{
    int n = 0;
    while (*line && n < max) {
        while (*line == ' ') *line++ = 0;
        if (!*line) break;
        f[n++] = line;
        while (*line && *line != ' ') line++;
    }
    return n;
}

static int64_t num(const char *s) { int64_t v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0'); return v; }

static void cmd_list(int max)
{
    for (size_t i = 0; i < sizeof g_list; i++) ((uint8_t *)g_list)[i] = 0xA5;
    int k = CALL(pkg_list, g_cli_envp, g_list, max);
    sc_put("L n="); sc_num(k);
    for (int i = 0; i < k; i++) {
        sc_put(" ["); sc_esc(g_list[i].name); sc_put("|"); sc_esc(g_list[i].version); sc_put("|"); sc_esc(g_list[i].kind);
        sc_put("|"); sc_esc(g_list[i].desc); sc_put("]");
    }
    if (k < 400) { sc_put(" next="); sc_num(((uint8_t *)&g_list[k])[0]); }
}

static void cmd_tmp(void)
{
    char dir[PATH_MAX];
    uint8_t dents[8192];
    int n = 0;
    if (tmp_ensure_dir(dir, PATH_MAX) == 0) {
        intptr_t fd = os_openat(AT_FDCWD, dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
        for (intptr_t got; !os_is_err(fd) && (got = os_dir_read((int)fd, dents, sizeof dents)) > 0;) {
            size_t pos = 0;
            uint8_t type;
            for (const char *nm; (nm = os_dir_next_ex(dents, (size_t)got, &pos, &type));) n += nm[0] != '.';
        }
        if (!os_is_err(fd)) (void)os_close((int)fd);
    }
    sc_put("T files="); sc_num(n);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    g_cli_envp = envp;
    os_fault_guard_install();
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[4];
        int n = sc_split(line, f, 4);
        if (!n) continue;
        switch (f[0][0]) {
        case 'R': {
            mem_zero(g_root, sizeof g_root);
            CALLV(pkg_get_root, envp, g_root, PATH_MAX);
            const char *rt = cfg_getenv(envp, "TREE=");
            sc_put("R ");
            if (rt && str_starts_with(g_root, rt)) { sc_put("<T>"); sc_esc(g_root + str_len(rt)); }
            else { sc_esc(g_root); sc_put(" len="); sc_num((int64_t)str_len(g_root)); }
            break;
        }
        case 'L': cmd_list(n > 1 ? (int)num(f[1]) : 400); break;
        case 'I': {
            if (n < 3) continue;
            int r = CALL(pkg_install_archive, envp, f[1], f[2][0] == '-' ? "" : f[2]);
            sc_put("I r="); sc_num(r);
            break;
        }
        case 'D': { int r = CALL(pkg_remove, envp, n > 1 ? f[1] : ""); sc_put("D r="); sc_num(r); break; }
        case 'S': {
            const char *s = n > 1 ? f[1] : "";
            const char *p = CALL(pkm_safe_relpath, s);
            sc_put("S name="); sc_num(CALL(pkm_safe_name, s)); sc_put(" rel="); sc_num(p ? (int64_t)(p - s) : -1);
            break;
        }
        case 'T': cmd_tmp(); break;
        default: continue;
        }
        sc_put("\n");
        sc_flush();
    }
    sc_flush();
    return 0;
}
