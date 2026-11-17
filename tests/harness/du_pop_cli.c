/* Freestanding harness linked with the real directory model: frozen asm dir_du_populate (ref_ prefix) against src/fs/disk_usage.c.
 *   <ref|c> <dir> <runs> [cancel]   `runs` times: fresh DirModel of dir, dir_du_populate, dump the whole model (sizes, flags,
 *                                   order, totals, sort state); runs after the first hit the subtree cache. cancel: a progress
 *                                   callback cancels every walk, the model must come back as a plain listing. */
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

extern int ref_dir_du_populate(DirModel *);
extern void ref_du_set_progress(int (*)(void *, DuProgress *), void *);
DirModel *DirModel_new(const char *path);
void Object_free(Object *);

static char g_out[1 << 18];
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

static int cancel_cb(void *ctx, DuProgress *p) { (void)ctx; return p->phase != DU_PHASE_DONE; }

static void dump(const char *tag, int ret, DirModel *m)
{
    put(tag); put(" ret="); num(ret); put(" count="); num((int64_t)m->count); put(" du_mode="); num(m->du_mode);
    put(" total="); num((int64_t)m->du_total); put(" bytes="); num((int64_t)m->total_bytes); put(" sort="); num(m->sort_mode);
    put(" desc="); num(m->sort_desc); put(" complete="); num(m->stats_complete); put(" unsorted="); num(m->is_unsorted); put("\n");
    for (uint64_t i = 0; i < m->count; i++) {
        const FileEntry *e = &m->entries[m->order[i]];
        put(m->name_pool + e->name_off); put(" s="); num(e->size); put(" f="); num(e->flags & ~(uint32_t)FE_SELECTED); put("\n");
    }
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 4) return 2;
    bool ref = !str_cmp(argv[1], "ref"), cancel = argc > 4;
    int runs = argv[3][0] - '0';
    du_cache_cleanup();
    (ref ? ref_du_set_progress : du_set_progress)(cancel ? cancel_cb : nullptr, nullptr);
    for (int r = 0; r < runs; r++) {
        DirModel *m = DirModel_new(argv[2]);
        if (!m) return 3;
        int ret = ref ? ref_dir_du_populate(m) : dir_du_populate(m);
        dump(ref ? "REF" : "C", ret, m);
        Object_free(&m->base);
    }
    flush();
    return 0;
}
