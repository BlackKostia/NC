/* src/ui/viewer_zoom_rect.c - ViewerDialog image zoom crop geometry, zoom badge & Kitty pan
 * (freestanding C23; replaces viewer_zoom_rect.s, kept as tests/harness/viewer_zoom_rect_reference.s). */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static uint32_t vz_axis_crop(int img_dim, int box_dim, uint32_t zoom,
                             uint32_t cur_pan, int *out_t, int *out_s)
{
    if (img_dim <= 0) img_dim = 1;
    if (box_dim <= 0) box_dim = 1;

    int t = (int)(((uint32_t)img_dim * zoom) / 100u);
    if (t == 0) t = 1;
    if (t > box_dim) t = box_dim;
    *out_t = t;

    int s = (int)(((uint32_t)t * 100u) / zoom);
    if (s == 0) s = 1;
    if (s > img_dim) s = img_dim;
    *out_s = s;

    int max_pan = img_dim - s;
    int p = (int32_t)cur_pan;
    if (p < 0) p = 0;
    if (p > max_pan) p = max_pan;
    return (uint32_t)p;
}

void vim_zoom_rect(ViewerDialog *v, int box_w, int box_h, int upscale,
                   int *out_tw, int *out_th, int *out_rect)
{
    v->img_box_w = (uint32_t)box_w;
    v->img_box_h = (uint32_t)box_h;
    const Image *im = (const Image *)v->img;

    if (v->img_zoom == 0) {
        uint32_t tw = (uint32_t)im->w;
        uint32_t th = (uint32_t)im->h;
        if (upscale != 0 || tw > (uint32_t)box_w || th > (uint32_t)box_h) {
            ImgFit f = img_fit(im->w, im->h, box_w, box_h);
            tw = (uint32_t)f.w;
            th = (uint32_t)f.h;
        }
        *out_tw = (int)tw;
        *out_th = (int)th;
        out_rect[0] = 0;
        out_rect[1] = 0;
        out_rect[2] = im->w;
        out_rect[3] = im->h;
        return;
    }

    v->img_pan_x = vz_axis_crop(im->w, box_w, v->img_zoom, v->img_pan_x, out_tw, &out_rect[2]);
    out_rect[0] = (int)v->img_pan_x;
    v->img_pan_y = vz_axis_crop(im->h, box_h, v->img_zoom, v->img_pan_y, out_th, &out_rect[3]);
    out_rect[1] = (int)v->img_pan_y;
}

void vim_draw_zoom_badge(ViewerDialog *v, ScreenBuffer *scr, const Theme *th)
{
    if (v->img_state != 1) return;
    const Image *im = (const Image *)v->img;
    char buf[56];
    char *p = buf;
    p += u64_to_dec((uint32_t)im->w, p);
    *p++ = 'x';
    p += u64_to_dec((uint32_t)im->h, p);
    *p++ = ' ';
    *p++ = '[';
    if (v->img_zoom != 0) {
        p += u64_to_dec(v->img_zoom, p);
        *p++ = '%';
    } else {
        p += str_copy(p, i18n_get()->s[LS_img_fit], 24);
    }
    if (v->img_braille != 0) {
        *p++ = ' ';
        *p++ = 'B';
    }
    *p++ = ']';
    *p = '\0';

    ScreenBuffer_set_pen(scr, th->accent, th->dialog_bg, ATTR_NONE);
    int bw = utf8_display_width(buf);
    int x = v->base.base.x + v->base.base.w - bw - 2;
    int y = v->base.base.y + v->base.base.h - 2;
    (void)ScreenBuffer_draw_text(scr, x, y, buf, bw);
}

int vim_kitty_pan(ViewerDialog *v, int proto, ImgPlace *p)
{
    if (proto != IMG_PROTO_KITTY) return 0;
    if (v->img_zoom == 0) {
        img_overlay_kitty_mark(nullptr);
        return 0;
    }

    const Image *im = (const Image *)v->img;
    if (im->w <= 0 || im->h <= 0) return 0;
    uint64_t px_cnt = (uint64_t)(uint32_t)im->w * (uint64_t)(uint32_t)im->h;
    if (px_cnt > 16777216u) return 0;

    const int32_t *box = (const int32_t *)((const uint8_t *)p + sizeof(ImgPlace));
    int tw = 0, th = 0, rect[4];
    vim_zoom_rect(v, box[0], box[1], 0, &tw, &th, rect);

    if (!img_overlay_kitty_ready(im->px)) {
        size_t cap = (size_t)px_cnt * 8u + 65536u;
        uint8_t *tmp = mem_alloc(cap);
        if (!tmp) return 0;
        size_t n = img_kitty_encode(im->px, im->w, im->h, -1, tmp, cap);
        if (n != 0) {
            (void)sys_write_all(STDOUT_FD, tmp, n);
            img_overlay_kitty_mark(im->px);
        }
        mem_free(tmp);
        if (n == 0) return 0;
    }

    const uint64_t kpan = 0x4B50414Eull;
    if (v->enc == 0 || v->enc_key != kpan) {
        mem_free((void *)(uintptr_t)v->enc);
        void *enc = mem_alloc(128);
        v->enc = (uint64_t)(uintptr_t)enc;
        if (!enc) return 0;
        v->enc_key = kpan;
    }

    v->thumb_w = (uint32_t)tw;
    v->thumb_h = (uint32_t)th;
    v->img_cache_key = ((uint64_t)v->img_zoom << 32) |
                       ((uint64_t)(v->img_pan_y & 0xFFFFu) << 16) |
                       (uint64_t)(v->img_pan_x & 0xFFFFu);
    vim_place(v, p);
    size_t plen = img_kitty_place((uint8_t *)(uintptr_t)v->enc, rect, (int)p->w, (int)p->h);
    v->enc_len = plen;
    p->len = plen;
    img_overlay_show(p);
    return 1;
}
