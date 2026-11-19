/* Freestanding differential harness for src/ui/{img_preview,img_quad,img_braille}.c versus
 * frozen x86_64 asm (tests/harness/img_{preview,quad,braille}_reference.s, ref_ prefix).
 * argv[1] = ref | c.
 *
 * Script on stdin:
 *   I <kind> <iw> <ih> <bg_hex>   generate deterministic RGBA test image in g_rgba
 *       kind 0: solid black (a=255)
 *       kind 1: low-contrast gradient (lum range 15: Braille uniform threshold)
 *       kind 2: medium-contrast gradient (lum range 16: Braille active threshold)
 *       kind 3: 2x2 / 2x4 rich multi-pattern (all 8 quad masks + Braille >4 inversion + alpha)
 *       kind 4: semi-transparent alpha gradient (a = 0..255)
 *       kind 5: checkerboard + diagonal corners (bright vs dark)
 *   R <mode> <bx> <by> <bw> <bh>  mode 0=half(rgba) 1=quad 2=braille; clear scr, draw, hash + sample cells */
#include "duop_img.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_event.h"
#include "ui_render.h"

#include IMG_PREV_SRC
#include IMG_QUAD_SRC
#include IMG_BR_SRC

#ifdef __x86_64__
extern void ref_img_draw_rgba(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v);
extern void ref_img_draw_quad(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v);
extern void ref_img_draw_braille(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v);
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;
static uint8_t g_rgba[64 * 64 * 4];
static ImgView g_view;

static void put_px(int iw, int x, int y, uint8_t r, uint8_t g, uint8_t b, uint8_t a)
{
    uint8_t *p = g_rgba + ((size_t)y * (size_t)iw + (size_t)x) * 4;
    p[0] = r; p[1] = g; p[2] = b; p[3] = a;
}

static void gen_image(int kind, int iw, int ih, uint32_t bg)
{
    if (iw > 64) iw = 64;
    if (ih > 64) ih = 64;
    g_view.rgba = g_rgba;
    g_view.iw = iw;
    g_view.ih = ih;
    g_view.bg = bg;
    for (int y = 0; y < ih; y++) {
        for (int x = 0; x < iw; x++) {
            if (kind == 0) {
                put_px(iw, x, y, 0, 0, 0, 255);
            } else if (kind == 1) {
                /* lum range = 15 (< 16 -> uniform Braille) */
                uint8_t v = (uint8_t)(100 + ((x + y) & 1 ? 15 : 0));
                put_px(iw, x, y, v, v, v, 255);
            } else if (kind == 2) {
                /* lum range = 16 (>= 16 -> active Braille) */
                uint8_t v = (uint8_t)(100 + ((x + y) & 1 ? 17 : 0));
                put_px(iw, x, y, v, v, v, 255);
            } else if (kind == 3) {
                /* Rich pattern exercising all 8 quadrant splits & Braille >4 inversion */
                int blk = (y / 4) * 8 + (x / 2);
                int lx = x & 1, ly = y & 3;
                int bit = (ly * 2 + lx) & 7;
                int pat = (blk * 37 + 13) & 0xFF;
                int on = (pat >> bit) & 1;
                uint8_t r = on ? (uint8_t)(200 + ((x * 11) & 55)) : (uint8_t)(10 + ((y * 7) & 31));
                uint8_t g = on ? (uint8_t)(180 + ((y * 13) & 63)) : (uint8_t)(20 + ((x * 9) & 31));
                uint8_t b = on ? (uint8_t)(210 - ((blk * 5) & 63)) : (uint8_t)(15 + ((blk * 3) & 31));
                uint8_t a = (uint8_t)(255 - ((blk & 3) * 60));
                put_px(iw, x, y, r, g, b, a);
            } else if (kind == 4) {
                uint8_t a = (uint8_t)(((x * 31 + y * 53) & 0xFF));
                put_px(iw, x, y, (uint8_t)(x * 19), (uint8_t)(y * 23), (uint8_t)((x + y) * 17), a);
            } else {
                int bright = ((x & 1) ^ (y & 1)) || (x == 0 && y == 0);
                put_px(iw, x, y, bright ? 240 : 12, bright ? 220 : 18, bright ? 200 : 24, 255);
            }
        }
    }
}

static void dump_cells_summary(const ScreenBuffer *s, int bx, int by, int bw, int bh)
{
    uint64_t h = 1469598103934665603ull;
    uint32_t non_space = 0, uniq_ch = 0;
    uint32_t first_ch = 0, first_fg = 0, first_bg = 0;
    for (int y = 0; y < s->height; y++) {
        for (int x = 0; x < s->width; x++) {
            const Cell *c = &s->back[(size_t)y * (size_t)s->width + (size_t)x];
            uint32_t vals[4] = {c->ch, c->fg, c->bg, c->attrs};
            for (int k = 0; k < 4; k++) {
                uint32_t v = vals[k];
                for (int b = 0; b < 4; b++) {
                    h = (h ^ ((v >> (b * 8)) & 0xFFu)) * 1099511628211ull;
                }
            }
            if (c->ch != ' ') {
                if (non_space == 0) { first_ch = c->ch; first_fg = c->fg; first_bg = c->bg; }
                non_space++;
                uniq_ch ^= (c->ch * 2654435761u);
            }
        }
    }
    char hx[17];
    (void)u64_to_hex(h, hx, 16);
    sc_put("R box="); sc_num(bx); sc_put(","); sc_num(by); sc_put(","); sc_num(bw); sc_put(","); sc_num(bh);
    sc_put(" n="); sc_num(non_space);
    sc_put(" ch="); sc_num(first_ch);
    sc_put(" fg="); sc_num(first_fg);
    sc_put(" bg="); sc_num(first_bg);
    sc_put(" xor="); sc_num(uniq_ch);
    sc_put(" h="); sc_put(hx);
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    ScreenBuffer *scr = ScreenBuffer_new(44, 20);
    if (!scr) return 3;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        if (line[0] == 'I') {
            int kind = (int)ui_parse_num(&a);
            int iw = (int)ui_parse_num(&a);
            int ih = (int)ui_parse_num(&a);
            uint32_t bg = (uint32_t)ui_parse_num(&a);
            gen_image(kind, iw, ih, bg);
        } else if (line[0] == 'R') {
            int mode = (int)ui_parse_num(&a);
            int bx = (int)ui_parse_num(&a), by = (int)ui_parse_num(&a);
            int bw = (int)ui_parse_num(&a), bh = (int)ui_parse_num(&a);
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            if (mode == 0) CALLV(img_draw_rgba, scr, bx, by, bw, bh, &g_view);
            else if (mode == 1) CALLV(img_draw_quad, scr, bx, by, bw, bh, &g_view);
            else CALLV(img_draw_braille, scr, bx, by, bw, bh, &g_view);
            dump_cells_summary(scr, bx, by, bw, bh);
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
