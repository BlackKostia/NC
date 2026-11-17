/* Freestanding harness: frozen asm fuzzy finder (ref_ prefix) next to src/fs/dir_fuzzy*.c and fs_write.c.
 *   score                        stdin lines "<query>\t<candidate>" -> "ref_score ref_mask c_score c_mask" per line
 *   collect <root> <cap> <max>   both walkers on one tree: "CMP pool items ret" flags, then the C result (offset dir path)
 *   write <ref|c> <path>         fs_write_file of stdin into path: prints the return value */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

extern int ref_fuzzy_score(const char *, const char *, uint64_t *);
extern int ref_dir_fuzzy_collect(const char *, char *, int, FuzzyItem *, int);
extern int ref_fs_write_file(const char *, const void *, uint64_t);

static char g_out[1 << 16];
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

static char *field(char **p)
{
    char *s = *p;
    while (**p && **p != '\t' && **p != '\n') (*p)++;
    if (**p) *(*p)++ = 0;
    return s;
}

static size_t slurp(char *in, size_t cap)
{
    size_t n = 0;
    intptr_t r;
    while (n < cap - 1 && (r = os_read(0, in + n, cap - 1 - n)) > 0) n += (size_t)r;
    in[n] = 0;
    return n;
}

static int dec(const char *s)
{
    int v = 0;
    while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
    return v;
}

#define POOL_MAX 262144
#define ITEMS_MAX 5000
static char pool_a[POOL_MAX], pool_b[POOL_MAX];
static FuzzyItem items_a[ITEMS_MAX], items_b[ITEMS_MAX];

static int same(const void *a, const void *b, size_t n)
{
    const uint8_t *x = a, *y = b;
    for (size_t i = 0; i < n; i++) if (x[i] != y[i]) return 0;
    return 1;
}

static void collect(const char *root, int cap, int max)
{
    for (size_t i = 0; i < sizeof pool_a; i++) pool_a[i] = pool_b[i] = (char)0xAA;
    for (size_t i = 0; i < sizeof items_a; i++) ((uint8_t *)items_a)[i] = ((uint8_t *)items_b)[i] = 0x5C;
    int ra = ref_dir_fuzzy_collect(root, pool_a, cap, items_a, max);
    int rb = dir_fuzzy_collect(root, pool_b, cap, items_b, max);
    int items_ok = ra == rb;
    for (int i = 0; items_ok && i < max; i++) {
        if (i < ra) {
            items_ok = items_a[i].path - pool_a == items_b[i].path - pool_b && items_a[i].is_dir == items_b[i].is_dir && items_a[i].pad == items_b[i].pad;
        } else {
            items_ok = same(&items_a[i], &items_b[i], sizeof(FuzzyItem));
        }
    }
    put("CMP pool="); num(same(pool_a, pool_b, (size_t)cap));
    put(" items="); num(items_ok);
    put(" ret="); num(ra); put("/"); num(rb); put("\n");
    for (int i = 0; i < rb; i++) {
        num(items_b[i].path - pool_b); put(" "); num(items_b[i].is_dir); put(" "); put(items_b[i].path); put("\n");
    }
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    if (!str_cmp(argv[1], "score")) {
        static char in[1 << 23];
        slurp(in, sizeof in);
        for (char *p = in; *p;) {
            char *q = field(&p), *c = field(&p);
            uint64_t ma = 0x1111, mb = 0x2222;
            int a = ref_fuzzy_score(q, c, &ma), b = fuzzy_score(q, c, &mb);
            num(a); put(" "); num((int64_t)(ma & 0x7FFFFFFFFFFFFFFFull)); put(" "); num((int64_t)(ma >> 63)); put(" ");
            num(b); put(" "); num((int64_t)(mb & 0x7FFFFFFFFFFFFFFFull)); put(" "); num((int64_t)(mb >> 63)); put("\n");
            if (a == b && ref_fuzzy_score(q, c, nullptr) != fuzzy_score(q, c, nullptr)) put("NULLMASK MISMATCH\n");
        }
    } else if (!str_cmp(argv[1], "collect") && argc >= 5) {
        collect(argv[2], dec(argv[3]), dec(argv[4]));
    } else if (!str_cmp(argv[1], "write") && argc >= 4) {
        static char in[1 << 22];
        size_t n = slurp(in, sizeof in);
        int r = !str_cmp(argv[2], "ref") ? ref_fs_write_file(argv[3], in, n) : fs_write_file(argv[3], in, n);
        num(r); put("\n");
    }
    flush();
    return 0;
}
