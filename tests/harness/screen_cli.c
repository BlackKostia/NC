/* Freestanding harness: frozen asm ScreenBuffer (ref_ prefix) next to src/tui/screen*.c.
 *   <ref|c> <seed> <iterations>   random drawing + flush sequences; the flushed ANSI bytes go to stdout, a state line
 *                                 (FNV of both cell buffers, geometry, pen, results) per iteration to stderr
 *   <ref|c> oom                   ScreenBuffer_new / resize under allocation failure (see guard_alloc.c)
 * The same seed drives both implementations, so identical behaviour means identical byte streams. */
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"

#define REFS(X) \
    X(ScreenBuffer *, new, (int, int)) X(void, dtor, (ScreenBuffer *)) X(intptr_t, resize, (ScreenBuffer *, int, int)) \
    X(void, flush, (ScreenBuffer *)) X(void, clear, (ScreenBuffer *, uint32_t, uint32_t)) \
    X(void, set_pen, (ScreenBuffer *, uint32_t, uint32_t, uint32_t)) X(void, set_cell, (ScreenBuffer *, int, int, uint32_t, uint32_t, uint32_t)) \
    X(void, set_cell_pen, (ScreenBuffer *, int, int, uint32_t)) X(void, fill_rect, (ScreenBuffer *, int, int, int, int, uint32_t)) \
    X(void, draw_hline, (ScreenBuffer *, int, int, int, uint32_t)) X(void, draw_box, (ScreenBuffer *, int, int, int, int, int)) \
    X(int, draw_text, (ScreenBuffer *, int, int, const char *, int)) X(void, draw_text_pad, (ScreenBuffer *, int, int, const char *, int))

#define DECL(R, n, A) extern R ref_ScreenBuffer_##n A;
REFS(DECL)
extern const ObjectVtbl ref_ScreenBuffer_vtbl;
typedef struct {
#define FIELD(R, n, A) R (*n) A;
    REFS(FIELD)
} Api;
#define REFINIT(R, n, A) .n = ref_ScreenBuffer_##n,
#define CINIT(R, n, A) .n = ScreenBuffer_##n,
static const Api k_ref = {REFS(REFINIT)}, k_c = {REFS(CINIT)};

static uint64_t rs = 1;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 20); }
static uint32_t pick(uint32_t n) { return rnd() % n; }

static uint64_t fnv(uint64_t h, const void *p, size_t n)
{
    for (size_t i = 0; i < n; i++) h = (h ^ ((const uint8_t *)p)[i]) * 0x100000001B3ull;
    return h;
}
static void report(const ScreenBuffer *s, int64_t extra)
{
    uint64_t h = 0xCBF29CE484222325ull;
    size_t cells = (size_t)s->width * (size_t)s->height;
    h = fnv(h, s->front, cells * 16);
    h = fnv(h, s->back, cells * 16);
    int32_t f[] = {s->width, s->height, s->force_full, s->pen_fg, s->pen_bg, s->pen_attrs};
    h = fnv(h, f, sizeof f);
    uint64_t g[] = {s->out_len, s->cell_cap, (uint64_t)extra};
    h = fnv(h, g, sizeof g);
    char t[24], line[64];
    size_t n = 0;
    t[u64_to_hex(h, t, 16)] = 0;
    for (const char *p = t; *p; p++) line[n++] = *p;
    line[n++] = '\n';
    (void)os_write(2, line, n);
}

static uint32_t color(uint32_t r)
{
    static const uint32_t pal[] = {0, 0x00FFFFFF, 1, 0x01000000, 0x01FF0000, 0x0100FF00, 0x010000FF, 0x01123456, 0x01FFFFFF, 0x0108090A, 0x01640A63};
    return pal[r % (sizeof pal / sizeof pal[0])];
}
static uint32_t glyph(uint32_t r)
{
    static const uint32_t g[] = {' ', 'a', 'Z', '~', 0x7F, 0x1B, 0x0A, 0, 0x410, 0x44F, 0x4E2D, 0x6587, 0xFF21, 0x300, 0x200B, 0x1F600, 0x2500, 0x256D, 0xFFFD, 0x110000, CELL_WIDE_TAIL};
    return g[r % (sizeof g / sizeof g[0])];
}
static size_t text(char *o)
{
    static const char *const bits[] = {"a", "Hello", " ", "й", "Файл", "中", "文件", "\x01", "\x7f", "\xcc\x81", "\xf0\x9f\x98\x80", "\xff", "\xc3", "ab\xe2\x82", "─", "ｗ"};
    size_t n = 0;
    for (uint32_t k = pick(12); k; k--) for (const char *s = bits[pick(sizeof bits / sizeof bits[0])]; *s; s++) o[n++] = *s;
    o[n] = 0;
    return n;
}

static void run(const Api *a, uint32_t seed, long iters)
{
    rs = seed * 2654435761u + 1;
    uint32_t w0 = pick(30), h0 = pick(12);
    ScreenBuffer *s = a->new(1 + (int)w0, 1 + (int)h0);
    if (!s) return;
    for (long it = 0; it < iters; it++) {
        int64_t extra = 0;
        for (uint32_t ops = 1 + pick(30); ops; ops--) {
            int w = s->width, h = s->height;
            uint32_t r[8];                                     /* argument evaluation order differs between gcc and clang */
            for (int i = 0; i < 8; i++) r[i] = rnd();
            int x = (int)(r[0] % ((uint32_t)w + 8)) - 4, y = (int)(r[1] % ((uint32_t)h + 8)) - 4;
            char buf[256];
            switch (r[2] % 16) {
            case 0: if (r[3] % 6 == 0) extra += a->resize(s, (int)(r[4] % 45) - 3, (int)(r[5] % 18) - 3); break;
            case 1: a->clear(s, color(r[3]), color(r[4])); break;
            case 2: a->set_pen(s, color(r[3]), color(r[4]), r[5] % 40); break;
            case 3: a->set_cell(s, x, y, glyph(r[3]), color(r[4]), color(r[5])); break;
            case 4: case 5: a->set_cell_pen(s, x, y, glyph(r[3])); break;
            case 6: a->fill_rect(s, x, y, (int)(r[3] % 20) - 3, (int)(r[4] % 8) - 2, r[5] % 3 ? ' ' : glyph(r[6])); break;
            case 7: a->draw_hline(s, x, y, (int)(r[3] % 40) - 4, glyph(r[4])); break;
            case 8: a->draw_box(s, x, y, (int)(r[3] % 25) - 2, (int)(r[4] % 10) - 2, (int)(r[5] % 2)); break;
            case 9: case 10: text(buf); extra = extra * 31 + a->draw_text(s, x, y, r[3] % 25 ? buf : nullptr, (int)(r[4] % 30) - 3); break;
            case 11: text(buf); a->draw_text_pad(s, x, y, buf, (int)(r[3] % 32) - 2); break;
            case 12: ScreenBuffer_rect_invalidate(s, x, y, (int)(r[3] % 10), (int)(r[4] % 5)); break;
            default: break;
            }
        }
        if (pick(8)) a->flush(s);
        if (pick(40) == 0) s->force_full = 1;
        if (pick(60) == 0) { extra += ScreenBuffer_rect_changed(s, 1, 1, 5, 3); }
        report(s, extra);
    }
    a->dtor(s);
    s = a->new(5, 3);
    a->set_pen(s, 0x01112233, 0x01445566, ATTR_BOLD | ATTR_UNDERLINE);
    a->draw_text(s, 0, 0, "x", 5);
    a->flush(s);
    report(s, 0);
    a->dtor(s);
    mem_free(s);
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 4) return 2;
    const Api *a = !str_cmp(argv[1], "ref") ? &k_ref : &k_c;
    long seed = 0, iters = 0;
    for (const char *s = argv[2]; *s; s++) seed = seed * 10 + (*s - '0');
    for (const char *s = argv[3]; *s; s++) iters = iters * 10 + (*s - '0');
    run(a, (uint32_t)seed, iters);
    return 0;
}
