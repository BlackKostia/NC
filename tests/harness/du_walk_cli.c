/* Freestanding harness: frozen asm Disk Usage walker (ref_ prefix) next to src/fs/du_parallel.c.
 *   <ref|c> <rootdir> <cb 0|1|2> <runs> <names...>   fresh cache and link set, then `runs` walks of the named folders below rootdir;
 *                                                     cb 1: progress callback that never cancels, cb 2: cancels on its first call,
 *                                                     cb 3: cancels on its first call, in the first run only.
 * Prints per run: item sizes, the DuProgress counters, how often the callback ran and how many calls carried phase DONE. */
#include "duop_du.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

extern void ref_du_parallel_walk(int, DuWorkItem *, int);
extern void ref_du_set_progress(int (*)(void *, DuProgress *), void *);
extern DuProgress *ref_du_progress(void);

int64_t du_mtime_sig(const FileStat *st) { return st->mtime ^ (int64_t)((uint64_t)st->mtime_nsec << 32); }   /* as in disk_usage */

static char g_out[1 << 16];
static size_t g_n;
static void flush(void) { (void)os_write(1, g_out, g_n); g_n = 0; }
static void put(const char *s) { while (*s) { if (g_n >= sizeof g_out - 8) flush(); g_out[g_n++] = *s++; } }
static void num(uint64_t v)
{
    char t[24];
    t[u64_to_dec(v, t)] = 0;
    put(t);
}

static int g_cb_mode, g_run;
static uint32_t g_calls, g_done_calls;

static int progress_cb(void *ctx, DuProgress *p)
{
    (void)ctx;
    __atomic_fetch_add(&g_calls, 1, __ATOMIC_RELAXED);
    if (p->phase == DU_PHASE_DONE) __atomic_fetch_add(&g_done_calls, 1, __ATOMIC_RELAXED);
    return p->phase != DU_PHASE_DONE && (g_cb_mode == 2 || (g_cb_mode == 3 && g_run == 0));   /* 3: cancel the first run only */
}

static void run(bool ref, int dfd, int cb, int runs, int n, char **names)
{
    static FileEntry fes[256];
    static DuWorkItem items[256];
    du_cache_cleanup();
    du_links_reset();
    g_cb_mode = cb;
    DuProgress *pr = ref ? ref_du_progress() : du_progress();
    pr->cancel = 0;
    (ref ? ref_du_set_progress : du_set_progress)(cb ? progress_cb : nullptr, nullptr);
    for (int r = 0; r < runs; r++) {
        for (int i = 0; i < n; i++) items[i] = (DuWorkItem){&fes[i], names[i], 0xDEAD};
        g_run = r;
        g_calls = g_done_calls = 0;
        (ref ? ref_du_parallel_walk : du_parallel_walk)(dfd, items, n);
        put(ref ? "REF run " : "C run "); num((uint64_t)r); put(": sizes");
        uint64_t sum = 0;
        for (int i = 0; i < n; i++) { put(" "); num(items[i].size); sum += items[i].size; }
        put(" sum="); num(sum);
        put(" dirs="); num(pr->dirs); put(" files="); num(pr->files); put(" bytes="); num(pr->bytes);
        put(" done="); num((uint64_t)pr->done); put(" total="); num((uint64_t)pr->total); put(" cancel="); num((uint64_t)pr->cancel);
        put(" phase="); num((uint64_t)pr->phase); put(" cb="); num(g_calls > 0); put(" donecalls="); num(g_done_calls); put(" ticks="); num(g_calls > g_done_calls); put("\n");
        pr->cancel = 0;
    }
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 6) return 2;
    int dfd = (int)os_openat(AT_FDCWD, argv[2], O_RDONLY | O_DIRECTORY, 0);
    if (dfd < 0) return 3;
    int cb = argv[3][0] - '0', runs = argv[4][0] - '0';
    run(!str_cmp(argv[1], "ref"), dfd, cb, runs, argc - 5, argv + 5);
    flush();
    return 0;
}
