/* Freestanding harness: frozen asm directory search (ref_ prefix) next to src/fs/dir_search*.c.
 *   lines                       stdin lines "G\t<str>\t<pat>" (glob), "M\t<name>\t<mask>\t<hasglob>" -> "ref c" per line
 *   grep <path> <pat>           ds_grep_file on one file
 *   run <root> <mask> <grep>    both implementations on the same tree; each prints its result and the whole DirModel */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

extern int ref_ds_glob_ci(const char *, const char *);
extern int ref_ds_match_mask(const char *, const char *, int);
extern int ref_ds_grep_file(int, const char *, const char *, size_t, char *);
extern int ref_dir_search_run(DirModel *, const char *, const char *, const char *);
extern int ref_ds_append_parent(DirModel *);
extern int ref_ds_append_entry(DirModel *, const char *, const FileStat *);
extern void ref_ds_join_rel(char *, const char *, const char *);

void DirModel_cancel_load(DirModel *m) { (void)m; }          /* the real one lives in the streaming loader */

static char g_out[1 << 20];
static size_t g_n;
static void flush(void) { (void)os_write(1, g_out, g_n); g_n = 0; }
static void put(const char *s) { while (*s) { if (g_n >= sizeof g_out - 8) flush(); g_out[g_n++] = *s++; } }
static void num(int64_t v)
{
    char t[24];
    if (v < 0) { put("-"); v = -v; }
    t[u64_to_dec((uint64_t)v, t)] = 0;
    put(t);
}

static void dump(const char *tag, int ret, const DirModel *m)
{
    put(tag); put(" ret="); num(ret);
    put(" count="); num((int64_t)m->count); put(" raw="); num((int64_t)m->raw_count); put(" dirs="); num(m->dir_count);
    put(" files="); num(m->file_count); put(" bytes="); num((int64_t)m->total_bytes); put(" dotdot="); num(m->has_dotdot);
    put(" virt="); num(m->virtual_mode); put(" used="); num((int64_t)m->name_used); put("\n");
    for (uint64_t i = 0; i < m->count; i++) {
        const FileEntry *e = &m->entries[m->order[i]];
        num(m->order[i]); put(" "); put(m->name_pool + e->name_off); put(" f="); num(e->flags); put(" s="); num(e->size);
        put(" m="); num(e->mode); put(" w="); num(e->disp_width); put(" l="); num(e->name_len); put(" x="); num(e->ext_offset); put("\n");
    }
}

static char *field(char **p)
{
    char *s = *p;
    while (**p && **p != '\t' && **p != '\n') (*p)++;
    if (**p) *(*p)++ = 0;
    return s;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    if (!str_cmp(argv[1], "lines")) {
        static char in[1 << 20];
        size_t n = 0;
        intptr_t r;
        while (n < sizeof in - 1 && (r = os_read(0, in + n, sizeof in - 1 - n)) > 0) n += (size_t)r;
        in[n] = 0;
        for (char *p = in; *p;) {
            char kind = *p;
            p += 2;
            char *a = field(&p), *b = field(&p);
            if (kind == 'G') { num(ref_ds_glob_ci(a, b)); put(" "); num(ds_glob_ci(a, b)); }
            else { int g = *field(&p) == '1'; num(ref_ds_match_mask(a, b, g)); put(" "); num(ds_match_mask(a, b, g)); }
            put("\n");
        }
    } else if (!str_cmp(argv[1], "grep") && argc >= 4) {
        static char b1[32768], b2[32768];
        size_t pl = str_len(argv[3]);
        num(ref_ds_grep_file(AT_FDCWD, argv[2], argv[3], pl, b1)); put(" "); num(ds_grep_file(AT_FDCWD, argv[2], argv[3], pl, b2)); put("\n");
    } else if (!str_cmp(argv[1], "parent")) {                        /* ds_append_parent / ds_append_entry / ds_join_rel */
        static DirModel a, b;
        static const char *const names[] = {"alpha", "b", "файл.txt", "dir", "x y"};
        FileStat st = {.size = 1234, .mtime = 99, .mode = S_IFREG | 0644};
        FileStat dir = {.mode = S_IFDIR | 0755}, exe = {.size = 7, .mode = S_IFREG | 0755};
        int ra = ref_ds_append_parent(&a), rb = ds_append_parent(&b);
        for (int i = 0; i < 300; i++) {                              /* crosses the 128-entry and 4096-byte growth steps */
            const FileStat *f = i % 7 == 0 ? &dir : i % 5 == 0 ? &exe : &st;
            char nm[64];
            ref_ds_join_rel(nm, i % 3 ? "pre/fix" : "", names[i % 5]);
            int ea = ref_ds_append_entry(&a, nm, f);
            char nm2[64];
            ds_join_rel(nm2, i % 3 ? "pre/fix" : "", names[i % 5]);
            int eb = ds_append_entry(&b, nm2, f);
            if ((ea < 0) != (eb < 0)) put("RETURN SIGN MISMATCH\n");
            if (str_cmp(nm, nm2)) put("JOIN MISMATCH\n");
        }
        dump("REF", ra, &a);
        dump("C", rb, &b);
    } else if (!str_cmp(argv[1], "run") && argc >= 5) {
        static DirModel a, b;
        const char *mask = argv[3][0] ? argv[3] : nullptr, *grep = argv[4][0] ? argv[4] : nullptr;
        int ra = ref_dir_search_run(&a, argv[2], mask, grep);
        int rb = dir_search_run(&b, argv[2], mask, grep);
        dump("REF", ra, &a);
        dump("C", rb, &b);
    }
    flush();
    return 0;
}
