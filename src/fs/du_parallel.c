/* src/fs/du_parallel.c - multi-threaded Disk Usage subtree walker (freestanding C23; replaces du_parallel.s).
 * Allocated bytes (st_blocks, directories included, like `du`) of the top-level folders are computed by up to four worker
 * threads (PAL clone + futex join); every worker keeps a private arena of one getdents block per recursion level (depth <= 64)
 * and its own stack. Walkers publish live DuProgress counters; with a progress callback registered (du_set_progress) every
 * folder is walked by a thread while the main thread runs the callback about every 100 ms (the app draws a progress window
 * and polls Esc) and a non-zero return cancels the walk. Fully walked directories are cached by (ino, dev, mtime), mounts
 * of derived filesystems (proc, sysfs, FUSE, ...) count as 0 and hard links count once per scan (du_link_first). */
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"

#define DUP_MAX_DEPTH 64
#define DUP_STRIDE 32768                 /* getdents64 buffer per recursion level */
#define DUP_ARENA_SZ (DUP_MAX_DEPTH * DUP_STRIDE)
#define DUP_STACK_SZ 65536
#define DUP_WORKERS 4
#define DUP_OPEN_DIR (O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)

typedef struct {                         /* shared by the workers of one du_parallel_walk call */
    int32_t dfd, count, next_idx, pad;
    DuWorkItem *items;
    uint64_t dev;                        /* st_dev of the scanned folder: top-level mounts are checked against it */
} DupCtx;

typedef struct {
    DupCtx *ctx;
    void *arena;
    int32_t ctid, pad;                   /* cleared by the kernel when the thread exits */
    void *stack_top;
} DupWorker;

typedef struct {                         /* one directory being walked */
    FileStat st;
    int64_t sig;
    uint64_t size;
    bool cacheable;
} DupDir;

static DuProgress g_dup_prog;
static int (*g_dup_cb)(void *ctx, DuProgress *p);
static void *g_dup_cb_ctx;

#define DUP_ADD(field, v) ((void)__atomic_fetch_add(&g_dup_prog.field, (v), __ATOMIC_RELAXED))
static bool dup_canceled(void) { return __atomic_load_n(&g_dup_prog.cancel, __ATOMIC_RELAXED) != 0; }

void du_set_progress(int (*cb)(void *ctx, DuProgress *p), void *ctx)   /* cb = NULL: no progress UI */
{
    g_dup_cb = cb;
    g_dup_cb_ctx = ctx;
}

DuProgress *du_progress(void) { return &g_dup_prog; }                 /* counters of the current / last walk (cancel is caller-reset) */

/* fstat the directory, skip a derived mount, consult the cache, count the directory's own blocks. true: settled (d->size is final) */
static bool dup_enter(int dfd, uint64_t parent_dev, DupDir *d)
{
    int64_t own = 0;
    d->cacheable = false;
    d->size = 0;
    d->st.dev = parent_dev;                                          /* children inherit it when fstat fails */
    if (os_fstat_du(dfd, &d->st, &own) >= 0) {
        if (d->st.dev != parent_dev && os_fs_is_derived(dfd)) return true;
        d->cacheable = true;
        d->sig = du_mtime_sig(&d->st);
        uint64_t cached;
        if (du_cache_get(d->st.ino, d->st.dev, d->sig, &cached)) {
            d->size = cached;
            DUP_ADD(bytes, cached);
            return true;
        }
    }
    DUP_ADD(dirs, 1);
    d->size = (uint64_t)own;
    DUP_ADD(bytes, (uint64_t)own);
    return false;
}

static uint64_t dup_walk_fd(int dfd, char *lvl, int depth, uint64_t parent_dev);

static uint64_t dup_subdir(int dfd, const char *name, char *lvl, int depth, uint64_t dev)
{
    intptr_t fd = os_openat(dfd, name, DUP_OPEN_DIR, 0);
    if (fd < 0) return 0;
    uint64_t size = dup_walk_fd((int)fd, lvl + DUP_STRIDE, depth + 1, dev);
    os_close((int)fd);
    return size;
}

/* allocated bytes of one non-directory entry (hard links count once per scan), or the subtree when it turns out to be a directory */
static uint64_t dup_stat_one(int dfd, const char *name, char *lvl, int depth, uint64_t parent_dev)
{
    FileStat st;
    int64_t usage = os_du_usage(dfd, name, &st);
    if (usage < 0) return 0;
    if ((st.mode & S_IFMT) == S_IFDIR) return dup_subdir(dfd, name, lvl, depth, parent_dev);
    if (st.nlink > 1 && !du_link_first(st.dev, st.ino)) return 0;      /* another name of an inode already counted */
    DUP_ADD(files, 1);
    DUP_ADD(bytes, (uint64_t)usage);
    return (uint64_t)usage;
}

/* allocated bytes of the subtree below dfd (directories included); 0 for a mount of a derived filesystem */
static uint64_t dup_walk_fd(int dfd, char *lvl, int depth, uint64_t parent_dev)
{
    if (depth >= DUP_MAX_DEPTH) return 0;
    DupDir d;
    if (dup_enter(dfd, parent_dev, &d)) return d.size;
    uint64_t total = d.size;
    intptr_t n;
    while ((n = os_dir_read(dfd, lvl, DUP_STRIDE)) > 0) {
        size_t pos = 0;
        for (;;) {
            if (dup_canceled()) return total;                        /* canceled: partial size, never cached */
            uint8_t type;
            const char *name = os_dir_next_ex(lvl, (size_t)n, &pos, &type);
            if (!name) break;
            if (name[0] == '.' && (!name[1] || (name[1] == '.' && !name[2]))) continue;
            if (type == PAL_DT_LNK) continue;
            total += type == PAL_DT_DIR ? dup_subdir(dfd, name, lvl, depth, d.st.dev) : dup_stat_one(dfd, name, lvl, depth, d.st.dev);
        }
    }
    if (d.cacheable) du_cache_put(d.st.ino, d.st.dev, d.sig, total);
    return total;
}

static void dup_worker_fn(void *arg)
{
    DupWorker *w = arg;
    DupCtx *cx = w->ctx;
    while (!dup_canceled()) {
        int32_t idx = __atomic_fetch_add(&cx->next_idx, 1, __ATOMIC_ACQ_REL);
        if (idx >= cx->count) break;
        DuWorkItem *it = &cx->items[idx];
        intptr_t fd = os_openat(cx->dfd, it->name, DUP_OPEN_DIR, 0);
        if (fd < 0) continue;
        it->size = dup_walk_fd((int)fd, w->arena, 0, cx->dev);
        DUP_ADD(done, 1);
        os_close((int)fd);
    }
}

/* runs the progress callback until every worker thread has exited (ctid cleared by the kernel); a non-zero return requests cancel */
static void dup_pump(DupWorker *w, int n)
{
    for (;;) {
        bool alive = false;
        for (int i = 0; i < n && !alive; i++) alive = __atomic_load_n(&w[i].ctid, __ATOMIC_ACQUIRE) != 0;
        if (!alive) return;
        if (g_dup_cb(g_dup_cb_ctx, &g_dup_prog)) __atomic_store_n(&g_dup_prog.cancel, 1, __ATOMIC_RELAXED);   /* waits up to ~100 ms for input */
    }
}

static void dup_prog_begin(int count)
{
    mem_zero(&g_dup_prog, offsetof(DuProgress, cancel));              /* dirs/files/bytes/done/total; cancel stays caller-owned */
    g_dup_prog.total = count;
    g_dup_prog.phase = DU_PHASE_RUN;
    g_dup_prog.start_ms = os_clock_ms();
}

static void dup_prog_end(void)                                       /* final callback (phase DONE) so the UI can close its window */
{
    if (!g_dup_cb) return;
    g_dup_prog.phase = DU_PHASE_DONE;
    g_dup_cb(g_dup_cb_ctx, &g_dup_prog);
}

/* fills items[i].size for the first `count` items (folders below dfd); without a callback the calling thread is worker 0 */
void du_parallel_walk(int dfd, DuWorkItem *items, int count)
{
    if (count <= 0) return;
    DupCtx cx = {.dfd = dfd, .count = count, .items = items};
    int workers = count < DUP_WORKERS ? count : DUP_WORKERS;
    dup_prog_begin(count);
    FileStat root;
    cx.dev = os_fstat(dfd, &root) < 0 ? ~0ull : root.dev;
    (void)du_cache_init();
    DupWorker *w = mem_alloc((size_t)workers * (sizeof(DupWorker) + DUP_ARENA_SZ + DUP_STACK_SZ));
    if (!w) return;
    char *cursor = (char *)(w + workers);
    for (int i = 0; i < workers; i++, cursor += DUP_ARENA_SZ + DUP_STACK_SZ)
        w[i] = (DupWorker){.ctx = &cx, .arena = cursor, .stack_top = cursor + DUP_ARENA_SZ + DUP_STACK_SZ};
    for (int i = g_dup_cb ? 0 : 1; i < workers; i++)                 /* with a callback every worker is a thread */
        if (os_thread_spawn(dup_worker_fn, &w[i], w[i].stack_top, &w[i].ctid) < 0) w[i].ctid = 0;
    if (g_dup_cb) dup_pump(w, workers);
    dup_worker_fn(&w[0]);                                            /* worker 0, and the items left by failed spawns */
    for (int i = 0; i < workers; i++) os_thread_join(&w[i].ctid);
    dup_prog_end();
    mem_free(w);
}
