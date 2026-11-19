/* Freestanding differential harness for src/ui/preview_pane{,_render}.c versus frozen x86_64 asm
 * (tests/harness/preview_pane{,_render}_reference.s, ref_ prefix). argv[1] = ref | c | oom. */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_img.h"
#include "duop_preview.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;
static int g_dispatch_ret;
static size_t g_thumb_ret;

int term_img_proto(void) { return IMG_PROTO_QUAD; }
CellPx term_cell_px(void) { return (CellPx){0, 0}; }
int img_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, const Theme *th) { (void)pv; (void)sb; (void)th; return 0; }
int elf_preview_try_render(PreviewPane *pv, ScreenBuffer *sb, const Theme *th) { (void)pv; (void)sb; (void)th; return 0; }

size_t fake_pv_make_thumb(const char *path, const uint8_t *head, size_t head_len,
                          const PvThumbReq *req, uint8_t *out, size_t cap);
size_t fake_pv_make_thumb(const char *path, const uint8_t *head, size_t head_len,
                          const PvThumbReq *req, uint8_t *out, size_t cap)
{
    (void)head; (void)out;
    sc_put("call pv_make_thumb p="); sc_esc(path); sc_put(" hl="); sc_num((int64_t)head_len);
    sc_put(" wh="); sc_num(req->w); sc_put("x"); sc_num(req->h);
    sc_put(" pr="); sc_num(req->proto); sc_put(" cap_ok="); sc_num(cap > 1000); sc_put("\n");
    return g_thumb_ret;
}

int fake_pv_mode_dispatch(PreviewPane *pv, ScreenBuffer *scr, const Theme *th);
int fake_pv_mode_dispatch(PreviewPane *pv, ScreenBuffer *scr, const Theme *th)
{
    (void)pv; (void)scr; (void)th;
    sc_put("call pv_mode_dispatch ret="); sc_num(g_dispatch_ret); sc_put("\n");
    return g_dispatch_ret;
}

void *fake_mem_alloc(uint64_t size);
void *fake_mem_alloc(uint64_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return mem_alloc(size);
}

void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size);
void *fake_object_alloc(const ObjectVtbl *vtbl, size_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return Object_alloc(vtbl, size);
}

#define mem_alloc fake_mem_alloc
#define Object_alloc fake_object_alloc
#define pv_make_thumb fake_pv_make_thumb
#define pv_mode_dispatch fake_pv_mode_dispatch
#include PPR_SRC
#include PP_SRC
#undef pv_mode_dispatch
#undef pv_make_thumb
#undef Object_alloc
#undef mem_alloc

#ifdef __x86_64__
extern const WidgetVtbl ref_PreviewPane_vtbl;
extern PreviewPane *ref_PreviewPane_new(App *app);
extern int ref_PreviewPane_load(PreviewPane *self, const char *full_path, const FileEntry *entry);
extern void ref_PreviewPane_read_sync(PreviewPane *self);
extern void ref_PreviewPane_accept(PreviewPane *self, size_t len, size_t tlen, const uint8_t *thumb);
extern const char *ref_pv_copy_line_strip_ansi(const char *p, const char *end, char *dst);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#define PP_VTBL (g_ref ? &ref_PreviewPane_vtbl : &PreviewPane_vtbl)
#else
#define CALL(f, ...) f(__VA_ARGS__)
#define PP_VTBL (&PreviewPane_vtbl)
#endif

static bool g_ref;

static void *as_ptr(PreviewPane *pv)
{
    uintptr_t a = (uintptr_t)pv;
    return (void *)a;
}

static void dump_pv(const char *tag, const PreviewPane *pv)
{
    sc_put(tag);
    sc_put(" bl="); sc_num((int64_t)pv->buf_len);
    sc_put(" tl="); sc_num(pv->total_lines);
    sc_put(" bin="); sc_num(pv->is_binary);
    sc_put(" dir="); sc_num(pv->is_dir);
    sc_put(" pnd="); sc_num(pv->pending);
    sc_put(" thl="); sc_num(pv->thumb_len);
    sc_put(" thg="); sc_num(pv->thumb_gen);
    sc_put(" sc="); sc_num(pv->scroll);
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    if (argv[1][0] == 'o') {
        ui_app_reset(&g_app);
        g_fail_alloc = 1;
        PreviewPane *p1 = PreviewPane_new(&g_app);
        g_fail_alloc = 2; /* Object_alloc ok, buf mem_alloc fails */
        PreviewPane *p2 = PreviewPane_new(&g_app);
        g_fail_alloc = 0;
        sc_put("OOM1 ok="); sc_num(p1 == nullptr);
        sc_put(" OOM2 ok="); sc_num(p2 == nullptr); sc_put("\n");
        sc_flush();
        return (p1 == nullptr && p2 == nullptr) ? 0 : 1;
    }
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(70, 20);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;
    PreviewPane *pv = nullptr;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'N': {
            if (pv) { DUOP_DELETE((Object *)as_ptr(pv)); pv = nullptr; }
            pv = CALL(PreviewPane_new, &g_app);
            sc_put("N ok="); sc_num(pv != nullptr);
            if (pv) {
                sc_put(" is_pp="); sc_num(Object_is_instance((const Object *)as_ptr(pv), (const ObjectVtbl *)PP_VTBL));
                sc_put(" is_w="); sc_num(DUOP_IS_INSTANCE((const Object *)as_ptr(pv), Widget_vtbl));
            }
            sc_put("\n");
            break;
        }
        case 'G': {
            if (!pv) break;
            int x = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
            int w = (int)ui_parse_num(&a), h = (int)ui_parse_num(&a);
            WIDGET_CALL((Widget *)as_ptr(pv), layout, x, y, w, h);
            break;
        }
        case 'L': {
            if (!pv) break;
            int kind = (int)ui_parse_num(&a); /* 0=NULL, 1=dir, 2=file */
            uint64_t sz = (uint64_t)ui_parse_num(&a);
            uint32_t mode = (uint32_t)ui_parse_num(&a);
            while (*a == ' ') a++;
            FileEntry ent;
            mem_zero(&ent, sizeof ent);
            ent.size = (int64_t)sz;
            ent.mode = mode;
            if (kind == 1) ent.flags = FE_IS_DIR;
            int rc = CALL(PreviewPane_load, pv, kind == 0 ? nullptr : a, kind == 0 ? nullptr : &ent);
            sc_put("L rc="); sc_num(rc); sc_put(" ");
            dump_pv("L", pv);
            break;
        }
        case 'S': {
            if (!pv) break;
            g_thumb_ret = (size_t)ui_parse_num(&a);
            CALL(PreviewPane_read_sync, pv);
            dump_pv("S", pv);
            break;
        }
        case 'C': {
            if (!pv) break;
            pv->scroll = (uint32_t)ui_parse_num(&a);
            g_dispatch_ret = (int)ui_parse_num(&a);
            break;
        }
        case 'R': {
            if (!pv) break;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            WIDGET_CALL((Widget *)as_ptr(pv), render, scr, (void *)theme);
            ui_dump(scr, pv->base.y, pv->base.h);
            break;
        }
        case 'A': {
            const char *src = "hi\t\x1b[31;1mred\x1b[0m\r\nplain\x1bXnext\n";
            char dst[260];
            const char *end = src + str_len(src);
            const char *p = src;
            for (int i = 0; i < 2; i++) {
                p = CALL(pv_copy_line_strip_ansi, p, end, dst);
                sc_put("A"); sc_num(i); sc_put(" |"); sc_esc(dst); sc_put("|\n");
            }
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    if (pv) DUOP_DELETE((Object *)as_ptr(pv));
    sc_flush();
    return 0;
}
