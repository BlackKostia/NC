/* Differential harness: frozen asm picture encoders (ref_ prefix) vs src/fs/img_{kitty,quant,sixel}.c.
 * Records on stdin: [u8 kind][u32 size][payload]; outputs are compared byte for byte inside guarded buffers.
 *   b64:    payload = bytes
 *   kitty:  payload = i32 w, h, cols, u32 cap, rgba[w*h*4]
 *   place:  payload = i32 x, y, w, h, cols, rows
 *   sixel:  payload = i32 w, h, u32 bg, u32 cap, rgba[w*h*4]
 *   quant:  payload = u32 bg, rgba[n*4]  (n = size / 4)                                                           */
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "duop_img.h"

extern size_t ref_img_b64_encode(const uint8_t *, size_t, char *);
extern size_t ref_img_kitty_encode(const uint8_t *, int, int, int, uint8_t *, size_t);
extern size_t ref_img_kitty_place(uint8_t *, const int *, int, int);
extern int ref_img_quantize(const uint8_t *, size_t, uint32_t, uint8_t *, uint32_t *);
extern size_t ref_img_sixel_encode(const uint8_t *, int, int, uint32_t, uint8_t *, size_t);

static void *guarded(size_t len)
{
    size_t data = (len + 4095) & ~(size_t)4095;
    if (!data) data = 4096;
    uint8_t *base = mmap(NULL, data + 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    mprotect(base + data, 4096, PROT_NONE);
    return base + data - len;
}
static struct { void *p, *base; size_t total; } g_live[64];
void *mem_alloc(size_t n)
{
    size_t data = (n + 4095) & ~(size_t)4095;
    if (!data) data = 4096;
    uint8_t *base = mmap(NULL, data + 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    mprotect(base + data, 4096, PROT_NONE);
    for (int i = 0; i < 64; i++)
        if (!g_live[i].p) { g_live[i].p = base + data - n; g_live[i].base = base; g_live[i].total = data + 4096; return g_live[i].p; }
    abort();
}
void mem_free(void *p)
{
    for (int i = 0; i < 64; i++)
        if (p && g_live[i].p == p) { munmap(g_live[i].base, g_live[i].total); g_live[i].p = NULL; return; }
}
void mem_zero(void *p, size_t n) { memset(p, 0, n); }

static int fail(const char *what, long rec) { printf("%s: record %ld differs\n", what, rec); return 1; }

int main(void)
{
    long rec = 0, nonzero = 0;
    for (;;) {
        uint8_t kind;
        uint32_t size;
        if (fread(&kind, 1, 1, stdin) != 1 || fread(&size, 4, 1, stdin) != 1) break;
        uint8_t *pay = malloc(size + 1);
        if (fread(pay, 1, size, stdin) != size) return 3;
        rec++;
        int32_t *iv = (int32_t *)pay;
        if (kind == 0) {
            char *a = guarded((size + 2) / 3 * 4), *b = guarded((size + 2) / 3 * 4);
            uint8_t *src = guarded(size);
            memcpy(src, pay, size);
            size_t ra = ref_img_b64_encode(src, size, a), rb = img_b64_encode(src, size, b);
            if (ra != rb || memcmp(a, b, ra)) return fail("b64", rec);
        } else if (kind == 1 || kind == 3) {
            int w = iv[0], h = iv[1];
            uint32_t arg = (uint32_t)iv[2], cap = (uint32_t)iv[3];
            size_t px = (size_t)w * h * 4;
            uint8_t *src = guarded(px), *a = guarded(cap), *b = guarded(cap);
            memcpy(src, pay + 16, px);
            memset(a, 0xA5, cap);
            memset(b, 0xA5, cap);
            size_t ra, rb;
            if (kind == 1) { ra = ref_img_kitty_encode(src, w, h, (int)arg, a, cap); rb = img_kitty_encode(src, w, h, (int)arg, b, cap); }
            else { ra = ref_img_sixel_encode(src, w, h, arg, a, cap); rb = img_sixel_encode(src, w, h, arg, b, cap); }
            if (ra != rb || memcmp(a, b, ra)) return fail(kind == 1 ? "kitty" : "sixel", rec);
            nonzero += ra != 0;
        } else if (kind == 2) {
            uint8_t *a = guarded(256), *b = guarded(256);
            size_t ra = ref_img_kitty_place(a, iv, iv[4], iv[5]), rb = img_kitty_place(b, iv, iv[4], iv[5]);
            if (ra != rb || memcmp(a, b, ra)) return fail("place", rec);
        } else if (kind == 4) {
            size_t n = (size - 4) / 4;
            uint32_t bg = (uint32_t)iv[0];
            uint8_t *src = guarded(n * 4), *ia = guarded(n), *ib = guarded(n);
            uint32_t pa[256] = {0}, pb[256] = {0};
            memcpy(src, pay + 4, n * 4);
            int ca = ref_img_quantize(src, n, bg, ia, pa), cb = img_quantize(src, n, bg, ib, pb);
            if (ca != cb || memcmp(pa, pb, sizeof(uint32_t) * (size_t)ca) || memcmp(ia, ib, n)) return fail("quant", rec);
            nonzero += ca != 0;
        }
        free(pay);
    }
    printf("OK %ld records (%ld produced output)\n", rec, nonzero);
    return 0;
}
