/* Freestanding differential & perf harness for src/ui/file_pane_render.c + file_pane_rows.c
 * versus frozen x86_64 asm (tests/harness/file_pane_render_reference.s, ref_ prefix).
 * argv[1] = ref | c; optional argv[2] = "bench" (runs 600 frames without dumping for perf_gate). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "ui_app_stub.h"
#include "ui_event.h"

static App g_app;
static FilePane g_fp;
static DirModel g_dm;
static NavTab g_tabs[4];
static FileEntry g_ents[256];
static uint32_t g_ord[256];
static char g_pool[8192];

int get_list_h(FilePane *fp)
{
    int h = fp->base.h - 5;
    return h >= 1 ? h : 1;
}

void fp_draw_search_badge(FilePane *fp, ScreenBuffer *scr) { (void)fp; (void)scr; }
void fp_draw_du_pane(FilePane *fp, ScreenBuffer *scr, const Theme *th) { (void)fp; (void)scr; (void)th; }

void fp_draw_glyph_and_git(ScreenBuffer *scr, int x3, int y, uint32_t glyph,
                           FilePane *fp, FileEntry *ent, const Theme *theme, uint32_t row_bg)
{
    (void)fp; (void)ent; (void)theme; (void)row_bg;
    ScreenBuffer_set_cell_pen(scr, x3, y, glyph);
}

void DirModel_stat_range(DirModel *m, size_t start, size_t len) { (void)m; (void)start; (void)len; }

FileEntry *DirModel_get_entry(DirModel *m, intptr_t idx)
{
    if (idx < 0 || (uint64_t)idx >= m->count) return nullptr;
    return &m->entries[m->order[idx]];
}

const char *DirModel_entry_name(const DirModel *m, const FileEntry *e) { return m->name_pool + e->name_off; }

size_t DirModel_count_selected(DirModel *m, int64_t *out_bytes)
{
    size_t cnt = 0;
    int64_t bytes = 0;
    for (uint64_t i = 0; i < m->count; i++) {
        FileEntry *e = &m->entries[m->order[i]];
        if (e->flags & FE_SELECTED) { cnt++; bytes += e->size; }
    }
    if (out_bytes) *out_bytes = bytes;
    return cnt;
}

#include FPR_ROWS_SRC
#include FPR_SRC

#ifdef __x86_64__
extern void ref_FilePane_render(Widget *self, void *scr, void *theme);
#define CALL_RENDER(fp, s, t) (g_ref ? ref_FilePane_render((Widget *)(fp), (s), (t)) : FilePane_render((Widget *)(fp), (s), (t)))
#else
#define CALL_RENDER(fp, s, t) FilePane_render((Widget *)(fp), (s), (t))
#endif

static bool g_ref;

static void add_entry(size_t idx, size_t *poff, const char *name, int64_t sz, int64_t mtime,
                      uint32_t mode, uint32_t flags)
{
    size_t len = str_len(name);
    mem_copy(g_pool + *poff, name, len + 1);
    int dw = utf8_display_width(name);
    g_ents[idx] = (FileEntry){
        .size = sz, .mtime = mtime, .mode = mode, .flags = flags,
        .name_off = (uint32_t)*poff, .name_len = (uint16_t)len,
        .disp_width = (uint8_t)(dw > 255 ? 255 : dw), .ext_offset = 0,
    };
    g_ord[idx] = (uint32_t)idx;
    *poff += len + 1;
}

static void init_model(int bench)
{
    mem_zero(&g_fp, sizeof g_fp);
    mem_zero(&g_dm, sizeof g_dm);
    mem_zero(g_tabs, sizeof g_tabs);
    g_fp.app = (uint64_t)(uintptr_t)&g_app;
    g_fp.model = (uint64_t)(uintptr_t)&g_dm;
    g_fp.tabs = (uint64_t)(uintptr_t)g_tabs;
    g_fp.tab_count = 1;
    g_fp.active_tab = 0;
    g_fp.hovered_row = (uint32_t)-1;
    g_fp.hovered_col_hdr = (uint32_t)-1;
    g_fp.base.flags = WF_VISIBLE | WF_FOCUSED;
    g_dm.entries = g_ents;
    g_dm.order = g_ord;
    g_dm.name_pool = g_pool;
    (void)str_copy(g_dm.path, "/home/dev/project/src/ui", PATH_MAX);
    (void)str_copy(g_tabs[0].path, "/home/dev/project/src/ui", PATH_MAX);
    (void)str_copy(g_tabs[1].path, "/var/log/deep", PATH_MAX);
    (void)str_copy(g_tabs[2].path, "/", PATH_MAX);
    g_tabs[3].path[0] = 0;

    size_t poff = 0;
    if (bench) {
        for (size_t i = 0; i < 200; i++) {
            char nm[32] = "file_entry_";
            char nb[24];
            u64_to_dec(i, nb);
            (void)str_cat(nm, nb, sizeof nm);
            (void)str_cat(nm, ".txt", sizeof nm);
            uint32_t fl = (i == 0) ? (FE_IS_DIR | FE_IS_PARENT) :
                          ((i % 7 == 0) ? FE_IS_DIR : ((i % 5 == 0) ? FE_IS_EXEC : 0));
            add_entry(i, &poff, nm, (int64_t)(i * 1024 + 512), 1700000000 + (int64_t)i * 60,
                      (fl & FE_IS_DIR) ? 0040755 : 0100644, fl);
        }
        g_dm.count = 200;
        g_dm.dir_count = 29;
        g_dm.file_count = 171;
        g_dm.total_bytes = 20000000;
        return;
    }

    add_entry(0, &poff, "..", 0, 1700000000, 0040755, FE_IS_DIR | FE_IS_PARENT);
    add_entry(1, &poff, "subdir", 4096, 1700000100, 0040755, FE_IS_DIR);
    add_entry(2, &poff, "run.sh", 2048, 1700000200, 0100755, FE_IS_EXEC);
    add_entry(3, &poff, "sym_file", 12, 1700000300, 0120777, FE_IS_LINK);
    add_entry(4, &poff, "sym_dir", 12, 1700000400, 0120777, FE_IS_LINK | FE_LINK_DIR);
    add_entry(5, &poff, ".hidden_rc", 512, 1700000500, 0100600, FE_IS_HIDDEN);
    add_entry(6, &poff, "a_very_long_filename_that_triggers_ellipsis_truncation.txt",
              999999, 1700000600, 0100644, FE_SELECTED);
    add_entry(7, &poff, "plain_a.c", 100, 1700000700, 0100644, 0);
    add_entry(8, &poff, "plain_b.c", 200, 1700000800, 0100644, 0);
    add_entry(9, &poff, "plain_c.c", 300, 1700000900, 0100644, 0);
    add_entry(10, &poff, "plain_d.c", 400, 1700001000, 0100644, 0);
    add_entry(11, &poff, "plain_e.c", 500, 1700001100, 0100644, 0);
    g_dm.count = 12;
    g_dm.dir_count = 1;
    g_dm.file_count = 10;
    g_dm.total_bytes = 1004060;
}

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    if (argc < 2) return 2;
    g_ref = argv[1][0] == 'r';
    const Theme *theme = ui_theme();
    ScreenBuffer *scr = ScreenBuffer_new(90, 40);
    if (!scr) return 3;
    ui_app_reset(&g_app);
    g_app.theme = (uintptr_t)theme;

    if (argc >= 3 && argv[2][0] == 'b') {
        init_model(1);
        g_fp.base.x = 0; g_fp.base.y = 0; g_fp.base.w = 80; g_fp.base.h = 36;
        for (int i = 0; i < 600; i++) {
            g_fp.scroll = (uint32_t)(i % 150);
            g_fp.cursor = g_fp.scroll + (uint32_t)(i % 30);
            CALL_RENDER(&g_fp, scr, (void *)theme);
        }
        return 0;
    }

    init_model(0);
    char *script = sc_read_all();
    for (char *line; (line = sc_next_line(&script));) {
        const char *a = line + (line[0] ? 1 : 0);
        switch (line[0]) {
        case 'G': {
            g_fp.base.x = (int32_t)ui_parse_num(&a);
            g_fp.base.y = (int32_t)ui_parse_num(&a);
            g_fp.base.w = (int32_t)ui_parse_num(&a);
            g_fp.base.h = (int32_t)ui_parse_num(&a);
            break;
        }
        case 'F': {
            int foc = (int)ui_parse_num(&a);
            g_fp.base.flags = WF_VISIBLE | (foc ? WF_FOCUSED : 0);
            g_fp.cursor = (uint32_t)ui_parse_num(&a);
            g_fp.scroll = (uint32_t)ui_parse_num(&a);
            g_fp.hovered_row = (uint32_t)ui_parse_num(&a);
            g_fp.hovered_col_hdr = (uint32_t)ui_parse_num(&a);
            break;
        }
        case 'S': {
            g_dm.sort_mode = (int32_t)ui_parse_num(&a);
            g_dm.sort_desc = (int32_t)ui_parse_num(&a);
            g_dm.is_unsorted = (int32_t)ui_parse_num(&a);
            g_dm.is_loading = (int32_t)ui_parse_num(&a);
            g_dm.load_aborted = (int32_t)ui_parse_num(&a);
            g_dm.huge_mode = (int32_t)ui_parse_num(&a);
            g_dm.raw_count = 4200;
            break;
        }
        case 'T': {
            g_fp.tab_count = (uint32_t)ui_parse_num(&a);
            g_fp.active_tab = (uint32_t)ui_parse_num(&a);
            break;
        }
        case 'P': {
            while (*a == ' ') a++;
            (void)str_copy(g_dm.path, a, PATH_MAX);
            break;
        }
        case 'L': {
            while (*a == ' ') a++;
            if (a[0] == '-' && !a[1]) g_dm.filter[0] = 0;
            else (void)str_copy(g_dm.filter, a, FILTER_MAX);
            break;
        }
        case 'U': {
            int sel = (int)ui_parse_num(&a);
            if (sel) g_ents[6].flags |= FE_SELECTED;
            else g_ents[6].flags &= ~(uint32_t)FE_SELECTED;
            break;
        }
        case 'R': {
            ScreenBuffer_clear(scr, 0x01010101, 0x01020202);
            CALL_RENDER(&g_fp, scr, (void *)theme);
            int rows = g_fp.base.h > 0 ? g_fp.base.h : 1;
            if (g_fp.base.y + rows > 40) rows = 40 - g_fp.base.y;
            ui_dump(scr, g_fp.base.y, rows);
            if (g_fp.tab_zone_count > 0) {
                const HitZone *tz = (const HitZone *)g_fp.tab_zones;
                sc_put("TZ cnt="); sc_num(g_fp.tab_zone_count);
                for (uint32_t i = 0; i < g_fp.tab_zone_count; i++) {
                    sc_put(" ["); sc_num((int16_t)tz[i].x1); sc_put(","); sc_num((int16_t)tz[i].x2);
                    sc_put("#"); sc_num((int16_t)tz[i].id); sc_put("]");
                }
                sc_put("\n");
            }
            break;
        }
        default: continue;
        }
        sc_flush();
    }
    sc_flush();
    return 0;
}
