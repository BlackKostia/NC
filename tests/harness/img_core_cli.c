/* Freestanding harness: the frozen asm image core (img_core_reference.s, x86_64, ref_ prefix) next to src/fs/img_core.c (compiled
 * into this unit, path in IC_SRC, its mem_alloc counted by ic_alloc). argv[1] = ref | c; the C decoders always allocate through
 * the C img_alloc. Script on stdin (hex = bytes in hex):
 *   D <hex> <path|->              img_detect
 *   A <w> <h> [hi]                img_alloc (hi: the asm call leaves garbage in the upper half of rdx, as the ABI allows)
 *   O <n>                         the n-th allocation of img_alloc fails
 *   N <iw> <ih> <bw> <bh>         img_fit
 *   S <w> <h> <seed> <ow> <oh> [x y rw rh] [off]   a random w x h picture scaled (img_scale or img_scale_rect) to ow x oh at
 *                                 offset off of a guarded buffer: a hash of the whole buffer
 *   F <file> <fmt> [cut]          img_decode of a file (cut: only the first cut bytes are mapped, the decoder is told the full
 *                                 size and faults on the unmapped page): rc, w, h, fmt, pixel hash
 *   P <w> <h> <ow> <oh> <reps>    timing of img_scale in ms */
#include "script_cli.h"
#include "duop_img.h"
#include "duop_pal.h"
#include "duop_oop.h"

void *ic_alloc(size_t n);
static int64_t g_fail_in;
void *ic_alloc(size_t n)
{
    if (g_fail_in > 0 && --g_fail_in == 0) return nullptr;
    return mem_alloc(n);
}

#define mem_alloc ic_alloc
#include IC_SRC
#undef mem_alloc

#ifdef __x86_64__
extern int ref_img_detect(const uint8_t *, size_t, const char *);
extern int ref_img_alloc(Image *, int, int);
extern int ic_ref_alloc_hi(Image *, int, int);
extern int ic_c_alloc_hi(Image *, int, int);
extern void ref_img_free(Image *);
extern ImgFit ref_img_fit(int, int, int, int);
extern void ref_img_scale(const Image *, uint8_t *, int, int);
extern void ref_img_scale_rect(const Image *, uint8_t *, int, int, const int *);
extern int ref_img_decode(const uint8_t *, size_t, int, Image *);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static uint8_t g_bytes[1 << 16];
static uint8_t g_dst[1 << 22];

static int sc_split(char *line, char **f, int max)
{
    int n = 0;
    while (*line && n < max) {
        while (*line == ' ') *line++ = 0;
        if (!*line) break;
        f[n++] = line;
        while (*line && *line != ' ') line++;
    }
    return n;
}

static int64_t num(const char *s)
{
    bool neg = *s == '-';
    int64_t v = 0;
    for (s += neg; *s >= '0' && *s <= '9'; s++) v = v * 10 + (*s - '0');
    return neg ? -v : v;
}

static int hexv(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : 0; }

static uint64_t fnv(const uint8_t *p, size_t n)
{
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull;
    return h;
}

static void put_hex(uint64_t v)
{
    char t[17];
    for (int i = 15; i >= 0; i--, v >>= 4) t[i] = "0123456789abcdef"[v & 15];
    t[16] = 0;
    sc_put(t);
}

static uint64_t g_rng;
static uint32_t rnd(void) { g_rng = g_rng * 6364136223846793005ull + 1442695040888963407ull; return (uint32_t)(g_rng >> 33); }

static bool picture(Image *img, int w, int h, uint64_t seed)
{
    img->px = mem_alloc((size_t)w * (size_t)h * 4);
    if (!img->px) return false;
    img->w = w; img->h = h; img->fmt = 0;
    g_rng = seed;
    for (size_t i = 0; i < (size_t)w * (size_t)h * 4; i++) img->px[i] = (uint8_t)rnd();
    return true;
}

static void cmd_scale(char **f, int n)
{
    Image img;
    if (n < 6 || !picture(&img, (int)num(f[1]), (int)num(f[2]), (uint64_t)num(f[3]))) return;
    int ow = (int)num(f[4]), oh = (int)num(f[5]);
    size_t off = n > 10 ? (size_t)num(f[10]) & 3 : n == 7 ? (size_t)num(f[6]) & 3 : 0;
    for (size_t i = 0; i < sizeof g_dst; i++) g_dst[i] = 0xA5;
    if (n >= 10) {
        const int rect[4] = {(int)num(f[6]), (int)num(f[7]), (int)num(f[8]), (int)num(f[9])};
        CALL(img_scale_rect, &img, g_dst + off, ow, oh, rect);
    } else {
        CALL(img_scale, &img, g_dst + off, ow, oh);
    }
    sc_put("S "); put_hex(fnv(g_dst, (size_t)(ow > 0 && oh > 0 ? ow * oh * 4 : 0) + 64));
    mem_free(img.px);
}

static void cmd_decode(char **f, int n)
{
    intptr_t fd = os_openat(AT_FDCWD, f[1], O_RDONLY | O_CLOEXEC, 0);
    FileStat st;
    if (fd < 0 || os_fstat((int)fd, &st) != 0 || st.size <= 0) { sc_put("F nofile"); if (fd >= 0) (void)os_close((int)fd); return; }
    size_t size = (size_t)st.size, cut = n > 3 ? (size_t)num(f[3]) : size;
    if (cut > size) cut = size;
    size_t pages = (cut + 4095) / 4096 + 1;                            /* the data end at the end of a page, an unmapped page follows */
    intptr_t m = os_mmap(nullptr, pages * 4096, PROT_RW, MAP_PRIVATE_ANON, -1, 0);
    if (m < 0 && m > -4096) { (void)os_close((int)fd); return; }
    uint8_t *base = (uint8_t *)m, *data = base + (pages - 1) * 4096 - cut;
    (void)os_munmap_raw(base + (pages - 1) * 4096, 4096);
    for (size_t got = 0; got < cut;) {
        intptr_t r = os_read((int)fd, data + got, cut - got);
        if (r <= 0) break;
        got += (size_t)r;
    }
    (void)os_close((int)fd);
    Image img = {.px = (uint8_t *)1, .w = -7, .h = -7, .fmt = -7};
    int rc = CALL(img_decode, data, size, (int)num(f[2]), &img);
    sc_put("F rc="); sc_num(rc); sc_put(" w="); sc_num(img.w); sc_put(" h="); sc_num(img.h); sc_put(" fmt="); sc_num(img.fmt);
    sc_put(" px=");
    if (img.px && rc == 0) put_hex(fnv(img.px, (size_t)img.w * (size_t)img.h * 4)); else sc_num(img.px != nullptr);
    if (rc == 0) img_free(&img);
    (void)os_munmap_raw(base, (pages - 1) * 4096);
}

static void cmd(char **f, int n)
{
    switch (f[0][0]) {
    case 'D': {
        size_t len = str_len(f[1]) / 2;
        for (size_t i = 0; i < len; i++) g_bytes[i] = (uint8_t)(hexv(f[1][2 * i]) << 4 | hexv(f[1][2 * i + 1]));
        const char *path = n > 2 && !(f[2][0] == '-' && !f[2][1]) ? f[2] : nullptr;
        sc_put("D "); sc_num(CALL(img_detect, g_bytes, len, path));
        break;
    }
    case 'A': {
        Image img = {.px = (uint8_t *)1, .w = -7, .h = -7, .fmt = 3};
        int w = (int)num(f[1]), h = (int)num(f[2]), rc;
#ifdef __x86_64__
        if (n > 3) rc = g_ref ? ic_ref_alloc_hi(&img, w, h) : ic_c_alloc_hi(&img, w, h);
        else
#endif
        rc = CALL(img_alloc, &img, w, h);
        sc_put("A rc="); sc_num(rc); sc_put(" w="); sc_num(img.w); sc_put(" h="); sc_num(img.h); sc_put(" px=");
        sc_num(img.px == (uint8_t *)1 ? 1 : img.px ? 2 : 0);
        if (rc == 0) { CALL(img_free, &img); sc_put(" freed="); sc_num(img.px == nullptr); }
        break;
    }
    case 'O': g_fail_in = num(f[1]); sc_put("O"); break;
    case 'N': {
        ImgFit r = CALL(img_fit, (int)num(f[1]), (int)num(f[2]), (int)num(f[3]), (int)num(f[4]));
        sc_put("N "); sc_num((int64_t)r.w); sc_put(" "); sc_num((int64_t)r.h);
        break;
    }
    case 'S': cmd_scale(f, n); break;
    case 'F': cmd_decode(f, n); break;
    case 'P': {
        Image img;
        if (!picture(&img, (int)num(f[1]), (int)num(f[2]), 1)) return;
        int64_t t0 = os_clock_ms();
        for (int64_t i = 0; i < num(f[5]); i++) CALL(img_scale, &img, g_dst, (int)num(f[3]), (int)num(f[4]));
        sc_put("P "); sc_num(os_clock_ms() - t0);
        mem_free(img.px);
        break;
    }
    default: return;
    }
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    os_fault_guard_install();                                  /* the TRY guard of img_decode needs the fault handler */
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        char *f[12];
        int n = sc_split(line, f, 12);
        if (n) cmd(f, n);
    }
    sc_flush();
    return 0;
}
