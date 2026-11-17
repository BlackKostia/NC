/* src/fs/dir_model_filter.c - the live filter and the lexical chdir of a DirModel (freestanding C23; replaces dir_model_filter.s plus
 * prepare_filter / entry_passes_filter of dir_model_load.s, kept as tests/harness/dir_model_filter_reference.s and
 * dir_model_flt_reference.s).
 *
 * The filter is a case-insensitive substring of the name (lower-cased once into flt_lc for the SIMD scan); hidden entries follow
 * show_hidden, ".." always stays. A filter that only extends the one that produced order[] narrows order[] in place and keeps its
 * sorted order; anything else rebuilds order[] from the raw entries and sorts it. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

/* DirModel.filter -> flt_lc (ASCII lower case, at most FILTER_MAX - 1 bytes) and flt_lc_len */
void prepare_filter(DirModel *m)
{
    int c = 0;
    for (;;) {
        uint8_t b = (uint8_t)m->filter[c];
        if (b >= 'A' && b <= 'Z') b += 32;
        m->flt_lc[c] = (char)b;
        if (!b) break;
        if (++c >= FILTER_MAX - 1) {
            m->flt_lc[c] = 0;
            break;
        }
    }
    m->flt_lc_len = c;
}

/* 1 when an entry with these flags and this name is visible under the prepared filter (the second argument is unused: asm callers
 * pass flags in edx and the name in rcx) */
int entry_passes_filter(const DirModel *m, uintptr_t unused, uint32_t flags, const char *name)
{
    (void)unused;
    if (flags & FE_IS_PARENT) return 1;
    if ((flags & FE_IS_HIDDEN) && !m->show_hidden) return 0;
    if (!m->flt_lc_len) return 1;
    return os_str_contains_ci_fast(name, m->flt_lc, (size_t)m->flt_lc_len);
}

static void flt_count(DirModel *m, uint32_t flags)
{
    if (flags & FE_IS_PARENT) return;
    if (flags & (FE_IS_DIR | FE_LINK_DIR)) m->dir_count++;
    else m->file_count++;
}

static bool flt_passes(const DirModel *m, const FileEntry *e) { return entry_passes_filter(m, 0, e->flags, m->name_pool + e->name_off); }

void DirModel_apply_filter(DirModel *m)
{
    prepare_filter(m);
    m->dir_count = m->file_count = 0;
    if (m->flt_valid && !m->is_loading && m->raw_count == m->flt_raw && m->show_hidden == m->flt_hidden &&
        str_starts_with(m->filter, m->flt_applied)) {
        uint64_t w = 0;                                                  /* narrowing: order[] filtered in place, still sorted */
        for (uint64_t r = 0; r < m->count; r++) {
            uint32_t idx = m->order[r];
            const FileEntry *e = &m->entries[idx];
            if (!flt_passes(m, e)) continue;
            m->order[w++] = idx;
            flt_count(m, e->flags);
        }
        m->count = w;
    } else {
        m->count = 0;
        for (uint64_t i = 0; i < m->raw_count; i++) {
            const FileEntry *e = &m->entries[i];
            if (!flt_passes(m, e)) continue;
            m->order[m->count++] = (uint32_t)i;
            flt_count(m, e->flags);
        }
        if (!m->is_loading && !m->is_unsorted && !m->huge_mode) DirModel_sort(m);
        if (m->is_loading) return;                                       /* the stream filters the rest as it arrives */
    }
    (void)str_copy(m->flt_applied, m->filter, FILTER_MAX);
    m->flt_raw = m->raw_count;
    m->flt_hidden = m->show_hidden;
    m->flt_valid = 1;
}

/* Lexically resolves target against m->path (no process-wide chdir / getcwd) and checks that it is a directory we can open; then
 * the current listing goes to the LRU dir cache and a valid cached snapshot of the target comes back in O(1), or the target is
 * reloaded. The filter is cleared. Before the point of no return (any failure up to the fstat) path and listing stay as they were.
 * 0, or -errno (-EINVAL: the resolved path does not fit PATH_MAX). */
intptr_t DirModel_chdir(DirModel *m, const char *target)
{
    char resolved[PATH_MAX];
    FileStat st;
    if (!path_normalize(m->path, target, resolved, PATH_MAX)) return -EINVAL;
    intptr_t fd = os_openat(AT_FDCWD, resolved, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (fd < 0) return fd;
    int r = os_fstat((int)fd, &st);
    (void)os_close((int)fd);
    if (r < 0) return r;
    close_stream_resources(m);
    (void)dircache_store(m);
    (void)str_copy(m->path, resolved, PATH_MAX);
    m->filter[0] = 0;
    int hit = dircache_fetch(m, &st);
    if (hit) {
        m->is_loading = m->load_aborted = m->flt_valid = 0;
        reset_entry_stats(m);
        if (hit != 1) {                                                  /* filter / view settings differ: re-filter and re-sort */
            m->is_unsorted = 0;
            DirModel_apply_filter(m);
        }
        (void)git_refresh(m);
        return 0;
    }
    if (!m->entries && (r = alloc_initial_arrays(m)) < 0) return r;     /* the listing was donated: fresh arrays */
    return DirModel_reload(m);
}
