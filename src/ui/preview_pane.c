/* src/ui/preview_pane.c - PreviewPane widget (Inherits from Widget): lifecycle, file loading,
 * synchronous fallback reader, buffer/thumbnail acceptance, and ANSI-stripping line copy
 * (freestanding C23; replaces src/ui/preview_pane.s, kept as tests/harness/preview_pane_reference.s). */
#include "duop_classes.h"
#include "duop_fs.h"
#include "duop_img.h"
#include "duop_preview.h"
#include "duop_string.h"
#include "duop_tui.h"
#include "duop_ui.h"

#define PV_BUF_TOTAL (PREVIEW_BUF_SIZE + 16u + IMG_THUMB_CAP)

static void PreviewPane_dtor(Object *self);

WIDGET_VTBL(PreviewPane_vtbl, "PreviewPane", Widget_vtbl, sizeof(PreviewPane),
            .base.dtor = PreviewPane_dtor, .render = PreviewPane_render,
            .on_mouse = PreviewPane_on_mouse);

PreviewPane *PreviewPane_new(App *app)
{
    void *raw = Object_alloc(DUOP_OBJ_VTBL(PreviewPane_vtbl), sizeof(PreviewPane));
    if (!raw) return nullptr;
    Widget_init((Widget *)raw, app, 103);
    PreviewPane *pv = raw;
    pv->app = (uint64_t)(uintptr_t)app;
    void *buf = mem_alloc(PV_BUF_TOTAL);
    if (!buf) {
        mem_free(raw);
        return nullptr;
    }
    pv->buf = (uint64_t)(uintptr_t)buf;
    return pv;
}

static void PreviewPane_dtor(Object *self)
{
    PreviewPane *pv = (PreviewPane *)(void *)self;
    mem_free((void *)(uintptr_t)pv->buf);
    pv->buf = 0;
}

int PreviewPane_load(PreviewPane *self, const char *full_path, const FileEntry *entry)
{
    self->scroll = 0;
    self->buf_len = 0;
    self->total_lines = 0;
    self->is_binary = 0;
    self->is_dir = 0;
    self->pending = 0;
    self->thumb_len = 0;
    self->view_mode = PV_MODE_AUTO;

    if (!entry || !full_path) return 0;
    (void)str_copy((char *)self->target_path, full_path, PATH_MAX);
    self->file_size = (uint64_t)entry->size;
    self->file_mode = entry->mode;
    if (entry->flags & (FE_IS_DIR | FE_LINK_DIR)) {
        self->is_dir = 1;
        return 0;
    }
    self->pending = 1;
    return 1;
}

void PreviewPane_accept(PreviewPane *self, size_t len, size_t tlen, const uint8_t *thumb)
{
    self->buf_len = (uint64_t)len;
    uint32_t tl = 0;
    if (tlen >= IMG_THUMB_HDR) {
        tl = (uint32_t)tlen;
        self->thumb_ptr = (uint64_t)(uintptr_t)thumb;
        self->thumb_mode = self->req_mode;
        self->thumb_gen++;
    }
    self->thumb_len = tl;
    self->pending = 0;
    self->total_lines = 0;
    self->is_binary = 0;

    uint8_t *buf = (uint8_t *)(uintptr_t)self->buf;
    buf[len] = 0;
    uint32_t lines = 1;
    for (size_t i = 0; i < len; i++) {
        if (buf[i] == 0 && i < 512u) self->is_binary = 1;
        if (buf[i] == '\n') lines++;
    }
    self->total_lines = len ? lines : 0;
}

void PreviewPane_read_sync(PreviewPane *self)
{
    uint8_t *buf = (uint8_t *)(uintptr_t)self->buf;
    size_t rd = 0;
    (void)fs_read_file_head((const char *)self->target_path, buf, PREVIEW_BUF_SIZE, &rd);
    self->buf_len = (uint64_t)rd;
    PvThumbReq req;
    (void)PreviewPane_thumb_req(self, &req);
    ImgFit bpx = pv_box_pixels(self, IMG_PROTO_QUAD);
    req.w = (uint16_t)bpx.w;
    req.h = (uint16_t)bpx.h;
    req.proto = IMG_PROTO_QUAD;
    req.cols = 0;
    req.pad[0] = 0;
    req.pad[1] = 0;
    self->req_mode = IMG_PROTO_QUAD;
    uint8_t *thumb_out = buf + rd + 1;
    size_t tlen = pv_make_thumb((const char *)self->target_path, buf, rd, &req,
                                thumb_out, PV_BUF_TOTAL - 1u - rd);
    PreviewPane_accept(self, rd, tlen, thumb_out);
}

const char *pv_copy_line_strip_ansi(const char *p, const char *end, char *dst)
{
    size_t n = 0;
    while (p < end) {
        uint8_t ch = (uint8_t)*p++;
        if (ch == '\n') break;
        if (ch == '\r') continue;
        if (ch == 27) {
            if (p < end && *p == '[') {
                p++;
                while (p < end) {
                    uint8_t c = (uint8_t)*p++;
                    if (c == '\n') { dst[n] = 0; return p; }
                    if (c >= 0x40 && c <= 0x7E) break;
                }
            }
            continue;
        }
        if (n >= 250) continue;
        if (ch == '\t') { dst[n++] = ' '; dst[n++] = ' '; continue; }
        dst[n++] = (char)ch;
    }
    dst[n] = 0;
    return p;
}
