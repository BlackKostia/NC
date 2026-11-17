/* src/fs/dir_cache.c - LRU directory cache: keeps the fully loaded listings of recently left directories (freestanding C23;
 * replaces dir_cache.s + dir_cache_fetch.s, kept as tests/harness/dir_cache_reference.s and dir_cache_fetch_reference.s).
 *
 * Leaving a directory donates its DirModel arrays (entries / order / name_pool) to a slot: an ownership transfer, no copy. Coming
 * back validates the snapshot with the directory's dev / inode / mtime (seconds + nanoseconds, captured when the listing was
 * loaded) and on a match hands the arrays back in O(1): no getdents64, no UTF-8 scan, no sort. At most DC_SLOTS snapshots and
 * DC_BUDGET bytes in total (LRU eviction), so a huge directory never pins hundreds of MiB. */
#include "duop_fs.h"
#include "duop_string.h"

typedef struct DCSlot {               /* layout of types.inc DCSlot (the frozen oracle still uses it) */
    FileEntry *entries;
    uint32_t *order;
    char *name_pool;
    uint64_t raw_count, raw_cap, name_used, name_cap, count;
    uint64_t dev, ino;
    int64_t mtime;
    uint64_t lru, bytes;              /* LRU clock stamp; footprint charged to the budget */
    uint32_t mtime_ns, used;
    int32_t dir_count, file_count, has_dotdot, sort_mode, sort_desc, show_hidden, is_unsorted, huge_mode;
    char filter[FILTER_MAX];
    char path[PATH_MAX];
} DCSlot;
_Static_assert(sizeof(DCSlot) == 4304, "DCSlot mirrors include/types.inc");

static DCSlot *g_dc_slots;            /* DCSlot[DC_SLOTS], allocated on the first store */
uint64_t g_dc_bytes;                  /* sum of DCSlot.bytes of the used slots */
static uint64_t g_dc_clock;           /* LRU clock */

/* releases the arrays of a used slot and marks it free */
static void dc_free_slot(DCSlot *s)
{
    if (!s->used) return;
    mem_free(s->entries);
    mem_free(s->order);
    mem_free(s->name_pool);
    g_dc_bytes -= s->bytes;
    s->used = 0;
}

/* the used slot holding path, or nullptr */
static DCSlot *dc_find(const char *path)
{
    if (!g_dc_slots) return nullptr;
    for (int i = 0; i < DC_SLOTS; i++)
        if (g_dc_slots[i].used && !str_cmp(g_dc_slots[i].path, path)) return &g_dc_slots[i];
    return nullptr;
}

/* the least recently used occupied slot (nullptr when none); with want_free, the first free slot wins */
static DCSlot *dc_pick(bool want_free)
{
    DCSlot *best = nullptr;
    uint64_t best_lru = UINT64_MAX;
    for (int i = 0; i < DC_SLOTS; i++) {
        DCSlot *s = &g_dc_slots[i];
        if (!s->used) {
            if (want_free) return s;
            continue;
        }
        if (s->lru < best_lru) { best_lru = s->lru; best = s; }
    }
    return best;
}

static void dc_take(DCSlot *s, DirModel *m, uint64_t bytes)       /* m's listing -> slot s */
{
    s->entries = m->entries;
    s->order = m->order;
    s->name_pool = m->name_pool;
    s->raw_count = m->raw_count;
    s->raw_cap = m->raw_cap;
    s->name_used = m->name_used;
    s->name_cap = m->name_cap;
    s->count = m->count;
    s->dev = m->dir_dev;
    s->ino = m->dir_ino;
    s->mtime = m->dir_mtime;
    s->mtime_ns = (uint32_t)m->dir_mtime_ns;
    s->dir_count = m->dir_count;
    s->file_count = m->file_count;
    s->has_dotdot = m->has_dotdot;
    s->sort_mode = m->sort_mode;
    s->sort_desc = m->sort_desc;
    s->show_hidden = m->show_hidden;
    s->is_unsorted = m->is_unsorted;
    s->huge_mode = m->huge_mode;
    (void)str_copy(s->filter, m->filter, FILTER_MAX);
    (void)str_copy(s->path, m->path, PATH_MAX);
    s->bytes = bytes;
    g_dc_bytes += bytes;
    s->lru = ++g_dc_clock;
    s->used = 1;
    m->entries = nullptr;
    m->order = nullptr;
    m->name_pool = nullptr;
    m->raw_cap = m->name_cap = m->raw_count = m->count = m->name_used = 0;
}

/* Donates a complete listing to the cache. Returns 1 when taken (m's arrays become NULL and its capacities 0), or 0 when m keeps
 * its arrays (loading or aborted, unknown stamp, no arrays, larger than the whole budget, no slot table). */
int dircache_store(DirModel *m)
{
    if (m->is_loading || m->load_aborted || !m->dir_ino || !m->entries) return 0;
    uint64_t bytes = m->raw_cap * (sizeof(FileEntry) + 4) + m->name_cap;
    if (bytes > DC_BUDGET) return 0;
    if (!g_dc_slots) {
        g_dc_slots = mem_alloc(DC_SLOTS * sizeof(DCSlot));
        if (!g_dc_slots) return 0;
    }
    DCSlot *old = dc_find(m->path);                                      /* replace an older snapshot of the same path */
    if (old) dc_free_slot(old);
    DCSlot *s = dc_pick(true);
    dc_free_slot(s);
    while (g_dc_bytes + bytes > DC_BUDGET) {                             /* evict LRU snapshots until this one fits */
        DCSlot *lru = dc_pick(false);
        if (!lru) return 0;
        dc_free_slot(lru);
    }
    dc_take(s, m, bytes);
    return 1;
}

/* Looks up m->path. On a valid snapshot (same dev / ino / mtime / mtime_nsec) installs it into m (freeing m's current arrays) and
 * returns 1 when order[] is reusable as it is, or 2 when the caller must re-filter / re-sort (the snapshot had a filter, or hidden
 * files / sort mode / direction differ). Returns 0 on a miss; a stale snapshot is dropped. */
int dircache_fetch(DirModel *m, const FileStat *st)
{
    DCSlot *s = dc_find(m->path);
    if (!s) return 0;
    if (st->dev != s->dev || st->ino != s->ino || st->mtime != s->mtime || st->mtime_nsec != s->mtime_ns) {
        dc_free_slot(s);
        return 0;
    }
    mem_free(m->entries);
    mem_free(m->order);
    mem_free(m->name_pool);
    m->entries = s->entries;
    m->order = s->order;
    m->name_pool = s->name_pool;
    m->raw_count = s->raw_count;
    m->raw_cap = s->raw_cap;
    m->name_used = s->name_used;
    m->name_cap = s->name_cap;
    m->count = s->count;
    m->dir_dev = s->dev;
    m->dir_ino = s->ino;
    m->dir_mtime = s->mtime;
    m->dir_mtime_ns = (int32_t)s->mtime_ns;
    m->dir_count = s->dir_count;
    m->file_count = s->file_count;
    m->has_dotdot = s->has_dotdot;
    m->is_unsorted = s->is_unsorted;
    m->huge_mode = s->huge_mode;
    int same_view = !s->filter[0] && s->show_hidden == m->show_hidden && s->sort_mode == m->sort_mode && s->sort_desc == m->sort_desc;
    g_dc_bytes -= s->bytes;
    s->used = 0;                                                         /* the arrays now belong to m */
    return same_view ? 1 : 2;
}

/* drops the snapshot of path (e.g. on inotify events) */
void dircache_invalidate(const char *path)
{
    DCSlot *s = dc_find(path);
    if (s) dc_free_slot(s);
}
