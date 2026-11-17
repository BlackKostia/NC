/* Differential harness: frozen asm image decoders (ref_ prefix) vs src/fs/img_*.c on stdin records
 *   [u32 le length][u8 format IMG_FMT_*][length bytes] ... until EOF
 * Both decoders see the input at the very end of a mapping followed by a PROT_NONE page and write into an exactly-sized
 * guarded pixel buffer, so any out-of-bounds access faults. Prints OK, or the first mismatch. A decoder that faults
 * is reported as "asm-fault"/"C-fault"; only a C fault (or a result mismatch) fails the run. */
#define _GNU_SOURCE
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include "duop_img.h"

#define RD(n) extern int ref_img_##n##_decode(const uint8_t *, size_t, Image *);
RD(bmp) RD(tga) RD(pnm) RD(qoi) RD(gif) RD(png) RD(jpeg)

static void *guarded(size_t len)                     /* len readable/writable bytes ending exactly at a guard page */
{
    size_t data = (len + 4095) & ~(size_t)4095;
    if (!data) data = 4096;
    uint8_t *base = mmap(NULL, data + 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    mprotect(base + data, 4096, PROT_NONE);
    return base + data - len;
}

/* heap shims: exactly-sized zero-filled blocks at the end of a mapping (mem_alloc is zero-filled in Duop) */
static struct { void *p, *base; size_t total; } g_live[256];
void *mem_alloc(size_t n)
{
    size_t data = (n + 4095) & ~(size_t)4095;
    if (!data) data = 4096;
    uint8_t *base = mmap(NULL, data + 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    mprotect(base + data, 4096, PROT_NONE);
    for (int i = 0; i < 256; i++)
        if (!g_live[i].p) { g_live[i].p = base + data - n; g_live[i].base = base; g_live[i].total = data + 4096; return g_live[i].p; }
    abort();
}
void mem_free(void *p)
{
    for (int i = 0; i < 256; i++)
        if (p && g_live[i].p == p) { munmap(g_live[i].base, g_live[i].total); g_live[i].p = NULL; return; }
}
void mem_copy(void *d, const void *s, size_t n) { memcpy(d, s, n); }
int img_alloc(Image *img, int w, int h)              /* the asm img_core semantics, with a guarded buffer */
{
    if (w <= 0 || h <= 0 || w > IMG_MAX_DIM || h > IMG_MAX_DIM) return IMG_E_CORRUPT;
    img->w = w;
    img->h = h;
    if ((int64_t)w * h > IMG_MAX_PIXELS) return IMG_E_UNSUP;
    img->px = guarded((size_t)w * h * 4);
    return 0;
}
void img_free(Image *img) { mem_free(img->px); img->px = NULL; }
void mem_zero(void *p, size_t n) { memset(p, 0, n); }

static sigjmp_buf jb;
static void on_segv(int s) { (void)s; siglongjmp(jb, 1); }

typedef int (*Dec)(const uint8_t *, size_t, Image *);
static int run(Dec f, const uint8_t *d, size_t n, Image *img, int *faulted)
{
    memset(img, 0, sizeof *img);
    *faulted = 0;
    if (sigsetjmp(jb, 1)) { *faulted = 1; return 0x7FFF; }
    return f(d, n, img);
}

int main(void)
{
    struct sigaction sa = {.sa_handler = on_segv, .sa_flags = SA_NODEFER};
    sigaction(SIGSEGV, &sa, NULL);
    static const struct { Dec ref, c; const char *name; } fmts[] = {
        [IMG_FMT_BMP] = {ref_img_bmp_decode, img_bmp_decode, "bmp"}, [IMG_FMT_TGA] = {ref_img_tga_decode, img_tga_decode, "tga"},
        [IMG_FMT_PNM] = {ref_img_pnm_decode, img_pnm_decode, "pnm"}, [IMG_FMT_QOI] = {ref_img_qoi_decode, img_qoi_decode, "qoi"},
        [IMG_FMT_GIF] = {ref_img_gif_decode, img_gif_decode, "gif"}, [IMG_FMT_PNG] = {ref_img_png_decode, img_png_decode, "png"}, [IMG_FMT_JPEG] = {ref_img_jpeg_decode, img_jpeg_decode, "jpeg"},
    };
    long recs = 0, asm_faults = 0, ok_imgs = 0;
    for (;;) {
        uint32_t len;
        uint8_t fmt;
        if (fread(&len, 4, 1, stdin) != 1) break;
        if (fread(&fmt, 1, 1, stdin) != 1 || fmt >= sizeof fmts / sizeof fmts[0] || !fmts[fmt].c) return 3;
        uint8_t *tmp = malloc(len + 1);
        if (fread(tmp, 1, len, stdin) != len) return 3;
        uint8_t *a = guarded(len), *b = guarded(len);
        memcpy(a, tmp, len);
        memcpy(b, tmp, len);
        Image ia, ib;
        int fa, fb;
        int ra = run(fmts[fmt].ref, a, len, &ia, &fa), rb = run(fmts[fmt].c, b, len, &ib, &fb);
        recs++;
        if (ra > 0 || ra < IMG_E_NOMEM) ra = IMG_E_FORMAT;                /* asm bug: `lea rax, [hsz + 14]` clobbered IMG_E_FORMAT before `ja` returned it */
        if (fb) { printf("%s record %ld: the C decoder faulted (asm %s)\n", fmts[fmt].name, recs, fa ? "faulted too" : "did not)"); return 1; }
        if (fa) { asm_faults++; continue; }
        if (ra != rb || (!ra && (ia.w != ib.w || ia.h != ib.h || memcmp(ia.px, ib.px, (size_t)ia.w * ia.h * 4)))) {
            printf("%s record %ld (len %u): asm rc=%d %dx%d, C rc=%d %dx%d%s\n", fmts[fmt].name, recs, len, ra, ia.w, ia.h, rb, ib.w, ib.h,
                   (!ra && !rb) ? " (pixels differ)" : "");
            FILE *f = fopen("/tmp/img_diff_fail.bin", "wb");
            if (f) { fwrite(tmp, 1, len, f); fclose(f); }
            return 1;
        }
        ok_imgs += !ra;
        free(tmp);
    }
    printf("OK %ld records (%ld decoded, %ld rejected, %ld asm faults on malformed input)\n", recs, ok_imgs, recs - ok_imgs - asm_faults, asm_faults);
    return 0;
}
