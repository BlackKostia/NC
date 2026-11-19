/* Freestanding differential harness for src/ui/syntax.c versus frozen x86_64 asm
 * (tests/harness/syntax_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   D <path>                                  syntax_detect(path)  (D! -> nullptr)
 *   L <x> <y> <max_w> <bg_slot> <path>\t<line>  syntax_draw_line(...) + ui_dump */
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_event.h"
#include "ui_render.h"

#include SYN_SRC

#ifdef __x86_64__
extern int ref_syntax_detect(const char *path);
extern void ref_syntax_draw_line(ScreenBuffer *scr, int x, int y, const char *line, int max_w,
                                 const char *path, const Theme *theme, uint32_t bg);
#define CALL_DET(p) (g_ref ? ref_syntax_detect(p) : syntax_detect(p))
#define CALL_DRAW(s, x, y, l, w, p, t, b) \
    do { if (g_ref) ref_syntax_draw_line(s, x, y, l, w, p, t, b); else syntax_draw_line(s, x, y, l, w, p, t, b); } while (0)
#else
#define CALL_DET(p) syntax_detect(p)
#define CALL_DRAW(s, x, y, l, w, p, t, b) syntax_draw_line(s, x, y, l, w, p, t, b)
#endif

static bool g_ref;

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(96, 4);
    if (!scr) return 3;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        if (line[0] == 'D') {
            const char *p = line[1] == '!' ? nullptr : (line[1] == ' ' ? line + 2 : line + 1);
            int lang = CALL_DET(p);
            sc_put("D "); sc_num(lang); sc_put("\n");
        } else if (line[0] == 'L') {
            const char *a = line + 1;
            int x = (int)ui_parse_num(&a);
            int y = (int)ui_parse_num(&a);
            int max_w = (int)ui_parse_num(&a);
            int bg_slot = (int)ui_parse_num(&a);
            while (*a == ' ') a++;
            char path_buf[128];
            size_t pi = 0;
            while (a[pi] && a[pi] != '\t' && pi + 1 < sizeof path_buf) {
                path_buf[pi] = a[pi];
                pi++;
            }
            path_buf[pi] = 0;
            const char *path = (pi == 1 && path_buf[0] == '!') ? nullptr : path_buf;
            const char *text = a[pi] == '\t' ? a + pi + 1 : "";
            uint32_t bg = (bg_slot >= 0 && bg_slot < 29) ? theme->colors[bg_slot] : theme->dialog_bg;

            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALL_DRAW(scr, x, y, text, max_w, path, theme, bg);
            sc_put("L\n");
            ui_dump(scr, y, 1);
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
