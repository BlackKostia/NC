/* Freestanding harness: the frozen asm lazy stat / selection (dir_model_stat_reference.s, dir_model_select_reference.s and the
 * DirModel_get_entry / mark_link_dir copy in dir_model_entry_reference.s; x86_64, ref_ prefix) or src/fs/dir_model_stat.c +
 * dir_model_select.c (compiled into this unit, paths in DM_SRC1 / DM_SRC2, allocation through dm_alloc). argv[1] = ref | c.
 * Script on stdin:
 *   P <dir> <dotdot 0|1> <dirs> <files>   a new model listing <dir> (dir_count / file_count as the loader would count them)
 *   N <name> <flags>                      appends an entry (loader flags: FE_IS_DIR from d_type, FE_DT_UNKNOWN, FE_IS_HIDDEN ...)
 *   R                                     order[] = reversed raw order (count = raw_count)
 *   K <count>                             a filtered view: only the first count order[] slots are visible
 *   W <fd 0|1>                            load_dirfd: an open fd of <dir> (as while streaming) or -1
 *   S <start> <len> | E <idx> | A | T <idx> | X | C | F <name> | G <idx>
 *        stat_range, ensure_entry_stat(get_entry), ensure_all_stats, toggle_select, select_all_toggle, count_selected,
 *        find_by_name, get_entry - each prints its result and the whole model
 *   O <n>                                 the n-th allocation fails;   Q  the number of open fds (the io_uring ring excluded) */
#include "script_cli.h"
#include "duop_fs.h"
#include "duop_pal.h"

void *dm_alloc(size_t n);
static int64_t g_fail_in;
void *dm_alloc(size_t n)
{
    if (g_fail_in > 0 && --g_fail_in == 0) return nullptr;
    return mem_alloc(n);
}

#define mem_alloc dm_alloc
#include DM_SRC1
#include DM_SRC2
#undef mem_alloc

#ifdef __x86_64__
extern FileEntry *ref_DirModel_get_entry(DirModel *, intptr_t);
extern void ref_DirModel_ensure_entry_stat(DirModel *, FileEntry *);
extern void ref_DirModel_stat_range(DirModel *, size_t, size_t);
extern void ref_DirModel_ensure_all_stats(DirModel *);
extern void ref_DirModel_toggle_select(DirModel *, intptr_t);
extern void ref_DirModel_select_all_toggle(DirModel *);
extern size_t ref_DirModel_count_selected(DirModel *, int64_t *);
extern intptr_t ref_DirModel_find_by_name(DirModel *, const char *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

#define MAXE 5000
static bool g_ref;
static DirModel g_m;
static FileEntry g_ent[MAXE];
static uint32_t g_order[MAXE];
static char g_pool[MAXE * 64];
static size_t g_pool_n;

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

static void put_model(void)
{
    sc_put(" dirs="); sc_num(g_m.dir_count); sc_put(" files="); sc_num(g_m.file_count);
    sc_put(" bytes="); sc_num((int64_t)g_m.total_bytes); sc_put(" complete="); sc_num(g_m.stats_complete);
    for (uint64_t i = 0; i < g_m.raw_count; i++) {
        const FileEntry *e = &g_ent[i];
        sc_put(" |"); sc_num(e->flags); sc_put(","); sc_num(e->size); sc_put(","); sc_num(e->mtime % 100000); sc_put(","); sc_num(e->mode);
    }
}

static void unescape(char *s)                      /* "\s" = blank, "\xNN" = byte */
{
    char *o = s;
    for (; *s; s++) {
        if (s[0] == '\\' && s[1] == 's') { *o++ = ' '; s++; }
        else if (s[0] == '\\' && s[1] == 'x' && s[2] && s[3]) {
            int v = 0;
            for (int k = 2; k < 4; k++) v = v * 16 + (s[k] <= '9' ? s[k] - '0' : s[k] - 'a' + 10);
            *o++ = (char)v;
            s += 3;
        } else *o++ = *s;
    }
    *o = 0;
}

static int count_fds(void)
{
    intptr_t fd = os_openat(AT_FDCWD, "/proc/self/fd", O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (fd < 0) return -1;
    static char buf[8192];
    int n = 0;
    for (;;) {
        intptr_t r = os_dir_read((int)fd, buf, sizeof buf);
        if (r <= 0) break;
        size_t pos = 0;
        for (const char *nm; (nm = os_dir_next(buf, (size_t)r, &pos));) {
            char link[64] = "/proc/self/fd/", target[64];
            (void)str_copy(link + 14, nm, 40);
            intptr_t k = os_readlinkat(AT_FDCWD, link, target, sizeof target - 1);
            target[k < 0 ? 0 : k] = 0;
            if (!str_starts_with(target, "anon_inode:[io_uring]")) n++;   /* the PAL's ring of os_batch_stat is not a leak */
        }
    }
    (void)os_close((int)fd);
    return n - 3;                                  /* ".", ".." and the fd of the listing itself */
}

static void cmd(char **f, int n)
{
    switch (f[0][0]) {
    case 'P':
        if (g_m.load_dirfd >= 0) (void)os_close(g_m.load_dirfd);
        g_m = (DirModel){0};
        g_m.entries = g_ent; g_m.order = g_order; g_m.name_pool = g_pool; g_m.load_dirfd = -1;
        (void)str_copy(g_m.path, f[1], PATH_MAX);
        g_m.has_dotdot = (int32_t)num(f[2]); g_m.dir_count = (int32_t)num(f[3]); g_m.file_count = (int32_t)num(f[4]);
        g_pool_n = 0;
        return;
    case 'N': {
        if (g_m.raw_count >= MAXE || n < 3) return;
        unescape(f[1]);
        FileEntry *e = &g_ent[g_m.raw_count];
        *e = (FileEntry){.flags = (uint32_t)num(f[2]), .name_off = (uint32_t)g_pool_n, .name_len = (uint16_t)str_len(f[1]), .size = -1, .mtime = -1};
        g_pool_n += str_copy(g_pool + g_pool_n, f[1], 256) + 1;
        g_order[g_m.raw_count] = (uint32_t)g_m.raw_count;
        g_m.raw_count++;
        g_m.count = g_m.raw_count;
        return;
    }
    case 'R': for (uint64_t i = 0; i < g_m.raw_count; i++) g_order[i] = (uint32_t)(g_m.raw_count - 1 - i); return;
    case 'K': g_m.count = (uint64_t)num(f[1]); return;
    case 'W':
        g_m.load_dirfd = num(f[1]) ? (int)os_openat(AT_FDCWD, g_m.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0) : -1;
        return;
    case 'O': g_fail_in = num(f[1]); return;
    case 'Q': sc_put("Q fds="); sc_num(count_fds() - (g_m.load_dirfd >= 0)); break;
    case 'S': CALL(DirModel_stat_range, &g_m, (size_t)num(f[1]), (size_t)num(f[2])); sc_put("S"); put_model(); break;
    case 'E': CALL(DirModel_ensure_entry_stat, &g_m, CALL(DirModel_get_entry, &g_m, num(f[1]))); sc_put("E"); put_model(); break;
    case 'A': CALL(DirModel_ensure_all_stats, &g_m); sc_put("A"); put_model(); break;
    case 'T': CALL(DirModel_toggle_select, &g_m, num(f[1])); sc_put("T"); put_model(); break;
    case 'X': CALL(DirModel_select_all_toggle, &g_m); sc_put("X"); put_model(); break;
    case 'C': {
        int64_t bytes = 12345;
        size_t k = CALL(DirModel_count_selected, &g_m, n > 1 ? &bytes : nullptr);
        sc_put("C "); sc_num((int64_t)k); sc_put(" "); sc_num(bytes);
        break;
    }
    case 'F': unescape(f[1]); sc_put("F "); sc_num(CALL(DirModel_find_by_name, &g_m, f[1])); break;
    case 'G': { FileEntry *e = CALL(DirModel_get_entry, &g_m, num(f[1])); sc_put("G "); sc_num(e ? e - g_ent : -1); break; }
    default: return;
    }
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    g_m.load_dirfd = -1;
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[6];
        int n = sc_split(line, f, 6);
        if (n) cmd(f, n);
    }
    sc_flush();
    return 0;
}
