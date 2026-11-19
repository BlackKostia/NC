/* Freestanding differential harness for src/ui/viewer_scrollbar.c versus frozen x86_64 asm
 * (tests/harness/viewer_scrollbar_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   W <x> <y> <w> <h>                                    set ViewerDialog widget rect
 *   I <state> <zoom> <iw> <ih> <bw> <bh> <px> <py>       set image state & draw vw_draw_img_scrollbars
 *   T <dlen> <vis> <hex> <top_or_row> <end_off>          set text/hex state & draw vw_draw_text_scrollbar
 *   M <kind> <btn> <x> <y> [mods]                        dispatch vw_img_scrollbar_mouse & print state */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static ViewerDialog g_vd;

void fake_vz_invalidate(ViewerDialog *v);
void fake_vz_invalidate(ViewerDialog *v)
{
    ui_log_call2("vz_invalidate", v == &g_vd, 0);
}

#define vz_invalidate fake_vz_invalidate
#include VSB_SRC
#undef vz_invalidate

#ifdef __x86_64__
extern void ref_vw_draw_img_scrollbars(ViewerDialog *v, ScreenBuffer *scr, const Theme *th);
extern void ref_vw_draw_text_scrollbar(ViewerDialog *v, ScreenBuffer *scr, const Theme *th, int64_t end_off);
extern int ref_vw_img_scrollbar_mouse(ViewerDialog *v, Event *e);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(40, 16);
    if (!scr) return 3;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'W':
            mem_zero(&g_vd, sizeof g_vd);
            g_vd.base.base.x = (int32_t)ui_parse_num(&a);
            g_vd.base.base.y = (int32_t)ui_parse_num(&a);
            g_vd.base.base.w = (int32_t)ui_parse_num(&a);
            g_vd.base.base.h = (int32_t)ui_parse_num(&a);
            break;
        case 'I': {
            g_vd.img_state = (uint32_t)ui_parse_num(&a);
            g_vd.img_zoom = (uint32_t)ui_parse_num(&a);
            Image *im = (Image *)g_vd.img;
            im->w = (int32_t)ui_parse_num(&a);
            im->h = (int32_t)ui_parse_num(&a);
            g_vd.img_box_w = (uint32_t)ui_parse_num(&a);
            g_vd.img_box_h = (uint32_t)ui_parse_num(&a);
            g_vd.img_pan_x = (uint32_t)ui_parse_num(&a);
            g_vd.img_pan_y = (uint32_t)ui_parse_num(&a);
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALLV(vw_draw_img_scrollbars, &g_vd, scr, theme);
            sc_put("I\n");
            ui_dump(scr, g_vd.base.base.y, g_vd.base.base.h);
            break;
        }
        case 'T': {
            g_vd.data_len = (uint64_t)ui_parse_num(&a);
            g_vd.vis_rows = (uint32_t)ui_parse_num(&a);
            g_vd.hex_mode = (uint32_t)ui_parse_num(&a);
            uint64_t pos = (uint64_t)ui_parse_num(&a);
            int64_t end_off = ui_parse_num(&a);
            g_vd.top_off = pos;
            g_vd.hex_row = pos;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALLV(vw_draw_text_scrollbar, &g_vd, scr, theme, end_off);
            sc_put("T\n");
            ui_dump(scr, g_vd.base.base.y, g_vd.base.base.h);
            break;
        }
        case 'M': {
            Event evt;
            if (ui_parse_event(line, &evt)) {
                int rc = CALL(vw_img_scrollbar_mouse, &g_vd, &evt);
                sc_put("M rc="); sc_num(rc);
                sc_put(" drag="); sc_num(g_vd.img_sb_drag);
                sc_put(" px="); sc_num(g_vd.img_pan_x);
                sc_put(" py="); sc_num(g_vd.img_pan_y);
                sc_put("\n");
            }
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
