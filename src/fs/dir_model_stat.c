/* src/fs/dir_model_stat.c - lazy stat of DirModel entries (freestanding C23; replaces dir_model_stat.s plus mark_link_dir and
 * DirModel_get_entry of dir_model_filter.s, kept as tests/harness/dir_model_stat_reference.s and dir_model_entry_reference.s).
 *
 * A listing is loaded from d_type alone; size, mtime, mode, the executable bit and "symlink to a directory" arrive only when an entry
 * is shown (DirModel_stat_range for the visible rows, DirModel_ensure_entry_stat for one entry) or a sort by size / time needs them
 * all (DirModel_ensure_all_stats, dir_model_select.c). An entry whose stat fails is marked ready all the same: it is never retried. */
#include "duop_fs.h"
#include "duop_pal.h"

FileEntry *DirModel_get_entry(DirModel *m, intptr_t idx)
{
    if (idx < 0 || (uint64_t)idx >= m->count) return nullptr;
    return &m->entries[m->order[idx]];
}

/* a symlink resolved to a directory: counted as a directory once, flagged FE_LINK_DIR */
void mark_link_dir(DirModel *m, FileEntry *e)
{
    if (!(e->flags & (FE_IS_DIR | FE_LINK_DIR))) {
        m->dir_count++;
        if (m->file_count) m->file_count--;
    }
    e->flags |= FE_LINK_DIR;
}

static int dm_open_dir(const DirModel *m) { return (int)os_openat(AT_FDCWD, m->path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0); }

/* size / mtime / mode / flags from st and FE_STAT_READY. A symlink's target is stat'ed through dirfd to tell FE_LINK_DIR, unless
 * dirfd is -2 (the batch caller resolves all targets of a chunk in one go). */
void apply_stat_to_entry(DirModel *m, FileEntry *e, const FileStat *st, int dirfd)
{
    uint32_t fl = e->flags;
    if (fl & FE_STAT_READY) return;
    e->size = st->size;
    e->mtime = st->mtime;
    e->mode = st->mode;
    fl &= ~(uint32_t)(FE_DT_UNKNOWN | FE_IS_EXEC);
    uint32_t type = st->mode & S_IFMT;
    if (type == S_IFLNK) {
        e->flags = fl | FE_IS_LINK | FE_STAT_READY;
        FileStat t;
        if (dirfd != -2 && os_statat(dirfd, m->name_pool + e->name_off, &t, 1) >= 0 && (t.mode & S_IFMT) == S_IFDIR) mark_link_dir(m, e);
        return;
    }
    if (type == S_IFDIR) {
        if (!(e->flags & (FE_IS_DIR | FE_LINK_DIR))) {
            fl |= FE_IS_DIR;
            m->dir_count++;
            if (m->file_count) m->file_count--;
        }
    } else {
        if (st->mode & 0111) fl |= FE_IS_EXEC;
        m->total_bytes += (uint64_t)st->size;
    }
    e->flags = fl | FE_STAT_READY;
}

/* stat of one entry through dirfd; a failed stat still marks it ready */
static void dm_stat_one(DirModel *m, FileEntry *e, int dirfd)
{
    FileStat st;
    if (os_statat(dirfd, m->name_pool + e->name_off, &st, 0) < 0) e->flags |= FE_STAT_READY;
    else apply_stat_to_entry(m, e, &st, dirfd);
}

void DirModel_ensure_entry_stat(DirModel *m, FileEntry *e)
{
    if (!m || !e || (e->flags & FE_STAT_READY)) return;
    int fd = dm_open_dir(m);
    if (fd < 0) {
        e->flags |= FE_STAT_READY;
        return;
    }
    dm_stat_one(m, e, fd);
    (void)os_close(fd);
}

/* Lazy stat of the visible rows [view_start, view_start + view_len) that are not ready yet; reuses the streaming fd. */
void DirModel_stat_range(DirModel *m, size_t view_start, size_t view_len)
{
    if (!m->count || !view_len) return;
    size_t end = view_start + view_len;
    if (end > m->count) end = m->count;
    size_t i = view_start;
    while (i < end && (m->entries[m->order[i]].flags & FE_STAT_READY)) i++;
    if (i >= end) return;                                             /* every visible row is cached */
    int fd = m->load_dirfd;
    bool own = fd < 0;
    if (own && (fd = dm_open_dir(m)) < 0) return;
    for (i = view_start; i < end; i++) {
        FileEntry *e = &m->entries[m->order[i]];
        if (!(e->flags & FE_STAT_READY)) dm_stat_one(m, e, fd);
    }
    if (own) (void)os_close(fd);
}
