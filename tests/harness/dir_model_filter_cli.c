/* Freestanding harness: the frozen asm filter / chdir (dir_model_filter_reference.s + dir_model_flt_reference.s, x86_64, ref_
 * prefix) or src/fs/dir_model_filter.c (compiled into this unit, path in DMF_SRC). Both share the C dir cache, sorts and stat
 * (linked normally) and the C DirModel class (compiled in, so that its allocations can fail too). DirModel_reload is a stand-in that lists the directory with getdents (d_type flags, ".." unless
 * "/", the stamp of the directory) without sorting; git_refresh / git_free_ctx count their calls. argv[1] = ref | c.
 * Script on stdin:
 *   M <n> <seed> <hidden %> <dirs %>   a synthetic listing of n entries in the model (names over a small alphabet)
 *   F <filter|-> [h <0|1>] [l <0|1>] [u <0|1>] [g <0|1>] [s <mode> <desc>] [r <raw_count>]
 *                                       sets the filter (and show_hidden / is_loading / is_unsorted / huge_mode / sort / a grown
 *                                       raw count), then DirModel_apply_filter
 *   D <target>                          DirModel_chdir on the model created by N
 *   N <path>                            a model of <path> (DirModel_new with the stand-in reload)
 *   O <n>                               the n-th allocation fails;   Z  dircache_invalidate of the model's path
 *   S                                   every entry stat'ed and selected (as after browsing), stats_complete = 1
 * After F / D the model is printed: result, path, counts, flags, the visible names in order, filter state. */
#include "script_cli.h"
#include "duop_fs.h"
#include "duop_pal.h"

void *dmf_alloc(size_t n);
static int64_t g_fail_in, g_reloads, g_gits;
void *dmf_alloc(size_t n)
{
    if (g_fail_in > 0 && --g_fail_in == 0) return nullptr;
    return mem_alloc(n);
}

#define mem_alloc dmf_alloc
#include DMF_SRC
#include "../../src/fs/dir_model.c"               /* alloc_initial_arrays: its allocations can fail on request too */
#undef mem_alloc

int git_refresh(DirModel *m) { (void)m; g_gits++; return 0; }
void git_free_ctx(DirModel *m) { m->git_ctx = nullptr; }

static void add_entry(DirModel *m, const char *name, uint32_t flags)
{
    if (m->raw_count >= m->raw_cap) return;
    size_t len = str_len(name);
    if (m->name_used + len + 1 > m->name_cap) return;
    FileEntry *e = &m->entries[m->raw_count];
    *e = (FileEntry){.flags = flags, .name_off = (uint32_t)m->name_used, .name_len = (uint16_t)len, .size = (int64_t)len * 7};
    mem_copy(m->name_pool + m->name_used, name, len + 1);
    m->name_used += len + 1;
    m->order[m->raw_count] = (uint32_t)m->raw_count;
    m->raw_count++;
    m->count = m->raw_count;
}

int DirModel_reload(DirModel *m)
{
    g_reloads++;
    m->raw_count = m->count = m->name_used = 0;
    m->dir_count = m->file_count = 0;
    m->has_dotdot = 0;
    intptr_t fd = os_openat(AT_FDCWD, m->path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (fd < 0) return (int)fd;
    FileStat st;
    if (os_fstat((int)fd, &st) == 0) { m->dir_dev = st.dev; m->dir_ino = st.ino; m->dir_mtime = st.mtime; m->dir_mtime_ns = (int32_t)st.mtime_nsec; }
    if (!(m->path[0] == '/' && !m->path[1])) { add_entry(m, "..", FE_IS_PARENT | FE_IS_DIR | FE_STAT_READY); m->has_dotdot = 1; }
    static char buf[16384];
    for (;;) {
        intptr_t r = os_dir_read((int)fd, buf, sizeof buf);
        if (r <= 0) break;
        size_t pos = 0;
        uint8_t type;
        for (const char *nm; (nm = os_dir_next_ex(buf, (size_t)r, &pos, &type));) {
            if (nm[0] == '.' && (!nm[1] || (nm[1] == '.' && !nm[2]))) continue;
            uint32_t fl = (type == PAL_DT_DIR ? FE_IS_DIR : 0) | (nm[0] == '.' ? FE_IS_HIDDEN : 0);
            add_entry(m, nm, fl);
            if (fl & FE_IS_DIR) m->dir_count++; else m->file_count++;
        }
    }
    (void)os_close((int)fd);
    return 0;
}

#ifdef __x86_64__
extern void ref_DirModel_apply_filter(DirModel *);
extern intptr_t ref_DirModel_chdir(DirModel *, const char *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static DirModel *g_m;
static uint64_t g_rng;
static uint32_t rnd(void) { g_rng = g_rng * 6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(g_rng >> 33); }

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

static int64_t num(const char *s) { int64_t v = 0; bool neg = *s == '-'; for (s += neg; *s >= '0' && *s <= '9'; s++) v = v * 10 + (*s - '0'); return neg ? -v : v; }

static void put_model(intptr_t r)
{
    DirModel *m = g_m;
    sc_put(" r="); sc_num(r); sc_put(" path="); sc_esc(m->path);
    sc_put(" n="); sc_num((int64_t)m->count); sc_put("/"); sc_num((int64_t)m->raw_count);
    sc_put(" d="); sc_num(m->dir_count); sc_put(" f="); sc_num(m->file_count);
    sc_put(" ld="); sc_num(m->is_loading); sc_put(" ab="); sc_num(m->load_aborted); sc_put(" us="); sc_num(m->is_unsorted);
    sc_put(" fv="); sc_num(m->flt_valid); sc_put(" fr="); sc_num((int64_t)m->flt_raw); sc_put(" fh="); sc_num(m->flt_hidden);
    sc_put(" lc="); sc_esc(m->flt_lc); sc_put("/"); sc_num(m->flt_lc_len); sc_put(" fa="); sc_esc(m->flt_applied); sc_put(" fi="); sc_esc(m->filter);
    sc_put(" reloads="); sc_num(g_reloads); sc_put(" git="); sc_num(g_gits); sc_put(" dc="); sc_num((int64_t)g_dc_bytes);
    sc_put(" ent="); sc_num(m->entries != nullptr);
    int64_t rdy = 0, sel = 0;
    for (uint64_t i = 0; i < m->raw_count && m->entries; i++) { rdy += !!(m->entries[i].flags & FE_STAT_READY); sel += !!(m->entries[i].flags & FE_SELECTED); }
    sc_put(" rdy="); sc_num(rdy); sc_put(" sel="); sc_num(sel); sc_put(" sc="); sc_num(m->stats_complete);
    sc_put(" ["); for (uint64_t i = 0; i < m->count && m->entries; i++) { sc_put(" "); sc_esc(m->name_pool + m->entries[m->order[i]].name_off); }
    sc_put(" ]");
}

static const char g_alpha[] = "abcABC.xé";

static void cmd_synth(char **f)
{
    DirModel *m = g_m;
    m->raw_count = m->count = m->name_used = 0;
    m->flt_valid = 0;
    g_rng = (uint64_t)num(f[2]);
    int hidden = (int)num(f[3]), dirs = (int)num(f[4]);
    add_entry(m, "..", FE_IS_PARENT | FE_IS_DIR | FE_STAT_READY);
    m->has_dotdot = 1;
    for (int64_t i = 0; i < num(f[1]); i++) {
        char nm[16];
        int len = 1 + (int)(rnd() % 6), k = 0;
        bool hid = (int)(rnd() % 100) < hidden;
        if (hid) nm[k++] = '.';
        for (; k < len + hid; k++) nm[k] = g_alpha[rnd() % (sizeof g_alpha - 1)];
        nm[k] = 0;
        uint32_t fl = (hid ? FE_IS_HIDDEN : 0) | ((int)(rnd() % 100) < dirs ? (rnd() % 3 ? FE_IS_DIR : FE_LINK_DIR) : 0);
        add_entry(m, nm, fl | FE_STAT_READY);
    }
}

static void cmd_filter(char **f, int n)
{
    DirModel *m = g_m;
    (void)str_copy(m->filter, f[1][0] == '-' && !f[1][1] ? "" : f[1], FILTER_MAX);
    for (int i = 2; i + 1 < n; i += 2) {
        int64_t v = num(f[i + 1]);
        switch (f[i][0]) {
        case 'h': m->show_hidden = (int32_t)v; break;
        case 'l': m->is_loading = (int32_t)v; break;
        case 'u': m->is_unsorted = (int32_t)v; break;
        case 'g': m->huge_mode = (int32_t)v; break;
        case 's': m->sort_mode = (int32_t)v; if (i + 2 < n) { m->sort_desc = (int32_t)num(f[i + 2]); i++; } break;
        case 'r': if ((uint64_t)v <= m->raw_cap) m->raw_count = (uint64_t)v; break;
        default: break;
        }
    }
    CALL(DirModel_apply_filter, m);
    sc_put("F"); put_model(0);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[18];
        int n = sc_split(line, f, 18);
        if (!n) continue;
        if (f[0][0] == 'N' && n >= 2) {
            if (g_m) Object_free(&g_m->base);
            g_reloads = g_gits = 0;
            g_m = DirModel_new(f[1]);
            if (g_m) g_m->stats_complete = 1;
            sc_put("N "); sc_num(g_m != nullptr); sc_put("\n");
            continue;
        }
        if (!g_m) continue;
        switch (f[0][0]) {
        case 'M': if (n >= 5) cmd_synth(f); break;
        case 'F': if (n >= 2) cmd_filter(f, n); else continue; break;
        case 'D': if (n >= 2) { intptr_t r = CALL(DirModel_chdir, g_m, f[1]); sc_put("D"); put_model(r); g_m->stats_complete = 1; } else continue; break;
        case 'O': g_fail_in = num(f[1]); continue;
        case 'Z': dircache_invalidate(g_m->path); continue;
        case 'S':
            for (uint64_t i = 0; i < g_m->raw_count; i++) g_m->entries[i].flags |= FE_STAT_READY | FE_SELECTED;
            g_m->stats_complete = 1;
            continue;
        default: continue;
        }
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
