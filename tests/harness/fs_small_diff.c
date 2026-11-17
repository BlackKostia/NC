/* Differential harness for small src/fs modules against their frozen asm (ref_ prefix). Prints OK or the first mismatch.
 * dir_diff_mark: random DirModels with colliding names, directories, sizes, "..", preset selection flags. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "duop_fs.h"

extern int ref_dir_diff_mark(DirModel *, DirModel *);

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 20); }

static void fill(DirModel *m, int n)
{
    static const char *names[] = {"..", "a", "b", "abc", "dir", "x.txt", "X.txt", "long_name_here", "é", "a b", "."};
    memset(m, 0, sizeof *m);
    m->entries = calloc(n + 1, sizeof(FileEntry));
    m->name_pool = calloc(1, 1024);
    uint32_t used = 0;
    for (int i = 0; i < n; i++) {
        const char *nm = names[rnd() % (sizeof names / sizeof *names)];
        size_t l = strlen(nm) + 1;
        memcpy(m->name_pool + used, nm, l);
        FileEntry *e = &m->entries[i];
        e->name_off = used;
        used += (uint32_t)l;
        e->size = rnd() % 4 ? (int64_t)(rnd() % 3) * 100 : (int64_t)rnd() - 100;
        e->flags = (rnd() % 3 == 0 ? FE_IS_DIR : 0) | (rnd() % 2 ? FE_SELECTED : 0) | (rnd() % 5 == 0 ? FE_IS_HIDDEN : 0) | (rnd() % 7 == 0 ? FE_STAT_READY : 0);
    }
    m->raw_count = (uint64_t)n;
}

int main(void)
{
    for (int it = 0; it < 200000; it++) {
        DirModel a, b, o;
        int n = (int)(rnd() % 12), k = (int)(rnd() % 12);
        fill(&a, n);
        fill(&o, k);
        b = a;
        b.entries = malloc((size_t)(n + 1) * sizeof(FileEntry));
        memcpy(b.entries, a.entries, (size_t)(n + 1) * sizeof(FileEntry));
        DirModel *oth = it % 97 == 0 ? NULL : &o, *act = it % 89 == 0 ? NULL : &a;
        int ra = ref_dir_diff_mark(act, oth), rb = dir_diff_mark(act ? &b : NULL, oth);
        if (ra != rb || (act && memcmp(a.entries, b.entries, (size_t)n * sizeof(FileEntry)))) { printf("dir_diff_mark differs (iter %d: %d vs %d)\n", it, ra, rb); return 1; }
        free(a.entries); free(a.name_pool); free(b.entries); free(o.entries); free(o.name_pool);
    }
    puts("OK dir_diff_mark: 200000 random model pairs identical");
    return 0;
}
