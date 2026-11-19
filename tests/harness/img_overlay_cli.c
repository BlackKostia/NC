/* Freestanding differential harness for src/ui/img_overlay.c versus frozen x86_64 asm
 * (tests/harness/img_overlay_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   P <proto>                           set fake term_img_proto() return (2=SIXEL, 3=KITTY)
 *   D <dlg_id>                          set app.active_dialog (0=none, 1=owner1, 2=owner2)
 *   C <changed>                         set fake ScreenBuffer_rect_changed() return (0/1)
 *   K <id>                              img_overlay_kitty_mark(ptr(id))  (0 -> nullptr)
 *   R <id>                              print img_overlay_kitty_ready(ptr(id))
 *   S <owner> <data_id> <key> <x> <y> <w> <h>   img_overlay_show(...)
 *   F                                   run pre_flush + post_flush, logging all emitted bytes & rect calls */
#include "duop_classes.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_proto = IMG_PROTO_SIXEL;
static int g_rect_changed;
static char g_dummy_scr[64];
static char g_owners[4];
static char g_pixels[4];
static const char g_payloads[4][24] = {
    "SIXEL_A",
    "SIXEL_B_LONG",
    "KITTY_PAYLOAD_1",
    "KITTY_PAYLOAD_2!",
};

intptr_t fake_write_all(int fd, const void *buf, size_t len);
intptr_t fake_write_all(int fd, const void *buf, size_t len)
{
    ui_log_call_bytes("write_all", fd, buf, len);
    return (intptr_t)len;
}

int fake_term_img_proto(void);
int fake_term_img_proto(void) { return g_proto; }

int fake_rect_changed(ScreenBuffer *s, int x, int y, int w, int h);
int fake_rect_changed(ScreenBuffer *s, int x, int y, int w, int h)
{
    sc_put("call rect_changed eq="); sc_num((void *)s == (void *)g_dummy_scr);
    sc_put(" "); sc_num(x); sc_put(" "); sc_num(y); sc_put(" "); sc_num(w); sc_put(" "); sc_num(h);
    sc_put(" -> "); sc_num(g_rect_changed); sc_put("\n");
    return g_rect_changed;
}

void fake_rect_invalidate(ScreenBuffer *s, int x, int y, int w, int h);
void fake_rect_invalidate(ScreenBuffer *s, int x, int y, int w, int h)
{
    sc_put("call rect_invalidate eq="); sc_num((void *)s == (void *)g_dummy_scr);
    sc_put(" "); sc_num(x); sc_put(" "); sc_num(y); sc_put(" "); sc_num(w); sc_put(" "); sc_num(h);
    sc_put("\n");
}

#define sys_write_all fake_write_all
#define term_img_proto fake_term_img_proto
#define ScreenBuffer_rect_changed fake_rect_changed
#define ScreenBuffer_rect_invalidate fake_rect_invalidate
#include OV_SRC
#undef ScreenBuffer_rect_invalidate
#undef ScreenBuffer_rect_changed
#undef term_img_proto
#undef sys_write_all

#ifdef __x86_64__
extern void ref_img_overlay_show(const ImgPlace *p);
extern void ref_img_preview_pre_flush(App *app);
extern void ref_img_preview_post_flush(App *app);
extern int ref_img_overlay_kitty_ready(const void *pixels);
extern void ref_img_overlay_kitty_mark(const void *pixels);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

static const void *id_ptr(char *arr, int id) { return (id > 0 && id < 4) ? &arr[id] : nullptr; }

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    ui_app_reset(&g_app);
    g_app.screen = (uint64_t)(uintptr_t)g_dummy_scr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'P': g_proto = (int)ui_parse_num(&a); break;
        case 'D': {
            int id = (int)ui_parse_num(&a);
            g_app.active_dialog = (uint64_t)(uintptr_t)id_ptr(g_owners, id);
            break;
        }
        case 'C': g_rect_changed = (int)ui_parse_num(&a); break;
        case 'K': {
            int id = (int)ui_parse_num(&a);
            CALLV(img_overlay_kitty_mark, id_ptr(g_pixels, id));
            break;
        }
        case 'R': {
            int id = (int)ui_parse_num(&a);
            sc_put("R "); sc_num(CALL(img_overlay_kitty_ready, id_ptr(g_pixels, id))); sc_put("\n");
            break;
        }
        case 'S': {
            int owner = (int)ui_parse_num(&a), did = (int)ui_parse_num(&a);
            uint64_t key = (uint64_t)ui_parse_num(&a);
            uint32_t x = (uint32_t)ui_parse_num(&a), y = (uint32_t)ui_parse_num(&a);
            uint32_t w = (uint32_t)ui_parse_num(&a), h = (uint32_t)ui_parse_num(&a);
            int idx = did & 3;
            ImgPlace p = {
                .owner = (uint64_t)(uintptr_t)id_ptr(g_owners, owner),
                .data = (uint64_t)(uintptr_t)g_payloads[idx],
                .len = str_len(g_payloads[idx]),
                .key = key,
                .x = x, .y = y, .w = w, .h = h,
            };
            CALLV(img_overlay_show, &p);
            break;
        }
        case 'F':
            sc_put("F pre\n");
            CALLV(img_preview_pre_flush, &g_app);
            sc_put("F post\n");
            CALLV(img_preview_post_flush, &g_app);
            break;
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
