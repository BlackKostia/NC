/* src/fs/dir_model_select.c - selection, lookup by name and the batched stat of a whole listing (freestanding C23; replaces
 * dir_model_select.s, kept as tests/harness/dir_model_select_reference.s). */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

#define BATCH_STAT_CHUNK 1024

typedef struct StatChunk {
    FileEntry *entries[BATCH_STAT_CHUNK];
    const char *names[BATCH_STAT_CHUNK];
    FileStat stats[BATCH_STAT_CHUNK];
    int32_t errs[BATCH_STAT_CHUNK];
} StatChunk;

/* the symlinks of a stat'ed chunk, compacted in place, resolved with one follow batch: directories become FE_LINK_DIR */
static void eas_links(DirModel *m, StatChunk *c, int dirfd, size_t n)
{
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        if (c->errs[i] || (c->stats[i].mode & S_IFMT) != S_IFLNK) continue;
        c->entries[k] = c->entries[i];
        c->names[k++] = c->names[i];
    }
    if (!k) return;
    (void)os_batch_stat(dirfd, c->names, c->stats, c->errs, k, 1);
    for (size_t i = 0; i < k; i++)
        if (!c->errs[i] && (c->stats[i].mode & S_IFMT) == S_IFDIR) mark_link_dir(m, c->entries[i]);
}

/* Stats every entry that is not ready yet, BATCH_STAT_CHUNK at a time through os_batch_stat (io_uring or the fallback), before a
 * sort by size or time. Without memory or a directory fd the listing stays as it is (stats_complete remains 0). */
void DirModel_ensure_all_stats(DirModel *m)
{
    if (m->stats_complete) return;
    StatChunk *c = mem_alloc(sizeof *c);
    if (!c) return;
    int fd = m->load_dirfd;
    bool own = fd < 0;
    if (own && (fd = (int)os_openat(AT_FDCWD, m->path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0)) < 0) {
        mem_free(c);
        return;
    }
    for (uint64_t i = (uint32_t)m->has_dotdot; i < m->raw_count;) {
        size_t n = 0;
        for (; i < m->raw_count && n < BATCH_STAT_CHUNK; i++) {
            FileEntry *e = &m->entries[i];
            if (e->flags & FE_STAT_READY) continue;
            c->entries[n] = e;
            c->names[n++] = m->name_pool + e->name_off;
        }
        if (!n) continue;
        (void)os_batch_stat(fd, c->names, c->stats, c->errs, n, 0);
        for (size_t k = 0; k < n; k++) {
            if (c->errs[k]) c->entries[k]->flags |= FE_STAT_READY;
            else apply_stat_to_entry(m, c->entries[k], &c->stats[k], -2);    /* link targets: one batched pass below */
        }
        eas_links(m, c, fd, n);
    }
    m->stats_complete = 1;
    if (own) (void)os_close(fd);
    mem_free(c);
}

void DirModel_toggle_select(DirModel *m, intptr_t idx)
{
    FileEntry *e = DirModel_get_entry(m, idx);
    if (!e || (e->flags & FE_IS_PARENT)) return;
    DirModel_ensure_entry_stat(m, e);
    e->flags ^= FE_SELECTED;
}

/* selects every visible entry, or clears the selection when anything is selected */
void DirModel_select_all_toggle(DirModel *m)
{
    bool any = false;
    for (uint64_t i = 0; i < m->count && !any; i++) {
        uint32_t fl = m->entries[m->order[i]].flags;
        any = !(fl & FE_IS_PARENT) && (fl & FE_SELECTED);
    }
    for (uint64_t i = 0; i < m->count; i++) {
        FileEntry *e = &m->entries[m->order[i]];
        if (e->flags & FE_IS_PARENT) continue;
        if (any) e->flags &= ~(uint32_t)FE_SELECTED;
        else e->flags |= FE_SELECTED;
    }
}

size_t DirModel_count_selected(DirModel *m, int64_t *out_bytes)
{
    size_t n = 0;
    int64_t bytes = 0;
    for (uint64_t i = 0; i < m->count; i++) {
        const FileEntry *e = &m->entries[m->order[i]];
        if (!(e->flags & FE_SELECTED)) continue;
        n++;
        bytes = (int64_t)((uint64_t)bytes + (uint64_t)e->size);
    }
    if (out_bytes) *out_bytes = bytes;
    return n;
}

/* view index of the visible entry called name, or -1 */
intptr_t DirModel_find_by_name(DirModel *m, const char *name)
{
    for (uint64_t i = 0; i < m->count; i++)
        if (!str_cmp(m->name_pool + m->entries[m->order[i]].name_off, name)) return (intptr_t)i;
    return -1;
}
