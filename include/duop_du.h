/* include/duop_du.h - C view of Disk Usage (src/fs/du_*.c, disk_usage.c): the live progress counters, the shared
 * hard-link set and the subtree size cache. DuProgress mirrors include/types.inc; tests/test_abi_layouts.py compares it. */
#pragma once
#include "duop_abi.h"
#include "duop_fs.h"

#define DU_PHASE_RUN 0                 /* DuProgress.phase: walk running */
#define DU_PHASE_DONE 1                /* final progress callback after the walk */

typedef struct DuProgress {
    int64_t start_ms;                  /* os_clock_ms() when the walk began */
    uint64_t dirs, files, bytes;       /* directories read, regular files counted, their allocated bytes */
    int32_t done, total;               /* top-level folders finished / to walk */
    int32_t cancel;                    /* set by the progress callback (Esc): walkers stop */
    int32_t phase;
} DuProgress;
_Static_assert(sizeof(DuProgress) == 48, "DuProgress is shared with assembly");

/* spinlock shared by the walker threads (the lock word lives in the .bss of the module that owns the table) */
static inline void du_spin_lock(uint32_t *lock)
{
    while (__atomic_exchange_n(lock, 1, __ATOMIC_ACQUIRE))
        while (__atomic_load_n(lock, __ATOMIC_RELAXED)) duop_cpu_relax();
}
static inline void du_spin_unlock(uint32_t *lock) { __atomic_store_n(lock, 0, __ATOMIC_RELEASE); }

void du_links_reset(void);                                   /* empty hard-link set for a new scan (allocated on first use) */
int du_link_first(uint64_t dev, uint64_t ino);               /* 1 = first sighting (count it), 0 = seen before */
void du_links_cleanup(void);

void *du_cache_init(void);                                   /* subtree size cache; NULL when out of memory */
int du_cache_get(uint64_t ino, uint64_t dev, int64_t mtime_sig, uint64_t *out_size);   /* 1 hit, 0 miss / stale */
void du_cache_put(uint64_t ino, uint64_t dev, int64_t mtime_sig, uint64_t size);
void du_cache_cleanup(void);

typedef struct DuWorkItem {            /* one top-level folder handed to du_parallel_walk */
    FileEntry *fe;                     /* listing entry that receives the size */
    const char *name;                  /* folder name below the scanned directory */
    uint64_t size;                     /* result: allocated bytes of the subtree */
} DuWorkItem;
_Static_assert(sizeof(DuWorkItem) == 24 || sizeof(void *) != 8, "DuWorkItem is 24 bytes on 64-bit targets");

int64_t du_mtime_sig(const FileStat *st);                    /* mtime and nanoseconds folded into one cache signature */
void du_parallel_walk(int dfd, DuWorkItem *items, int count);   /* sizes of the folders below dfd, up to four worker threads */
void du_set_progress(int (*cb)(void *ctx, DuProgress *p), void *ctx);   /* cb returns non-zero to cancel; NULL: no progress UI */
DuProgress *du_progress(void);
int dir_du_populate(DirModel *m);                            /* 1 size-sorted Disk Usage view, 0 canceled / not listable */
void du_leave(DirModel *m);                                  /* back to the name-sorted listing */
