/* Freestanding harness: the frozen asm package registry (pkg_registry_reference.s, x86_64, ref_ prefix) or src/fs/pkg_registry.c
 * (compiled into this unit, path in PKR_SRC). Stand-ins for the package manager around it: pkg_get_root (PKG_ROOT), pkg_mkdir_p,
 * pkg_write_file, pkg_fetch_url ("...good..." URLs deliver <root>/remote.tsv), pkg_list (<root>/installed.txt: "name version"
 * lines) and pkg_install_archive (prints its call; fails for "...fail..." URLs). argv[1] = ref | c. Script on stdin:
 *   U   pkg_registry_update, then the registry file     L <max>   pkg_registry_list     F <name>   pkg_registry_find
 *   G   pkg_registry_upgrade                            S <a> <b> pkg_semver_cmp */
#include "script_cli.h"
#include "duop_pkg.h"
#include "duop_pal.h"

static char g_root[PATH_MAX];

void pkg_get_root(char **envp, char *out, int cap) { (void)envp; (void)str_copy(out, g_root, (size_t)cap); }
void pkg_mkdir_p(const char *path) { (void)os_mkdirat(AT_FDCWD, path, 0755); }

int pkg_write_file(const char *path, const void *buf, uint64_t len)
{
    intptr_t fd = os_openat(AT_FDCWD, path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    intptr_t w = sys_write_all((int)fd, buf, (size_t)len);
    (void)os_close((int)fd);
    return w < 0 ? -1 : 0;
}

static char g_tmp[PATH_MAX];
static char g_text[70000];

int pkg_fetch_url(char **envp, const char *url, const char *dest)
{
    (void)envp;
    sc_put("  fetch "); sc_esc(url); sc_put("\n");
    bool good = false;
    for (const char *p = url; *p; p++) if (str_starts_with(p, "good")) good = true;
    if (!good) return -1;
    (void)path_join(g_tmp, g_root, "remote.tsv", PATH_MAX);
    size_t got;
    if (fs_read_file_head(g_tmp, g_text, sizeof g_text, &got) < 0) return -1;
    return pkg_write_file(dest, g_text, got);
}

int pkg_list(char **envp, PkgEntry *out, int max)
{
    (void)envp;
    (void)path_join(g_tmp, g_root, "installed.txt", PATH_MAX);
    size_t got;
    if (fs_read_file_head(g_tmp, g_text, sizeof g_text - 1, &got) < 0) return 0;
    g_text[got] = 0;
    int n = 0;
    for (char *p = g_text; *p && n < max;) {
        char *e = p;
        while (*e && *e != '\n') e++;
        char *sp = p;
        while (sp < e && *sp != ' ') sp++;
        mem_zero(&out[n], sizeof out[n]);
        size_t k = (size_t)(sp - p) < 63 ? (size_t)(sp - p) : 63;
        mem_copy(out[n].name, p, k);
        if (sp < e) { size_t v = (size_t)(e - sp - 1) < 31 ? (size_t)(e - sp - 1) : 31; mem_copy(out[n].version, sp + 1, v); }
        n++;
        p = *e ? e + 1 : e;
    }
    return n;
}

int pkg_install_archive(char **envp, const char *url, const char *sha)
{
    (void)envp;
    sc_put("  install "); sc_esc(url); sc_put(" "); sc_esc(sha); sc_put("\n");
    for (const char *p = url; *p; p++) if (str_starts_with(p, "fail")) return -5;
    return 0;
}

#include PKR_SRC

#ifdef __x86_64__
extern int ref_pkg_registry_update(char **), ref_pkg_registry_list(char **, PkgRegEntry *, int);
extern int ref_pkg_registry_find(char **, const char *, PkgRegEntry *), ref_pkg_registry_upgrade(char **), ref_pkg_semver_cmp(const char *, const char *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static PkgRegEntry g_list[80];

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

static void put_entry(const PkgRegEntry *e)
{
    sc_put(" ["); sc_esc(e->name); sc_put("|"); sc_esc(e->version); sc_put("|"); sc_esc(e->kind); sc_put("|"); sc_esc(e->sha256);
    sc_put("|"); sc_esc(e->url); sc_put("|"); sc_esc(e->desc); sc_put("]");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const char *root = env_getenv(envp, "PKG_ROOT");
    (void)str_copy(g_root, root ? root : "/nonexistent", PATH_MAX);
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[4];
        int n = sc_split(line, f, 4);
        if (!n) continue;
        switch (f[0][0]) {
        case 'U': {
            int r = CALL(pkg_registry_update, envp);
            sc_put("U r="); sc_num(r);
            (void)path_join(g_tmp, g_root, "registry.tsv", PATH_MAX);
            size_t got = 0;
            if (fs_read_file_head(g_tmp, g_text, sizeof g_text - 1, &got) >= 0) { g_text[got] = 0; sc_put(" file="); sc_num((int64_t)got); }
            break;
        }
        case 'L': {
            for (size_t i = 0; i < sizeof g_list; i++) ((uint8_t *)g_list)[i] = 0xA5;
            int k = CALL(pkg_registry_list, envp, g_list, (int)num(f[1]));
            sc_put("L n="); sc_num(k);
            for (int i = 0; i < k; i++) put_entry(&g_list[i]);
            sc_put(" next="); sc_num(((uint8_t *)&g_list[k])[0]);
            break;
        }
        case 'F': {
            PkgRegEntry e;
            mem_zero(&e, sizeof e);
            int r = CALL(pkg_registry_find, envp, n > 1 ? f[1] : "", &e);
            sc_put("F r="); sc_num(r); if (!r) put_entry(&e);
            break;
        }
        case 'G': { int r = CALL(pkg_registry_upgrade, envp); sc_put("G r="); sc_num(r); break; }
        case 'S': if (n < 3) continue; sc_put("S "); sc_num(CALL(pkg_semver_cmp, f[1], f[2])); break;
        default: continue;
        }
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
