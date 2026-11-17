/* Freestanding allocator stress harness (x86_64 and aarch64): prints "ok <n>" or "FAIL <what>". */
#include "duop_abi.h"

void *mem_alloc(size_t size);
void mem_free(void *p);
void *mem_realloc(void *p, size_t size);
int mem_slab_arena_count(void);
void mem_zero(void *dst, size_t n);

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 24); }
static long checks;
static void fail(const char *what)
{
    (void)os_write(1, "FAIL ", 5);
    size_t n = 0;
    while (what[n]) n++;
    (void)os_write(1, what, n);
    (void)os_write(1, "\n", 1);
    os_exit(1);
}
#define EXPECT(c, what) do { checks++; if (!(c)) fail(what); } while (0)

static bool all_zero(const uint8_t *p, size_t n) { for (size_t i = 0; i < n; i++) if (p[i]) return false; return true; }
static void fill(uint8_t *p, size_t n, uint8_t seed) { for (size_t i = 0; i < n; i++) p[i] = (uint8_t)(seed + i * 7); }
static bool check(const uint8_t *p, size_t n, uint8_t seed) { for (size_t i = 0; i < n; i++) if (p[i] != (uint8_t)(seed + i * 7)) return false; return true; }

typedef struct { uint8_t *p; size_t n; uint8_t seed; } Slot;
static Slot slots[512];

static void random_churn(void)
{
    for (long it = 0; it < 200000; it++) {
        Slot *s = &slots[rnd() % 512];
        uint32_t op = rnd() % 4;
        if (s->p && (op == 0 || op == 1)) {                           /* free, contents must have survived */
            EXPECT(check(s->p, s->n, s->seed), "content corrupted before free");
            mem_free(s->p);
            s->p = nullptr;
        } else if (s->p && op == 2) {                                /* realloc grow/shrink keeps the common prefix */
            size_t nn = rnd() % 8 ? rnd() % 3000 : rnd() % 200000;
            uint8_t *q = mem_realloc(s->p, nn ? nn : 1);
            EXPECT(q != nullptr, "realloc failed");
            size_t keep = s->n < nn ? s->n : nn;
            EXPECT(check(q, keep, s->seed), "realloc lost data");
            EXPECT(((uintptr_t)q & 15) == 0, "realloc misaligned");
            s->p = q; s->n = nn ? nn : 1; fill(s->p, s->n, s->seed = (uint8_t)rnd());
        } else if (!s->p) {
            size_t n = rnd() % 16 == 0 ? rnd() % 300000 : rnd() % 2000;
            uint8_t *q = mem_alloc(n);
            size_t eff = n ? n : 1;
            EXPECT(q != nullptr, "alloc failed");
            EXPECT(((uintptr_t)q & 15) == 0, "alloc misaligned");
            EXPECT(all_zero(q, eff), "alloc not zero-filled");
            s->p = q; s->n = eff; fill(q, eff, s->seed = (uint8_t)rnd());
        }
    }
    for (int i = 0; i < 512; i++) if (slots[i].p) { EXPECT(check(slots[i].p, slots[i].n, slots[i].seed), "content corrupted at end"); mem_free(slots[i].p); slots[i].p = nullptr; }
}

static void edge_cases(void)
{
    uint8_t *z = mem_alloc(0);
    EXPECT(z != nullptr && ((uintptr_t)z & 15) == 0, "alloc(0) must return a usable block");
    mem_free(z);
    mem_free(nullptr);
    EXPECT(mem_alloc((size_t)-1) == nullptr, "absurd alloc must fail with NULL");
    uint8_t *r = mem_realloc(nullptr, 100);
    EXPECT(r != nullptr && all_zero(r, 100), "realloc(NULL) acts as alloc");
    fill(r, 100, 3);
    EXPECT(mem_realloc(r, (size_t)-1) == nullptr && check(r, 100, 3), "failed realloc leaves the old block intact");
    mem_free(r);
    uint8_t *g = mem_alloc(65520);                                   /* biggest slab request */
    uint8_t *h = mem_alloc(65521);                                   /* smallest mmap request */
    EXPECT(g && h && all_zero(g, 65520) && all_zero(h, 65521), "slab/mmap boundary");
    fill(g, 65520, 9); fill(h, 65521, 5);
    h = mem_realloc(h, 5u << 20);                                    /* mremap growth keeps contents */
    EXPECT(h && check(h, 65521, 5) && all_zero(h + 65521, 4096), "mremap growth");
    mem_free(g); mem_free(h);
    uint8_t *keep = mem_alloc(200);                                  /* keeps its arena alive so the free list is used */
    uint8_t *a = mem_alloc(200);                                     /* recycled blocks are zeroed again */
    fill(a, 200, 77);
    mem_free(a);
    uint8_t *b = mem_alloc(200);
    EXPECT(b == a && all_zero(b, 200), "recycled slab block must be the freed one and zero-filled");
    mem_free(b);
    mem_free(keep);
}

static void arena_reclaim(void)
{
    enum { N = 700 };
    static uint8_t *blk[N];
    int before = mem_slab_arena_count();
    for (int i = 0; i < N; i++) { blk[i] = mem_alloc(4000); EXPECT(blk[i] != nullptr, "arena alloc"); }
    int grown = mem_slab_arena_count();
    EXPECT(grown > before, "arenas must grow under load");
    for (int i = 0; i < N; i++) mem_free(blk[i]);
    EXPECT(mem_slab_arena_count() < grown, "empty arenas must be returned to the kernel");
    for (int i = 0; i < N; i++) { blk[i] = mem_alloc(4000); EXPECT(blk[i] && all_zero(blk[i], 4000), "reuse after reclaim"); }
    for (int i = 0; i < N; i++) mem_free(blk[i]);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)envp; (void)auxv;
    edge_cases();
    arena_reclaim();
    random_churn();
    char out[32] = "ok ";
    size_t n = 3;
    char t[12]; int k = 0; long c = checks;
    do { t[k++] = (char)('0' + c % 10); c /= 10; } while (c);
    while (k) out[n++] = t[--k];
    out[n++] = '\n';
    (void)os_write(1, out, n);
    return 0;
}
