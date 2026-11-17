/* src/core/memcheck.c - MEMCHECK=1 heap leak and bad-free tracker (freestanding C23; replaces memcheck.s).
 *
 * Only the leak-check build (make MEMCHECK=1, -DMEMCHECK=1) contains code; every other build compiles this file to an
 * empty object. mem_alloc/mem_free/mem_realloc (memory.c) report each block with its caller; the table is an open-addressing
 * hash of 65536 slots in an anonymous mapping (tombstone = freed). mc_report prints one MC_SUMMARY line and one MC_LEAK line
 * per live block to stderr, or to $DUOP_MEMCHECK_LOG (scripts/memcheck.py parses the lines). Bad frees (unknown or already freed
 * pointer) are logged when they happen. No heap use, no libc. */
#ifdef MEMCHECK
#include "duop_abi.h"
#include "duop_pal.h"
#include "duop_string.h"

#define MC_CAP 65536u
#define MC_MASK (MC_CAP - 1)
#define MC_TOMB ((uintptr_t)-1)
#define MC_LINE 256
#define MC_STDERR 2

typedef struct McEntry { uintptr_t ptr; uint64_t size, caller, seq; } McEntry;        /* ptr 0 = never used */
_Static_assert(sizeof(McEntry) == 32, "table slot size");

static McEntry *g_mc_table;
static uint64_t g_mc_allocs, g_mc_frees, g_mc_live, g_mc_live_bytes, g_mc_peak, g_mc_bad, g_mc_seq;
static int g_mc_fd;

static uint32_t mc_hash(uint64_t ptr) { return (uint32_t)(((ptr >> 4) * 0x9E3779B97F4A7C15ull) ^ ptr) & MC_MASK; }

/* ---- line formatting ---- */
static char *mc_str(char *p, const char *s)
{
    while (*s) *p++ = *s++;
    return p;
}
static char *mc_hex(char *p, uint64_t v)
{
    static const char digits[] = "0123456789abcdef";
    *p++ = '0';
    *p++ = 'x';
    for (int shift = 60; shift >= 0; shift -= 4) *p++ = digits[(v >> shift) & 15];
    return p;
}
static char *mc_dec(char *p, uint64_t v) { return p + u64_to_dec(v, p); }
static void mc_flush(const char *line, char *end)
{
    *end++ = '\n';
    (void)os_write(g_mc_fd, line, (size_t)(end - line));
}

/* ---- table ---- */
void mc_init(char **envp)
{
    g_mc_fd = MC_STDERR;
    for (; envp && *envp; envp++) {
        if (!str_starts_with(*envp, "DUOP_MEMCHECK_LOG=")) continue;
        intptr_t fd = os_openat(AT_FDCWD, *envp + 18, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        if (fd >= 0) g_mc_fd = (int)fd;
        break;
    }
    intptr_t map = os_mmap(nullptr, MC_CAP * sizeof(McEntry), PROT_RW, MAP_PRIVATE_ANON, -1, 0);
    if (!os_is_err(map)) g_mc_table = (McEntry *)map;
}

void mc_on_alloc(void *ptr, size_t size, void *caller)
{
    if (!ptr || !g_mc_table) return;
    uint32_t i = mc_hash((uintptr_t)ptr);
    for (uint32_t probes = 0; probes < MC_CAP; probes++, i = (i + 1) & MC_MASK) {
        McEntry *e = &g_mc_table[i];
        if (e->ptr && e->ptr != MC_TOMB) continue;
        *e = (McEntry){ (uintptr_t)ptr, size, (uintptr_t)caller, ++g_mc_seq };
        g_mc_allocs++;
        g_mc_live++;
        g_mc_live_bytes += size;
        if (g_mc_live_bytes > g_mc_peak) g_mc_peak = g_mc_live_bytes;
        return;
    }                                                          /* table full: the block goes untracked */
}

static void mc_log_badfree(uintptr_t ptr, uintptr_t caller)
{
    char line[MC_LINE];
    char *p = mc_hex(mc_str(line, "MC_BADFREE ptr="), ptr);
    mc_flush(line, mc_hex(mc_str(p, " caller="), caller));
}

void mc_on_free(void *ptr, void *caller)
{
    if (!ptr || !g_mc_table) return;
    uint32_t i = mc_hash((uintptr_t)ptr);
    for (uint32_t probes = 0; probes < MC_CAP; probes++, i = (i + 1) & MC_MASK) {
        McEntry *e = &g_mc_table[i];
        if (!e->ptr) break;                                    /* never used: not tracked */
        if (e->ptr != (uintptr_t)ptr) continue;
        e->ptr = MC_TOMB;
        g_mc_live_bytes -= e->size;
        g_mc_live--;
        g_mc_frees++;
        return;
    }
    g_mc_bad++;
    mc_log_badfree((uintptr_t)ptr, (uintptr_t)caller);
}

void mc_on_realloc(void *old_ptr, void *new_ptr, size_t size, void *caller)
{
    if (old_ptr) mc_on_free(old_ptr, caller);
    if (new_ptr) mc_on_alloc(new_ptr, size, caller);
}

/* ---- report ---- */
static void mc_summary(void)
{
    char line[MC_LINE];
    char *p = mc_dec(mc_str(line, "MC_SUMMARY allocs="), g_mc_allocs);
    p = mc_dec(mc_str(p, " frees="), g_mc_frees);
    p = mc_dec(mc_str(p, " live="), g_mc_live);
    p = mc_dec(mc_str(p, " live_bytes="), g_mc_live_bytes);
    p = mc_dec(mc_str(p, " peak_bytes="), g_mc_peak);
    mc_flush(line, mc_dec(mc_str(p, " bad_frees="), g_mc_bad));
}

static void mc_leak(const McEntry *e)
{
    char line[MC_LINE];
    char *p = mc_hex(mc_str(line, "MC_LEAK ptr="), e->ptr);
    p = mc_dec(mc_str(p, " size="), e->size);
    p = mc_hex(mc_str(p, " caller="), e->caller);
    mc_flush(line, mc_dec(mc_str(p, " seq="), e->seq));
}

void mc_report(void)
{
    mc_summary();
    if (g_mc_table)
        for (uint32_t i = 0; i < MC_CAP; i++)
            if (g_mc_table[i].ptr && g_mc_table[i].ptr != MC_TOMB) mc_leak(&g_mc_table[i]);
    if (g_mc_fd > MC_STDERR) (void)os_close(g_mc_fd);
}
#endif /* MEMCHECK */
