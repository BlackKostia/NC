/* src/ui/info_dialog.c - Detailed File Info dialog (inode, nlink, mode, CRC32, SHA-256)
 * (freestanding C23; replaces src/ui/info_dialog.s, kept as tests/harness/info_dialog_reference.s). */
#include "duop_classes.h"
#include "duop_hash.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"
#include "i18n_slots.h"

static void InfoDialog_layout(Widget *self, int x, int y, int w, int h);
static void InfoDialog_render(Widget *self, void *screen, void *theme);
static int InfoDialog_on_key(Widget *self, void *event);

DIALOG_VTBL(InfoDialog_vtbl, "InfoDialog", Dialog_vtbl, sizeof(InfoDialog),
            .base.layout = InfoDialog_layout, .base.render = InfoDialog_render,
            .base.on_key = InfoDialog_on_key,
            .on_confirm = Dialog_on_cancel, .on_cancel = Dialog_on_cancel);

InfoDialog *InfoDialog_new(App *app, const char *path)
{
    void *raw = Object_alloc(DUOP_OBJ_VTBL(InfoDialog_vtbl), sizeof(InfoDialog));
    if (!raw) return nullptr;
    InfoDialog *d = raw;

    Dialog_init((Dialog *)raw, app, i18n_get()->s[LS_dlg_title_info], OP_INFO);
    (void)str_copy((char *)d->target_path, path, sizeof d->target_path);

    FileStat st;
    if (os_statat(AT_FDCWD, path, &st, 0) >= 0) {
        mem_copy(d->st, &st, sizeof st);
        if ((st.mode & S_IFMT) == S_IFREG) {
            uint32_t crc = 0;
            char sha[68];
            if (hash_file(path, &crc, sha) == 0) {
                d->crc32 = crc;
                mem_copy(d->sha_hex, sha, 65);
                d->hash_ok = 1;
            }
        }
    }

    int tw = app ? (int)app->term_w : 80;
    int th = app ? (int)app->term_h : 24;
    InfoDialog_layout((Widget *)raw, 0, 0, tw, th);
    return d;
}

static void InfoDialog_layout(Widget *self, int x, int y, int w, int h)
{
    (void)x;
    (void)y;
    int dw = w - 4;
    if (dw > 76) dw = 76;
    if (dw < 44) dw = 44;

    self->w = dw;
    self->h = 13;
    self->x = (w - dw) >> 1;
    self->y = (h - 13) >> 1;

    const LangStrings *ls = i18n_get();
    dlg_layout_right_buttons((Dialog *)self, ls->s[LS_dlg_btn_close], nullptr);
}

static void id_hex32(uint32_t v, char out[9])
{
    static const char hex[16] = "0123456789abcdef";
    for (int i = 7; i >= 0; i--) {
        out[i] = hex[v & 0x0FU];
        v >>= 4;
    }
    out[8] = '\0';
}

static void id_draw_kv(const InfoDialog *d, ScreenBuffer *scr, int row_off,
                       const char *lbl, const char *val)
{
    int ry = d->base.base.y + row_off;
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 3, ry, lbl, 9);
    (void)ScreenBuffer_draw_text(scr, d->base.base.x + 11, ry, val, d->base.base.w - 14);
}

static void InfoDialog_render(Widget *self, void *screen, void *theme)
{
    InfoDialog *d = (InfoDialog *)self;
    ScreenBuffer *scr = screen;
    const Theme *th = theme;
    const LangStrings *ls = i18n_get();

    Dialog_draw_frame((Dialog *)self, scr, th, ls->s[LS_dlg_btn_close], nullptr);
    ScreenBuffer_set_pen(scr, th->text, th->dialog_bg, ATTR_NONE);

    id_draw_kv(d, scr, 2, "Path:   ", path_basename((const char *)d->target_path));

    FileStat st;
    mem_copy(&st, d->st, sizeof st);
    char buf[64];

    (void)u64_to_dec(st.size, buf);
    id_draw_kv(d, scr, 3, "Size:   ", buf);

    (void)u64_to_dec(st.ino, buf);
    id_draw_kv(d, scr, 4, "Inode:  ", buf);

    (void)u64_to_dec(st.nlink, buf);
    id_draw_kv(d, scr, 5, "Links:  ", buf);

    uint64_t n = u64_to_dec(st.uid, buf);
    buf[n] = ':';
    (void)u64_to_dec(st.gid, buf + n + 1);
    id_draw_kv(d, scr, 6, "Owner:  ", buf);

    if (d->hash_ok) {
        id_hex32(d->crc32, buf);
        id_draw_kv(d, scr, 7, "CRC32:  ", buf);
        id_draw_kv(d, scr, 8, "SHA256: ", (const char *)d->sha_hex);
    } else {
        id_draw_kv(d, scr, 7, "CRC32:  ", "(dir/n/a)");
    }
}

static int InfoDialog_on_key(Widget *self, void *event)
{
    uint32_t lat = ((const Event *)event)->lat;
    if (lat == KEY_ESC || lat == KEY_ENTER || lat == 'q') {
        Dialog_on_cancel((Dialog *)self);
        return 1;
    }
    return 0;
}
