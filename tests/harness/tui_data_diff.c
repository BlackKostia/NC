/* Differential harness: frozen asm (ref_ prefix) vs src/tui/{theme,kbd_map,screen_rect}.c on random inputs.
 * Prints OK or the first mismatch. Host libc is allowed here: only the module under test is freestanding. */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "duop_config.h"
#include "duop_tui.h"

/* host stand-ins for what config_load.c imports (the config loader itself is not under test here) */
void *mem_alloc(size_t n) { return calloc(1, n); }
void mem_free(void *p) { free(p); }
intptr_t sys_read_retry(int fd, void *b, size_t n) { ssize_t r; while ((r = read(fd, b, n)) < 0 && errno == EINTR) {} return r; }
int os_fstat(int fd, FileStat *o) { struct stat s; if (fstat(fd, &s) < 0) return -1; memset(o, 0, sizeof *o); o->mode = s.st_mode; o->size = s.st_size; return 0; }
intptr_t os_openat(int d, const char *p, int f, unsigned m) { int r = openat(d, p, f, m); return r < 0 ? -errno : r; }
intptr_t os_close(int fd) { return close(fd); }

extern const Theme *ref_theme_get(int);
extern int ref_theme_count(void);
extern void ref_kbd_map_reset(void);
extern int ref_kbd_latin(int);
extern void ref_kbd_layout_parse(char *);
extern int ref_ScreenBuffer_rect_changed(ScreenBuffer *, int, int, int, int);
extern void ref_ScreenBuffer_rect_invalidate(ScreenBuffer *, int, int, int, int);

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 20); }

static int test_theme(void)
{
    if (ref_theme_count() != theme_count()) { puts("theme_count differs"); return 1; }
    for (int iter = 0; iter < 20000; iter++) {
        memset(&g_config, 0, sizeof g_config);
        if (iter % 3) {
            g_config.color_mask = rnd() & ((1u << 29) - 1);
            if (iter % 7 == 0) g_config.color_mask = 0x1FFFFFFF;
            for (int k = 0; k < 29; k++) g_config.colors[k] = 0x01000000u | (rnd() & 0xFFFFFF);
        }
        int idx = iter < 40 ? iter - 20 : (int)rnd() - (int)(rnd() >> 1);
        if (iter == 40) idx = INT32_MIN;
        if (iter == 41) idx = INT32_MAX;
        const Theme *a = ref_theme_get(idx), *b = theme_get(idx);
        if (strcmp(a->name, b->name) || memcmp((char *)a + 8, (char *)b + 8, sizeof(Theme) - 8)) {
            printf("theme_get(%d) mismatch (iter %d)\n", idx, iter);
            return 1;
        }
    }
    return 0;
}

/* ---- keyboard layouts ---- */
static const char *rows[] = {"qwertyuiop[]", "asdfghjkl;'", "zxcvbnm,./", "1234567890-=", "qwertyuiopasdfghjklzxcvbnm", " \tq w"};
static size_t put_cp(char *o, uint32_t cp)
{
    if (cp < 0x80) { o[0] = (char)cp; return 1; }
    if (cp < 0x800) { o[0] = (char)(0xC0 | cp >> 6); o[1] = (char)(0x80 | (cp & 0x3F)); return 2; }
    if (cp < 0x10000) { o[0] = (char)(0xE0 | cp >> 12); o[1] = (char)(0x80 | (cp >> 6 & 0x3F)); o[2] = (char)(0x80 | (cp & 0x3F)); return 3; }
    o[0] = (char)(0xF0 | cp >> 18); o[1] = (char)(0x80 | (cp >> 12 & 0x3F)); o[2] = (char)(0x80 | (cp >> 6 & 0x3F)); o[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}
static uint32_t pick_cp(void)
{
    switch (rnd() % 9) {
    case 0: return 0x20 + rnd() % 0x5F;                    /* ASCII */
    case 1: return 0x80 + rnd() % 0x80;                    /* Latin-1 */
    case 2: case 3: return 0x410 + rnd() % 0x40;           /* Cyrillic */
    case 4: return 0x391 + rnd() % 0x40;                   /* Greek */
    case 5: return 0xFFFD;
    case 6: return 0x100000 + rnd() % 0x20;                /* around KEY_UP: special-key range */
    case 7: return 0x800 + rnd() % 0xF000;
    default: return 0x10000 + rnd() % 0xFFFF;
    }
}
static size_t gen_layout(char *o, size_t cap)
{
    size_t n = 0;
    int lines = 1 + rnd() % 14;
    if (rnd() % 11 == 0) lines = 40;                       /* enough distinct pairs to overflow KBD_MAP_MAX */
    for (int l = 0; l < lines && n + 400 < cap; l++) {
        switch (rnd() % 9) {
        case 0: n += (size_t)sprintf(o + n, "# comment\n"); break;
        case 1: n += (size_t)sprintf(o + n, "name = Test layout\r\n"); break;
        case 2: n += (size_t)sprintf(o + n, "keysx = qwe\nkeys\nchars   \n  chars = яя\n"); break;
        case 3: n += (size_t)sprintf(o + n, "\n   \t\n"); break;
        default: {
            int keys = rnd() % 2;
            n += (size_t)sprintf(o + n, "%s%s%s", rnd() % 4 == 0 ? "  \t" : "", keys ? "keys" : "chars", rnd() % 3 ? " = " : "=");
            int cols = rnd() % 4 == 0 ? 95 : 1 + rnd() % 30;
            if (keys) {
                const char *r = rows[rnd() % 6];
                size_t rl = strlen(r);
                for (int c = 0; c < cols; c++) o[n++] = rnd() % 40 == 0 ? (char)(rnd() % 0x20 ? 0x21 + rnd() % 0x5E : 0x7F) : (cols > 30 ? (char)(0x21 + c % 0x5E) : r[c % rl]);
            } else {
                for (int c = 0; c < cols; c++) {
                    if (rnd() % 60 == 0) { o[n++] = (char)(0xC0 + rnd() % 0x40); continue; }   /* malformed: lead byte alone */
                    n += put_cp(o + n, cols > 30 ? 0x500 + rnd() % 0x2000 : pick_cp());
                }
            }
            if (rnd() % 5 == 0) n += (size_t)sprintf(o + n, "%s", rnd() % 2 ? "  \t" : "\r");
            o[n++] = '\n';
        }
        }
    }
    if (rnd() % 4) o[n++] = '\n';
    o[n] = 0;
    return n;
}

static int test_kbd(void)
{
    static char ta[30000], tb[30000];
    for (int iter = 0; iter < 30000; iter++) {
        ref_kbd_map_reset();
        kbd_map_reset();
        int files = 1 + rnd() % 3;
        for (int f = 0; f < files; f++) {
            size_t n = gen_layout(ta, sizeof ta - 1);
            memcpy(tb, ta, n + 1);
            ref_kbd_layout_parse(ta);
            kbd_layout_parse(tb);
            if (memcmp(ta, tb, n + 1)) { printf("kbd: parsed text differs, iter %d\n", iter); return 1; }
        }
        for (int k = -3; k < 0x700; k++)
            if (ref_kbd_latin(k) != kbd_latin(k)) { printf("kbd_latin(%d) differs, iter %d: %d vs %d\n", k, iter, ref_kbd_latin(k), kbd_latin(k)); return 1; }
        for (int j = 0; j < 400; j++) {
            int k = j < 100 ? (int)(0x100000 + j) : (int)(0x391 + rnd() % 0x20000);
            if (ref_kbd_latin(k) != kbd_latin(k)) { printf("kbd_latin(%x) differs, iter %d\n", k, iter); return 1; }
        }
    }
    return 0;
}

/* ---- screen rects ---- */
static int test_rect(void)
{
    static Cell fa[24 * 24], fb[24 * 24], back[24 * 24];
    for (int iter = 0; iter < 200000; iter++) {
        int w = 1 + rnd() % 22, h = 1 + rnd() % 22, n = w * h;
        for (int i = 0; i < n; i++) { back[i] = (Cell){rnd() % 3, rnd() % 2, 0, rnd() % 2}; fa[i] = back[i]; }
        for (int m = rnd() % 4; m-- > 0;) fa[rnd() % n].ch ^= 1 + rnd() % 3;
        memcpy(fb, fa, sizeof(Cell) * n);
        ScreenBuffer sa = {.front = fa, .back = back, .width = w, .height = h, .force_full = rnd() % 8 == 0};
        ScreenBuffer sb = sa;
        sb.front = fb;
        int x = (int)(rnd() % 40) - 8, y = (int)(rnd() % 40) - 8, rw = (int)(rnd() % 40) - 6, rh = (int)(rnd() % 40) - 6;
        if (iter % 50 == 0) { x = INT32_MIN + (int)(rnd() % 3); rw = INT32_MAX - (int)(rnd() % 3); }
        if (iter % 50 == 1) { y = INT32_MIN; rh = INT32_MAX; }
        if (iter % 50 == 2) { x = -1; rw = INT32_MIN; }
        int ra = ref_ScreenBuffer_rect_changed(&sa, x, y, rw, rh), rb = ScreenBuffer_rect_changed(&sb, x, y, rw, rh);
        if (ra != rb) { printf("rect_changed(%d,%d,%d,%d) in %dx%d: %d vs %d\n", x, y, rw, rh, w, h, ra, rb); return 1; }
        ref_ScreenBuffer_rect_invalidate(&sa, x, y, rw, rh);
        ScreenBuffer_rect_invalidate(&sb, x, y, rw, rh);
        if (memcmp(fa, fb, sizeof(Cell) * n)) { printf("rect_invalidate(%d,%d,%d,%d) in %dx%d differs\n", x, y, rw, rh, w, h); return 1; }
    }
    return 0;
}

int main(void)
{
    if (test_theme() || test_kbd() || test_rect()) return 1;
    puts("OK 20000 theme configs, 30000 random layout sets, 200000 random rects identical");
    return 0;
}
