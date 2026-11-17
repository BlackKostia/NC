/* Freestanding harness: the frozen asm loader / streamer (dir_model_load_reference.s + dir_model_stream_reference.s, x86_64, ref_
 * prefix) or src/fs/dir_model_load.c + dir_model_stream.c (compiled into this unit, paths in DML_SRC1 / DML_SRC2). The C DirModel
 * class is compiled in as well, so that every mem_alloc / mem_realloc can fail on request; filter, sorts, stat and dir cache are the
 * C modules. git_refresh / git_free_ctx count their calls. argv[1] = ref | c. Script on stdin:
 *   E <huge> <batch>         g_huge_threshold / g_stream_batch
 *   F <filter|-> <hidden>    filter and show_hidden of the next model
 *   L <path> [a <k>] [r <k>] a fresh model of path (alloc_initial_arrays) and DirModel_reload; the k-th mem_alloc / mem_realloc
 *                            from now fails
 *   R                        DirModel_reload of the current model again (a refresh: nothing may survive from before)
 *   S <max>                  DirModel_step_load;   A <max>  step until the load ends;   X  DirModel_cancel_load
 *   K                        dircache_store (then the snapshot is dropped again): would the dir cache take this listing?
 *   T <path> <max>           timing: reload + stream to the end, best of 3 (ms) */
#include "script_cli.h"
#include "duop_fs.h"
#include "duop_pal.h"

void *dml_alloc(size_t n);
void *dml_realloc(void *p, size_t n);
static int64_t g_fail_alloc, g_fail_realloc, g_gits;
void *dml_alloc(size_t n)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return mem_alloc(n);
}
void *dml_realloc(void *p, size_t n)
{
    if (g_fail_realloc > 0 && --g_fail_realloc == 0) return nullptr;
    return mem_realloc(p, n);
}

int git_refresh(DirModel *m) { (void)m; g_gits++; return 0; }
void git_free_ctx(DirModel *m) { m->git_ctx = nullptr; }

#define mem_alloc dml_alloc
#define mem_realloc dml_realloc
#include DML_SRC1
#include DML_SRC2
#include "../../src/fs/dir_model.c"
#undef mem_alloc
#undef mem_realloc

#ifdef __x86_64__
extern int ref_DirModel_reload(DirModel *);
extern intptr_t ref_DirModel_step_load(DirModel *, size_t);
extern void ref_DirModel_cancel_load(DirModel *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static DirModel *g_m;
static char g_filter[FILTER_MAX];
static int g_hidden = 1;

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

static uint64_t fnv(uint64_t h, const void *p, size_t n)
{
    for (size_t i = 0; i < n; i++) h = (h ^ ((const uint8_t *)p)[i]) * 1099511628211ull;
    return h;
}

static void put_model(int64_t r)
{
    DirModel *m = g_m;
    sc_put(" r="); sc_num(r); sc_put(" n="); sc_num((int64_t)m->count); sc_put("/"); sc_num((int64_t)m->raw_count);
    sc_put(" d="); sc_num(m->dir_count); sc_put(" f="); sc_num(m->file_count); sc_put(" dd="); sc_num(m->has_dotdot);
    sc_put(" ld="); sc_num(m->is_loading); sc_put(" ab="); sc_num(m->load_aborted); sc_put(" hu="); sc_num(m->huge_mode);
    sc_put(" us="); sc_num(m->is_unsorted); sc_put(" fv="); sc_num(m->flt_valid); sc_put(" fd="); sc_num(m->load_dirfd >= 0);
    sc_put(" buf="); sc_num(m->load_buf != nullptr); sc_put(" ino="); sc_num(m->dir_ino != 0); sc_put(" git="); sc_num(g_gits);
    sc_put(" caps="); sc_num((int64_t)m->raw_cap); sc_put("/"); sc_num((int64_t)m->name_cap); sc_put("/"); sc_num((int64_t)m->name_used);
    uint64_t h = 1469598103934665603ull;
    for (uint64_t i = 0; i < m->raw_count; i++) {
        const FileEntry *e = &m->entries[i];
        h = fnv(h, e, sizeof *e);
        h = fnv(h, m->name_pool + e->name_off, e->name_len + 1u);
    }
    h = fnv(h, m->order, m->count * 4);
    sc_put(" h="); sc_num((int64_t)(h >> 1));
    for (uint64_t i = 0; i < m->count && i < 12; i++) {
        const FileEntry *e = &m->entries[m->order[i]];
        sc_put(" "); sc_esc(m->name_pool + e->name_off); sc_put(":"); sc_num(e->flags); sc_put(","); sc_num(e->mode);
        sc_put(","); sc_num(e->disp_width); sc_put(","); sc_num(e->ext_offset);
    }
}

static void new_model(const char *path)
{
    if (g_m) Object_free(&g_m->base);
    g_m = Object_alloc(&DirModel_vtbl, DIRMODEL_SIZE);
    if (!g_m) return;
    g_m->load_dirfd = -1;
    g_m->show_hidden = g_hidden;
    if (alloc_initial_arrays(g_m)) return;
    (void)str_copy(g_m->path, path, PATH_MAX);
    (void)str_copy(g_m->filter, g_filter, FILTER_MAX);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    g_huge_threshold = HUGE_DIR_THRESHOLD;
    g_stream_batch = 4096;
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[8];
        int n = sc_split(line, f, 8);
        if (!n) continue;
        switch (f[0][0]) {
        case 'E': g_huge_threshold = (uint64_t)num(f[1]); g_stream_batch = (uint64_t)num(f[2]); continue;
        case 'F': (void)str_copy(g_filter, f[1][0] == '-' && !f[1][1] ? "" : f[1], FILTER_MAX); g_hidden = (int)num(f[2]); continue;
        case 'L': {
            new_model(f[1]);
            if (!g_m || !g_m->entries) { sc_put("L nomodel\n"); continue; }
            for (int i = 2; i + 1 < n; i += 2) {
                if (f[i][0] == 'a') g_fail_alloc = num(f[i + 1]);
                else g_fail_realloc = num(f[i + 1]);
            }
            g_gits = 0;
            int r = CALL(DirModel_reload, g_m);
            g_fail_alloc = 0;
            sc_put("L"); put_model(r);
            break;
        }
        case 'S': case 'A': {
            if (!g_m || !g_m->entries) continue;
            if (n > 2) g_fail_realloc = num(f[2]);
            intptr_t r = 0;
            int64_t steps = 0;
            do { r = CALL(DirModel_step_load, g_m, (size_t)num(f[1])); steps++; } while (f[0][0] == 'A' && r == 1 && steps < 1000000);
            g_fail_realloc = 0;
            sc_put(f[0][0] == 'A' ? "A steps=" : "S"); if (f[0][0] == 'A') sc_num(steps);
            put_model(r);
            break;
        }
        case 'R': if (!g_m || !g_m->entries) continue; g_gits = 0; { int r = CALL(DirModel_reload, g_m); sc_put("R"); put_model(r); } break;
        case 'X': if (!g_m) continue; CALL(DirModel_cancel_load, g_m); sc_put("X"); put_model(0); break;
        case 'K': {
            if (!g_m) continue;
            DirModel probe = *g_m;                                    /* the store would take the arrays: try it on a copy */
            int took = dircache_store(&probe);
            if (took) { dircache_invalidate(probe.path); g_m->entries = nullptr; g_m->order = nullptr; g_m->name_pool = nullptr; g_m->raw_count = g_m->count = 0; }
            sc_put("K "); sc_num(took);
            break;
        }
        case 'T': {
            int64_t best = INT64_MAX;
            for (int k = 0; k < 3; k++) {
                new_model(f[1]);
                if (!g_m || !g_m->entries) break;
                int64_t t0 = os_clock_ms();
                (void)CALL(DirModel_reload, g_m);
                while (CALL(DirModel_step_load, g_m, (size_t)num(f[2])) == 1) {}
                int64_t dt = os_clock_ms() - t0;
                if (dt < best) best = dt;
            }
            sc_put("T "); sc_num(best);
            break;
        }
        default: continue;
        }
        sc_put("\n");
    }
    if (g_m) Object_free(&g_m->base);
    sc_flush();
    return 0;
}
