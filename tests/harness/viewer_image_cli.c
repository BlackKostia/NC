/* Freestanding differential harness for src/ui/viewer_image.c versus frozen x86_64 asm
 * (tests/harness/viewer_image_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_detect_ret;
static int g_decode_ret;
static int g_decode_w;
static int g_decode_h;
static int g_decode_px_ok;
static uint8_t g_fake_px[16];
static uint8_t g_fake_file[16] = "PNGDATA";

void App_close_dialog(App *app, int result) { ui_log_call2("App_close_dialog", app == &g_app, result); }

int fake_img_detect(const uint8_t *d, size_t n, const char *path);
int fake_img_detect(const uint8_t *d, size_t n, const char *path)
{
    sc_put("call img_detect n="); sc_num((int64_t)n); sc_put(" d_ok="); sc_num(d == g_fake_file);
    sc_put(" p="); sc_esc(path); sc_put("\n");
    return g_detect_ret;
}

int fake_img_decode(const uint8_t *d, size_t n, int fmt, Image *out);
int fake_img_decode(const uint8_t *d, size_t n, int fmt, Image *out)
{
    (void)d;
    sc_put("call img_decode n="); sc_num((int64_t)n); sc_put(" fmt="); sc_num(fmt); sc_put("\n");
    if (g_decode_ret != 0) return g_decode_ret;
    out->w = g_decode_w;
    out->h = g_decode_h;
    out->px = g_decode_px_ok ? g_fake_px : nullptr;
    return 0;
}

void fake_img_free(Image *img);
void fake_img_free(Image *img)
{
    sc_put("call img_free w="); sc_num(img->w); sc_put(" h="); sc_num(img->h);
    sc_put(" px="); sc_num(img->px != nullptr); sc_put("\n");
    img->px = nullptr;
    img->w = 0;
    img->h = 0;
}

void fake_ViewerDialog_on_btn0(ViewerDialog *v);
void fake_ViewerDialog_on_btn0(ViewerDialog *v)
{
    v->hex_mode ^= 1;
    sc_put("call ViewerDialog_on_btn0 hex="); sc_num(v->hex_mode); sc_put("\n");
}

void fake_vim_draw_picture(ViewerDialog *v, ScreenBuffer *scr, const Theme *th);
void fake_vim_draw_picture(ViewerDialog *v, ScreenBuffer *scr, const Theme *th)
{
    (void)scr; (void)th;
    sc_put("call vim_draw_picture st="); sc_num((int32_t)v->img_state); sc_put("\n");
}

void fake_vim_draw_zoom_badge(ViewerDialog *v, ScreenBuffer *scr, const Theme *th);
void fake_vim_draw_zoom_badge(ViewerDialog *v, ScreenBuffer *scr, const Theme *th)
{
    (void)scr; (void)th;
    sc_put("call vim_draw_zoom_badge z="); sc_num(v->img_zoom); sc_put("\n");
}

void fake_vw_draw_img_scrollbars(ViewerDialog *v, ScreenBuffer *scr, const Theme *th);
void fake_vw_draw_img_scrollbars(ViewerDialog *v, ScreenBuffer *scr, const Theme *th)
{
    (void)scr; (void)th;
    sc_put("call vw_draw_img_scrollbars z="); sc_num(v->img_zoom); sc_put("\n");
}

#define img_detect fake_img_detect
#define img_decode fake_img_decode
#define img_free fake_img_free
#define ViewerDialog_on_btn0 fake_ViewerDialog_on_btn0
#define vim_draw_picture fake_vim_draw_picture
#define vim_draw_zoom_badge fake_vim_draw_zoom_badge
#define vw_draw_img_scrollbars fake_vw_draw_img_scrollbars
#include VI_SRC
#undef vw_draw_img_scrollbars
#undef vim_draw_zoom_badge
#undef vim_draw_picture
#undef ViewerDialog_on_btn0
#undef img_free
#undef img_decode
#undef img_detect

#ifdef __x86_64__
extern void ref_ViewerDialog_set_mode(ViewerDialog *v, int mode);
extern void ref_ViewerDialog_render_image(ViewerDialog *v, ScreenBuffer *scr);
extern int ref_viewer_mode_key(ViewerDialog *v, Event *e);
extern void ref_viewer_img_free(ViewerDialog *v);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

static void dump_v(const char *tag, const ViewerDialog *v)
{
    sc_put(tag);
    sc_put(" im="); sc_num(v->img_mode);
    sc_put(" st="); sc_num((int32_t)v->img_state);
    sc_put(" hex="); sc_num(v->hex_mode);
    sc_put(" th="); sc_num(v->thumb != 0);
    sc_put(" enc="); sc_num(v->enc != 0);
    sc_put(" rd="); sc_num(g_app.need_redraw);
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

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;

    ViewerDialog *v = mem_alloc(sizeof(ViewerDialog));
    if (!v) return 4;
    mem_zero(v, sizeof *v);

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'V': {
            mem_free((void *)(uintptr_t)v->thumb);
            mem_free((void *)(uintptr_t)v->enc);
            mem_zero(v, sizeof *v);
            v->base.base.x = 4; v->base.base.y = 2; v->base.base.w = 60; v->base.base.h = 16;
            int has_app = (int)ui_parse_num(&a);
            v->base.app = has_app ? (uint64_t)(uintptr_t)&g_app : 0;
            v->base.title = (uint64_t)(uintptr_t)"img.png";
            v->data = (uint64_t)(uintptr_t)g_fake_file;
            v->data_len = 7;
            (void)str_copy((char *)v->path, "/tmp/img.png", 64);
            v->hex_mode = (uint32_t)ui_parse_num(&a);
            v->img_mode = (uint32_t)ui_parse_num(&a);
            v->img_state = (uint32_t)ui_parse_num(&a);
            g_app.need_redraw = 0;
            break;
        }
        case 'D': {
            g_detect_ret = (int)ui_parse_num(&a);
            g_decode_ret = (int)ui_parse_num(&a);
            g_decode_w = (int)ui_parse_num(&a);
            g_decode_h = (int)ui_parse_num(&a);
            g_decode_px_ok = (int)ui_parse_num(&a);
            break;
        }
        case 'S': {
            int mode = (int)ui_parse_num(&a);
            g_app.need_redraw = 0;
            CALL(ViewerDialog_set_mode, v, mode);
            dump_v("S", v);
            break;
        }
        case 'K': {
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = CALL(viewer_mode_key, v, &evt);
                sc_put("K rc="); sc_num(rc); sc_put(" ");
                dump_v("K", v);
            }
            break;
        }
        case 'R': {
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALL(ViewerDialog_render_image, v, scr);
            ui_dump(scr, v->base.base.y, v->base.base.h);
            break;
        }
        case 'F': {
            v->thumb = (uint64_t)(uintptr_t)mem_alloc(32);
            v->enc = (uint64_t)(uintptr_t)mem_alloc(32);
            CALL(viewer_img_free, v);
            dump_v("F", v);
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
