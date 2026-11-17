/* src/core/memory.c - core memory allocator and bulk memory routines (freestanding C23; replaces memory.s).
 *
 * Hybrid allocator, single-threaded by design (background work runs in a forked process with its own
 * copy-on-write allocator state):
 *   - small objects (size + 16 <= 64 KiB): power-of-two slab classes 64 B .. 64 KiB carved from 256 KiB anonymous
 *     arenas and recycled through per-class free lists -> O(1) and no syscall after warm-up;
 *   - large objects: a dedicated anonymous mmap, grown with mremap and released with munmap.
 * Every block has a 16-byte header. header[0] is either the mapped byte size of a large block (a multiple of 4096)
 * or the slab tag ((arena_index + 1) << 12 | class + 1, never page aligned); header[1] links free blocks.
 * Returned memory is always zero-filled and 16-byte aligned. Arenas whose blocks are all free are returned to
 * the kernel (except the last one).
 */
#include "duop_abi.h"
#include "duop_pal.h"

#define SLAB_MIN_SHIFT 6                                   /* 64 B blocks */
#define SLAB_MAX_SHIFT 16                                  /* 64 KiB blocks */
#define SLAB_CLASSES (SLAB_MAX_SHIFT - SLAB_MIN_SHIFT + 1)
#define SLAB_ARENA 262144u                                 /* refill granularity */
#define SLAB_MAX_REQ ((1u << SLAB_MAX_SHIFT) - 16)
#define MAX_SLAB_ARENAS 256
#define PAGE 4096u

typedef struct BlockHdr { uint64_t tag; union { uintptr_t next; uint64_t slot; }; } BlockHdr;
_Static_assert(sizeof(BlockHdr) == 16, "block header keeps 16-byte payload alignment");

static uintptr_t slab_free[SLAB_CLASSES];                  /* free-list heads (block header addresses) */
static uintptr_t slab_bump[SLAB_CLASSES];                  /* next uncarved block in the current arena */
static uintptr_t slab_end[SLAB_CLASSES];                   /* end of the current arena */
static uintptr_t slab_arena_base[MAX_SLAB_ARENAS];
static uint32_t slab_arena_live[MAX_SLAB_ARENAS];          /* blocks handed out per arena */
static uint32_t slab_cur_arena[SLAB_CLASSES];              /* arena index + 1 of the arena being carved, 0 = untracked */
static uint32_t slab_arena_cnt;

static inline BlockHdr *hdr(uintptr_t a) { return (BlockHdr *)a; }
static inline uintptr_t block_size(unsigned cls) { return (uintptr_t)1 << (cls + SLAB_MIN_SHIFT); }

/* mmap a new arena for class cls and make it the carving target; false when the kernel refuses. */
static bool arena_refill(unsigned cls)
{
    intptr_t m = os_mmap(nullptr, SLAB_ARENA, PROT_RW, MAP_PRIVATE_ANON, -1, 0);
    if (os_is_err(m)) return false;
    slab_bump[cls] = (uintptr_t)m;
    slab_end[cls] = (uintptr_t)m + SLAB_ARENA;
    for (unsigned i = 0; i < MAX_SLAB_ARENAS; i++) {
        if (slab_arena_base[i]) continue;
        slab_arena_base[i] = (uintptr_t)m;
        slab_arena_live[i] = 0;
        slab_cur_arena[cls] = i + 1;
        slab_arena_cnt++;
        return true;
    }
    slab_cur_arena[cls] = 0;                               /* registry full: blocks are served but never reclaimed */
    return true;
}

static void *alloc_big(size_t size)
{
    if (size > (size_t)-4112) return nullptr;
    size_t total = (size + 16 + PAGE - 1) & ~(size_t)(PAGE - 1);
    intptr_t m = os_mmap(nullptr, total, PROT_RW, MAP_PRIVATE_ANON, -1, 0);
    if (os_is_err(m)) return nullptr;
    hdr((uintptr_t)m)->tag = total;
    return (void *)((uintptr_t)m + 16);
}

static void *alloc_raw(size_t size)
{
    if (!size) size = 1;
    if (size > SLAB_MAX_REQ) return alloc_big(size);
    unsigned k = (unsigned)(sizeof(unsigned long long) * 8 - (unsigned)__builtin_clzll(size + 15));  /* bsr + 1 */
    if (k < SLAB_MIN_SHIFT) k = SLAB_MIN_SHIFT;
    unsigned cls = k - SLAB_MIN_SHIFT;
    uintptr_t blk = block_size(cls);

    uintptr_t b = slab_free[cls];
    if (b) {                                               /* recycled block: clear the link and the payload */
        BlockHdr *h = hdr(b);
        slab_free[cls] = h->next;
        if (h->tag >> 12) slab_arena_live[(h->tag >> 12) - 1]++;
        os_mem_set_fast((uint8_t *)h + 8, 0, blk - 8);
        return (uint8_t *)h + 16;
    }
    for (;;) {
        uintptr_t cur = slab_bump[cls];
        if (cur && cur + blk <= slab_end[cls]) {
            slab_bump[cls] = cur + blk;
            uint32_t a = slab_cur_arena[cls];
            if (a) slab_arena_live[a - 1]++;
            hdr(cur)->tag = ((uint64_t)a << 12) | (cls + 1);   /* fresh arena memory is already zero */
            return (uint8_t *)cur + 16;
        }
        if (!arena_refill(cls)) return nullptr;
    }
}

/* Drop arena `arena` (all of class cls, nothing live): unlink its blocks from the free list and unmap it. */
static void reclaim_arena(unsigned arena, unsigned cls)
{
    uintptr_t base = slab_arena_base[arena];
    if (!base) return;
    uintptr_t end = base + SLAB_ARENA;
    uintptr_t cur;
    uintptr_t *slot = &slab_free[cls];                     /* walks the list through the link words */
    while ((cur = *slot) != 0) {
        if (cur >= base && cur < end) *slot = hdr(cur)->next;
        else slot = &hdr(cur)->next;
    }
    if (slab_cur_arena[cls] == arena + 1) {
        slab_cur_arena[cls] = 0;
        slab_bump[cls] = 0;
        slab_end[cls] = 0;
    }
    slab_arena_base[arena] = 0;
    slab_arena_cnt--;
    (void)os_munmap_raw((void *)base, SLAB_ARENA);
}

static void free_raw(void *ptr)
{
    if (!ptr) return;
    BlockHdr *h = (BlockHdr *)((uint8_t *)ptr - 16);
    uint64_t tag = h->tag;
    if (!(tag & (PAGE - 1))) {                             /* large block */
        (void)os_munmap_raw(h, (size_t)tag);
        return;
    }
    unsigned cls = (unsigned)(tag & 0xF) - 1;
    h->next = slab_free[cls];
    slab_free[cls] = (uintptr_t)h;
    uint32_t a = (uint32_t)(tag >> 12);
    if (a && --slab_arena_live[a - 1] == 0 && slab_arena_cnt > 1) reclaim_arena(a - 1, cls);
}

static void *realloc_raw(void *ptr, size_t size)
{
    if (!ptr) return alloc_raw(size);
    if (size > (size_t)-16 - PAGE) return nullptr;
    BlockHdr *h = (BlockHdr *)((uint8_t *)ptr - 16);
    uint64_t tag = h->tag;
    if (!(tag & (PAGE - 1))) {                             /* large: grow in place or via mremap, never shrink */
        size_t mapped = (size + 16 + PAGE - 1) & ~(size_t)(PAGE - 1);
        if (mapped <= tag) return ptr;
        void *m = os_mem_remap(h, (size_t)tag, mapped);
        if (!m || os_is_err((intptr_t)m)) return nullptr;
        hdr((uintptr_t)m)->tag = mapped;
        return (uint8_t *)m + 16;
    }
    uintptr_t blk = block_size((unsigned)(tag & 0xF) - 1);
    if (size + 16 <= blk) return ptr;
    void *n = alloc_raw(size);
    if (!n) return nullptr;
    os_mem_copy_fast(n, ptr, blk - 16);
    free_raw(ptr);
    return n;
}

#ifdef MEMCHECK
/* Leak/bad-free tracking build: report every call with its caller to the asm memcheck module. */
__attribute__((noinline)) void *mem_alloc(size_t size)
{
    void *p = alloc_raw(size);
    if (p) mc_on_alloc(p, size, __builtin_return_address(0));
    return p;
}

__attribute__((noinline)) void mem_free(void *ptr)
{
    if (!ptr) return;
    mc_on_free(ptr, __builtin_return_address(0));
    free_raw(ptr);
}

__attribute__((noinline)) void *mem_realloc(void *ptr, size_t size)
{
    void *n = realloc_raw(ptr, size);
    if (n) mc_on_realloc(ptr, n, size, __builtin_return_address(0));
    return n;
}
#else
void *mem_alloc(size_t size) { return alloc_raw(size); }
void mem_free(void *ptr) { free_raw(ptr); }
void *mem_realloc(void *ptr, size_t size) { return realloc_raw(ptr, size); }
#endif

int mem_slab_arena_count(void) { return (int)slab_arena_cnt; }

void mem_copy(void *dst, const void *src, size_t n) { os_mem_copy_fast(dst, src, n); }
void mem_move(void *dst, const void *src, size_t n) { os_mem_move_fast(dst, src, n); }
void mem_set(void *dst, int byte, size_t n) { os_mem_set_fast(dst, byte, n); }
void mem_zero(void *dst, size_t n) { os_mem_set_fast(dst, 0, n); }
int mem_cmp(const void *a, const void *b, size_t n) { return os_mem_cmp_fast(a, b, n); }
