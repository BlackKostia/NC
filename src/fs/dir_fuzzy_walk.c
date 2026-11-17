/* src/fs/dir_fuzzy_walk.c - bounded recursive tree collector of the fuzzy finder (freestanding C23; replaces dir_fuzzy_walk.s
 * and the walker of dir_fuzzy.s). Names relative to the root are packed into the caller's pool and listed in FuzzyItem
 * records; ".", ".." and ".git" are skipped, symlinks are listed but never entered, depth <= 8. The big per-level buffers
 * (directory block, absolute and relative child path) live in one heap block so the recursion frame stays tiny. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

#define FUZZY_MAX_DEPTH 8
#define FUZZY_DENTS 8192

typedef struct {
    char dents[FUZZY_DENTS];
    char abs[PATH_MAX];            /* absolute path of the child being entered */
    char rel[PATH_MAX];            /* its path relative to the collected root */
} FuzzyLevel;

typedef struct {
    char *pool;
    uint32_t used, cap;
    FuzzyItem *items;
    int32_t count, max;
    FuzzyLevel *level;             /* FUZZY_MAX_DEPTH levels */
} FuzzyCtx;

/* dst = pfx + "/" + name (just name for an empty pfx); -1 when the result would not fit PATH_MAX */
static int fz_join(char *dst, const char *pfx, const char *name)
{
    if (!*pfx) {
        if (str_len(name) >= PATH_MAX) return -1;
        str_copy(dst, name, PATH_MAX);
        return 0;
    }
    if (str_len(pfx) >= PATH_MAX - 2) return -1;
    size_t n = str_copy(dst, pfx, PATH_MAX);
    if (!n || dst[n - 1] != '/') {
        if (n >= PATH_MAX - 2) return -1;
        dst[n++] = '/';
    }
    size_t room = PATH_MAX - 1 - n;
    if (str_len(name) > room) return -1;
    str_copy(dst + n, name, room + 1);
    return 0;
}

static bool fz_skip(const char *n)
{
    return n[0] == '.' && (!n[1] || (n[1] == '.' && !n[2]) || (n[1] == 'g' && n[2] == 'i' && n[3] == 't' && !n[4]));
}

static void fz_push(FuzzyCtx *cx, const char *rel, uint8_t type)
{
    uint32_t len = (uint32_t)str_len(rel) + 1;
    uint32_t end = cx->used + len;
    if (end > cx->cap) return;                                    /* pool full: the entry is dropped, the walk goes on */
    char *p = cx->pool + cx->used;
    cx->used = end;
    str_copy(p, rel, len);
    FuzzyItem *it = &cx->items[cx->count++];
    it->path = p;
    it->is_dir = type == PAL_DT_DIR;
    it->pad = 0;
}

static void fz_walk(FuzzyCtx *cx, const char *dir_abs, const char *rel_pfx, int depth)
{
    if (depth >= FUZZY_MAX_DEPTH || cx->count >= cx->max) return;
    intptr_t fd = os_openat(AT_FDCWD, dir_abs, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
    if (fd < 0) return;
    FuzzyLevel *lv = &cx->level[depth];
    intptr_t n;
    while ((n = os_dir_read((int)fd, lv->dents, FUZZY_DENTS)) > 0) {
        size_t pos = 0;
        for (;;) {
            if (cx->count >= cx->max) goto done;
            uint8_t type;
            const char *name = os_dir_next_ex(lv->dents, (size_t)n, &pos, &type);
            if (!name) break;
            if (fz_skip(name) || fz_join(lv->rel, rel_pfx, name) < 0) continue;
            fz_push(cx, lv->rel, type);
            if (type != PAL_DT_DIR || fz_join(lv->abs, dir_abs, name) < 0) continue;
            fz_walk(cx, lv->abs, lv->rel, depth + 1);
        }
    }
done:
    os_close((int)fd);
}

int dir_fuzzy_collect(const char *root, char *pool, int pool_cap, FuzzyItem *items, int max_items)
{
    FuzzyCtx cx = {.pool = pool, .cap = (uint32_t)pool_cap, .items = items, .max = max_items};
    cx.level = mem_alloc(sizeof(FuzzyLevel) * FUZZY_MAX_DEPTH);
    if (!cx.level) return 0;
    fz_walk(&cx, root, "", 0);
    mem_free(cx.level);
    return cx.count;
}
