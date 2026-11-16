// Guard-page replacement for duop's mem_alloc/mem_free/mem_realloc (fuzz harness only).
#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/mman.h>

#define TBL (1u << 18)
struct ent { uintptr_t ptr; void *base; size_t total; size_t size; };
static struct ent tbl[TBL];
long g_live_allocs, g_total_allocs;

static unsigned hash(uintptr_t p) { return (unsigned)((p >> 4) * 2654435761u) & (TBL - 1); }

static void *gal(size_t size, int exact) __attribute__((force_align_arg_pointer));
static void *gal(size_t size, int exact) {
    if (size == 0) size = 1;
    if (size > ((size_t)1 << 40)) return NULL;
    size_t asz = exact ? size : ((size + 15) & ~(size_t)15);
    size_t data = (asz + 4095) & ~(size_t)4095;
    size_t total = data + 2 * 4096;                 // [front guard][data][rear guard]
    unsigned char *base = mmap(NULL, total, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (base == MAP_FAILED) return NULL;
    if (mprotect(base + 4096, data, PROT_READ | PROT_WRITE)) { munmap(base, total); return NULL; }
    unsigned char *end = base + 4096 + data;
    unsigned char *p = end - asz;
    unsigned h = hash((uintptr_t)p);
    for (unsigned i = 0; i < TBL; i++) {
        struct ent *e = &tbl[(h + i) & (TBL - 1)];
        if (!e->ptr) { e->ptr = (uintptr_t)p; e->base = base; e->total = total; e->size = size; g_live_allocs++; g_total_allocs++; return p; }
    }
    munmap(base, total);
    return NULL;
}

static struct ent *find(uintptr_t p) {
    unsigned h = hash(p);
    for (unsigned i = 0; i < TBL; i++) {
        struct ent *e = &tbl[(h + i) & (TBL - 1)];
        if (e->ptr == p) return e;
        if (!e->ptr && !e->base) return NULL;
    }
    return NULL;
}

__attribute__((force_align_arg_pointer)) void *mem_alloc(size_t n) { return gal(n, 0); }
__attribute__((force_align_arg_pointer)) void *guard_exact(size_t n) { return gal(n, 1); }

__attribute__((force_align_arg_pointer)) void mem_free(void *p) {
    if (!p) return;
    struct ent *e = find((uintptr_t)p);
    if (!e) { __builtin_trap(); }                    // bad / double free
    munmap(e->base, e->total);                       // later access faults (use-after-free)
    e->ptr = 0; e->base = (void *)1;                 // tombstone
    g_live_allocs--;
}

__attribute__((force_align_arg_pointer)) void *mem_realloc(void *p, size_t n) {
    if (!p) return gal(n, 0);
    if (n > (size_t)-16 - 4096) return NULL;
    struct ent *e = find((uintptr_t)p);
    if (!e) __builtin_trap();
    void *q = gal(n, 0);
    if (!q) return NULL;
    memcpy(q, p, e->size < n ? e->size : n);
    mem_free(p);
    return q;
}
