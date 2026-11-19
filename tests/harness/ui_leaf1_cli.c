/* Freestanding differential harness for U1.1 leaf UI helpers:
 *   popup_osc52.c, term_keys.c, term_pane_input.c, preview_pane_mouse.c, header_bar_git.c
 * versus their frozen x86_64 asm oracles (*_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   O <text>                         osc52_copy_text(text)   (O! -> nullptr)
 *   E <key> <mods>                   term_key_encode(&evt, buf)
 *   T <vis> <inited> <fd>            set g_term_visible / g_term_inited / g_term_fd
 *   K <key> <mods> [lat]             term_on_key(&g_app, &evt)
 *   S                                term_shutdown()
 *   P <scroll> <lines> <bin> <blen>  configure PreviewPane
 *   M <kind> <btn> <x> <y> [mods]    PreviewPane_on_mouse(&g_pp, &evt)
 *   H <x> <y> <w> <rmode>            hdr_draw_mode_and_git(&g_hb, scr, theme, ls) + ui_dump
 *   B <brand>                        override LS_hdr_brand
 *   A <fail_alloc>                   1 -> fail next mem_alloc (OOM test, C only) */
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

int32_t g_term_visible;
int32_t g_term_inited;
int32_t g_term_fd;

static App g_app;
static union { PreviewPane pp; Widget w; } g_pp_u;
#define g_pp (g_pp_u.pp)
static HeaderBar g_hb;
static char g_brand_buf[128];
static int g_fail_alloc;

/* Recording stand-ins for external side-effect calls */
intptr_t fake_write_all(int fd, const void *buf, size_t len);
intptr_t fake_write_all(int fd, const void *buf, size_t len)
{
    ui_log_call_bytes("write_all", fd, buf, len);
    return (intptr_t)len;
}

void *fake_mem_alloc(size_t sz);
void *fake_mem_alloc(size_t sz)
{
    if (g_fail_alloc) { g_fail_alloc = 0; return nullptr; }
    return mem_alloc(sz);
}

void term_toggle(App *app);
void term_toggle(App *app) { ui_log_call2("term_toggle", app == &g_app, 0); }

intptr_t fake_pty_write(int fd, const void *buf, size_t len);
intptr_t fake_pty_write(int fd, const void *buf, size_t len)
{
    ui_log_call_bytes("pty_write", fd, buf, len);
    return (intptr_t)len;
}

void fake_pty_close(int fd);
void fake_pty_close(int fd) { ui_log_call2("pty_close", fd, 0); }

void hdr_draw_git_badge(void *hdr, void *scr, const void *theme, int x, int y);
void hdr_draw_git_badge(void *hdr, void *scr, const void *theme, int x, int y)
{
    sc_put("call git_badge eq="); sc_num(hdr == &g_hb && scr != nullptr && theme == &g_ui_theme);
    sc_put(" x="); sc_num(x); sc_put(" y="); sc_num(y); sc_put("\n");
}

#define sys_write_all fake_write_all
#define mem_alloc fake_mem_alloc
#include OSC52_SRC
#undef mem_alloc
#undef sys_write_all

#include TKEYS_SRC

#define os_pty_write fake_pty_write
#define os_pty_close fake_pty_close
#include TINPUT_SRC
#undef os_pty_close
#undef os_pty_write

#include PMOUSE_SRC
#include HGIT_SRC

#ifdef __x86_64__
extern void ref_osc52_copy_text(const char *);
extern int ref_term_key_encode(const void *, char *);
extern int ref_term_on_key(void *, void *);
extern void ref_term_shutdown(void);
extern int ref_PreviewPane_on_mouse(Widget *, void *);
extern void ref_hdr_draw_mode_and_git(void *, void *, const void *, const void *);
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
    ScreenBuffer *scr = ScreenBuffer_new(100, 4);
    if (!scr) return 3;
    ui_app_reset(&g_app);
    g_pp.app = (uint64_t)(uintptr_t)&g_app;
    g_hb.app = (uint64_t)(uintptr_t)&g_app;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        Event evt;
        switch (line[0]) {
        case 'A': g_fail_alloc = (int)ui_parse_num(&a); break;
        case 'O':
            if (*a == '!') CALLV(osc52_copy_text, nullptr);
            else CALLV(osc52_copy_text, *a == ' ' ? a + 1 : a);
            sc_put("O done\n");
            break;
        case 'E': {
            int32_t key = (int32_t)ui_parse_num(&a), mods = (int32_t)ui_parse_num(&a);
            evt = ui_evt_key(key, mods, key);
            char out[16];
            mem_zero(out, sizeof out);
            int n = CALL(term_key_encode, &evt, out);
            sc_put("E n="); sc_num(n);
            if (n > 0) {
                sc_put(" |");
                for (int i = 0; i < n; i++) {
                    char c[2] = {out[i], 0};
                    if (out[i]) sc_esc(c); else sc_put("\\x00");
                }
                sc_put("|");
            }
            sc_put("\n");
            break;
        }
        case 'T':
            g_term_visible = (int32_t)ui_parse_num(&a);
            g_term_inited = (int32_t)ui_parse_num(&a);
            g_term_fd = (int32_t)ui_parse_num(&a);
            break;
        case 'K':
            if (ui_parse_event(line, &evt)) {
                int rc = CALL(term_on_key, &g_app, &evt);
                sc_put("K rc="); sc_num(rc); sc_put(" fd="); sc_num(g_term_fd); sc_put("\n");
            }
            break;
        case 'S':
            CALLV(term_shutdown);
            sc_put("S fd="); sc_num(g_term_fd); sc_put("\n");
            break;
        case 'P':
            g_pp.scroll = (uint32_t)ui_parse_num(&a);
            g_pp.total_lines = (uint32_t)ui_parse_num(&a);
            g_pp.is_binary = (uint32_t)ui_parse_num(&a);
            g_pp.buf_len = (uint64_t)ui_parse_num(&a);
            g_app.need_redraw = 0;
            break;
        case 'M':
            if (ui_parse_event(line, &evt)) {
                int rc = CALL(PreviewPane_on_mouse, &g_pp_u.w, &evt);
                ui_dump_event_res("M", rc, &g_app, nullptr);
                sc_put("  scroll="); sc_num(g_pp.scroll); sc_put("\n");
            }
            break;
        case 'B':
            while (*a == ' ') a++;
            (void)str_copy(g_brand_buf, a, sizeof g_brand_buf);
            ui_i18n_mut()->s[LS_hdr_brand] = g_brand_buf;
            break;
        case 'H': {
            g_hb.base.x = (int32_t)ui_parse_num(&a);
            g_hb.base.y = (int32_t)ui_parse_num(&a);
            g_hb.base.w = (int32_t)ui_parse_num(&a);
            g_hb.base.h = 1;
            g_app.right_mode = (uint32_t)ui_parse_num(&a);
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALLV(hdr_draw_mode_and_git, &g_hb, scr, theme, i18n_get());
            sc_put("H\n");
            ui_dump(scr, g_hb.base.y, 1);
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
