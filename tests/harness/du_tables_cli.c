/* Freestanding harness: frozen asm hard-link set and subtree cache (ref_ prefix) next to src/fs/du_links.c, du_cache.c.
 *   ops        stdin lines: "L dev ino" "G ino dev sig" "P ino dev sig size" "R" "I" "C" "X" -> "ref c" per line
 *   threads    four threads hammer the C link set and cache with overlapping keys; prints the first-sighting totals */
#include "duop_du.h"
#include "duop_oop.h"
#include "duop_string.h"
#include "duop_sys.h"

#ifndef NO_REF                               /* the aarch64 build has no frozen asm to compare with */
extern void ref_du_links_reset(void);
extern int ref_du_link_first(uint64_t, uint64_t);
extern void ref_du_links_cleanup(void);
extern void *ref_du_cache_init(void);
extern int ref_du_cache_get(uint64_t, uint64_t, int64_t, uint64_t *);
extern void ref_du_cache_put(uint64_t, uint64_t, int64_t, uint64_t);
extern void ref_du_cache_cleanup(void);
#endif
int os_thread_spawn(void (*fn)(void *), void *arg, void *stack_top, int *ctid_out);
void os_thread_join(int *ctid);

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

static uint64_t num_arg(const char *s) { uint64_t v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (uint64_t)(*s++ - '0'); return v; }

#ifndef NO_REF
static uint64_t arg(char **p)
{
    while (**p == ' ') (*p)++;
    bool neg = **p == '-';
    if (neg) (*p)++;
    uint64_t v = 0;
    while (**p >= '0' && **p <= '9') v = v * 10 + (uint64_t)(*(*p)++ - '0');
    return neg ? -v : v;
}

static void ops(void)
{
    static char in[1 << 23];
    size_t n = 0;
    intptr_t r;
    while (n < sizeof in - 1 && (r = os_read(0, in + n, sizeof in - 1 - n)) > 0) n += (size_t)r;
    in[n] = 0;
    for (char *p = in; *p;) {
        char op = *p++;
        uint64_t a = arg(&p), b = arg(&p), c = arg(&p), d = arg(&p);
        while (*p && *p != '\n') p++;
        if (*p) p++;
        switch (op) {
        case 'L': num((uint64_t)ref_du_link_first(a, b)); put(" "); num((uint64_t)du_link_first(a, b)); break;
        case 'R': ref_du_links_reset(); du_links_reset(); put("- -"); break;
        case 'C': ref_du_links_cleanup(); du_links_cleanup(); put("- -"); break;
        case 'I': num(ref_du_cache_init() != nullptr); put(" "); num(du_cache_init() != nullptr); break;
        case 'X': ref_du_cache_cleanup(); du_cache_cleanup(); put("- -"); break;
        case 'P': ref_du_cache_put(a, b, (int64_t)c, d); du_cache_put(a, b, (int64_t)c, d); put("- -"); break;
        case 'G': {
            uint64_t sa = 0x1111, sb = 0x1111;
            int ra = ref_du_cache_get(a, b, (int64_t)c, &sa), rb = du_cache_get(a, b, (int64_t)c, &sb);
            num((uint64_t)ra); put(" "); num((uint64_t)rb); put(" "); num(sa); put(" "); num(sb);
            break;
        }
        }
        put("\n");
    }
}

#endif

#define THREADS 4
static uint64_t g_keys = 6000, g_forged, g_iters = 150000, g_round;
static uint64_t g_first[THREADS], g_hit[THREADS];
static int g_tid[THREADS];
static char g_stack[THREADS][65536] __attribute__((aligned(16)));
static int g_id[THREADS];

static uint64_t seed_of(int id, uint64_t round) { return 0x9E3779B97F4A7C15ull * (uint64_t)(id + 1) ^ (round * 0xD6E8FEB86659FD93ull + 1); }

static uint64_t next_key(uint64_t *x)
{
    *x ^= *x << 13; *x ^= *x >> 7; *x ^= *x << 17;
    return 1 + *x % g_keys;
}

/* forged: every key hashes to the same slot (h = ino * 0x9E3779B97F4A7C15 ^ dev is constant), so the probe runs are long and contended */
static uint64_t key_dev(uint64_t key) { return g_forged ? key * 0x9E3779B97F4A7C15ull ^ 0x123456789ABCDEFull : key & 3; }

static void worker(void *p)
{
    int id = *(int *)p;
    uint64_t x = seed_of(id, g_round);
    for (uint64_t i = 0; i < g_iters; i++) {
        uint64_t key = next_key(&x);
        uint64_t dev = key_dev(key);
        g_first[id] += (uint64_t)du_link_first(dev, key);
        du_cache_put(key, dev, (int64_t)key, key * 7);
        uint64_t sz = 0;
        if (du_cache_get(key, dev, (int64_t)key, &sz) && sz != key * 7) g_hit[id] = (uint64_t)-1;   /* torn read: wrong size for the key */
    }
}

/* rounds x (reset, four threads, join): the link set must report every distinct key exactly once per round */
static void threads(uint64_t keys, uint64_t forged, uint64_t rounds, uint64_t iters)
{
    g_keys = keys;
    g_forged = forged;
    g_iters = iters;
    (void)du_cache_init();
    int inline_runs = 0;
    uint64_t bad_rounds = 0, torn = 0;
    static uint8_t seen[8192];
    for (uint64_t r = 0; r < rounds; r++) {
        g_round = r;
        du_links_reset();
        for (int i = 0; i < THREADS; i++) g_first[i] = 0;
        for (int i = 0; i < THREADS; i++) {
            g_id[i] = i;
            if (os_thread_spawn(worker, &g_id[i], g_stack[i] + sizeof g_stack[i], &g_tid[i]) < 0) { worker(&g_id[i]); inline_runs++; }   /* qemu-user refuses clone() without CLONE_SYSVSEM */
        }
        for (int i = 0; i < THREADS; i++) os_thread_join(&g_tid[i]);
        uint64_t first = 0, distinct = 0;
        for (size_t i = 0; i < sizeof seen; i++) seen[i] = 0;
        for (int id = 0; id < THREADS; id++) {
            first += g_first[id];
            torn += g_hit[id] == (uint64_t)-1;
            g_hit[id] = 0;
            uint64_t x = seed_of(id, r);
            for (uint64_t i = 0; i < iters; i++) { uint64_t k = next_key(&x); distinct += !seen[k]; seen[k] = 1; }
        }
        bad_rounds += first != distinct;
    }
    put("inline="); num((uint64_t)inline_runs); put(" bad_rounds="); num(bad_rounds); put(" torn="); num(torn); put("\n");
    du_links_cleanup();
    du_cache_cleanup();
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
#ifndef NO_REF
    if (!str_cmp(argv[1], "ops")) ops();
    else
#endif
    if (!str_cmp(argv[1], "threads") && argc >= 6) threads(num_arg(argv[2]), num_arg(argv[3]), num_arg(argv[4]), num_arg(argv[5]));
    flush();
    return 0;
}
