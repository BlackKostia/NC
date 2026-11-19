/* src/ui/img_overlay.c - Pixel-protocol image overlay (Sixel / Kitty) for one picture at a time
 * (freestanding C23; replaces img_overlay.s, kept as tests/harness/img_overlay_reference.s). */
#include "duop_classes.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "duop_ui.h"

static const char seq_kitty_del[16] = "\x1b_Ga=d,d=A,q=2\x1b\\";
static const char seq_kitty_del_p[16] = "\x1b_Ga=d,d=a,q=2\x1b\\";
static const char seq_ov_sync_on[8] = "\x1b[?2026h";
static const char seq_ov_sync_off[8] = "\x1b[?2026l";

static ImgPlace ov_cur;
static ImgPlace ov_last;
static int32_t ov_cur_on;
static int32_t ov_last_on;
static int32_t ov_last_proto;
static int32_t ov_emit;
static int32_t ov_del_on_emit;
static const void *ov_kitty_tx_img;

int img_overlay_kitty_ready(const void *pixels)
{
    return pixels == ov_kitty_tx_img ? 1 : 0;
}

void img_overlay_kitty_mark(const void *pixels)
{
    ov_kitty_tx_img = pixels;
}

void img_overlay_show(const ImgPlace *p)
{
    mem_copy(&ov_cur, p, sizeof ov_cur);
    ov_cur_on = 1;
}

static int ov_same_rect(void)
{
    return ov_cur.x == ov_last.x && ov_cur.y == ov_last.y &&
           ov_cur.w == ov_last.w && ov_cur.h == ov_last.h;
}

static int ov_same(void)
{
    return ov_cur.key == ov_last.key && ov_cur.data == ov_last.data && ov_same_rect();
}

static void ov_remove(App *app)
{
    ov_last_on = 0;
    ov_kitty_tx_img = nullptr;
    if (ov_last_proto == IMG_PROTO_KITTY) {
        (void)sys_write_all(STDOUT_FD, seq_kitty_del, sizeof seq_kitty_del);
        return;
    }
    ScreenBuffer *scr = (ScreenBuffer *)(uintptr_t)app->screen;
    ScreenBuffer_rect_invalidate(scr, (int)ov_last.x, (int)ov_last.y, (int)ov_last.w, (int)ov_last.h);
}

void img_preview_pre_flush(App *app)
{
    ov_emit = 0;
    ov_del_on_emit = 0;
    int vis = 0;
    if (ov_cur_on != 0 && (app->active_dialog == 0 || app->active_dialog == ov_cur.owner))
        vis = 1;
    ov_cur_on = 0;

    if (ov_last_on == 0) {
        ov_emit = vis;
        return;
    }
    if (!vis) {
        ov_remove(app);
        return;
    }
    if (ov_same()) {
        if (ov_last_proto == IMG_PROTO_SIXEL) {
            ScreenBuffer *scr = (ScreenBuffer *)(uintptr_t)app->screen;
            ov_emit = ScreenBuffer_rect_changed(scr, (int)ov_cur.x, (int)ov_cur.y,
                                                (int)ov_cur.w, (int)ov_cur.h);
        }
        return;
    }
    if (ov_same_rect()) {
        ov_last_on = 0;
        ov_emit = vis;
        return;
    }
    if (ov_last_proto == IMG_PROTO_KITTY) {
        ov_del_on_emit = 1;
        ov_last_on = 0;
        ov_emit = vis;
        return;
    }
    ov_remove(app);
    ov_emit = vis;
}

void img_preview_post_flush(App *app)
{
    (void)app;
    if (ov_emit == 0) return;

    (void)sys_write_all(STDOUT_FD, seq_ov_sync_on, sizeof seq_ov_sync_on);
    if (ov_del_on_emit != 0) {
        ov_del_on_emit = 0;
        const char *del = ov_kitty_tx_img ? seq_kitty_del_p : seq_kitty_del;
        (void)sys_write_all(STDOUT_FD, del, sizeof seq_kitty_del);
    }

    char seq[48];
    seq[0] = 0x1B;
    seq[1] = '[';
    size_t n = 2;
    n += u64_to_dec((uint64_t)(ov_cur.y + 1u), seq + n);
    seq[n++] = ';';
    n += u64_to_dec((uint64_t)(ov_cur.x + 1u), seq + n);
    seq[n++] = 'H';
    (void)sys_write_all(STDOUT_FD, seq, n);

    (void)sys_write_all(STDOUT_FD, (const void *)(uintptr_t)ov_cur.data, (size_t)ov_cur.len);
    (void)sys_write_all(STDOUT_FD, seq_ov_sync_off, sizeof seq_ov_sync_off);

    mem_copy(&ov_last, &ov_cur, sizeof ov_last);
    ov_last_on = 1;
    ov_last_proto = term_img_proto();
    ov_emit = 0;
}
