/* Freestanding differential harness for src/ui/hex_edit.c versus frozen x86_64 asm
 * (tests/harness/hex_edit_reference.s, ref_ prefix). argv[1] = ref | c. */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_keys.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static int g_fail_alloc;
static int g_write_rc;
static uint8_t g_mmap_buf[32];

void App_set_status(App *app, const char *msg, int kind)
{
    sc_put("call App_set_status "); sc_num(app == &g_app);
    sc_put(" k="); sc_num(kind); sc_put(" |"); sc_esc(msg ? msg : ""); sc_put("|\n");
}

intptr_t fake_os_munmap(void *addr, size_t len);
intptr_t fake_os_munmap(void *addr, size_t len)
{
    sc_put("call os_munmap eq="); sc_num(addr == g_mmap_buf); sc_put(" len="); sc_num((int64_t)len); sc_put("\n");
    return 0;
}

int fake_fs_write_file(const char *path, const void *buf, uint64_t len);
int fake_fs_write_file(const char *path, const void *buf, uint64_t len)
{
    const uint8_t *b = buf;
    sc_put("call fs_write_file p="); sc_esc(path); sc_put(" len="); sc_num((int64_t)len); sc_put(" hex=");
    static const char hx[] = "0123456789abcdef";
    for (uint64_t i = 0; i < len && i < 16; i++) {
        char s[3] = {hx[b[i] >> 4], hx[b[i] & 15], 0};
        sc_put(s);
    }
    sc_put("\n");
    return g_write_rc;
}

const char *fake_fs_errno_message(int neg_errno);
const char *fake_fs_errno_message(int neg_errno)
{
    sc_put("call fs_errno_message "); sc_num(neg_errno); sc_put("\n");
    return "I/O error";
}

void *fake_mem_alloc(uint64_t size);
void *fake_mem_alloc(uint64_t size)
{
    if (g_fail_alloc > 0 && --g_fail_alloc == 0) return nullptr;
    return mem_alloc(size);
}

#define os_munmap fake_os_munmap
#define fs_write_file fake_fs_write_file
#define fs_errno_message fake_fs_errno_message
#define mem_alloc fake_mem_alloc
#include HE_SRC
#undef mem_alloc
#undef fs_errno_message
#undef fs_write_file
#undef os_munmap

#ifdef __x86_64__
extern void ref_hex_edit_free(ViewerDialog *vd);
extern int ref_hex_edit_on_key(ViewerDialog *vd, Event *ev);
#define CALL(f, ...) (g_ref ? ref_##f(__VA_ARGS__) : f(__VA_ARGS__))
#else
#define CALL(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

static void dump_vd(const char *tag, const ViewerDialog *v)
{
    const HexEditCtx *c = (const HexEditCtx *)(uintptr_t)v->hex_edit_ctx;
    sc_put(tag);
    sc_put(" map="); sc_num((int64_t)v->map_len);
    sc_put(" rd="); sc_num(g_app.need_redraw);
    if (c) {
        sc_put(" act="); sc_num(c->active);
        sc_put(" nib="); sc_num(c->nibble);
        sc_put(" drt="); sc_num(c->dirty);
        sc_put(" uc="); sc_num(c->undo_cnt);
        sc_put(" cur="); sc_num((int64_t)c->cursor);
    } else {
        sc_put(" ctx=NULL");
    }
    const uint8_t *b = (const uint8_t *)(uintptr_t)v->data;
    if (b && v->data_len) {
        static const char hx[] = "0123456789abcdef";
        sc_put(" data=");
        for (uint64_t i = 0; i < v->data_len && i < 8; i++) {
            char s[3] = {hx[b[i] >> 4], hx[b[i] & 15], 0};
            sc_put(s);
        }
    }
    sc_put("\n");
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    ui_app_reset(&g_app);

    ViewerDialog *v = mem_alloc(sizeof(ViewerDialog));
    if (!v) return 4;
    mem_zero(v, sizeof *v);

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'V': {
            CALL(hex_edit_free, v);
            if (v->data && v->data != (uint64_t)(uintptr_t)g_mmap_buf)
                mem_free((void *)(uintptr_t)v->data);
            mem_zero(v, sizeof *v);
            v->base.app = (uint64_t)(uintptr_t)&g_app;
            (void)str_copy((char *)v->path, "/tmp/edit.bin", 64);
            v->hex_mode = (uint32_t)ui_parse_num(&a);
            int use_mmap = (int)ui_parse_num(&a);
            uint64_t dlen = (uint64_t)ui_parse_num(&a);
            v->hex_row = (uint64_t)ui_parse_num(&a);
            v->data_len = dlen;
            for (uint64_t i = 0; i < dlen && i < 32; i++) g_mmap_buf[i] = (uint8_t)(0x10 + i);
            if (use_mmap) {
                v->data = (uint64_t)(uintptr_t)g_mmap_buf;
                v->map_len = dlen;
            } else if (dlen) {
                uint8_t *hb = mem_alloc(dlen);
                mem_copy(hb, g_mmap_buf, dlen);
                v->data = (uint64_t)(uintptr_t)hb;
                v->map_len = 0;
            }
            g_app.need_redraw = 0;
            break;
        }
        case 'E': {
            g_fail_alloc = (int)ui_parse_num(&a);
            g_write_rc = (int)ui_parse_num(&a);
            break;
        }
        case 'K': {
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = CALL(hex_edit_on_key, v, &evt);
                sc_put("K rc="); sc_num(rc); sc_put(" ");
                dump_vd("K", v);
            }
            break;
        }
        case 'F': {
            CALL(hex_edit_free, v);
            dump_vd("F", v);
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    CALL(hex_edit_free, v);
    if (v->data && v->data != (uint64_t)(uintptr_t)g_mmap_buf)
        mem_free((void *)(uintptr_t)v->data);
    mem_free(v);
    sc_flush();
    return 0;
}
