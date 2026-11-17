/* src/fs/disk_usage.c - ncdu-style Disk Usage of a directory listing (freestanding C23; replaces disk_usage.s): every entry
 * shows its allocated space like `du` (st_blocks; directories included, mounts of derived filesystems skipped - see
 * du_parallel.c). Files are measured directly, folders in batches of 64 through io_uring statx + the subtree cache, and
 * the folders the cache cannot answer are walked in parallel. The model ends up sorted by size, largest first. */
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"

#define DU_BATCH 64
#define DU_MAX_MISSES 32768
#define DU_MAX_DEPTH 64
#define DU_OFF_PTRS 32768                /* arena: FileEntry *[64] at 0, names at DU_OFF_PTRS, errors, FileStat[64], misses at DU_STRIDE */
#define DU_OFF_ERRS (DU_OFF_PTRS + DU_BATCH * 8)
#define DU_OFF_STATS (DU_OFF_ERRS + DU_BATCH * 4)
#define DU_STRIDE 40960
_Static_assert(DU_OFF_STATS + DU_BATCH * sizeof(FileStat) <= DU_STRIDE, "stat block fits below the miss list");

typedef struct { FileEntry **fe; const char **names; int32_t *errs; FileStat *stats; DuWorkItem *misses; } DuBatch;

static DuBatch du_batch_of(void *arena)
{
    char *a = arena;
    return (DuBatch){(FileEntry **)a, (const char **)(a + DU_OFF_PTRS), (int32_t *)(a + DU_OFF_ERRS), (FileStat *)(a + DU_OFF_STATS),
                     (DuWorkItem *)(a + DU_STRIDE)};
}

int64_t du_mtime_sig(const FileStat *st) { return st->mtime ^ (int64_t)((uint64_t)st->mtime_nsec << 32); }

/* statx the queued folders; cache hits are final, the others are appended to the miss list. Returns the bytes of the hits */
static uint64_t du_flush_dir_batch(int dfd, void *arena, int count, int *miss_cnt)
{
    if (!count) return 0;
    DuBatch b = du_batch_of(arena);
    os_batch_stat(dfd, b.names, b.stats, b.errs, (size_t)count, 0);
    uint64_t sum = 0;
    for (int i = 0; i < count; i++) {
        uint64_t size;
        if (!b.errs[i] && du_cache_get(b.stats[i].ino, b.stats[i].dev, du_mtime_sig(&b.stats[i]), &size)) {
            b.fe[i]->size = (int64_t)size;
            b.fe[i]->flags |= FE_STAT_READY;
            sum += size;
        } else if (*miss_cnt < DU_MAX_MISSES) {
            b.misses[(*miss_cnt)++] = (DuWorkItem){b.fe[i], b.names[i], 0};
        }
    }
    return sum;
}

/* walks the cache misses (even one folder goes to a worker: the UI shows progress) and stores their sizes */
static uint64_t du_resolve_misses(int dfd, void *arena, int miss_cnt)
{
    if (!miss_cnt) return 0;
    DuWorkItem *miss = du_batch_of(arena).misses;
    du_parallel_walk(dfd, miss, miss_cnt);
    uint64_t sum = 0;
    for (int i = 0; i < miss_cnt; i++) {
        miss[i].fe->size = (int64_t)miss[i].size;
        miss[i].fe->flags |= FE_STAT_READY;
        sum += miss[i].size;
    }
    return sum;
}

/* shows the allocated size of a listed non-directory (sparse files, symlinks) and returns what it adds to the total:
 * 0 for another name of a hard-linked inode already counted */
static uint64_t du_top_file(int dfd, const char *name, FileEntry *e)
{
    FileStat st;
    int64_t usage = os_du_usage(dfd, name, &st);
    if (usage < 0) return 0;
    e->size = usage;
    e->flags |= FE_STAT_READY;
    if (st.nlink > 1 && !du_link_first(st.dev, st.ino)) return 0;
    return (uint64_t)usage;
}

void du_leave(DirModel *m)               /* back to the normal name-sorted listing */
{
    m->du_mode = 0;
    m->sort_mode = SORT_NAME;
    m->sort_desc = 0;
    DirModel_reload(m);
}

/* 1: size-sorted Disk Usage view; 0 when the walk was canceled from the progress UI (back to the normal listing) */
static int du_finish(DirModel *m, uint64_t total)
{
    if (du_progress()->cancel) { du_leave(m); return 0; }
    m->du_total = total;
    m->total_bytes = total;                                          /* pane summary: allocated space too */
    m->du_mode = 1;
    m->sort_mode = SORT_SIZE;
    m->sort_desc = 1;
    m->stats_complete = 1;
    m->is_unsorted = 0;
    DirModel_sort(m);
    return 1;
}

/* 1 done, 0 canceled from the progress UI (Esc): the model is then back in the normal listing, or the folder cannot be opened */
int dir_du_populate(DirModel *m)
{
    du_progress()->cancel = 0;
    du_links_reset();                                                /* hard links count once per scan */
    while (m->is_loading) DirModel_step_load(m, 4096);
    intptr_t fd = os_openat(AT_FDCWD, m->path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (fd < 0) return 0;
    char *arena = mem_alloc((size_t)DU_MAX_DEPTH * DU_STRIDE);
    DuBatch b = du_batch_of(arena);
    uint64_t total = 0;
    int queued = 0, misses = 0;
    for (uint64_t i = 0; i < m->raw_count; i++) {
        FileEntry *e = &m->entries[i];
        if (e->flags & FE_IS_PARENT) continue;
        const char *name = DirModel_entry_name(m, e);
        if (!(e->flags & FE_IS_DIR)) { total += du_top_file((int)fd, name, e); continue; }
        if (!arena) continue;
        b.fe[queued] = e;
        b.names[queued++] = name;
        if (queued < DU_BATCH) continue;
        total += du_flush_dir_batch((int)fd, arena, queued, &misses);
        queued = 0;
    }
    if (arena) {
        total += du_flush_dir_batch((int)fd, arena, queued, &misses);
        total += du_resolve_misses((int)fd, arena, misses);
    }
    mem_free(arena);
    os_close((int)fd);
    return du_finish(m, total);
}
