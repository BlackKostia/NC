/* Freestanding differential harness for src/ui/file_pane_layout.c versus frozen x86_64 asm
 * (file_pane_layout_reference.s + file_pane_cols_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   L <x> <y> <w> <h>    reset hdr_zones sentinel, call FilePane_layout(&g_fp, x, y, w, h), dump geometry + zones */
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_string.h"
#include "duop_ui.h"
#include "script_cli.h"
#include "ui_event.h"

static union { FilePane fp; Widget w; } g_fp_u;
#define g_fp (g_fp_u.fp)

void FilePane_ensure_visible(FilePane *self)
{
    sc_put("call ensure_visible eq=");
    sc_num(self == &g_fp);
    sc_put("\n");
}

#include FPL_SRC

#ifdef __x86_64__
extern void ref_FilePane_layout(Widget *self, int x, int y, int w, int h);
#define CALL_LAYOUT(s, x, y, w, h) do { if (g_ref) ref_FilePane_layout(s, x, y, w, h); else FilePane_layout(s, x, y, w, h); } while (0)
#else
#define CALL_LAYOUT(s, x, y, w, h) FilePane_layout(s, x, y, w, h)
#endif

static bool g_ref;

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        if (line[0] != 'L') continue;
        const char *a = line + 1;
        int x = (int)ui_parse_num(&a);
        int y = (int)ui_parse_num(&a);
        int w = (int)ui_parse_num(&a);
        int h = (int)ui_parse_num(&a);

        mem_zero(&g_fp, sizeof g_fp);
        for (size_t i = 0; i < sizeof g_fp.hdr_zones; i++) g_fp.hdr_zones[i] = 0x5Au;
        g_fp.hdr_zone_count = 99;

        CALL_LAYOUT(&g_fp_u.w, x, y, w, h);

        sc_put("rect ");
        sc_num(g_fp.base.x); sc_put(" "); sc_num(g_fp.base.y); sc_put(" ");
        sc_num(g_fp.base.w); sc_put(" "); sc_num(g_fp.base.h);
        sc_put(" cnt="); sc_num(g_fp.hdr_zone_count);
        const HitZone *z = (const HitZone *)g_fp.hdr_zones;
        uint32_t n = g_fp.hdr_zone_count <= 4 ? g_fp.hdr_zone_count : 4;
        for (uint32_t i = 0; i < n; i++) {
            sc_put(" ["); sc_num(z[i].x1); sc_put(".."); sc_num(z[i].x2);
            sc_put("@"); sc_num(z[i].y); sc_put(" id="); sc_num(z[i].id); sc_put("]");
        }
        sc_put("\n");
        sc_flush();
    }
    sc_flush();
    return 0;
}
