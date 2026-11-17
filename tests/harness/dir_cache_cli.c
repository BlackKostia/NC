/* Freestanding harness: the frozen asm LRU directory cache (dir_cache_reference.s + dir_cache_fetch_reference.s, x86_64, ref_
 * prefix) or src/fs/dir_cache.c (compiled into this unit, path in DC_SRC); argv[1] = ref | c, one implementation per process
 * (the cache is global state). Both allocate and free through dc_alloc / dc_free here, so ownership is observable: every array a
 * model gets is a 16-byte block tagged with a unique id. Script on stdin, one command per line:
 *   M <k> <path> <filter|-> <entries 0/1> <is_loading> <load_aborted> <dev> <ino> <mtime> <mtime_ns> <raw_count> <raw_cap>
 *     <name_used> <name_cap> <count> <dir_count> <file_count> <has_dotdot> <sort_mode> <sort_desc> <show_hidden> <is_unsorted>
 *     <huge_mode>                                  (re)fills model k (0..3) with fresh tagged arrays (its old ones are freed)
 *   V <k> <sort_mode> <sort_desc> <show_hidden>   changes the view settings of model k
 *   S <k>                                          dircache_store(model k)
 *   F <k> <dev> <ino> <mtime> <mtime_ns>           dircache_fetch(model k, stat)
 *   I <path>                                       dircache_invalidate(path)
 *   O <n>                                          the n-th allocation from now fails (1 = the next one)
 * After S / F / I it prints the result, g_dc_bytes, the ids freed since the last command and model k's fields. */
#include "script_cli.h"
#include "duop_fs.h"

void *dc_alloc(size_t n);
void dc_free(void *p);

static int64_t g_fail_in;
static char g_freed[4096];
static size_t g_freed_n;

void *dc_alloc(size_t n)
{
    if (g_fail_in > 0 && --g_fail_in == 0) return nullptr;
    return mem_alloc(n);
}

void dc_free(void *p)
{
    if (p && g_freed_n < sizeof g_freed - 32) {
        char t[24];
        g_freed[g_freed_n++] = ' ';
        size_t k = u64_to_dec(*(uint64_t *)p, t);
        for (size_t i = 0; i < k; i++) g_freed[g_freed_n++] = t[i];
    }
    mem_free(p);
}

#define mem_alloc dc_alloc
#define mem_free dc_free
#include DC_SRC
#undef mem_alloc
#undef mem_free

#ifdef __x86_64__
extern int ref_dircache_store(DirModel *m);
extern int ref_dircache_fetch(DirModel *m, const FileStat *st);
extern void ref_dircache_invalidate(const char *path);
extern uint64_t ref_g_dc_bytes;
#endif

static DirModel g_m[4];
static uint64_t g_next_id = 1;
static bool g_ref;

static int64_t num(const char *s)
{
    bool neg = *s == '-';
    int64_t v = 0;
    for (s += neg; *s >= '0' && *s <= '9'; s++) v = v * 10 + (*s - '0');
    return neg ? -v : v;
}

static void *tagged(void)
{
    uint64_t *p = mem_alloc(16);
    if (p) { p[0] = g_next_id++; p[1] = 0; }
    return p;
}

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

static void put_id(const void *p) { sc_put(" "); sc_num(p ? (int64_t)*(const uint64_t *)p : 0); }

static void put_model(const DirModel *m)
{
    put_id(m->entries); put_id(m->order); put_id(m->name_pool);
    const int64_t v[] = {(int64_t)m->raw_count, (int64_t)m->raw_cap, (int64_t)m->name_used, (int64_t)m->name_cap, (int64_t)m->count,
                         (int64_t)m->dir_dev, (int64_t)m->dir_ino, m->dir_mtime, m->dir_mtime_ns, m->dir_count, m->file_count,
                         m->has_dotdot, m->is_unsorted, m->huge_mode, m->sort_mode, m->sort_desc, m->show_hidden};
    for (size_t i = 0; i < sizeof v / sizeof v[0]; i++) { sc_put(" "); sc_num(v[i]); }
}

static void cmd_model(char **f, int n)
{
    if (n < 24) return;
    DirModel *m = &g_m[num(f[1]) & 3];
    mem_free(m->entries); mem_free(m->order); mem_free(m->name_pool);
    (void)str_copy(m->path, f[2], PATH_MAX);
    (void)str_copy(m->filter, f[3][0] == '-' && !f[3][1] ? "" : f[3], FILTER_MAX);
    bool arrays = num(f[4]);
    m->entries = arrays ? tagged() : nullptr;
    m->order = arrays ? tagged() : nullptr;
    m->name_pool = arrays ? tagged() : nullptr;
    m->is_loading = (int32_t)num(f[5]); m->load_aborted = (int32_t)num(f[6]);
    m->dir_dev = (uint64_t)num(f[7]); m->dir_ino = (uint64_t)num(f[8]); m->dir_mtime = num(f[9]); m->dir_mtime_ns = (int32_t)num(f[10]);
    m->raw_count = (uint64_t)num(f[11]); m->raw_cap = (uint64_t)num(f[12]); m->name_used = (uint64_t)num(f[13]);
    m->name_cap = (uint64_t)num(f[14]); m->count = (uint64_t)num(f[15]);
    m->dir_count = (int32_t)num(f[16]); m->file_count = (int32_t)num(f[17]); m->has_dotdot = (int32_t)num(f[18]);
    m->sort_mode = (int32_t)num(f[19]); m->sort_desc = (int32_t)num(f[20]); m->show_hidden = (int32_t)num(f[21]);
    m->is_unsorted = (int32_t)num(f[22]); m->huge_mode = (int32_t)num(f[23]);
    g_freed_n = 0;
}

static int do_store(DirModel *m)
{
#ifdef __x86_64__
    if (g_ref) return ref_dircache_store(m);
#endif
    return dircache_store(m);
}

static int do_fetch(DirModel *m, const FileStat *st)
{
#ifdef __x86_64__
    if (g_ref) return ref_dircache_fetch(m, st);
#endif
    return dircache_fetch(m, st);
}

static void do_invalidate(const char *path)
{
#ifdef __x86_64__
    if (g_ref) { ref_dircache_invalidate(path); return; }
#endif
    dircache_invalidate(path);
}

static uint64_t bytes(void)
{
#ifdef __x86_64__
    if (g_ref) return ref_g_dc_bytes;
#endif
    return g_dc_bytes;
}

static void report(const char *tag, int r, const DirModel *m)
{
    sc_put(tag); sc_put(" r="); sc_num(r); sc_put(" bytes="); sc_num((int64_t)bytes());
    sc_put(" freed=["); g_freed[g_freed_n] = 0; sc_put(g_freed); sc_put(" ] m=");
    if (m) put_model(m);
    sc_put("\n");
    g_freed_n = 0;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[26];
        int n = sc_split(line, f, 26);
        if (!n) continue;
        DirModel *m = n > 1 ? &g_m[num(f[1]) & 3] : nullptr;
        switch (f[0][0]) {
        case 'M': cmd_model(f, n); break;
        case 'V': if (n >= 5) { m->sort_mode = (int32_t)num(f[2]); m->sort_desc = (int32_t)num(f[3]); m->show_hidden = (int32_t)num(f[4]); } break;
        case 'S': report("S", do_store(m), m); break;
        case 'F': {
            if (n < 6) break;
            FileStat st = {.dev = (uint64_t)num(f[2]), .ino = (uint64_t)num(f[3]), .mtime = num(f[4]), .mtime_nsec = (uint32_t)num(f[5])};
            report("F", do_fetch(m, &st), m);
            break;
        }
        case 'I': if (n >= 2) { do_invalidate(f[1]); report("I", 0, nullptr); } break;
        case 'O': if (n >= 2) g_fail_in = num(f[1]); break;
        default: break;
        }
    }
    sc_flush();
    return 0;
}
