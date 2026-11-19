/* src/ui/viewer_pixels.c - ViewerDialog picture output: scaled thumbnail cache, quadrant /
 * half-block / Braille cell drawing, and Sixel / Kitty overlay encoding and placement
 * (freestanding C23; replaces src/ui/viewer_pixels.s, kept as tests/harness/viewer_pixels_reference.s). */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"

typedef struct VimPlaceBuf {
    ImgPlace place;
    int32_t box_w;
    int32_t box_h;
    int32_t kcols;
} VimPlaceBuf;
_Static_assert(offsetof(VimPlaceBuf, box_w) == 48 && offsetof(VimPlaceBuf, box_h) == 52 &&
               offsetof(VimPlaceBuf, kcols) == 56, "VimPlaceBuf tail offsets shared with vim_kitty_pan");

static void vim_block_box(ScreenBuffer *scr, const ViewerDialog *v, int proto, const ImgView *iv)
{
    int bx = v->base.base.x + 1, by = v->base.base.y + 1;
    int bw = v->base.base.w - 2, bh = v->base.base.h - 3;
    if (v->img_zoom != 0) {
        int cw = (int)v->thumb_w;
        if (proto != IMG_PROTO_HALF) cw = (int)(((uint32_t)cw + 1u) >> 1);
        if (cw < bw) {
            bx += (bw - cw) >> 1;
            bw = cw;
        }
        int ch = (int)v->thumb_h;
        if (v->img_braille) ch = (int)(((uint32_t)ch + 3u) >> 2);
        else ch = (int)(((uint32_t)ch + 1u) >> 1);
        if (ch < bh) {
            by += (bh - ch) >> 1;
            bh = ch;
        }
    }
    if (v->img_braille) img_draw_braille(scr, bx, by, bw, bh, iv);
    else if (proto == IMG_PROTO_HALF) img_draw_rgba(scr, bx, by, bw, bh, iv);
    else img_draw_quad(scr, bx, by, bw, bh, iv);
}

__attribute__((noinline))
static int vim_fit_thumb(ViewerDialog *v, int pw, int ph, int upscale)
{
    int tw = 0, th = 0, rect[4];
    vim_zoom_rect(v, pw, ph, upscale, &tw, &th, rect);
    uint64_t key = ((uint64_t)v->img_zoom << 32) |
                   ((uint64_t)(v->img_pan_y & 0xFFFFu) << 16) |
                   (uint64_t)(v->img_pan_x & 0xFFFFu);
    if (v->thumb && tw == (int)v->thumb_w && th == (int)v->thumb_h && key == v->img_cache_key)
        return 1;
    mem_free((void *)(uintptr_t)v->thumb);
    v->thumb = 0;
    v->thumb_w = 0;
    v->thumb_h = 0;
    if (tw <= 0 || th <= 0) return 0;
    uint64_t px = (uint64_t)(uint32_t)tw * (uint64_t)(uint32_t)th;
    if (px > IMG_MAX_PIXELS) return 0;
    uint8_t *buf = mem_alloc(px * 4u);
    v->thumb = (uint64_t)(uintptr_t)buf;
    if (!buf) return 0;
    v->thumb_w = (uint32_t)tw;
    v->thumb_h = (uint32_t)th;
    v->img_cache_key = key;
    Image im;
    mem_copy(&im, v->img, sizeof im);
    img_scale_rect(&im, buf, tw, th, rect);
    return 1;
}

static size_t vim_encode_into(const ViewerDialog *v, int proto, const VimPlaceBuf *box, uint32_t bg, size_t cap)
{
    const uint8_t *px = (const uint8_t *)(uintptr_t)v->thumb;
    uint8_t *out = (uint8_t *)(uintptr_t)v->enc;
    int tw = (int)v->thumb_w, th = (int)v->thumb_h;
    if (proto != IMG_PROTO_KITTY)
        return img_sixel_encode(px, tw, th, bg & 0xFFFFFFu, out, cap);
    int kc = box->kcols;
    if (kc != 0) {
        if (box->box_w <= 0) return 0;
        kc = (int)(((uint64_t)(uint32_t)tw * (uint64_t)(uint32_t)kc + (uint64_t)(uint32_t)box->box_w - 1u) /
                   (uint64_t)(uint32_t)box->box_w);
    }
    return img_kitty_encode(px, tw, th, kc, out, cap);
}

static size_t vim_encode(ViewerDialog *v, int proto, const VimPlaceBuf *box, uint32_t bg)
{
    uint64_t key = ((uint64_t)(uint32_t)v->thumb_h << 32) |
                   ((uint64_t)(uint32_t)(((uint32_t)v->thumb_w << 8) | (uint32_t)proto));
    if (v->enc && key == v->enc_key) return (size_t)v->enc_len;
    mem_free((void *)(uintptr_t)v->enc);
    uint64_t cap = (uint64_t)(uint32_t)v->thumb_w * (uint64_t)(uint32_t)v->thumb_h * 8u + 1048576u;
    uint8_t *enc = mem_alloc(cap);
    v->enc = (uint64_t)(uintptr_t)enc;
    if (!enc) {
        v->enc_len = 0;
        return 0;
    }
    v->enc_key = key;
    size_t len = vim_encode_into(v, proto, box, bg, (size_t)cap);
    v->enc_len = len;
    return len;
}

void vim_place(ViewerDialog *v, ImgPlace *p)
{
    const int32_t *box = (const int32_t *)((const uint8_t *)p + sizeof(ImgPlace));
    int bw = box[0] > 0 ? box[0] : 1;
    int bh = box[1] > 0 ? box[1] : 1;
    p->owner = (uint64_t)(uintptr_t)v;
    p->data = v->enc;
    p->len = v->enc_len;
    p->key = v->enc_key ^ v->img_cache_key ^ v->enc;

    int cols = v->base.base.w - 2;
    uint32_t pw = (uint32_t)(((uint64_t)(uint32_t)v->thumb_w * (uint64_t)(uint32_t)cols + (uint64_t)(uint32_t)bw - 1u) /
                             (uint64_t)(uint32_t)bw);
    p->w = pw;
    p->x = (uint32_t)(v->base.base.x + 1 + ((cols - (int)pw) >> 1));

    int rows = v->base.base.h - 3;
    uint32_t ph = (uint32_t)(((uint64_t)(uint32_t)v->thumb_h * (uint64_t)(uint32_t)rows + (uint64_t)(uint32_t)bh - 1u) /
                             (uint64_t)(uint32_t)bh);
    p->h = ph;
    p->y = (uint32_t)(v->base.base.y + 1 + ((rows - (int)ph) >> 1));
}

void vim_draw_picture(ViewerDialog *v, ScreenBuffer *scr, const Theme *theme)
{
    int proto = term_img_proto();
    int cols = v->base.base.w - 2;
    int rows = v->base.base.h - 3;
    ImgFit bpx = img_box_pixels(cols, rows, proto);
    int bw = (int)bpx.w, bh = (int)bpx.h, kcols = 0;
    if (proto == IMG_PROTO_KITTY && cols > 0 && rows > 0) {
        CellPx cp = term_cell_px();
        if (cp.w == 0 || cp.h == 0) kcols = cols > 255 ? 255 : cols;
    }
    if (proto < IMG_PROTO_SIXEL && v->img_braille)
        bh = (int)((uint32_t)rows << 2);

    VimPlaceBuf buf;
    buf.box_w = bw;
    buf.box_h = bh;
    buf.kcols = kcols;

    if (vim_kitty_pan(v, proto, &buf.place)) return;
    if (!vim_fit_thumb(v, bw, bh, proto < IMG_PROTO_SIXEL ? 1 : 0)) return;
    if (proto < IMG_PROTO_SIXEL) {
        ImgView iv = {(const uint8_t *)(uintptr_t)v->thumb, (int32_t)v->thumb_w,
                      (int32_t)v->thumb_h, theme->dialog_bg};
        vim_block_box(scr, v, proto, &iv);
        return;
    }
    if (!vim_encode(v, proto, &buf, theme->dialog_bg)) return;
    vim_place(v, &buf.place);
    img_overlay_show(&buf.place);
}
