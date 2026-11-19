/* src/ui/viewer_dialog_render.c - ViewerDialog text and hex frame rendering
 * (freestanding C23; replaces src/ui/viewer_dialog_render.s, kept as
 * tests/harness/viewer_dialog_render_reference.s). */
#include "duop_classes.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define VW_LINE_MAX 248

static void vw_draw_header_and_hint(Widget *self, const ViewerDialog *v, ScreenBuffer *scr, const Theme *th)
{
    const LangStrings *ls = i18n_get();
    Dialog_draw_frame((Dialog *)self, scr, th, ls->s[LS_dlg_btn_hex], ls->s[LS_dlg_btn_close]);

    ScreenBuffer_set_pen(scr, th->dir_fg, th->dialog_bg, ATTR_BOLD);
    (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y + 1, (const char *)v->path, self->w - 4);

    ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
    const HitZone *bz = (const HitZone *)(const void *)((const Dialog *)self)->btns;
    int room = (int16_t)bz[0].x1 - (self->x + 3);
    if (room > 0)
        (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y + self->h - 2, ls->s[LS_dlg_vw_hint], room);
}

static size_t vw_copy_text_line(const uint8_t *src, size_t len, char *line)
{
    size_t dst = 0;
    for (size_t i = 0; i < len && dst < VW_LINE_MAX; i++) {
        uint8_t ch = src[i];
        if (ch == '\r') continue;
        if (ch == '\t') { line[dst++] = ' '; line[dst++] = ' '; continue; }
        line[dst++] = ch ? (char)ch : '.';
    }
    line[dst] = 0;
    return dst;
}

__attribute__((noinline))
static int64_t vw_render_text(const Widget *self, const ViewerDialog *v, ScreenBuffer *scr,
                              const Theme *th, int rows)
{
    char line[256], num[32];
    int nw = (int)u64_to_dec(v->top_line + (uint64_t)rows, num);
    if (nw < 5) nw = 5;
    int numw = nw + 1;
    uint64_t line_no = v->top_line;
    uint64_t off = v->top_off;
    const uint8_t *data = (const uint8_t *)(uintptr_t)v->data;

    for (int row = 0; row < rows && off < v->data_len; row++, line_no++) {
        (void)u64_to_dec(line_no + 1u, num);
        ScreenBuffer_set_pen(scr, th->muted, th->dialog_bg, ATTR_NONE);
        ScreenBuffer_draw_text_pad(scr, self->x + 2, self->y + 2 + row, num, numw);

        size_t llen = os_mem_find_byte(data + off, (size_t)(v->data_len - off), '\n');
        (void)vw_copy_text_line(data + off, llen, line);
        syntax_draw_line(scr, self->x + 3 + numw, self->y + 2 + row, line,
                         self->w - 5 - numw, (const char *)v->path, th, th->dialog_bg);
        off += (uint64_t)llen + 1u;
    }
    return (int64_t)off;
}

static int64_t vw_render_hex(const Widget *self, const ViewerDialog *v, ScreenBuffer *scr,
                             const Theme *th, int rows)
{
    static const char hx[] = "0123456789abcdef";
    char line[256];
    uint64_t off = v->hex_row << 4;
    const uint8_t *data = (const uint8_t *)(uintptr_t)v->data;

    for (int row = 0; row < rows && off < v->data_len; row++, off += 16u) {
        int n = (int)u64_to_hex(off, line, 8);
        line[n] = ':';
        line[n + 1] = ' ';
        int hp = n + 2;
        int ap = n + 2 + 49;
        line[ap - 1] = '|';
        for (int c = 0; c < 16; c++) {
            if (off + (uint64_t)c < v->data_len) {
                uint8_t b = data[off + (uint64_t)c];
                line[hp] = hx[b >> 4];
                line[hp + 1] = hx[b & 15u];
                line[hp + 2] = ' ';
                line[ap] = b >= 0x20 && b <= 0x7E ? (char)b : '.';
            } else {
                line[hp] = ' ';
                line[hp + 1] = ' ';
                line[hp + 2] = ' ';
                line[ap] = ' ';
            }
            hp += 3;
            ap++;
        }
        line[hp] = ' ';
        line[ap] = '|';
        line[ap + 1] = 0;
        ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);
        (void)ScreenBuffer_draw_text(scr, self->x + 2, self->y + 2 + row, line, self->w - 4);
    }
    return (int64_t)off;
}

void ViewerDialog_render(Widget *self, void *screen, void *theme)
{
    ViewerDialog *v = (ViewerDialog *)(void *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    if (v->img_mode != 0) {
        ViewerDialog_render_image(v, scr);
        return;
    }
    vw_draw_header_and_hint(self, v, scr, th);
    int rows = self->h - 5;
    v->vis_rows = (uint32_t)rows;
    int64_t end_off = 0;
    if (rows >= 1 && v->data != 0) {
        if (v->hex_mode == 0)
            end_off = vw_render_text(self, v, scr, th, rows);
        else
            end_off = vw_render_hex(self, v, scr, th, rows);
    }
    vw_draw_text_scrollbar(v, scr, th, end_off);
}
