/* Freestanding differential harness for src/ui/git_render.c + src/ui/du_render.c versus frozen x86_64 asm
 * (tests/harness/git_render_reference.s + du_render_reference.s, ref_ prefix). argv[1] = ref | c.
 *
 * Script on stdin:
 *   G <x3> <y> <glyph> <bg_slot> <status_ch> <has_name>   fp_draw_glyph_and_git + ui_dump
 *   H <x> <y> <has_app> <has_pane> <branch>               hdr_draw_git_badge + ui_dump
 *   B <x> <y> <w> <du_mode> <theme_idx> [badge_override]  fp_draw_du_badge + ui_dump (prints theme_get arg on C)
 *   D <x> <y> <w> <h> <du_mode> <scroll> <cursor> <focused> <du_total>
 *       followed by E <flags> <size> lines (up to 16) then P to call fp_draw_du_pane + ui_dump
 *   Q   probe mode (prints theme_get idx explicitly to show asm bug vs C fix) */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static HeaderBar g_hb;
static FilePane g_fp;
static DirModel g_dm;
static FileEntry g_ents[16];
static uint32_t g_ent_cnt;
static int g_git_status;
static int g_has_name;
static char g_branch_buf[128];
static char g_badge_buf[64];
static int g_log_theme_idx;

const char *DirModel_entry_name(const DirModel *dm, const FileEntry *e)
{
    (void)dm; (void)e;
    return g_has_name ? "demo.c" : nullptr;
}

FileEntry *DirModel_get_entry(DirModel *dm, intptr_t idx)
{
    if (dm != &g_dm || idx < 0 || (uint32_t)idx >= g_ent_cnt) return nullptr;
    return &g_ents[idx];
}

int git_lookup(DirModel *dm, const char *name)
{
    (void)dm; (void)name;
    return g_git_status;
}

const char *git_branch(DirModel *dm)
{
    (void)dm;
    return g_branch_buf;
}

const Theme *fake_theme_get(int idx);
const Theme *fake_theme_get(int idx)
{
    if (g_log_theme_idx) {
        sc_put("theme_get idx="); sc_num(idx); sc_put("\n");
    }
    return &g_ui_theme;
}

#include GIT_SRC

#define theme_get fake_theme_get
#include DU_SRC
#undef theme_get

#ifdef __x86_64__
extern void ref_fp_draw_glyph_and_git(ScreenBuffer *, int, int, uint32_t, FilePane *, FileEntry *, const Theme *, uint32_t);
extern void ref_hdr_draw_git_badge(void *, void *, const void *, int, int);
extern void ref_fp_draw_du_badge(FilePane *, ScreenBuffer *);
extern void ref_fp_draw_du_pane(FilePane *, ScreenBuffer *, const Theme *);
#define CALLV(f, ...) do { if (g_ref) ref_##f(__VA_ARGS__); else f(__VA_ARGS__); } while (0)
#else
#define CALLV(f, ...) f(__VA_ARGS__)
#endif

static bool g_ref;

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(80, 12);
    if (!scr) return 3;

    ui_app_reset(&g_app);
    g_fp.model = (uint64_t)(uintptr_t)&g_dm;
    g_fp.app = (uint64_t)(uintptr_t)&g_app;

    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'Q':
            g_log_theme_idx = (int)ui_parse_num(&a);
            break;
        case 'G': {
            int x3 = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
            uint32_t glyph = (uint32_t)ui_parse_num(&a);
            int bg_slot = (int)ui_parse_num(&a);
            g_git_status = (int)ui_parse_num(&a);
            g_has_name = (int)ui_parse_num(&a);
            uint32_t row_bg = (bg_slot >= 0 && bg_slot < 29) ? theme->colors[bg_slot] : theme->surface;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            ScreenBuffer_set_pen(scr, theme->dir_fg, row_bg, ATTR_NONE);
            CALLV(fp_draw_glyph_and_git, scr, x3, y, glyph, &g_fp, &g_ents[0], theme, row_bg);
            sc_put("G\n");
            ui_dump(scr, y, 1);
            break;
        }
        case 'H': {
            int x = (int)ui_parse_num(&a), y = (int)ui_parse_num(&a);
            int has_app = (int)ui_parse_num(&a), has_pane = (int)ui_parse_num(&a);
            while (*a == ' ') a++;
            (void)str_copy(g_branch_buf, a, sizeof g_branch_buf);
            mem_zero(&g_hb, sizeof g_hb);
            g_hb.app = has_app ? (uint64_t)(uintptr_t)&g_app : 0;
            g_app.active_pane = has_pane ? (uint64_t)(uintptr_t)&g_fp : 0;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALLV(hdr_draw_git_badge, &g_hb, scr, theme, x, y);
            sc_put("H\n");
            ui_dump(scr, y, 1);
            break;
        }
        case 'B': {
            g_fp.base.x = (int32_t)ui_parse_num(&a);
            g_fp.base.y = (int32_t)ui_parse_num(&a);
            g_fp.base.w = (int32_t)ui_parse_num(&a);
            g_dm.du_mode = (uint32_t)ui_parse_num(&a);
            g_app.theme_idx = (uint32_t)ui_parse_num(&a);
            while (*a == ' ') a++;
            if (*a) {
                (void)str_copy(g_badge_buf, a, sizeof g_badge_buf);
                ui_i18n_mut()->s[LS_fp_du_badge] = g_badge_buf;
            } else {
                ui_i18n_mut()->s[LS_fp_du_badge] = lang_en_table.s[LS_fp_du_badge];
            }
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALLV(fp_draw_du_badge, &g_fp, scr);
            sc_put("B\n");
            ui_dump(scr, g_fp.base.y, 1);
            break;
        }
        case 'D': {
            g_fp.base.x = (int32_t)ui_parse_num(&a);
            g_fp.base.y = (int32_t)ui_parse_num(&a);
            g_fp.base.w = (int32_t)ui_parse_num(&a);
            g_fp.base.h = (int32_t)ui_parse_num(&a);
            g_dm.du_mode = (uint32_t)ui_parse_num(&a);
            g_fp.scroll = (uint32_t)ui_parse_num(&a);
            g_fp.cursor = (uint32_t)ui_parse_num(&a);
            g_fp.base.flags = ui_parse_num(&a) ? WF_FOCUSED : 0;
            g_dm.du_total = (uint64_t)ui_parse_num(&a);
            g_ent_cnt = 0;
            break;
        }
        case 'E': {
            if (g_ent_cnt < 16) {
                mem_zero(&g_ents[g_ent_cnt], sizeof g_ents[g_ent_cnt]);
                g_ents[g_ent_cnt].flags = (uint32_t)ui_parse_num(&a);
                g_ents[g_ent_cnt].size = (uint64_t)ui_parse_num(&a);
                g_ent_cnt++;
            }
            break;
        }
        case 'P': {
            g_dm.count = g_ent_cnt;
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALLV(fp_draw_du_pane, &g_fp, scr, theme);
            sc_put("P\n");
            int rows = g_fp.base.h > 0 && g_fp.base.y + g_fp.base.h <= scr->height ? g_fp.base.h : 1;
            ui_dump(scr, g_fp.base.y, rows);
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
