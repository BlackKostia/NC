/* Freestanding differential harness for src/ui/preview_mode.c versus frozen x86_64 asm
 * (tests/harness/preview_mode_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_preview.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_proto;
static uint64_t g_cw, g_ch;
static int g_elf_ret;

int term_img_proto(void) { return g_proto; }
CellPx term_cell_px(void) { return (CellPx){g_cw, g_ch}; }

int fake_img_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, const Theme *th);
int fake_img_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, const Theme *th)
{
    (void)sb; (void)th;
    sc_put("call img_preview_try_render tlen="); sc_num(pv->thumb_len); sc_put("\n");
    return 1;
}

int fake_elf_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, const Theme *th);
int fake_elf_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, const Theme *th)
{
    (void)pv; (void)sb; (void)th;
    sc_put("call elf_preview_try_render ret="); sc_num(g_elf_ret); sc_put("\n");
    return g_elf_ret;
}

#define img_preview_try_render fake_img_preview_try_render
#define elf_preview_try_render fake_elf_preview_try_render
#include PM_SRC
#undef elf_preview_try_render
#undef img_preview_try_render

#ifdef __x86_64__
extern ImgFit ref_img_box_pixels(int cols, int rows, int proto);
extern ImgFit ref_pv_box_pixels(PreviewPane *pv, int proto);
extern uint32_t ref_PreviewPane_thumb_req(PreviewPane *pv, PvThumbReq *out);
extern void ref_PreviewPane_cycle_mode(PreviewPane *pv);
extern int ref_pv_mode_dispatch(PreviewPane *pv, ScreenBuffer *scr, const Theme *th);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(80, 20);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;

    PreviewPane *pv = mem_alloc(sizeof(PreviewPane));
    if (!pv) return 4;
    mem_zero(pv, sizeof *pv);

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'E': {
            g_proto = (int)ui_parse_num(&a);
            g_cw = (uint64_t)ui_parse_num(&a);
            g_ch = (uint64_t)ui_parse_num(&a);
            g_elf_ret = (int)ui_parse_num(&a);
            break;
        }
        case 'B': {
            int cols = (int)ui_parse_num(&a), rows = (int)ui_parse_num(&a), pr = (int)ui_parse_num(&a);
            ImgFit r = CALL(img_box_pixels, cols, rows, pr);
            sc_put("B "); sc_num((int64_t)r.w); sc_put("x"); sc_num((int64_t)r.h); sc_put("\n");
            break;
        }
        case 'P': {
            mem_zero(pv, sizeof *pv);
            pv->app = (uint64_t)(uintptr_t)&g_app;
            pv->base.x = (int32_t)ui_parse_num(&a);
            pv->base.y = (int32_t)ui_parse_num(&a);
            pv->base.w = (int32_t)ui_parse_num(&a);
            pv->base.h = (int32_t)ui_parse_num(&a);
            pv->thumb_len = (uint32_t)ui_parse_num(&a);
            pv->view_mode = (uint32_t)ui_parse_num(&a);
            pv->is_binary = (uint32_t)ui_parse_num(&a);
            pv->scroll = 5;
            break;
        }
        case 'Q': {
            PvThumbReq req;
            mem_zero(&req, sizeof req);
            uint32_t dims = CALL(PreviewPane_thumb_req, pv, &req);
            sc_put("Q dims="); sc_num(dims); sc_put(" wh="); sc_num(req.w); sc_put("x"); sc_num(req.h);
            sc_put(" pr="); sc_num(req.proto); sc_put(" cols="); sc_num(req.cols);
            sc_put(" bg="); sc_num(req.bg); sc_put(" rm="); sc_num(pv->req_mode); sc_put("\n");
            ImgFit b = CALL(pv_box_pixels, pv, g_proto);
            sc_put("PB "); sc_num((int64_t)b.w); sc_put("x"); sc_num((int64_t)b.h); sc_put("\n");
            break;
        }
        case 'C': {
            g_app.need_redraw = 0;
            CALL(PreviewPane_cycle_mode, pv);
            sc_put("C vm="); sc_num(pv->view_mode); sc_put(" sc="); sc_num(pv->scroll);
            sc_put(" rd="); sc_num(g_app.need_redraw); sc_put("\n");
            break;
        }
        case 'D': {
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            int rc = CALL(pv_mode_dispatch, pv, scr, theme);
            sc_put("D rc="); sc_num(rc); sc_put("\n");
            ui_dump(scr, pv->base.y + pv->base.h - 1, 1);
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    mem_free(pv);
    sc_flush();
    return 0;
}
