/* Freestanding differential harness for src/ui/viewer_pixels.c versus frozen x86_64 asm
 * (tests/harness/viewer_pixels_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static int g_proto;
static uint64_t g_cw, g_ch;
static int g_kitty_pan_ret;
static int g_fail_alloc;
static uint8_t g_rgba[64 * 64 * 4];

int term_img_proto(void) { return g_proto; }
CellPx term_cell_px(void) { return (CellPx){g_cw, g_ch}; }

void stub_box_px(int cols, int rows, int proto, int out[3]);
void stub_box_px(int cols, int rows, int proto, int out[3])
{
    out[0] = 0; out[1] = 0; out[2] = 0;
    if (cols <= 0 || rows <= 0) return;
    if (proto == IMG_PROTO_HALF) { out[0] = cols; out[1] = rows * 2; return; }
    if (proto < IMG_PROTO_SIXEL) { out[0] = cols * 2; out[1] = rows * 2; return; }
    int cw = (int)g_cw, ch = (int)g_ch, kc = 0;
    if (cw == 0 || ch == 0) {
        if (proto == IMG_PROTO_KITTY) {
            cw = 10; ch = 20;
            kc = cols > 255 ? 255 : cols;
        } else {
            cw = 6; ch = 12;
        }
    }
    int w = cw * cols, h = ch * rows;
    if (w > 2048) w = 2048;
    if (h > 2048) h = 2048;
    out[0] = w; out[1] = h; out[2] = kc;
}

#ifndef __x86_64__
ImgFit img_box_pixels(int cols, int rows, int proto)
{
    int out[3];
    stub_box_px(cols, rows, proto, out);
    return (ImgFit){(uint64_t)(uint32_t)out[0], (uint64_t)(uint32_t)out[1]};
}
#endif

int fake_vim_kitty_pan(ViewerDialog *v, int proto, ImgPlace *p);
int fake_vim_kitty_pan(ViewerDialog *v, int proto, ImgPlace *p)
{
    const int32_t *box = (const int32_t *)((const uint8_t *)p + sizeof(ImgPlace));
    sc_put("call vim_kitty_pan p="); sc_num(proto);
    sc_put(" box="); sc_num(box[0]); sc_put("x"); sc_num(box[1]); sc_put(" kc="); sc_num(box[2]);
    sc_put(" z="); sc_num(v->img_zoom); sc_put("\n");
    return g_kitty_pan_ret;
}

void fake_img_overlay_show(const ImgPlace *p);
void fake_img_overlay_show(const ImgPlace *p)
{
    sc_put("call img_overlay_show len="); sc_num((int64_t)p->len);
    sc_put(" rect="); sc_num(p->x); sc_put(","); sc_num(p->y);
    sc_put(","); sc_num(p->w); sc_put(","); sc_num(p->h);
    sc_put(" has_data="); sc_num(p->data != 0);
    sc_put(" has_key="); sc_num(p->key != 0);
    sc_put("\n");
}

void fake_img_draw_rgba(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v);
void fake_img_draw_rgba(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
{
    (void)scr;
    sc_put("call img_draw_rgba box="); sc_num(bx); sc_put(","); sc_num(by);
    sc_put(","); sc_num(bw); sc_put(","); sc_num(bh);
    sc_put(" iv="); sc_num(v->iw); sc_put("x"); sc_num(v->ih);
    sc_put(" bg="); sc_num(v->bg); sc_put(" px="); sc_num(v->rgba != nullptr); sc_put("\n");
}

void fake_img_draw_quad(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v);
void fake_img_draw_quad(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
{
    (void)scr;
    sc_put("call img_draw_quad box="); sc_num(bx); sc_put(","); sc_num(by);
    sc_put(","); sc_num(bw); sc_put(","); sc_num(bh);
    sc_put(" iv="); sc_num(v->iw); sc_put("x"); sc_num(v->ih);
    sc_put(" bg="); sc_num(v->bg); sc_put(" px="); sc_num(v->rgba != nullptr); sc_put("\n");
}

void fake_img_draw_braille(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v);
void fake_img_draw_braille(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
{
    (void)scr;
    sc_put("call img_draw_braille box="); sc_num(bx); sc_put(","); sc_num(by);
    sc_put(","); sc_num(bw); sc_put(","); sc_num(bh);
    sc_put(" iv="); sc_num(v->iw); sc_put("x"); sc_num(v->ih);
    sc_put(" bg="); sc_num(v->bg); sc_put(" px="); sc_num(v->rgba != nullptr); sc_put("\n");
}

void fake_img_scale_rect(const Image *src, uint8_t *dst, int ow, int oh, const int *rect);
void fake_img_scale_rect(const Image *src, uint8_t *dst, int ow, int oh, const int *rect)
{
    sc_put("call img_scale_rect src="); sc_num(src->w); sc_put("x"); sc_num(src->h);
    sc_put(" out="); sc_num(ow); sc_put("x"); sc_num(oh);
    sc_put(" r="); sc_num(rect[0]); sc_put(","); sc_num(rect[1]);
    sc_put(","); sc_num(rect[2]); sc_put(","); sc_num(rect[3]); sc_put("\n");
    if (dst && ow > 0 && oh > 0) dst[0] = 0x5A;
}

size_t fake_img_sixel_encode(const uint8_t *rgba, int w, int h, uint32_t bg, uint8_t *out, size_t cap);
size_t fake_img_sixel_encode(const uint8_t *rgba, int w, int h, uint32_t bg, uint8_t *out, size_t cap)
{
    sc_put("call img_sixel_encode "); sc_num(w); sc_put("x"); sc_num(h);
    sc_put(" bg="); sc_num(bg); sc_put(" cap_ok="); sc_num(cap >= 1048576u);
    sc_put(" px="); sc_num(rgba != nullptr); sc_put("\n");
    if (out && cap >= 4) { out[0] = 'S'; out[1] = 'X'; }
    return 42;
}

size_t fake_img_kitty_encode(const uint8_t *rgba, int w, int h, int cols, uint8_t *out, size_t cap);
size_t fake_img_kitty_encode(const uint8_t *rgba, int w, int h, int cols, uint8_t *out, size_t cap)
{
    sc_put("call img_kitty_encode "); sc_num(w); sc_put("x"); sc_num(h);
    sc_put(" cols="); sc_num(cols); sc_put(" cap_ok="); sc_num(cap >= 1048576u);
    sc_put(" px="); sc_num(rgba != nullptr); sc_put("\n");
    if (out && cap >= 4) { out[0] = 'K'; out[1] = 'T'; }
    return 77;
}

void *fake_mem_alloc(uint64_t size);
void *fake_mem_alloc(uint64_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return mem_alloc(size);
}

#define vim_kitty_pan fake_vim_kitty_pan
#define img_overlay_show fake_img_overlay_show
#define img_draw_rgba fake_img_draw_rgba
#define img_draw_quad fake_img_draw_quad
#define img_draw_braille fake_img_draw_braille
#define img_scale_rect fake_img_scale_rect
#define img_sixel_encode fake_img_sixel_encode
#define img_kitty_encode fake_img_kitty_encode
#define mem_alloc fake_mem_alloc
#include VP_SRC
#undef mem_alloc
#undef img_kitty_encode
#undef img_sixel_encode
#undef img_scale_rect
#undef img_draw_braille
#undef img_draw_quad
#undef img_draw_rgba
#undef img_overlay_show
#undef vim_kitty_pan

#ifdef __x86_64__
extern void ref_vim_draw_picture(ViewerDialog *v, ScreenBuffer *scr, const Theme *theme);
extern void ref_vim_place(ViewerDialog *v, ImgPlace *p);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

static void dump_v(const char *tag, const ViewerDialog *v)
{
    sc_put(tag);
    sc_put(" th="); sc_num(v->thumb != 0);
    sc_put(" tw="); sc_num(v->thumb_w); sc_put("x"); sc_num(v->thumb_h);
    sc_put(" enc="); sc_num(v->enc != 0); sc_put(" el="); sc_num((int64_t)v->enc_len);
    sc_put(" ek="); sc_num((int64_t)v->enc_key); sc_put(" ck="); sc_num((int64_t)v->img_cache_key);
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(80, 24);
    if (!scr) return 3;

    ViewerDialog *v = mem_alloc(sizeof(ViewerDialog));
    if (!v) return 4;
    mem_zero(v, sizeof *v);

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'V': {
            mem_free((void *)(uintptr_t)v->thumb);
            mem_free((void *)(uintptr_t)v->enc);
            mem_zero(v, sizeof *v);
            v->base.base.x = (int32_t)ui_parse_num(&a);
            v->base.base.y = (int32_t)ui_parse_num(&a);
            v->base.base.w = (int32_t)ui_parse_num(&a);
            v->base.base.h = (int32_t)ui_parse_num(&a);
            Image im = {0};
            im.w = (int32_t)ui_parse_num(&a);
            im.h = (int32_t)ui_parse_num(&a);
            im.px = g_rgba;
            mem_copy(v->img, &im, sizeof im);
            v->img_zoom = (uint32_t)ui_parse_num(&a);
            v->img_braille = (uint32_t)ui_parse_num(&a);
            v->img_pan_x = (int32_t)ui_parse_num(&a);
            v->img_pan_y = (int32_t)ui_parse_num(&a);
            break;
        }
        case 'Z': {
            v->img_zoom = (uint32_t)ui_parse_num(&a);
            v->img_braille = (uint32_t)ui_parse_num(&a);
            v->img_pan_x = (int32_t)ui_parse_num(&a);
            v->img_pan_y = (int32_t)ui_parse_num(&a);
            break;
        }
        case 'E': {
            g_proto = (int)ui_parse_num(&a);
            g_cw = (uint64_t)ui_parse_num(&a);
            g_ch = (uint64_t)ui_parse_num(&a);
            g_kitty_pan_ret = (int)ui_parse_num(&a);
            g_fail_alloc = (int)ui_parse_num(&a);
            break;
        }
        case 'D': {
            CALL(vim_draw_picture, v, scr, theme);
            dump_v("D", v);
            break;
        }
        case 'P': {
            struct { ImgPlace p; int32_t bw, bh, kc; } buf;
            mem_zero(&buf, sizeof buf);
            buf.bw = (int32_t)ui_parse_num(&a);
            buf.bh = (int32_t)ui_parse_num(&a);
            CALL(vim_place, v, &buf.p);
            sc_put("P rect="); sc_num(buf.p.x); sc_put(","); sc_num(buf.p.y);
            sc_put(","); sc_num(buf.p.w); sc_put(","); sc_num(buf.p.h);
            sc_put(" own="); sc_num(buf.p.owner == (uint64_t)(uintptr_t)v);
            sc_put(" len="); sc_num((int64_t)buf.p.len);
            sc_put("\n");
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    mem_free((void *)(uintptr_t)v->thumb);
    mem_free((void *)(uintptr_t)v->enc);
    mem_free(v);
    sc_flush();
    return 0;
}
