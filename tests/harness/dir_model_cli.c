/* Freestanding harness: the frozen asm DirModel class (dir_model_reference.s, x86_64, ref_ prefix) or src/fs/dir_model.c (compiled
 * into this unit, path in DMC_SRC). The object runtime (src/core/oop_rt.c) is compiled in too, so that every mem_alloc / mem_free -
 * the object itself included - goes through dmc_alloc / dmc_free and live blocks can be counted. DirModel_reload and git_free_ctx
 * are stand-ins that record their calls. argv[1] = ref | c. Script on stdin:
 *   V <env...>          DirModel_init_env with the given "KEY=value" strings (- = NULL envp): both globals
 *   N <path|-> [fail]   DirModel_new (- = NULL: the cwd); fail = the n-th allocation fails; then the dtor, Object_free
 *   I <n> <dotdot>      a model with n entries of mixed flags: invalidate_stats and reset_entry_stats on copies
 *   C <fd 0|1> <buf 0|1>  close_stream_resources with an open fd / a load buffer, twice
 *   E                   DirModel_entry_name with NULL arguments and a real entry;   T  the vtable
 * Every command prints its results and the number of blocks it left allocated. */
#include "script_cli.h"
#include "duop_fs.h"
#include "duop_pal.h"

void *dmc_alloc(size_t n);
void dmc_free(void *p);
static int64_t g_fail_in, g_live, g_reloads, g_git_frees;
static char g_reload_path[PATH_MAX];

void *dmc_alloc(size_t n)
{
    if (g_fail_in > 0 && --g_fail_in == 0) return nullptr;
    void *p = mem_alloc(n);
    if (p) g_live++;
    return p;
}

void dmc_free(void *p)
{
    if (p) g_live--;
    mem_free(p);
}

int DirModel_reload(DirModel *m) { g_reloads++; (void)str_copy(g_reload_path, m->path, PATH_MAX); return 0; }
void git_free_ctx(DirModel *dm) { g_git_frees++; dm->git_ctx = nullptr; }

#define mem_alloc dmc_alloc
#define mem_free dmc_free
#include "../../src/core/oop_rt.c"
#include DMC_SRC
#undef mem_alloc
#undef mem_free

#ifdef __x86_64__
extern void ref_DirModel_init_env(char **);
extern DirModel *ref_DirModel_new(const char *);
extern void ref_DirModel_invalidate_stats(DirModel *);
extern void ref_reset_entry_stats(DirModel *);
extern void ref_close_stream_resources(DirModel *);
extern const char *ref_DirModel_entry_name(const DirModel *, const FileEntry *);
extern const ObjectVtbl ref_DirModel_vtbl;
extern uint64_t ref_g_huge_threshold, ref_g_stream_batch;
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define VAR(v) (g_ref ? ref_##v : v)
#define VTBL (g_ref ? &ref_DirModel_vtbl : &DirModel_vtbl)
#else
#define VTBL (&DirModel_vtbl)
#define CALL(f, ...) f(__VA_ARGS__)
#define VAR(v) (v)
#endif

static bool g_ref;
static FileEntry g_ent[64];

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

static int64_t g_live0;
static void live(void) { sc_put(" live="); sc_num(g_live - g_live0); }   /* blocks gained during this command */

static void cmd_new(char **f, int n)
{
    g_fail_in = n > 2 ? num(f[2]) : 0;
    g_reloads = 0;
    g_reload_path[0] = 0;
    DirModel *m = CALL(DirModel_new, f[1][0] == '-' && !f[1][1] ? nullptr : f[1]);
    g_fail_in = 0;
    sc_put("N m="); sc_num(m != nullptr); live();
    if (m) {
        sc_put(" fd="); sc_num(m->load_dirfd); sc_put(" hidden="); sc_num(m->show_hidden); sc_put(" sort="); sc_num(m->sort_mode);
        sc_put(" caps="); sc_num((int64_t)m->raw_cap); sc_put("/"); sc_num((int64_t)m->name_cap);
        sc_put(" arrays="); sc_num(!!m->entries + !!m->order + !!m->name_pool);
        sc_put(" vptr="); sc_num(m->base.vptr == VTBL);
        sc_put(" path="); sc_esc(m->path); sc_put(" reloads="); sc_num(g_reloads); sc_put(" "); sc_esc(g_reload_path);
        m->load_dirfd = (int)os_openat(AT_FDCWD, "/", O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
        m->load_buf = mem_alloc(100);
        if (m->load_buf) g_live++;
        int64_t before = g_git_frees;
        Object_free(&m->base);
        sc_put(" freed:"); live(); sc_put(" git="); sc_num(g_git_frees - before);
    }
}

static void put_flags(const DirModel *m)
{
    for (uint64_t i = 0; i < m->raw_count; i++) { sc_put(" "); sc_num(g_ent[i].flags); }
    sc_put(" tb="); sc_num((int64_t)m->total_bytes); sc_put(" sc="); sc_num(m->stats_complete);
}

static void cmd_reset(char **f)
{
    DirModel m = {0};
    m.entries = g_ent;
    m.raw_count = (uint64_t)num(f[1]) % 64;
    m.has_dotdot = (int32_t)num(f[2]);
    for (int pass = 0; pass < 2; pass++) {
        for (uint64_t i = 0; i < m.raw_count; i++) g_ent[i].flags = (uint32_t)(i * 2654435761u) & 0x1FF;
        m.total_bytes = 777; m.stats_complete = 1;
        if (pass) CALL(reset_entry_stats, &m); else CALL(DirModel_invalidate_stats, &m);
        sc_put(pass ? " R" : "I"); put_flags(&m);
    }
}

static void cmd_close(char **f)
{
    DirModel m = {0};
    m.load_dirfd = num(f[1]) ? (int)os_openat(AT_FDCWD, "/", O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0) : -1;
    int fd = m.load_dirfd;
    m.load_buf = num(f[2]) ? dmc_alloc(64) : nullptr;
    m.load_pos = 5; m.load_bytes = 9;
    CALL(close_stream_resources, &m);
    CALL(close_stream_resources, &m);
    sc_put("C fd="); sc_num(m.load_dirfd); sc_put(" buf="); sc_num(m.load_buf != nullptr);
    sc_put(" pos="); sc_num((int64_t)m.load_pos); sc_put(" bytes="); sc_num((int64_t)m.load_bytes);
    sc_put(" closed="); sc_num(fd < 0 ? 1 : os_close(fd) == -EBADF); live();
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[12];
        int n = sc_split(line, f, 11);
        if (!n) continue;
        g_live0 = g_live;
        switch (f[0][0]) {
        case 'V': {
            char *env[12] = {0};
            for (int i = 1; i < n; i++) env[i - 1] = f[i];
            CALL(DirModel_init_env, n > 1 && f[1][0] == '-' && !f[1][1] ? nullptr : env);
            sc_put("V "); sc_num((int64_t)VAR(g_huge_threshold)); sc_put(" "); sc_num((int64_t)VAR(g_stream_batch));
            break;
        }
        case 'N': if (n >= 2) cmd_new(f, n); break;
        case 'I': if (n >= 3) cmd_reset(f); break;
        case 'C': if (n >= 3) cmd_close(f); break;
        case 'E': {
            DirModel m = {0};
            static char pool[] = "zero\0first\0second";
            m.name_pool = pool;
            FileEntry e = {.name_off = 5};
            sc_put("E "); sc_num(CALL(DirModel_entry_name, nullptr, &e) == nullptr); sc_num(CALL(DirModel_entry_name, &m, nullptr) == nullptr);
            sc_put(" "); sc_esc(CALL(DirModel_entry_name, &m, &e));
            break;
        }
        case 'T': {
            const ObjectVtbl *v = VTBL;
            sc_put("T "); sc_esc(v->class_name); sc_put(" "); sc_num((int64_t)v->inst_size); sc_put(" super="); sc_num(v->super == &Object_vtbl);
            sc_put(" dtor="); sc_num(v->dtor != nullptr);
            break;
        }
        default: continue;
        }
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
