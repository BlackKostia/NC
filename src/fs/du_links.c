/* src/fs/du_links.c - hard-link accounting for Disk Usage (freestanding C23; replaces du_links.s): a file with several
 * names (st_nlink > 1) is counted once per scan, like `du`. A (dev, ino) set shared by the walker threads behind a
 * spinlock; du_links_reset (main thread) allocates it on first use and empties it for every scan. */
#include "duop_du.h"
#include "duop_oop.h"

#define DL_CAP 262144u                 /* slots (power of two), 16 bytes each = 4 MiB */
#define DL_MASK (DL_CAP - 1)
#define DL_PROBES 64

typedef struct { uint64_t ino, dev; } LinkSlot;     /* ino 0 = free */

static LinkSlot *g_dl_tbl;
static uint32_t g_dl_used;                          /* slots taken since the last reset */
static uint32_t g_dl_lock;

void du_links_reset(void)
{
    if (!g_dl_tbl) {
        g_dl_tbl = mem_alloc(DL_CAP * sizeof(LinkSlot));
        if (!g_dl_tbl) return;
        g_dl_used = 1;                                  /* fresh heap memory: cleared below */
    }
    if (g_dl_used) {
        mem_zero(g_dl_tbl, DL_CAP * sizeof(LinkSlot));
        g_dl_used = 0;
    }
}

/* 1 = first sighting (count it), 0 = seen before. Without a table or with a crowded probe run it answers 1: never undercount. */
int du_link_first(uint64_t dev, uint64_t ino)
{
    LinkSlot *tbl = g_dl_tbl;
    if (!tbl) return 1;
    du_spin_lock(&g_dl_lock);
    uint64_t h = ino * 0x9E3779B97F4A7C15ull ^ dev;
    uint32_t i = (uint32_t)(h ^ (h >> 29)) & DL_MASK;
    int first = 1;
    for (int probes = 0; probes < DL_PROBES; probes++, i = (i + 1) & DL_MASK) {
        LinkSlot *s = &tbl[i];
        if (!s->ino) { s->ino = ino; s->dev = dev; g_dl_used++; break; }
        if (s->ino == ino && s->dev == dev) { first = 0; break; }
    }
    du_spin_unlock(&g_dl_lock);
    return first;
}

void du_links_cleanup(void)
{
    void *t = g_dl_tbl;
    if (!t) return;
    g_dl_tbl = nullptr;
    mem_free(t);
}
