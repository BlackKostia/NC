/* Freestanding differential harness for src/ui/{viewer_zoom,viewer_zoom_rect}.c versus frozen x86_64 asm
 * (tests/harness/viewer_zoom{,_rect}_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   S <mode> <state> <iw> <ih> <bw> <bh> <zoom> <px> <py> <braille>  configure ViewerDialog
 *   K <key> <mods> [lat]                    vim_zoom_key + dump state
 *   M <kind> <btn> <x> <y> [mods]           vim_zoom_mouse + dump state
 *   R <bw> <bh> <upscale>                   vim_zoom_rect + dump out_tw, out_th, rect, pan
 *   B <x> <y> <w> <h>                       vim_draw_zoom_badge + ui_dump
 *   P <proto> <box_w> <box_h> <ready> <fail_alloc>   vim_kitty_pan + dump calls & state */
#include "duop_classes.h"
#include "duop_img.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static ViewerDialog g_vd;
static uint8_t g_px[64];
static char *g_env[2] = {"DISPLAY=:0", nullptr};
static int g_kitty_ready;
static int g_fail_alloc;
static int g_sb_mouse_ret;

int fake_open_external(const char *path, char **envp);
int fake_open_external(const char *path, char **envp)
{
    sc_put("call open_external path="); sc_put(path);
    sc_put(" env_eq="); sc_num(envp == g_env); sc_put("\n");
    return 0;
}

int fake_sb_mouse(ViewerDialog *v, Event *e);
int fake_sb_mouse(ViewerDialog *v, Event *e)
{
    sc_put("call sb_mouse eq="); sc_num(v == &g_vd);
    sc_put(" kind="); sc_num(e->mouse_kind); sc_put("\n");
    return g_sb_mouse_ret;
}

int fake_kitty_ready(const void *pixels);
int fake_kitty_ready(const void *pixels)
{
    sc_put("call kitty_ready eq="); sc_num(pixels == g_px); sc_put("\n");
    return g_kitty_ready;
}

void fake_kitty_mark(const void *pixels);
void fake_kitty_mark(const void *pixels)
{
    sc_put("call kitty_mark eq="); sc_num(pixels == g_px ? 1 : (pixels == nullptr ? 0 : 2)); sc_put("\n");
    g_kitty_ready = (pixels == g_px);
}

void fake_overlay_show(const ImgPlace *p);
void fake_overlay_show(const ImgPlace *p)
{
    sc_put("call overlay_show len="); sc_num((int64_t)p->len);
    sc_put(" w="); sc_num(p->w); sc_put(" h="); sc_num(p->h);
    if (p->data && p->len > 0 && p->len < 128) {
        sc_put(" |");
        char tmp[128];
        mem_copy(tmp, (const void *)(uintptr_t)p->data, (size_t)p->len);
        tmp[p->len] = 0;
        sc_esc(tmp);
        sc_put("|");
    }
    sc_put("\n");
}

void fake_vim_place(ViewerDialog *v, ImgPlace *p);
void fake_vim_place(ViewerDialog *v, ImgPlace *p)
{
    p->owner = (uint64_t)(uintptr_t)v;
    p->data = v->enc;
    p->x = 3; p->y = 2; p->w = 20; p->h = 10;
    sc_put("call vim_place tw="); sc_num(v->thumb_w); sc_put(" th="); sc_num(v->thumb_h); sc_put("\n");
}

intptr_t fake_write_all(int fd, const void *buf, size_t len);
intptr_t fake_write_all(int fd, const void *buf, size_t len)
{
    ui_log_call_bytes("write_all", fd, buf, len);
    return (intptr_t)len;
}

void *fake_mem_alloc(size_t sz);
void *fake_mem_alloc(size_t sz)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return mem_alloc(sz);
}

size_t fake_kitty_encode(const uint8_t *rgba, int w, int h, int cols, uint8_t *out, size_t cap);
size_t fake_kitty_encode(const uint8_t *rgba, int w, int h, int cols, uint8_t *out, size_t cap)
{
    sc_put("call kitty_encode eq="); sc_num(rgba == g_px);
    sc_put(" w="); sc_num(w); sc_put(" h="); sc_num(h);
    sc_put(" cols="); sc_num(cols); sc_put(" cap="); sc_num((int64_t)cap); sc_put("\n");
    static const char msg[] = "KTX";
    if (cap < 3) return 0;
    mem_copy(out, msg, 3);
    return 3;
}

#define sys_open_external fake_open_external
#define vw_img_scrollbar_mouse fake_sb_mouse
#include VZ_SRC
#undef vw_img_scrollbar_mouse
#undef sys_open_external

#define img_overlay_kitty_ready fake_kitty_ready
#define img_overlay_kitty_mark fake_kitty_mark
#define img_overlay_show fake_overlay_show
#define vim_place fake_vim_place
#define sys_write_all fake_write_all
#define mem_alloc fake_mem_alloc
#define img_kitty_encode fake_kitty_encode
#include VZR_SRC
#undef img_kitty_encode
#undef mem_alloc
#undef sys_write_all
#undef vim_place
#undef img_overlay_show
#undef img_overlay_kitty_mark
#undef img_overlay_kitty_ready

#ifdef __x86_64__
extern int ref_vim_zoom_key(ViewerDialog *v, Event *e);
extern int ref_vim_zoom_mouse(ViewerDialog *v, Event *e);
extern void ref_vim_zoom_rect(ViewerDialog *v, int bw, int bh, int up, int *tw, int *th, int *rect);
extern void ref_vim_draw_zoom_badge(ViewerDialog *v, ScreenBuffer *scr, const Theme *th);
extern int ref_vim_kitty_pan(ViewerDialog *v, int proto, ImgPlace *p);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

static void dump_state(const char *tag, int rc)
{
    sc_put(tag); sc_put(" rc="); sc_num(rc);
    sc_put(" z="); sc_num(g_vd.img_zoom);
    sc_put(" px="); sc_num(g_vd.img_pan_x);
    sc_put(" py="); sc_num(g_vd.img_pan_y);
    sc_put(" br="); sc_num(g_vd.img_braille);
    sc_put(" ck="); sc_num((int64_t)g_vd.img_cache_key);
    sc_put(" ek="); sc_num((int64_t)g_vd.enc_key);
    sc_put(" dr="); sc_num(g_app.need_redraw);
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(60, 8);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.envp = (uint64_t)(uintptr_t)g_env;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'S': {
            if (g_vd.enc) mem_free((void *)(uintptr_t)g_vd.enc);
            mem_zero(&g_vd, sizeof g_vd);
            g_vd.base.app = (uint64_t)(uintptr_t)&g_app;
            (void)str_copy((char *)g_vd.path, "/tmp/pic.png", sizeof g_vd.path);
            Image *im = (Image *)g_vd.img;
            im->px = g_px;
            g_vd.img_mode = (uint32_t)ui_parse_num(&a);
            g_vd.img_state = (uint32_t)ui_parse_num(&a);
            im->w = (int32_t)ui_parse_num(&a);
            im->h = (int32_t)ui_parse_num(&a);
            g_vd.img_box_w = (uint32_t)ui_parse_num(&a);
            g_vd.img_box_h = (uint32_t)ui_parse_num(&a);
            g_vd.img_zoom = (uint32_t)ui_parse_num(&a);
            g_vd.img_pan_x = (uint32_t)ui_parse_num(&a);
            g_vd.img_pan_y = (uint32_t)ui_parse_num(&a);
            g_vd.img_braille = (uint32_t)ui_parse_num(&a);
            g_vd.img_cache_key = 42;
            g_vd.enc_key = 7;
            g_app.need_redraw = 0;
            break;
        }
        case 'K':
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = CALL(vim_zoom_key, &g_vd, &evt);
                dump_state("K", rc);
            }
            break;
        case 'M':
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                g_sb_mouse_ret = 1;
                int rc = CALL(vim_zoom_mouse, &g_vd, &evt);
                dump_state("M", rc);
            }
            break;
        case 'R': {
            int bw = (int)ui_parse_num(&a), bh = (int)ui_parse_num(&a), up = (int)ui_parse_num(&a);
            int tw = -1, th = -1, rect[4] = {-1, -1, -1, -1};
            CALLV(vim_zoom_rect, &g_vd, bw, bh, up, &tw, &th, rect);
            sc_put("R tw="); sc_num(tw); sc_put(" th="); sc_num(th);
            sc_put(" rect="); sc_num(rect[0]); sc_put(","); sc_num(rect[1]);
            sc_put(","); sc_num(rect[2]); sc_put(","); sc_num(rect[3]);
            sc_put(" pan="); sc_num(g_vd.img_pan_x); sc_put(","); sc_num(g_vd.img_pan_y);
            sc_put("\n");
            break;
        }
        case 'B': {
            g_vd.base.base.x = (int32_t)ui_parse_num(&a);
            g_vd.base.base.y = (int32_t)ui_parse_num(&a);
            g_vd.base.base.w = (int32_t)ui_parse_num(&a);
            g_vd.base.base.h = (int32_t)ui_parse_num(&a);
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALLV(vim_draw_zoom_badge, &g_vd, scr, theme);
            sc_put("B\n");
            int row = g_vd.base.base.y + g_vd.base.base.h - 2;
            if (row >= 0 && row < scr->height) ui_dump(scr, row, 1);
            break;
        }
        case 'P': {
            struct { ImgPlace p; int32_t box[2]; } pb;
            mem_zero(&pb, sizeof pb);
            int proto = (int)ui_parse_num(&a);
            pb.box[0] = (int32_t)ui_parse_num(&a);
            pb.box[1] = (int32_t)ui_parse_num(&a);
            g_kitty_ready = (int)ui_parse_num(&a);
            g_fail_alloc = (int)ui_parse_num(&a);
            int rc = CALL(vim_kitty_pan, &g_vd, proto, &pb.p);
            dump_state("P", rc);
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    if (g_vd.enc) mem_free((void *)(uintptr_t)g_vd.enc);
    sc_flush();
    return 0;
}
