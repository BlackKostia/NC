/* src/fs/preview_helper.c - the preview helper process and the image thumbnailer (freestanding C23; replaces preview_helper.s, kept
 * as tests/harness/preview_helper_reference.s).
 *
 * pv_helper_main serves {seq, path, thumb request} messages from fs_preview_request: it reads the file head without ever blocking
 * (O_NONBLOCK: a FIFO under the cursor cannot hang it) and, for images, decodes the whole file and puts the thumbnail payload
 * (IMG_THUMB_HDR + RGBA pixels for block output, a ready Sixel / Kitty stream for pixel protocols) into the shared slot of the
 * request. pv_make_thumb is also called by the UI itself when no helper is available. */
#include "duop_preview.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define PV_HDR 16
#define PV_REQ 20

typedef struct PvRequest { uint32_t seq, len; PvThumbReq treq; } PvRequest;
_Static_assert(sizeof(PvRequest) == PV_REQ, "request layout of fs_preview_request");

static char g_ph_path[PATH_MAX];
static uint8_t g_ph_msg[PV_HDR + PREVIEW_BUF_SIZE];   /* reply header + head bytes: one write */

static void put16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { put16(p, v); put16(p + 2, v >> 16); }

/* mmap + decode a regular file of at most PV_MAX_IMG bytes: 0 or IMG_E_* */
static int pv_load_image(const char *path, int fmt, Image *img)
{
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);   /* the file may have become a FIFO since the head read */
    if (fd < 0) return IMG_E_FORMAT;
    FileStat st;
    int rc = IMG_E_FORMAT;
    if (os_fstat((int)fd, &st) == 0 && (st.mode & S_IFMT) == S_IFREG && st.size > 0 && (uint64_t)st.size <= PV_MAX_IMG) {
        void *map = os_mmap_file_ro((int)fd, (size_t)st.size);
        if (map) {
            rc = img_decode(map, (size_t)st.size, fmt, img);
            os_munmap(map, (size_t)st.size);
        }
    }
    (void)os_close((int)fd);
    return rc;
}

/* output size: block output always fills the box; pixel protocols never upscale (crisp small images) */
static ImgFit pv_out_size(const Image *img, const PvThumbReq *req)
{
    if (req->proto >= IMG_PROTO_SIXEL && (uint32_t)img->w <= req->w && (uint32_t)img->h <= req->h)
        return (ImgFit){(uint32_t)img->w, (uint32_t)img->h};
    return img_fit(img->w, img->h, req->w, req->h);
}

/* Sixel or Kitty escape stream of the scaled picture behind the header; IMG_THUMB_HDR alone on OOM */
static uint32_t pv_encode_pixels(uint8_t *out, const Image *img, const PvThumbReq *req, size_t cap)
{
    uint32_t ow = load_le16(out + 12), oh = load_le16(out + 14);
    uint8_t *px = mem_alloc((size_t)(ow * oh) * 4);
    if (!px) return IMG_THUMB_HDR;
    img_scale(img, px, (int)ow, (int)oh);
    size_t n;
    if (req->proto == IMG_PROTO_KITTY) {
        uint32_t cols = req->cols;                                   /* box cols (0 = native pixel size) */
        if (cols) cols = req->w ? (ow * cols + req->w - 1) / req->w : 0;   /* ceil(ow * box cols / box px w); no box width: native */
        n = img_kitty_encode(px, (int)ow, (int)oh, (int)cols, out + IMG_THUMB_HDR, cap - IMG_THUMB_HDR);
    } else {
        n = img_sixel_encode(px, (int)ow, (int)oh, req->bg, out + IMG_THUMB_HDR, cap - IMG_THUMB_HDR);   /* alpha over the pane background */
    }
    mem_free(px);
    return (uint32_t)n + IMG_THUMB_HDR;
}

static size_t pv_render_payload(uint8_t *out, const Image *img, const PvThumbReq *req, size_t cap)
{
    put32(out + 4, (uint32_t)img->w);
    put32(out + 8, (uint32_t)img->h);
    ImgFit sz = pv_out_size(img, req);
    uint32_t ow = (uint32_t)sz.w, oh = (uint32_t)sz.h;
    put16(out + 12, ow);
    put16(out + 14, oh);
    if (req->proto >= IMG_PROTO_SIXEL) return pv_encode_pixels(out, img, req, cap);
    size_t bytes = (size_t)(ow * oh) * 4 + IMG_THUMB_HDR;          /* block output: plain RGBA */
    if (bytes > cap) return IMG_THUMB_HDR;
    img_scale(img, out + IMG_THUMB_HDR, (int)ow, (int)oh);
    return bytes;
}

size_t pv_make_thumb(const char *path, const uint8_t *head, size_t head_len, const PvThumbReq *req, uint8_t *out, size_t cap)
{
    int fmt = img_detect(head, head_len, path);
    if (!fmt) return 0;
    put32(out, (uint32_t)fmt);                                      /* fmt, src w/h = 0, out 0x0 (= undecodable) */
    put32(out + 4, 0);
    put32(out + 8, 0);
    put32(out + 12, 0);
    Image img;
    uint32_t r = IMG_THUMB_HDR;
    if (pv_load_image(path, fmt, &img) == 0) {
        r = (uint32_t)pv_render_payload(out, &img, req, cap);
        img_free(&img);
    }
    return r;
}

/* the head of the file (or a package listing) into g_ph_msg + PV_HDR: err (0 or -errno of open) and the length */
static void pv_read_head(uint8_t *head, int32_t *err, uint32_t *len)
{
    *len = 0;
    int n = pkg_preview_try(g_envp, g_ph_path, (char *)head, PREVIEW_BUF_SIZE);
    if (n >= 0) { *err = 0; *len = (uint32_t)n; return; }
    intptr_t fd = os_openat(AT_FDCWD, g_ph_path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
    *err = (int32_t)fd;
    if (fd < 0) return;
    uint32_t got = 0;
    while (got < PREVIEW_BUF_SIZE) {
        intptr_t r = os_read((int)fd, head + got, PREVIEW_BUF_SIZE - got);
        if (r == -EINTR) continue;
        if (r <= 0) break;
        got += (uint32_t)r;
    }
    (void)os_close((int)fd);
    *err = 0;
    *len = got;
}

void pv_helper_main(int req_fd, int resp_fd)
{
    os_signals_worker_mode();
    for (;;) {
        PvRequest rq;
        if (pv_read_exact(req_fd, &rq, PV_REQ) <= 0 || rq.len > PATH_MAX - 1) break;
        intptr_t r = pv_read_exact(req_fd, g_ph_path, rq.len);
        if (r < 0 || (size_t)r != rq.len) break;                       /* the UI went away mid-message */
        g_ph_path[rq.len] = 0;
        uint8_t *head = g_ph_msg + PV_HDR;
        int32_t err;
        uint32_t len, tlen = 0;
        pv_read_head(head, &err, &len);
        uint8_t *slot = err >= 0 && load_le32(&rq.treq) ? fs_preview_shm_slot(rq.seq) : nullptr;   /* dims 0: text only */
        if (slot) tlen = (uint32_t)pv_make_thumb(g_ph_path, head, len, &rq.treq, slot, PV_SHM_SLOT_SZ);
        const uint32_t hdr[4] = {rq.seq, (uint32_t)err, len, tlen};
        mem_copy(g_ph_msg, hdr, sizeof hdr);
        if (sys_write_all(resp_fd, g_ph_msg, PV_HDR + len) < 0) break;
    }
    os_exit(0);
}
