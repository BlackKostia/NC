/* src/fs/du_cache.c - in-memory recursive directory size cache for instant Disk Usage navigation (freestanding C23;
 * replaces du_cache.s). Open-addressing table of (ino, dev, mtime signature, size) slots shared by the walker threads
 * behind a spinlock; a changed mtime signature is a miss, a full 16-slot probe run evicts the first slot. */
#include "duop_du.h"
#include "duop_oop.h"

#define DU_CACHE_CAP 131072u
#define DU_CACHE_MASK (DU_CACHE_CAP - 1)
#define DU_PROBES 16

typedef struct { uint64_t ino, dev; int64_t mtime_sig; uint64_t size; } DuSlot;
_Static_assert(sizeof(DuSlot) == 32, "DuSlot is 32 bytes");

static DuSlot *g_du_tbl;
static uint32_t g_du_lock;

static uint32_t du_hash_key(uint64_t ino, uint64_t dev)
{
    uint64_t h = ino * 0x9E3779B97F4A7C15ull ^ dev;
    h = (h ^ (h >> 30)) * 0xBF58476D1CE4E5B9ull;
    return (uint32_t)h & DU_CACHE_MASK;
}

/* safe to call repeatedly from the main thread; returns the table (NULL when out of memory) */
void *du_cache_init(void)
{
    if (g_du_tbl) return g_du_tbl;
    DuSlot *t = mem_alloc(DU_CACHE_CAP * sizeof(DuSlot));
    if (!t) return nullptr;
    mem_zero(t, DU_CACHE_CAP * sizeof(DuSlot));
    g_du_tbl = t;
    return t;
}

/* 1 hit (size in *out_size), 0 miss (absent, stale mtime signature, or no table) */
int du_cache_get(uint64_t ino, uint64_t dev, int64_t mtime_sig, uint64_t *out_size)
{
    if (!g_du_tbl || !ino) return 0;
    du_spin_lock(&g_du_lock);
    DuSlot *tbl = g_du_tbl;
    uint32_t i = du_hash_key(ino, dev);
    int hit = 0;
    for (int probes = 0; probes < DU_PROBES; probes++, i = (i + 1) & DU_CACHE_MASK) {
        const DuSlot *s = &tbl[i];
        if (!s->ino) break;
        if (s->ino != ino || s->dev != dev) continue;
        if (s->mtime_sig == mtime_sig) { *out_size = s->size; hit = 1; }
        break;
    }
    du_spin_unlock(&g_du_lock);
    return hit;
}

void du_cache_put(uint64_t ino, uint64_t dev, int64_t mtime_sig, uint64_t size)
{
    if (!ino || !g_du_tbl) return;
    du_spin_lock(&g_du_lock);
    DuSlot *tbl = g_du_tbl;
    uint32_t first = du_hash_key(ino, dev), i = first;
    DuSlot *slot = &tbl[first];                         /* a full probe run evicts the initial slot */
    for (int probes = 0; probes < DU_PROBES; probes++, i = (i + 1) & DU_CACHE_MASK) {
        if (!tbl[i].ino || (tbl[i].ino == ino && tbl[i].dev == dev)) { slot = &tbl[i]; break; }
    }
    *slot = (DuSlot){ino, dev, mtime_sig, size};
    du_spin_unlock(&g_du_lock);
}

void du_cache_cleanup(void)
{
    void *t = g_du_tbl;
    if (!t) return;
    g_du_tbl = nullptr;
    mem_free(t);
}
