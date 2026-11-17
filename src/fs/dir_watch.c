/* src/fs/dir_watch.c - kernel change notifications for the two displayed directories (freestanding C23; replaces dir_watch.s).
 *
 * One non-blocking watch fd (inotify on Linux, through the PAL) with up to two watches: slot 0 = left pane, slot 1 = right
 * pane. Both panes on the same directory share the kernel watch descriptor. dirwatch_poll drains the pending events and
 * classifies them per slot:
 *   structural (entries created / deleted / renamed, overflow) -> the listing must be reloaded
 *   content    (file data or attributes changed)               -> cached stats are stale */
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_string.h"

#define DW_MASK (PAL_IN_CREATE | PAL_IN_DELETE | PAL_IN_MOVED_FROM | PAL_IN_MOVED_TO | PAL_IN_MODIFY | PAL_IN_ATTRIB | PAL_IN_DELETE_SELF | PAL_IN_MOVE_SELF)
#define DW_STRUCT (PAL_IN_CREATE | PAL_IN_DELETE | PAL_IN_MOVED_FROM | PAL_IN_MOVED_TO | PAL_IN_DELETE_SELF | PAL_IN_MOVE_SELF | PAL_IN_Q_OVERFLOW)
#define DW_BUF 8192

typedef struct {
    char path[2][PATH_MAX];            /* watched directory of each slot */
    char buf[DW_BUF];                  /* event buffer */
} DWState;

static DWState *g_dw_state;
static int32_t g_dw_fd1;               /* watch fd + 1 (0 = not initialized) */
static int32_t g_dw_wd[2];             /* kernel watch descriptor per slot (-1 = none once initialized; .data must stay empty) */

/* 0, or -errno (the feature simply stays off on failure) */
int dirwatch_init(void)
{
    if (g_dw_fd1) return 0;
    DWState *st = mem_alloc(sizeof *st);
    if (!st) return -ENOMEM;
    int fd = os_watch_init();
    if (fd < 0) {
        mem_free(st);
        return fd;
    }
    g_dw_fd1 = fd + 1;
    g_dw_state = st;
    g_dw_wd[0] = g_dw_wd[1] = -1;
    return 0;
}

int dirwatch_fd(void) { return g_dw_fd1 - 1; }              /* watch fd or -1 */

/* (re)targets a slot; no-op if unchanged */
void dirwatch_set(int slot, const char *path)
{
    slot &= 1;
    if (!g_dw_fd1) return;
    char *cur = g_dw_state->path[slot];
    if (!str_cmp(cur, path)) return;
    int old = g_dw_wd[slot];
    if (old >= 0 && old != g_dw_wd[slot ^ 1]) (void)os_watch_rm(g_dw_fd1 - 1, old);   /* the other slot may share the descriptor */
    str_copy(cur, path, PATH_MAX);
    int wd = os_watch_add(g_dw_fd1 - 1, path, DW_MASK);
    g_dw_wd[slot] = wd < 0 ? -1 : wd;
}

/* Drains all pending events. Bits: 1 = slot 0 structural, 2 = slot 0 content, 4 = slot 1 structural, 8 = slot 1 content. */
uint32_t dirwatch_poll(void)
{
    uint32_t bits = 0;
    if (!g_dw_fd1) return 0;
    DWState *st = g_dw_state;
    for (;;) {
        intptr_t n = os_watch_read(g_dw_fd1 - 1, st->buf, DW_BUF);
        if (n <= 0) return bits;
        size_t pos = 0;
        int wd;
        uint32_t mask;
        while (os_watch_next(st->buf, (size_t)n, &pos, &wd, &mask)) {
            uint32_t kind = (mask & DW_STRUCT) ? 1 : 2;
            if (mask & PAL_IN_Q_OVERFLOW) { bits |= 1 | 4; continue; }   /* lost events: refresh both panes */
            if (wd == g_dw_wd[0]) bits |= kind;
            if (wd == g_dw_wd[1]) bits |= kind << 2;
        }
    }
}

void dirwatch_cleanup(void)                                  /* closes the watch fd and frees the state */
{
    if (g_dw_fd1) {
        (void)os_close(g_dw_fd1 - 1);
        g_dw_fd1 = 0;
    }
    DWState *st = g_dw_state;
    g_dw_state = nullptr;
    mem_free(st);
    g_dw_wd[0] = g_dw_wd[1] = -1;
}
