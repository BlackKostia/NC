/* src/ui/hex_edit.c - In-place Hex editor inside ViewerDialog (E to toggle, 0-9a-f nibbles,
 * Ctrl+Z undo ring, Ctrl+S atomic save via fs_write_file; freestanding C23; replaces
 * src/ui/hex_edit.s, kept as tests/harness/hex_edit_reference.s). */
#include "duop_app.h"
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_keys.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"

#define HEX_UNDO_MAX 64

typedef struct HexUndo {
    uint64_t off;
    uint8_t old_byte;
    uint8_t pad[7];
} HexUndo;

typedef struct HexEditCtx {
    int32_t active;
    int32_t nibble;
    int32_t dirty;
    uint32_t undo_cnt;
    uint64_t cursor;
    HexUndo undo_ring[HEX_UNDO_MAX];
} HexEditCtx;
_Static_assert(sizeof(HexEditCtx) == 1048 && offsetof(HexEditCtx, cursor) == 16 &&
               offsetof(HexEditCtx, undo_ring) == 24 && sizeof(HexUndo) == 16,
               "HexEditCtx layout differs from the assembler");

void hex_edit_free(ViewerDialog *vd)
{
    void *ctx = (void *)(uintptr_t)vd->hex_edit_ctx;
    if (!ctx) return;
    mem_free(ctx);
    vd->hex_edit_ctx = 0;
}

static HexEditCtx *hex_edit_ensure_writable(ViewerDialog *vd)
{
    HexEditCtx *ctx = (HexEditCtx *)(uintptr_t)vd->hex_edit_ctx;
    if (!ctx) {
        ctx = mem_alloc(sizeof *ctx);
        if (!ctx) return nullptr;
        mem_zero(ctx, sizeof *ctx);
        vd->hex_edit_ctx = (uint64_t)(uintptr_t)ctx;
    }
    if (vd->map_len != 0 && vd->data_len != 0) {
        void *buf = mem_alloc(vd->data_len);
        if (!buf) return nullptr;
        mem_copy(buf, (const void *)(uintptr_t)vd->data, vd->data_len);
        (void)os_munmap((void *)(uintptr_t)vd->data, vd->map_len);
        vd->data = (uint64_t)(uintptr_t)buf;
        vd->map_len = 0;
    }
    return ctx;
}

static int hex_parse_nibble(uint32_t ch)
{
    if (ch >= '0' && ch <= '9') return (int)(ch - '0');
    if (ch >= 'a' && ch <= 'f') return (int)(ch - 'a' + 10);
    if (ch >= 'A' && ch <= 'F') return (int)(ch - 'A' + 10);
    return -1;
}

static int hex_edit_ctrl(ViewerDialog *vd, HexEditCtx *ctx, uint32_t key)
{
    if (key == 'z') {
        if (ctx->undo_cnt != 0) {
            ctx->undo_cnt--;
            const HexUndo *u = &ctx->undo_ring[ctx->undo_cnt & 63u];
            ((uint8_t *)(uintptr_t)vd->data)[u->off] = u->old_byte;
            ctx->cursor = u->off;
            ctx->nibble = 0;
        }
        return 1;
    }
    if (key == 's') {
        if (fs_write_file((const char *)vd->path, (const void *)(uintptr_t)vd->data, vd->data_len) == 0) {
            ctx->dirty = 0;
        } else {
            const char *msg = fs_errno_message(-EIO);
            App *app = (App *)(uintptr_t)vd->base.app;
            if (app) App_set_status(app, msg, MSG_ERR);
        }
        return 1;
    }
    return 0;
}

static void hex_edit_write_nibble(ViewerDialog *vd, HexEditCtx *ctx, int nib)
{
    uint64_t pos = ctx->cursor;
    if (pos >= vd->data_len) return;
    uint8_t *data = (uint8_t *)(uintptr_t)vd->data;
    uint8_t cur = data[pos];
    if (ctx->nibble == 0) {
        HexUndo *u = &ctx->undo_ring[ctx->undo_cnt & 63u];
        u->off = pos;
        u->old_byte = cur;
        ctx->undo_cnt++;
        data[pos] = (uint8_t)((cur & 0x0Fu) | ((uint32_t)nib << 4));
        ctx->nibble = 1;
        ctx->dirty = 1;
        return;
    }
    data[pos] = (uint8_t)((cur & 0xF0u) | (uint32_t)nib);
    ctx->nibble = 0;
    ctx->dirty = 1;
    if (pos + 1 < vd->data_len) ctx->cursor = pos + 1;
}

int hex_edit_on_key(ViewerDialog *vd, Event *ev)
{
    if (vd->hex_mode == 0) return 0;
    uint32_t key = ev->key, mods = ev->mods;
    HexEditCtx *ctx = (HexEditCtx *)(uintptr_t)vd->hex_edit_ctx;
    if (!(mods & (MOD_CTRL | MOD_ALT)) && (key == 'e' || key == 'E')) {
        ctx = hex_edit_ensure_writable(vd);
        if (!ctx) return 0;
        ctx->active ^= 1;
        ctx->cursor = vd->hex_row << 4;
        ctx->nibble = 0;
        ((App *)(uintptr_t)vd->base.app)->need_redraw = 1;
        return 1;
    }
    if (!ctx || !ctx->active) return 0;
    if (mods & MOD_CTRL) {
        if (!hex_edit_ctrl(vd, ctx, key)) return 0;
    } else if (key == KEY_LEFT) {
        if (ctx->cursor > 0) { ctx->cursor--; ctx->nibble = 0; }
    } else if (key == KEY_RIGHT) {
        if (ctx->cursor + 1 < vd->data_len) { ctx->cursor++; ctx->nibble = 0; }
    } else {
        int nib = hex_parse_nibble(key);
        if (nib < 0) return 0;
        hex_edit_write_nibble(vd, ctx, nib);
    }
    App *app = (App *)(uintptr_t)vd->base.app;
    if (app) app->need_redraw = 1;
    return 1;
}
