/* Freestanding differential harness for src/ui/img_preview_api.c versus frozen x86_64 asm
 * (tests/harness/img_preview_api_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   B <bpx_w> <bpx_h>                               set fake pv_box_pixels() return
 *   T <x> <y> <w> <h> <tlen> <tmode> <tgen> <tw> <th>   call img_preview_try_render + dump calls/screen */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_preview.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static PreviewPane g_pv;
static uint8_t g_thumb[128];
static uint32_t g_bpx_w = 240, g_bpx_h = 180;

ImgFit fake_pv_box_pixels(PreviewPane *pv, int proto);
ImgFit fake_pv_box_pixels(PreviewPane *pv, int proto)
{
    sc_put("call pv_box_pixels eq="); sc_num(pv == &g_pv);
    sc_put(" proto="); sc_num(proto); sc_put("\n");
    return (ImgFit){g_bpx_w, g_bpx_h};
}

void fake_img_draw_quad(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v);
void fake_img_draw_quad(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
{
    sc_put("call draw_quad scr="); sc_num(scr != nullptr);
    sc_put(" box="); sc_num(bx); sc_put(","); sc_num(by); sc_put(","); sc_num(bw); sc_put(","); sc_num(bh);
    sc_put(" data_eq="); sc_num(v->rgba == g_thumb + IMG_THUMB_HDR);
    sc_put(" iw="); sc_num(v->iw); sc_put(" ih="); sc_num(v->ih);
    sc_put(" bg="); ui_put_color(v->bg); sc_put("\n");
}

void fake_img_draw_rgba(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v);
void fake_img_draw_rgba(ScreenBuffer *scr, int bx, int by, int bw, int bh, const ImgView *v)
{
    sc_put("call draw_rgba scr="); sc_num(scr != nullptr);
    sc_put(" box="); sc_num(bx); sc_put(","); sc_num(by); sc_put(","); sc_num(bw); sc_put(","); sc_num(bh);
    sc_put(" data_eq="); sc_num(v->rgba == g_thumb + IMG_THUMB_HDR);
    sc_put(" iw="); sc_num(v->iw); sc_put(" ih="); sc_num(v->ih);
    sc_put(" bg="); ui_put_color(v->bg); sc_put("\n");
}

void fake_img_overlay_show(const ImgPlace *p);
void fake_img_overlay_show(const ImgPlace *p)
{
    sc_put("call overlay_show own="); sc_num(p->owner == (uint64_t)(uintptr_t)&g_pv);
    sc_put(" data="); sc_num(p->data == (uint64_t)(uintptr_t)(g_thumb + IMG_THUMB_HDR));
    sc_put(" len="); sc_num((int64_t)p->len);
    sc_put(" key="); sc_num((int64_t)p->key);
    sc_put(" rect="); sc_num(p->x); sc_put(","); sc_num(p->y);
    sc_put(","); sc_num(p->w); sc_put(","); sc_num(p->h); sc_put("\n");
}

#define pv_box_pixels fake_pv_box_pixels
#define img_draw_quad fake_img_draw_quad
#define img_draw_rgba fake_img_draw_rgba
#define img_overlay_show fake_img_overlay_show
#include IPA_SRC
#undef img_overlay_show
#undef img_draw_rgba
#undef img_draw_quad
#undef pv_box_pixels

#ifdef __x86_64__
extern int ref_img_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, const Theme *th);
#define CALL_IPA(p, s, t) (g_ref ? ref_img_preview_try_render(p, s, t) : img_preview_try_render(p, s, t))
#else
#define CALL_IPA(p, s, t) img_preview_try_render(p, s, t)
#endif

static bool g_ref;

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(64, 16);
    if (!scr) return 3;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        if (line[0] == 'B') {
            g_bpx_w = (uint32_t)ui_parse_num(&a);
            g_bpx_h = (uint32_t)ui_parse_num(&a);
        } else if (line[0] == 'T') {
            mem_zero(&g_pv, sizeof g_pv);
            mem_zero(g_thumb, sizeof g_thumb);
            g_pv.base.x = (int32_t)ui_parse_num(&a);
            g_pv.base.y = (int32_t)ui_parse_num(&a);
            g_pv.base.w = (int32_t)ui_parse_num(&a);
            g_pv.base.h = (int32_t)ui_parse_num(&a);
            g_pv.thumb_len = (uint32_t)ui_parse_num(&a);
            g_pv.thumb_mode = (uint32_t)ui_parse_num(&a);
            g_pv.thumb_gen = (uint32_t)ui_parse_num(&a);
            uint16_t tw = (uint16_t)ui_parse_num(&a);
            uint16_t th = (uint16_t)ui_parse_num(&a);
            g_thumb[12] = (uint8_t)(tw & 0xFF); g_thumb[13] = (uint8_t)(tw >> 8);
            g_thumb[14] = (uint8_t)(th & 0xFF); g_thumb[15] = (uint8_t)(th >> 8);
            g_pv.thumb_ptr = (uint64_t)(uintptr_t)g_thumb;

            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            int rc = CALL_IPA(&g_pv, scr, theme);
            sc_put("T rc="); sc_num(rc); sc_put("\n");
            if (g_pv.base.y + 3 < scr->height) ui_dump(scr, g_pv.base.y + 3, 1);
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
