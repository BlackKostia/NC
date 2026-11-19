/* src/ui/viewer_dialog.c - ViewerDialog (Inherits from Dialog): Text / Hex / Image file viewer
 * with read-only mmap for arbitrary-size regular files, SIMD newline scanning, and offset-based
 * navigation (freestanding C23; replaces viewer_dialog{,_end,_input}.s, kept as tests/harness/viewer_dialog*_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_keys.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

#define VIEWER_MAX_SIZE 1048576u

static void ViewerDialog_dtor(Object *self);
static void ViewerDialog_layout(Widget *self, int x, int y, int w, int h);
static int ViewerDialog_on_key(Widget *self, void *event);
static int ViewerDialog_on_mouse(Widget *self, void *event);

static void vw_on_btn0_dlg(Dialog *self) { ViewerDialog_on_btn0((ViewerDialog *)(void *)self); }

DIALOG_VTBL(ViewerDialog_vtbl, "ViewerDialog", Dialog_vtbl, sizeof(ViewerDialog),
            .base.base.dtor = ViewerDialog_dtor, .base.layout = ViewerDialog_layout,
            .base.render = ViewerDialog_render, .base.on_key = ViewerDialog_on_key,
            .base.on_mouse = ViewerDialog_on_mouse, .on_confirm = vw_on_btn0_dlg,
            .on_cancel = Dialog_on_cancel);

static void vw_load_file(ViewerDialog *v, const char *path)
{
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
    if (!os_is_err(fd)) {
        FileStat st;
        if (!os_is_err(os_fstat((int)fd, &st)) && (st.mode & S_IFMT) == S_IFREG && st.size > 0) {
            void *p = os_mmap_file_ro((int)fd, (size_t)st.size);
            if (p) {
                v->data = (uint64_t)(uintptr_t)p;
                v->data_len = (uint64_t)st.size;
                v->map_len = (uint64_t)st.size;
            }
        }
        (void)os_close((int)fd);
    }
    if (v->data == 0) {
        void *fbuf = nullptr;
        size_t flen = 0;
        (void)fs_read_file_alloc(path, VIEWER_MAX_SIZE, &fbuf, &flen);
        v->data = (uint64_t)(uintptr_t)fbuf;
        v->data_len = (uint64_t)flen;
    }
}

ViewerDialog *ViewerDialog_new(App *app, const char *path)
{
    void *raw = Object_alloc(DUOP_OBJ_VTBL(ViewerDialog_vtbl), sizeof(ViewerDialog));
    if (!raw) return nullptr;
    Dialog_init((Dialog *)raw, app, i18n_get()->s[LS_dlg_title_viewer], 0);
    ViewerDialog *v = raw;
    v->base.focus_btn = 1;
    v->total_lines = (uint64_t)(int64_t)-1;
    (void)str_copy((char *)v->path, path, PATH_MAX);
    vw_load_file(v, path);
    if (v->data != 0) {
        size_t scan = v->data_len <= 512u ? (size_t)v->data_len : 512u;
        size_t pos = os_mem_find_byte((const void *)(uintptr_t)v->data, scan, 0);
        if (pos < scan) v->hex_mode = 1;
    }
    ViewerDialog_layout((Widget *)raw, 0, 0, (int)app->term_w, (int)app->term_h);
    return v;
}

static void ViewerDialog_dtor(Object *self)
{
    ViewerDialog *v = (ViewerDialog *)(void *)self;
    viewer_img_free(v);
    hex_edit_free(v);
    if (v->map_len != 0)
        (void)os_munmap((void *)(uintptr_t)v->data, (size_t)v->map_len);
    else
        mem_free((void *)(uintptr_t)v->data);
    v->data = 0;
}

static void ViewerDialog_layout(Widget *self, int x, int y, int w, int h)
{
    int dw = w - 4;
    if (dw < 30) dw = w;
    int dh = h - 2;
    if (dh < 12) dh = h;
    Widget_layout(self, x + ((w - dw) >> 1), y + ((h - dh) >> 1), dw, dh);
    ViewerDialog *v = (ViewerDialog *)(void *)self;
    v->vis_rows = (uint32_t)(self->h - 5);
    const LangStrings *ls = i18n_get();
    dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_hex], ls->s[LS_dlg_btn_close]);
}

void ViewerDialog_on_btn0(ViewerDialog *v)
{
    v->hex_mode ^= 1u;
    if (v->hex_mode) {
        v->hex_row = v->top_off >> 4;
    } else {
        v->top_off = 0;
        v->top_line = 0;
    }
    ((App *)(uintptr_t)v->base.app)->need_redraw = 1;
}

static int vw_line_down(ViewerDialog *v)
{
    const uint8_t *data = (const uint8_t *)(uintptr_t)v->data;
    if (!data || v->top_off >= v->data_len) return 0;
    uint64_t rem = v->data_len - v->top_off;
    size_t idx = os_mem_find_byte(data + v->top_off, (size_t)rem, '\n');
    if (idx >= rem) return 0;
    uint64_t next = v->top_off + (uint64_t)idx + 1u;
    if (next >= v->data_len) return 0;
    v->top_off = next;
    v->top_line++;
    return 1;
}

static int vw_line_up(ViewerDialog *v)
{
    uint64_t off = v->top_off;
    if (off == 0) return 0;
    const uint8_t *data = (const uint8_t *)(uintptr_t)v->data;
    int64_t p = (int64_t)off - 2;
    uint64_t dst = 0;
    while (p >= 0) {
        if (data[p] == '\n') { dst = (uint64_t)(p + 1); break; }
        p--;
    }
    v->top_off = dst;
    v->top_line = v->top_line > 0 ? v->top_line - 1u : 0;
    return 1;
}

static void vw_scroll(ViewerDialog *v, int64_t delta)
{
    if (v->hex_mode == 0) {
        while (delta > 0 && vw_line_down(v)) delta--;
        while (delta < 0 && vw_line_up(v)) delta++;
    } else {
        int64_t row = (int64_t)v->hex_row + delta;
        if (row < 0) row = 0;
        int64_t max_r = (int64_t)((v->data_len + 15u) >> 4) - 1;
        if (max_r < 0) max_r = 0;
        if (row > max_r) row = max_r;
        v->hex_row = (uint64_t)row;
    }
    ((App *)(uintptr_t)v->base.app)->need_redraw = 1;
}

static void vw_home(ViewerDialog *v)
{
    v->top_off = 0;
    v->top_line = 0;
    v->hex_row = 0;
    ((App *)(uintptr_t)v->base.app)->need_redraw = 1;
}

static void vw_end(ViewerDialog *v)
{
    uint64_t len = v->data_len;
    if (v->hex_mode != 0) {
        int64_t hr = (int64_t)((len + 15u) >> 4) - (int64_t)(int32_t)v->vis_rows;
        v->hex_row = hr > 0 ? (uint64_t)hr : 0;
        ((App *)(uintptr_t)v->base.app)->need_redraw = 1;
        return;
    }
    const uint8_t *data = (const uint8_t *)(uintptr_t)v->data;
    if (data && len != 0) {
        if ((int64_t)v->total_lines < 0) {
            uint64_t total = os_mem_count_byte(data, (size_t)len, '\n');
            if (data[len - 1] != '\n') total++;
            v->total_lines = total;
        }
        int64_t p = (int64_t)len - 1;
        if (data[p] == '\n') p--;
        uint64_t last_off = 0;
        while (p >= 0) {
            if (data[p] == '\n') { last_off = (uint64_t)(p + 1); break; }
            p--;
        }
        v->top_off = last_off;
        v->top_line = v->total_lines > 0 ? v->total_lines - 1u : 0;
        int64_t up = (int64_t)(int32_t)v->vis_rows - 1;
        while (up > 0 && vw_line_up(v)) up--;
    }
    ((App *)(uintptr_t)v->base.app)->need_redraw = 1;
}

static int ViewerDialog_on_key(Widget *self, void *event)
{
    ViewerDialog *v = (ViewerDialog *)(void *)self;
    Event *ev = event;
    if (hex_edit_on_key(v, ev)) return 1;
    if (viewer_mode_key(v, ev)) return 1;
    if (vim_zoom_key(v, ev)) return 1;
    switch (ev->lat) {
    case KEY_ESC: case 'q': case 'Q': case KEY_F3: case KEY_F10:
        DIALOG_CALL((Dialog *)self, on_cancel);
        break;
    case 'h': case 'H':
        ViewerDialog_on_btn0(v);
        break;
    case KEY_UP: case 'k':
        vw_scroll(v, -1);
        break;
    case KEY_DOWN: case 'j':
        vw_scroll(v, 1);
        break;
    case KEY_PGUP:
        vw_scroll(v, -((int64_t)(int32_t)v->vis_rows - 1));
        break;
    case KEY_PGDN: case ' ':
        vw_scroll(v, (int64_t)(int32_t)v->vis_rows - 1);
        break;
    case KEY_HOME:
        vw_home(v);
        break;
    case KEY_END:
        vw_end(v);
        break;
    default:
        break;
    }
    return 1;
}

static int ViewerDialog_on_mouse(Widget *self, void *event)
{
    ViewerDialog *v = (ViewerDialog *)(void *)self;
    Event *ev = event;
    if (vim_zoom_mouse(v, ev)) return 1;
    if (ev->mouse_kind != MACT_WHEEL) return Dialog_on_mouse(self, event);
    vw_scroll(v, ev->mouse_btn == MOUSE_WHEEL_UP ? -3 : 3);
    return 1;
}
