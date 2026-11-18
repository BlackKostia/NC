/* include/duop_preview.h - C view of the asynchronous preview reader (src/fs/preview_io.c: UI side, preview_helper.c: helper process). */
#pragma once
#include "duop_config.h"
#include "duop_img.h"
#include "duop_oop.h"
#include "duop_sys.h"

#define IMG_PROTO_QUAD 0             /* the same values as duop_tui.h (term_img_proto) */
#define IMG_PROTO_HALF 1
#define IMG_PROTO_SIXEL 2
#define IMG_PROTO_KITTY 3
#define PREVIEW_BUF_SIZE 32768       /* head bytes per reply (config.inc) */
#define IMG_THUMB_HDR 16             /* u32 fmt, u32 src_w, u32 src_h, u16 tw, u16 th */
#define IMG_THUMB_MAXW 160
#define IMG_THUMB_MAXH 100
#define IMG_THUMB_CAP (IMG_THUMB_HDR + IMG_THUMB_MAXW * IMG_THUMB_MAXH * 4)
#define PV_SHM_CAP 25165824          /* helper -> UI shared payload buffer (24 MiB, lazily touched) */
#define PV_SHM_SLOT_SZ 12582912      /* half of PV_SHM_CAP: seq & 1 ping-pong slots */
#define PV_STUCK_MS 1000             /* a helper busy for longer is killed and replaced */
#define PV_MAX_IMG 268435456         /* never decode files above 256 MiB */

/* {box w | h << 16 (0 = text only), IMG_PROTO_* | cols << 8, background 0xRRGGBB} */
typedef struct PvThumbReq { uint16_t w, h; uint8_t proto, cols, pad[2]; uint32_t bg; } PvThumbReq;
_Static_assert(sizeof(PvThumbReq) == 12, "PvThumbReq is filled by assembly");

/* UI side (preview_io.c) */
int fs_preview_request(const char *path, uint32_t dims, uint32_t mode, uint32_t bg);   /* seq > 0, or -1 (read synchronously) */
int fs_preview_fd(void);                                                 /* reply fd to poll, or -1 */
int fs_preview_receive(void *buf, size_t cap, uint32_t *out_seq, size_t *out_len, size_t *out_tlen);   /* 1: one reply, 0: none */
void fs_preview_stop(void);
uint8_t *fs_preview_shm(void);
uint8_t *fs_preview_shm_slot(uint32_t seq);
intptr_t pv_read_exact(int fd, void *buf, size_t n);                     /* n, bytes before EOF, or -errno (stalled writer: -EIO) */

/* helper process (preview_helper.c) */
[[noreturn]] void pv_helper_main(int req_fd, int resp_fd);
size_t pv_make_thumb(const char *path, const uint8_t *head, size_t head_len, const PvThumbReq *req, uint8_t *out, size_t cap);

/* other layers */
int pkg_preview_try(char **envp, const char *path, char *out, int max_len);   /* bytes, or -1 when path is no package */
