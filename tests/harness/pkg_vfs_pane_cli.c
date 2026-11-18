/* Freestanding harness: the frozen asm VFS pane (pkg_vfs_pane_reference.s, x86_64, ref_ prefix) or src/fs/pkg_vfs_pane.c
 * (compiled into this unit, path in PKP_SRC) over the real DirModel and package manager; providers are real scripts. argv[1] =
 * ref | c; the root comes from the environment, TREE= masks paths. Script on stdin:
 *   N <dir>   a new DirModel on a real directory      F <uri>   pkg_vfs_find_by_uri      L <uri>   pkg_vfs_load_dir, then the model
 *   U <cap> <uri>   pkg_vfs_parent_uri               R <uri>   pkg_vfs_read_uri, then the temp file      T   files in the temp dir */
#include "script_cli.h"
#include "duop_pkg.h"
#include "duop_config.h"

int git_refresh(DirModel *m) { (void)m; return 0; }
void git_free_ctx(DirModel *m) { m->git_ctx = nullptr; }

#include PKP_SRC

#ifdef __x86_64__
extern int ref_pkg_vfs_find_by_uri(char **, const char *, char *), ref_pkg_vfs_load_dir(char **, DirModel *, const char *);
extern int ref_pkg_vfs_parent_uri(const char *, char *, int), ref_pkg_vfs_read_uri(char **, const char *, char *, int);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static const char *g_tree;
static DirModel *g_m;
static char g_buf[PATH_MAX + 64];
static uint8_t g_file[1 << 20];

static void put_path(const char *s)
{
    if (g_tree && str_starts_with(s, g_tree)) { sc_put("<T>"); sc_esc(s + str_len(g_tree)); } else sc_esc(s);
}

static uint64_t fnv(const uint8_t *p, size_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull;
    return h >> 1;
}

static void put_model(void)
{
    sc_put(" path="); put_path(g_m->path); sc_put(" vm="); sc_num(g_m->virtual_mode); sc_put(" n="); sc_num((int64_t)g_m->count);
    sc_put(" dirs="); sc_num(g_m->dir_count); sc_put(" files="); sc_num(g_m->file_count); sc_put(" stats="); sc_num(g_m->stats_complete);
    if (g_m->virtual_mode == 3 && g_m->arc_ctx) { sc_put(" orig="); put_path(g_m->arc_ctx); }
    for (uint64_t i = 0; i < g_m->count; i++) {
        const FileEntry *e = &g_m->entries[g_m->order[i]];
        sc_put(" "); sc_esc(g_m->name_pool + e->name_off); sc_put(":"); sc_num(e->flags & (FE_IS_DIR | FE_IS_PARENT));
        sc_put(":"); sc_num(e->size); sc_put(":"); sc_num(e->mtime); sc_put(":"); sc_num(e->mode);
    }
}

static void cmd_tmp(void)
{
    char dir[PATH_MAX];
    static uint8_t dents[8192];
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
    g_tree = cfg_getenv(envp, "TREE=");
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char cmd = line[0];
        char *arg = line[0] && line[1] == ' ' ? line + 2 : line + 1;
        sc_flush();
        switch (cmd) {
        case 'N':
            if (g_m) Object_free(&g_m->base);
            g_m = DirModel_new(arg);
            while (g_m && g_m->is_loading) (void)DirModel_step_load(g_m, 0);
            sc_put("N"); if (g_m) put_model();
            break;
        case 'F': {
            mem_zero(g_buf, sizeof g_buf);
            int r = CALL(pkg_vfs_find_by_uri, envp, arg, g_buf);
            sc_put("F r="); sc_num(r); if (!r) { sc_put(" "); put_path(g_buf); }
            break;
        }
        case 'L': { if (!g_m) continue; int r = CALL(pkg_vfs_load_dir, envp, g_m, arg); sc_put("L r="); sc_num(r); put_model(); break; }
        case 'U': {
            int cap = 0;
            while (*arg >= '0' && *arg <= '9') cap = cap * 10 + (*arg++ - '0');
            if (*arg == ' ') arg++;
            for (size_t i = 0; i < sizeof g_buf; i++) g_buf[i] = '#';
            int r = CALL(pkg_vfs_parent_uri, arg, g_buf, cap);
            size_t over = 0;
            for (size_t i = (size_t)cap + 1; i < sizeof g_buf; i++) over += g_buf[i] != '#';
            sc_put("U r="); sc_num(r); sc_put(" out="); sc_esc(g_buf);
            sc_put(" over="); sc_num((int64_t)over);
            break;
        }
        case 'R': {
            mem_zero(g_buf, sizeof g_buf);
            int r = CALL(pkg_vfs_read_uri, envp, arg, g_buf, PATH_MAX);
            sc_put("R r="); sc_num(r);
            size_t got = 0;
            if (r != 0) sc_put(g_buf[0] && fs_read_file_head(g_buf, g_file, sizeof g_file, &got) >= 0 ? " left" : " none");
            else if (g_buf[0] && fs_read_file_head(g_buf, g_file, sizeof g_file, &got) >= 0) {
                sc_put(" file len="); sc_num((int64_t)got); sc_put(" h="); sc_num((int64_t)fnv(g_file, got));
                (void)os_unlinkat(AT_FDCWD, g_buf, 0);
            } else sc_put(g_buf[0] ? " nofile" : " nopath");
            break;
        }
        case 'T': cmd_tmp(); break;
        default: continue;
        }
        sc_put("\n");
        sc_flush();
    }
    if (g_m) Object_free(&g_m->base);
    sc_flush();
    return 0;
}
