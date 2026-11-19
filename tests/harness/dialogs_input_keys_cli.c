/* Freestanding differential harness for src/ui/dialogs_input_keys.c versus frozen x86_64 asm
 * (tests/harness/dialogs_input_keys_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   R <text>              reset InputDialog with initial UTF-8 text (cursor at end, focus_btn=0)
 *   F <n>                 fill buffer with <n> 'a' chars (cursor at end)
 *   K <key> <mods> [lat]  dispatch Event via InputDialog_on_key, print rc, dirty, focus, len, cursor, buf */
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static union { InputDialog id; Dialog d; Widget w; } g_dlg_u;
#define g_dlg (g_dlg_u.id)

static void fake_confirm(Dialog *self) { ui_log_call2("on_confirm", self == &g_dlg_u.d, 0); }
static void fake_cancel(Dialog *self)  { ui_log_call2("on_cancel", self == &g_dlg_u.d, 0); }

void Dialog_dtor(Widget *self) { (void)self; }
void Dialog_layout(Widget *self, int x, int y, int w, int h) { (void)self; (void)x; (void)y; (void)w; (void)h; }
void Dialog_render(Widget *self, void *scr, void *th) { (void)self; (void)scr; (void)th; }
int Dialog_on_key(Widget *self, void *ev) { (void)self; (void)ev; return 0; }
int Dialog_on_mouse(Widget *self, void *ev) { (void)self; (void)ev; return 0; }
void Dialog_on_confirm(Dialog *self) { fake_confirm(self); }
void Dialog_on_cancel(Dialog *self)  { fake_cancel(self); }

DIALOG_VTBL(test_input_vtbl, "TestInputDialog", Widget_vtbl, sizeof(InputDialog),
            .on_confirm = fake_confirm, .on_cancel = fake_cancel);

#include DIK_SRC

#ifdef __x86_64__
extern int ref_InputDialog_on_key(Widget *self, void *event);
#define CALL_KEY(w, e) (g_ref ? ref_InputDialog_on_key(w, e) : InputDialog_on_key(w, e))
#else
#define CALL_KEY(w, e) InputDialog_on_key(w, e)
#endif

static bool g_ref;

static void reset_dlg(const char *txt, size_t n)
{
    mem_zero(&g_dlg, sizeof g_dlg);
    g_dlg.base.base.base.vptr = DUOP_OBJ_VTBL(test_input_vtbl);
    g_dlg.base.app = (uint64_t)(uintptr_t)&g_app;
    if (n >= INPUT_MAX) n = INPUT_MAX - 1;
    if (n) mem_copy(g_dlg.buf, txt, n);
    g_dlg.buf[n] = 0;
    for (size_t i = n + 1; i < INPUT_MAX; i++) g_dlg.buf[i] = 'Z';
    g_dlg.len = (uint32_t)n;
    g_dlg.cursor = (uint32_t)n;
    g_app.need_redraw = 0;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    ui_app_reset(&g_app);
    reset_dlg("", 0);

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        if (line[0] == 'R') {
            const char *s = line[1] == ' ' ? line + 2 : line + 1;
            reset_dlg(s, str_len(s));
        } else if (line[0] == 'F') {
            const char *a = line + 1;
            size_t n = (size_t)ui_parse_num(&a);
            char tmp[INPUT_MAX];
            if (n >= INPUT_MAX) n = INPUT_MAX - 1;
            for (size_t i = 0; i < n; i++) tmp[i] = 'a';
            reset_dlg(tmp, n);
        } else if (line[0] == 'K') {
            Event evt;
            if (ui_parse_event(line, &evt)) {
                g_app.need_redraw = 0;
                int rc = CALL_KEY(&g_dlg_u.w, &evt);
                sc_put("K rc="); sc_num(rc);
                sc_put(" dirty="); sc_num(g_app.need_redraw);
                sc_put(" fb="); sc_num(g_dlg.base.focus_btn);
                sc_put(" len="); sc_num(g_dlg.len);
                sc_put(" cur="); sc_num(g_dlg.cursor);
                sc_put(" |"); sc_esc((const char *)g_dlg.buf); sc_put("|\n");
            }
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
