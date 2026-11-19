/* src/ui/file_pane_layout.c - FilePane adaptive column geometry & header hit-zones
 * (freestanding C23; replaces file_pane_layout.s, kept as tests/harness/file_pane_layout_reference.s). */
#include "duop_classes.h"
#include "duop_config.h"
#include "duop_ui.h"

FilePaneCols file_pane_compute_cols(int32_t w)
{
    int32_t inner = w > 3 ? w - 2 : 1;
    int32_t size_w = 0;
    int32_t extra_w = 0;
    int32_t extra_is_date = 0;

    if (w >= 54) {
        size_w = 9;
        extra_w = 17; /* 1 space + 16 date */
        extra_is_date = 1;
    } else if (w >= 40) {
        size_w = 9;
        extra_w = 11; /* 1 space + 10 perms */
    } else if (w >= 28) {
        size_w = 9;
    }

    int32_t name_w = inner - size_w - extra_w;
    return (FilePaneCols){name_w, size_w, extra_w, extra_is_date};
}

static void fpl_set_zone(HitZone *z, int32_t x1, int32_t x2, int32_t y, uint16_t id)
{
    z->x1 = (uint16_t)x1;
    z->x2 = (uint16_t)x2;
    z->y = (uint16_t)y;
    z->id = id;
}

void FilePane_layout(Widget *self, int x, int y, int w, int h)
{
    FilePane *fp = (FilePane *)self;
    Widget_layout(self, x, y, w, h);

    FilePaneCols c = file_pane_compute_cols(fp->base.w);
    int32_t col = fp->base.x + 1;
    int32_t row = fp->base.y + 1;
    HitZone *zones = (HitZone *)fp->hdr_zones;
    uint32_t cnt = 1;

    fpl_set_zone(&zones[0], col, col + c.name_w, row, SORT_NAME);
    col += c.name_w;

    if (c.size_w != 0) {
        fpl_set_zone(&zones[1], col, col + c.size_w, row, SORT_SIZE);
        col += c.size_w;
        cnt = 2;

        if (c.extra_w != 0) {
            uint16_t id = c.extra_is_date ? SORT_MTIME : SORT_EXT;
            fpl_set_zone(&zones[2], col, col + c.extra_w, row, id);
            cnt = 3;
        }
    }

    fp->hdr_zone_count = cnt;
    FilePane_ensure_visible(fp);
}
