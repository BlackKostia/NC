/* Freestanding harness: the frozen asm sorts (dir_sort*_reference.s, x86_64, ref_ prefix) and src/fs/dir_sort.c +
 * dir_sort_radix.c (compiled into this unit, paths in DS_SRC1 / DS_SRC2, allocation through ds_alloc). argv[1] = ref | c.
 * DirModel_ensure_all_stats is a stand-in that counts its calls and marks the stats complete. Script on stdin:
 *   E <n> <seed> <names kind 0..3> <dups %> <dirs %> [keys]   a random listing of n entries (FileEntry + name pool + order);
 *                                                        keys 1 / 2: sizes and times below 256 / 2^24 (one / three radix lanes)
 *   M <mode> <desc> <dotdot> <count> <stats>            DirModel_sort with these settings over order[0..count): the order and
 *                                                        is_unsorted are printed as a hash plus the first 24 indices
 *   K <i> <j> <mode> <desc>                             cmp_indices(i, j), extract_radix_key(i), make_prefix_key(i)
 *   H <mode> <desc> <len> / I ... / R ...               heapsort_u32 / insertion_sort_u32 / radix_sort_u32 on order[0..len)
 *   O <n>                                               the n-th allocation fails
 *   T <mode> <desc> <reps>                              DirModel_sort timing (ms) on the current listing */
#include "script_cli.h"
#include "duop_fs.h"

void *ds_alloc(size_t n);
static int64_t g_fail_in;
void *ds_alloc(size_t n)
{
    if (g_fail_in > 0 && --g_fail_in == 0) return nullptr;
    return mem_alloc(n);
}

#define mem_alloc ds_alloc
#include DS_SRC1
#include DS_SRC2
#undef mem_alloc

static int g_stats_calls;
void DirModel_ensure_all_stats(DirModel *m) { g_stats_calls++; m->stats_complete = 1; }

#ifdef __x86_64__
extern void ref_DirModel_sort(DirModel *);
extern int ref_cmp_indices(uint32_t, uint32_t, const FileEntry *, const char *, uint32_t, uint32_t);
extern uint64_t ref_extract_radix_key(uint32_t, const FileEntry *, uint32_t, uint32_t);
extern uint64_t ref_make_prefix_key(uint32_t, const FileEntry *, const char *, uint32_t, uint32_t);
extern void ref_heapsort_u32(uint32_t *, size_t, const FileEntry *, const char *, uint32_t, uint32_t);
extern void ref_insertion_sort_u32(uint32_t *, size_t, const FileEntry *, const char *, uint32_t, uint32_t);
extern void ref_radix_sort_u32(uint32_t *, size_t, const FileEntry *, const char *, uint32_t, uint32_t);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

#define MAXN 200000
static bool g_ref;
static DirModel g_m;
static FileEntry g_ent[MAXN];
static uint32_t g_order[MAXN], g_base[MAXN];
static uint8_t g_seen[MAXN];
static char g_pool[MAXN * 64];
static size_t g_n;
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

static int64_t num(const char *s)
{
    bool neg = *s == '-';
    int64_t v = 0;
    for (s += neg; *s >= '0' && *s <= '9'; s++) v = v * 10 + (*s - '0');
    return neg ? -v : v;
}

static const char g_alpha[] = "aAbBcCzZ09._-~ ";
static const char *const g_utf8[] = {"\xc3\xa9", "\xd0\xb0", "\xe2\x82\xac", "\xff", "\x7f"};

/* kind 0: short ASCII, 1: long names sharing 8-12 byte prefixes, 2: with UTF-8 / high bytes, 3: extensions,
 *      4: 24-byte shared camera-like prefix, 5: adversarial equal / near-equal names */
static size_t make_name(char *out, int kind)
{
    size_t n = 0, len = 1 + rnd() % (kind == 1 ? 20 : 9);
    if (kind == 1) { const char *pre = rnd() & 1 ? "SameprefiX" : "sameprefix"; while (*pre) out[n++] = *pre++; len += 2; }
    if (kind == 4) {
        const char *pre = "camera_photo_2026_11_20_";
        while (*pre) out[n++] = *pre++;
        for (int d = 0; d < 6; d++) out[n++] = (char)('0' + rnd() % 10);
        const char *suf = ".jpg";
        while (*suf) out[n++] = *suf++;
        out[n] = 0;
        return n;
    }
    if (kind == 5) {
        const char *s = rnd() % 3 ? "SameFileName" : "samefilename";
        while (*s) out[n++] = *s++;
        out[n] = 0;
        return n;
    }
    while (n < len) {
        if (kind == 2 && rnd() % 4 == 0) { for (const char *u = g_utf8[rnd() % 5]; *u;) out[n++] = *u++; continue; }
        out[n++] = g_alpha[rnd() % (sizeof g_alpha - 1)];
    }
    if (kind == 3 && rnd() % 5) {
        static const char *const ext[] = {".c", ".C", ".h", ".tar.gz", ".longextension", ".", ".Txt", ".txt", ".a"};
        for (const char *e = ext[rnd() % 9]; *e;) out[n++] = *e++;
    }
    out[n] = 0;
    return n;
}

static void cmd_listing(char **f)
{
    g_n = (size_t)num(f[1]);
    if (g_n > MAXN) g_n = MAXN;
    g_rng = (uint64_t)num(f[2]);
    int kind = (int)num(f[3]), dups = (int)num(f[4]), dirs = (int)num(f[5]), keys = f[6] ? (int)num(f[6]) : 0;
    size_t pool = 0;
    for (size_t i = 0; i < g_n; i++) {
        FileEntry *e = &g_ent[i];
        if (i && (int)(rnd() % 100) < dups) { *e = g_ent[rnd() % i]; e->flags = 0; }   /* the same name / size / time again */
        else {
            e->name_off = (uint32_t)pool;
            e->name_len = (uint16_t)make_name(g_pool + pool, kind);
            pool += e->name_len + 1u;
            const char *nm = g_pool + e->name_off;
            e->ext_offset = 0;
            for (uint32_t k = 1; k < e->name_len; k++) if (nm[k] == '.') e->ext_offset = (uint8_t)(k < 256 ? k : 0);
            uint32_t r = rnd();
            e->size = r % 3 == 0 ? (int64_t)(rnd() % 8) : r % 3 == 1 ? (int64_t)rnd() << 20 : -(int64_t)(rnd() % 5);
            e->mtime = rnd() % 2 ? (int64_t)(rnd() % 16) : ((int64_t)rnd() << 31) - ((int64_t)1 << 40);
            if (rnd() % 50 == 0) { e->size = INT64_MAX - rnd() % 2; e->mtime = INT64_MIN + rnd() % 2; }
            if (keys) { uint32_t lim = keys == 1 ? 256 : 1u << 24; e->size = rnd() % lim; e->mtime = rnd() % lim; }
            e->mode = 0;
            e->disp_width = 0;
        }
        uint32_t fl = (int)(rnd() % 100) < dirs ? (rnd() % 4 ? FE_IS_DIR : FE_LINK_DIR) : 0;
        e->flags = fl | (rnd() % 7 == 0 ? FE_IS_HIDDEN : 0);
        g_base[i] = (uint32_t)i;
    }
    for (size_t i = g_n; i > 1; i--) { size_t j = rnd() % i; uint32_t t = g_base[i - 1]; g_base[i - 1] = g_base[j]; g_base[j] = t; }
    sc_put("E "); sc_num((int64_t)g_n);
}

static uint64_t fnv_keys(size_t n, uint32_t mode, bool check_dirs)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) {
        const FileEntry *e = &g_ent[g_order[i]];
        if (check_dirs) {
            uint64_t d = (e->flags & (FE_IS_DIR | FE_LINK_DIR)) ? 1u : 0u;
            h = (h ^ d) * 1099511628211ull;
        }
        if (mode == SORT_SIZE) h = (h ^ (uint64_t)e->size) * 1099511628211ull;
        else if (mode == SORT_MTIME) h = (h ^ (uint64_t)e->mtime) * 1099511628211ull;
        else if (mode == SORT_EXT) h = (h ^ (uint64_t)e->ext_offset) * 1099511628211ull;
        for (const uint8_t *p = (const uint8_t *)g_pool + e->name_off; *p; p++)
            h = (h ^ *p) * 1099511628211ull;
        h = (h ^ 0xffu) * 1099511628211ull;
    }
    return h;
}

static int verify_order(size_t start, size_t count, uint32_t mode, uint32_t desc, bool check_dirs)
{
    for (size_t i = 0; i < count; i++) g_seen[g_base[i]] = 1;
    for (size_t i = 0; i < count; i++) {
        uint32_t idx = g_order[i];
        if (idx >= g_n || !g_seen[idx]) return 0;
        g_seen[idx] = 0;
    }
    for (size_t i = count; i < g_n; i++) if (g_order[i] != g_base[i]) return 0;
    if (start == 1 && count >= 1 && g_order[0] != g_base[0]) return 0;
    if (count <= start + 1) return 1;
    bool in_files = false;
    for (size_t i = start; i < count; i++) {
        bool is_dir = (g_ent[g_order[i]].flags & (FE_IS_DIR | FE_LINK_DIR)) != 0;
        if (check_dirs) {
            if (!is_dir) in_files = true;
            else if (in_files) return 0;
        }
        if (i > start) {
            bool prev_dir = (g_ent[g_order[i - 1]].flags & (FE_IS_DIR | FE_LINK_DIR)) != 0;
            if (!check_dirs || prev_dir == is_dir) {
                if (cmp_indices(g_order[i - 1], g_order[i], g_ent, g_pool, mode, desc) > 0) return 0;
            }
        }
    }
    return 1;
}

static void put_order(size_t start, size_t count, uint32_t mode, uint32_t desc, bool check_dirs)
{
    int ok = verify_order(start, count, mode, desc, check_dirs);
    sc_put(" ok="); sc_num(ok); sc_put(" h="); sc_num((int64_t)(fnv_keys(g_n, mode, check_dirs) >> 1));
}

static void reset_order(void) { for (size_t i = 0; i < g_n; i++) g_order[i] = g_base[i]; }

static void cmd_sort(char **f)
{
    reset_order();
    g_m.entries = g_ent; g_m.order = g_order; g_m.name_pool = g_pool;
    g_m.sort_mode = (int32_t)num(f[1]); g_m.sort_desc = (int32_t)num(f[2]); g_m.has_dotdot = (int32_t)num(f[3]);
    g_m.count = (uint64_t)num(f[4]); g_m.stats_complete = (int32_t)num(f[5]); g_m.is_unsorted = 7;
    g_stats_calls = 0;
    CALL(DirModel_sort, &g_m);
    sc_put("M stats="); sc_num(g_stats_calls); sc_put(" unsorted="); sc_num(g_m.is_unsorted);
    put_order((size_t)g_m.has_dotdot, (size_t)g_m.count, (uint32_t)g_m.sort_mode, (uint32_t)g_m.sort_desc, true);
}

static void cmd_slice(char kind, char **f)
{
    reset_order();
    uint32_t mode = (uint32_t)num(f[1]), desc = (uint32_t)num(f[2]);
    size_t len = (size_t)num(f[3]);
    if (len > g_n) len = g_n;
    if (kind == 'H') CALL(heapsort_u32, g_order, len, g_ent, g_pool, mode, desc);
    else if (kind == 'I') CALL(insertion_sort_u32, g_order, len, g_ent, g_pool, mode, desc);
    else CALL(radix_sort_u32, g_order, len, g_ent, g_pool, mode, desc);
    char t[3] = {kind, 0, 0};
    sc_put(t); put_order(0, len, mode, desc, false);
}

static void cmd_keys(char **f)
{
    uint32_t i = (uint32_t)num(f[1]) % (uint32_t)g_n, j = (uint32_t)num(f[2]) % (uint32_t)g_n, mode = (uint32_t)num(f[3]), desc = (uint32_t)num(f[4]);
    int c = CALL(cmp_indices, i, j, g_ent, g_pool, mode, desc);
    sc_put("K "); sc_num(c < 0 ? -1 : c > 0); sc_put(" "); sc_num(c);
    sc_put(" "); sc_num((int64_t)(CALL(extract_radix_key, i, g_ent, mode, desc) >> 1));
    sc_put(" "); sc_num((int64_t)(CALL(make_prefix_key, i, g_ent, g_pool, mode, desc) >> 1));
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[9] = {0};
        int n = sc_split(line, f, 8);
        if (!n) continue;
        switch (f[0][0]) {
        case 'E': if (n >= 6) cmd_listing(f); break;
        case 'M': if (n >= 6) cmd_sort(f); break;
        case 'K': if (n >= 5 && g_n) cmd_keys(f); break;
        case 'H': case 'I': case 'R': if (n >= 4) cmd_slice(f[0][0], f); break;
        case 'O': g_fail_in = num(f[1]); sc_put("O"); break;
        case 'T': {
            int64_t best = INT64_MAX;
            for (int64_t r = 0; r < num(f[3]); r++) {
                reset_order();
                g_m.entries = g_ent; g_m.order = g_order; g_m.name_pool = g_pool; g_m.count = g_n; g_m.has_dotdot = 0;
                g_m.sort_mode = (int32_t)num(f[1]); g_m.sort_desc = (int32_t)num(f[2]); g_m.stats_complete = 1;
                int64_t t0 = os_clock_ms();
                CALL(DirModel_sort, &g_m);
                int64_t dt = os_clock_ms() - t0;
                if (dt < best) best = dt;
            }
            sc_put("T "); sc_num(best);
            break;
        }
        case 'P': {
            int64_t best = INT64_MAX;
            int32_t mode = (int32_t)num(f[1]), desc = (int32_t)num(f[2]), pre = (int32_t)num(f[3]);
            for (int64_t r = 0; r < num(f[4]); r++) {
                reset_order();
                g_m.entries = g_ent; g_m.order = g_order; g_m.name_pool = g_pool; g_m.count = g_n; g_m.has_dotdot = 0;
                g_m.sort_mode = mode; g_m.sort_desc = pre; g_m.stats_complete = 1;
                CALL(DirModel_sort, &g_m);
                g_m.sort_desc = desc;
                int64_t t0 = os_clock_ms();
                CALL(DirModel_sort, &g_m);
                int64_t dt = os_clock_ms() - t0;
                if (dt < best) best = dt;
            }
            sc_put("P "); sc_num(best);
            break;
        }
        case 'Q': {
            reset_order();
            g_m.entries = g_ent; g_m.order = g_order; g_m.name_pool = g_pool; g_m.count = g_n; g_m.has_dotdot = 0;
            g_m.sort_mode = (int32_t)num(f[1]); g_m.sort_desc = (int32_t)num(f[3]); g_m.stats_complete = 1;
            CALL(DirModel_sort, &g_m);
            g_m.sort_desc = (int32_t)num(f[2]);
            CALL(DirModel_sort, &g_m);
            sc_put("Q");
            put_order(0, g_n, (uint32_t)g_m.sort_mode, (uint32_t)g_m.sort_desc, true);
            break;
        }
        default: continue;
        }
        sc_put("\n");
    }
    sc_flush();
    return 0;
}
