/* Спайк-драйвер: однаковий для asm- та C-реалізацій (лінкується з одним із них). Друкує контрольну суму й час. */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <zlib.h>

typedef struct { uint64_t cp, len; } Utf8Dec;
typedef struct { int64_t size, mtime; uint32_t mode, flags, name_off; uint16_t name_len; uint8_t disp_width, ext_offset; } FileEntry;
extern Utf8Dec utf8_decode(const uint8_t *);
extern int64_t utf8_encode(uint32_t, uint8_t *);
extern int32_t utf8_char_width(uint32_t);
extern int32_t utf8_display_width(const uint8_t *);
extern void radix_sort_u32(uint32_t *, uint64_t, const FileEntry *, const char *, uint32_t, uint32_t);
extern int64_t inflate_raw(const void *, uint64_t, void *, uint64_t);
extern int64_t inflate_zlib(const void *, uint64_t, void *, uint64_t);

void *mem_alloc(uint64_t n) { return calloc(1, n); }
void mem_free(void *p) { free(p); }
/* Заглушка: тай-брейк за значенням індексу (детермінований, однаковий для обох реалізацій). */
void introsort_u32(uint32_t *a, uint64_t n, const FileEntry *e, const char *p, uint32_t m, uint32_t d)
{
    (void)e; (void)p; (void)m; (void)d;
    for (uint64_t i = 1; i < n; i++) { uint32_t v = a[i]; uint64_t j = i; while (j && a[j-1] > v) { a[j] = a[j-1]; j--; } a[j] = v; }
}
uint64_t extract_radix_key(uint32_t idx, const FileEntry *e, uint32_t mode, uint32_t desc)
{
    int64_t v = mode == 2 ? e[idx].mtime : e[idx].size;
    uint64_t k = (uint64_t)v ^ 0x8000000000000000ull;
    return desc ? ~k : k;
}

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec * 1e-9; }
static uint64_t rs = 88172645463325252ull;
static uint64_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static uint64_t fnv(uint64_t h, const void *p, size_t n) { const uint8_t *b = p; while (n--) { h ^= *b++; h *= 1099511628211ull; } return h; }

int main(void)
{
    uint64_t h = 1469598103934665603ull;
    /* UTF-8: 4M случайних байтових послідовностей + усі кодпоінти */
    uint8_t buf[8]; double t0 = now(); uint64_t acc = 0;
    for (int i = 0; i < 4000000; i++) {
        uint64_t r = rnd(); memcpy(buf, &r, 8); buf[7] = (i % 7) ? buf[7] | 1 : 0;
        if (i & 1) { buf[0] = 0xC0 | (buf[0] & 0x1F); buf[1] = 0x80 | (buf[1] & 0x3F); }
        Utf8Dec d = utf8_decode(buf); acc += d.cp * 31 + d.len;
    }
    for (uint32_t cp = 0; cp <= 0x110000; cp++) { uint8_t o[8] = {0}; int64_t n = utf8_encode(cp, o); acc = acc * 131 + n + utf8_char_width(cp); h = fnv(h, o, 4); }
    uint8_t s[] = "Привіт, 世界! héllo ﬁle 😀 \xE0\x80\x80 \xF4\x90\x80\x80 end";
    for (int i = 0; i < 200000; i++) acc += utf8_display_width(s);
    h = fnv(h, &acc, 8); double t_utf8 = now() - t0;
    /* Radix: 1M записів, size/mtime, asc/desc */
    uint64_t N = 1000000; FileEntry *e = calloc(N, sizeof *e); uint32_t *a = malloc(N * 4);
    for (uint64_t i = 0; i < N; i++) { e[i].size = (int64_t)(rnd() % 100000) - 500; e[i].mtime = (int64_t)(rnd() % 1000000000); }
    t0 = now();
    for (int mode = 1; mode <= 2; mode++) for (int desc = 0; desc < 2; desc++) {
        for (uint64_t i = 0; i < N; i++) a[i] = (uint32_t)i;
        radix_sort_u32(a, N, e, "", mode, desc); h = fnv(h, a, N * 4);
    }
    double t_radix = now() - t0;
    /* Inflate: zlib-стиснення 8 MiB напівпередбачуваних даних, fixed/dynamic/stored */
    size_t RN = 8 << 20; uint8_t *raw = malloc(RN);
    for (size_t i = 0; i < RN; i++) raw[i] = (uint8_t)((i % 251) ^ ((rnd() & 15) == 0 ? rnd() : 0) ^ (i >> 9));
    uint8_t *out = malloc(RN); double t_inf = 0;
    int levels[] = {0, 1, 6, 9};
    for (int li = 0; li < 4; li++) {
        uLongf cl = compressBound(RN); uint8_t *c = malloc(cl); compress2(c, &cl, raw, RN, levels[li]);
        t0 = now();
        for (int rep = 0; rep < 3; rep++) { memset(out, 0, RN); int64_t n = inflate_zlib(c, cl, out, RN); if (n != (int64_t)RN || memcmp(out, raw, RN)) { printf("INFLATE MISMATCH level %d n=%ld\n", levels[li], (long)n); return 1; } }
        t_inf += now() - t0; free(c);
    }
    /* Некоректні потоки не мають падати/писати поза межі */
    for (int i = 0; i < 20000; i++) { uint8_t junk[300]; for (int k = 0; k < 300; k++) junk[k] = (uint8_t)rnd(); uint8_t o2[4096]; int64_t n = inflate_raw(junk, sizeof junk, o2, sizeof o2); h = fnv(h, &n, 8); if (n > 0) h = fnv(h, o2, n); }
    printf("checksum=%016llx utf8=%.1fms radix=%.1fms inflate=%.1fms\n", (unsigned long long)h, t_utf8 * 1e3, t_radix * 1e3, t_inf * 1e3);
    return 0;
}
