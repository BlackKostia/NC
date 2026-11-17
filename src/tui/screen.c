/* src/tui/screen.c - ScreenBuffer lifecycle and the differential ANSI flush (freestanding C23; replaces screen.s,
 * screen_out.s and the out_* helpers of screen_text.s).
 *
 * ScreenBuffer_flush() compares the back buffer with the front buffer (SIMD skip over unchanged cells), and emits only
 * the changed ones as TrueColor SGR + UTF-8, wrapped in a DEC 2026 synchronized update so the terminal presents the
 * frame atomically. The output buffer is bounded: when it cannot grow, bytes are dropped instead of overrunning. */
#include "duop_pal.h"
#include "duop_sys.h"
#include "duop_tui.h"

int utf8_encode(uint32_t cp, char *out);
int utf8_char_width(uint32_t cp);

const ObjectVtbl ScreenBuffer_vtbl = { &Object_vtbl, "ScreenBuffer", sizeof(ScreenBuffer), (void (*)(Object *))ScreenBuffer_dtor };

#define SYNC_BEGIN "\x1b[?2026h"
#define SYNC_END "\x1b[0m\x1b[?2026l"

ScreenBuffer *ScreenBuffer_new(int width, int height)
{
    ScreenBuffer *s = Object_alloc(&ScreenBuffer_vtbl, sizeof *s);
    if (!s) return nullptr;
    s->out_buf = mem_alloc(OUT_BUF_INIT_CAP);
    if (!s->out_buf) { mem_free(s); return nullptr; }
    s->out_cap = OUT_BUF_INIT_CAP;
    s->out_len = 0;
    if (ScreenBuffer_resize(s, width, height) < 0) {
        ScreenBuffer_dtor(s);
        mem_free(s);
        return nullptr;
    }
    return s;
}

void ScreenBuffer_dtor(ScreenBuffer *s)
{
    mem_free(s->front);
    mem_free(s->back);
    mem_free(s->out_buf);
    s->front = nullptr;
    s->back = nullptr;
    s->out_buf = nullptr;
}

/* ---- bounded output buffer ---- */
static int out_ensure(ScreenBuffer *s, size_t need)         /* 0, or -ENOMEM when the buffer cannot grow */
{
    size_t want, cap;
    if (__builtin_add_overflow(s->out_len, need, &want)) return -ENOMEM;
    if (want <= s->out_cap) return 0;
    if (__builtin_add_overflow(s->out_cap * 2, 4096, &cap) || s->out_cap > SIZE_MAX / 2) return -ENOMEM;
    if (cap < want) cap = want;
    char *p = mem_realloc(s->out_buf, cap);
    if (!p) return -ENOMEM;
    s->out_buf = p;
    s->out_cap = cap;
    return 0;
}

static void out_byte(ScreenBuffer *s, char b)
{
    if (s->out_len < s->out_cap) s->out_buf[s->out_len++] = b;
}

static void out_cstr(ScreenBuffer *s, const char *str, size_t len)
{
    if (len > s->out_cap - s->out_len) return;
    mem_copy(s->out_buf + s->out_len, str, len);
    s->out_len += len;
}

static void out_u32(ScreenBuffer *s, uint32_t v)
{
    char tmp[12];
    size_t n = 0;
    do { tmp[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    if (n > s->out_cap - s->out_len) return;
    while (n) s->out_buf[s->out_len++] = tmp[--n];
}

static char *put_u8(char *p, uint32_t v)                    /* decimal 0..255 without a division loop */
{
    if (v >= 100) { *p++ = (char)('0' + v / 100); v %= 100; *p++ = (char)('0' + v / 10); }
    else if (v >= 10) *p++ = (char)('0' + v / 10);
    *p++ = (char)('0' + v % 10);
    return p;
}

/* "\x1b[38;2;R;G;Bm" / "\x1b[48;2;R;G;Bm"; the caller reserved room, otherwise nothing is written */
static void out_rgb_sgr(ScreenBuffer *s, uint32_t rgb, bool is_bg)
{
    if (24 > s->out_cap - s->out_len) return;
    char *p = s->out_buf + s->out_len, *start = p;
    *p++ = 0x1B; *p++ = '['; *p++ = is_bg ? '4' : '3'; *p++ = '8'; *p++ = ';'; *p++ = '2';
    for (int shift = 16; shift >= 0; shift -= 8) { *p++ = ';'; p = put_u8(p, (rgb >> shift) & 0xFF); }
    *p++ = 'm';
    s->out_len += (size_t)(p - start);
}

/* ESC [ 0 (;1 bold)(;2 dim)(;3 italic)(;4 underline)(;7 reverse) m */
static void out_attrs(ScreenBuffer *s, uint32_t a)
{
    out_byte(s, 0x1B); out_byte(s, '['); out_byte(s, '0');
    static const struct { uint8_t bit, digit; } map[] = {{ATTR_BOLD, '1'}, {ATTR_DIM, '2'}, {ATTR_ITALIC, '3'}, {ATTR_UNDERLINE, '4'}, {ATTR_REVERSE, '7'}};
    for (size_t i = 0; i < sizeof map / sizeof map[0]; i++)
        if (a & map[i].bit) { out_byte(s, ';'); out_byte(s, (char)map[i].digit); }
    out_byte(s, 'm');
}

typedef struct { uint32_t fg, bg, attrs; int32_t last_x, last_y; } Pen;

/* Emits one changed cell: cursor move when not adjacent, SGR for what differs, then the character. */
static void flush_cell(ScreenBuffer *s, const Cell *c, int x, int y, Pen *p)
{
    (void)out_ensure(s, 128);                                /* cursor move + SGR + two RGB sequences + UTF-8 <= 96 B */
    if (y != p->last_y || p->last_x + 1 != x) {
        out_byte(s, 0x1B); out_byte(s, '[');
        out_u32(s, (uint32_t)y + 1);
        out_byte(s, ';');
        out_u32(s, (uint32_t)x + 1);
        out_byte(s, 'H');
    }
    if (c->attrs != p->attrs) {
        out_attrs(s, c->attrs);
        p->attrs = c->attrs;
        p->fg = p->bg = 0xFFFFFFFFu;                         /* SGR 0 reset the colours */
    }
    if (c->fg != p->fg && (c->fg & 0x01000000u)) { out_rgb_sgr(s, c->fg, false); p->fg = c->fg; }
    if (c->bg != p->bg && (c->bg & 0x01000000u)) { out_rgb_sgr(s, c->bg, true); p->bg = c->bg; }
    uint32_t cp = c->ch < 0x20 ? ' ' : c->ch;
    if (s->out_len + 4 > s->out_cap) return;
    s->out_len += (size_t)utf8_encode(cp, s->out_buf + s->out_len);
    int w = utf8_char_width(cp);
    p->last_x = x + (w ? w : 1) - 1;
    p->last_y = y;
}

void ScreenBuffer_flush(ScreenBuffer *s)
{
    s->out_len = 0;
    (void)out_ensure(s, 64);
    out_cstr(s, SYNC_BEGIN, sizeof SYNC_BEGIN - 1);
    int w = s->width, h = s->height;
    int32_t cells = (int32_t)((uint32_t)w * (uint32_t)h);
    if (cells <= 0) return;
    if (s->force_full) {
        s->force_full = 0;
        os_mem_set_fast(s->front, 0xFF, (size_t)(uint32_t)cells << 4);   /* nothing equals 0xFF.. cells: every cell is rewritten */
    }
    Pen pen = {0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, -2, -2};
    Cell *back = s->back, *front = s->front;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w;) {
            size_t skip = os_mem_mismatch16(back, front, (size_t)(w - x));   /* unchanged cells cost one SIMD call */
            x += (int)skip;
            back += skip;
            front += skip;
            if (x >= w) break;
            *front = *back;
            if (back->ch != CELL_WIDE_TAIL) flush_cell(s, back, x, y, &pen);
            x++;
            back++;
            front++;
        }
    }
    if (s->out_len <= sizeof SYNC_BEGIN - 1) { s->out_len = 0; return; }     /* no cell changed: emit nothing at all */
    (void)out_ensure(s, 32);
    out_cstr(s, SYNC_END, sizeof SYNC_END - 1);
    if (sys_write_all(1, s->out_buf, s->out_len) < 0) s->force_full = 1;
    s->out_len = 0;
}
