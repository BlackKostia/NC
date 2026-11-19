/* src/ui/img_preview_api.c - Image preview placement & cell/overlay dispatch
 * (freestanding C23; replaces img_preview_api.s, kept as tests/harness/img_preview_api_reference.s). */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_preview.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

ImgFit pv_box_pixels(PreviewPane *pv, int proto); /* src/ui/preview_mode.s */

static void iptr_draw_unsup(const PreviewPane *pv, ScreenBuffer *sb, const Theme *th)
{
    ScreenBuffer_set_pen(sb, th->warn_fg, th->surface, ATTR_NONE);
    const char *msg = i18n_get()->s[LS_img_unsup];
    (void)ScreenBuffer_draw_text(sb, pv->base.x + 2, pv->base.y + 3, msg, pv->base.w - 4);
}

static int iptr_place(PreviewPane *pv, const uint8_t *hdr, uint32_t mode, ImgPlace *out)
{
    out->owner = (uint64_t)(uintptr_t)pv;
    out->data = (uint64_t)(uintptr_t)(hdr + IMG_THUMB_HDR);
    out->len = (uint64_t)(pv->thumb_len - IMG_THUMB_HDR);
    out->key = (uint64_t)pv->thumb_gen;

    uint32_t tw = load_le16(hdr + 12);
    uint32_t th_px = load_le16(hdr + 14);
    ImgFit bpx = pv_box_pixels(pv, (int)mode);
    uint32_t box_px_w = (uint32_t)bpx.w;
    uint32_t box_px_h = (uint32_t)bpx.h;
    int32_t box_cols = pv->base.w - 2;
    int32_t box_rows = pv->base.h - 5;
    if (box_px_w == 0 || box_px_h == 0 || box_cols <= 0 || box_rows <= 0) return 0;

    uint32_t pw = (tw * (uint32_t)box_cols + box_px_w - 1u) / box_px_w;
    uint32_t ph = (th_px * (uint32_t)box_rows + box_px_h - 1u) / box_px_h;
    out->w = pw;
    out->h = ph;
    out->x = (uint32_t)(pv->base.x + 1 + ((box_cols - (int32_t)pw) >> 1));
    out->y = (uint32_t)(pv->base.y + 3 + ((box_rows - (int32_t)ph) >> 1));
    return 1;
}

int img_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, const Theme *th)
{
    if (pv->thumb_len < IMG_THUMB_HDR) return 0;
    const uint8_t *hdr = (const uint8_t *)(uintptr_t)pv->thumb_ptr;
    if (!hdr) return 0;

    uint16_t tw = load_le16(hdr + 12);
    uint16_t th_px = load_le16(hdr + 14);
    if (tw == 0) {
        iptr_draw_unsup(pv, sb, th);
        return 1;
    }

    uint32_t mode = pv->thumb_mode & 0xFFu;
    if (mode >= IMG_PROTO_SIXEL) {
        if (pv->thumb_len < IMG_THUMB_HDR + 16) {
            iptr_draw_unsup(pv, sb, th);
            return 1;
        }
        ImgPlace place;
        if (iptr_place(pv, hdr, mode, &place)) img_overlay_show(&place);
        return 1;
    }

    ImgView v = {hdr + IMG_THUMB_HDR, (int32_t)tw, (int32_t)th_px, th->surface};
    int bx = pv->base.x + 1;
    int by = pv->base.y + 3;
    int bw = pv->base.w - 2;
    int bh = pv->base.h - 5;
    if (mode == IMG_PROTO_HALF) img_draw_rgba(sb, bx, by, bw, bh, &v);
    else img_draw_quad(sb, bx, by, bw, bh, &v);
    return 1;
}
