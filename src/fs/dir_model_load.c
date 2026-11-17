/* src/fs/dir_model_load.c - (re)loading a DirModel: capacity growth, the start of a load and its end (freestanding C23; replaces
 * dir_model_load.s, kept as tests/harness/dir_model_load_reference.s). The batches in between are read by dir_model_stream.c.
 *
 * DirModel_reload resets the listing, opens the directory, stamps it (dev / inode / mtime) for the dir cache, adds the synthetic
 * ".." (except at "/") and reads the first batch; the event loop streams the rest. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

#define INITIAL_FILE_CAP 512
#define INITIAL_NAME_CAP 65536

/* room for one more entry and need_name_bytes more name bytes (entries / order double, the pool doubles until it fits):
 * 0, or -ENOMEM with the arrays still valid */
int ensure_capacity(DirModel *m, size_t need_name_bytes)
{
    if (m->raw_count >= m->raw_cap) {
        uint64_t nc = (m->raw_cap ? m->raw_cap : INITIAL_FILE_CAP / 2) * 2;
        FileEntry *e = mem_realloc(m->entries, nc * sizeof(FileEntry));
        if (!e) return -ENOMEM;
        m->entries = e;
        uint32_t *o = mem_realloc(m->order, nc * 4);
        if (!o) return -ENOMEM;
        m->order = o;
        m->raw_cap = nc;
    }
    uint64_t want = m->name_used + need_name_bytes;
    if (want > m->name_cap) {
        uint64_t nc = m->name_cap ? m->name_cap : INITIAL_NAME_CAP;
        if (m->name_cap || nc < want)
            do nc <<= 1; while (nc < want);
        char *p = mem_realloc(m->name_pool, nc);
        if (!p) return -ENOMEM;
        m->name_pool = p;
        m->name_cap = nc;
    }
    return 0;
}

/* the load is over (canceled: Esc, the rows so far stay): stream resources released, the listing sorted unless it is huge */
void finish_load_internal(DirModel *m, int canceled)
{
    close_stream_resources(m);
    m->is_loading = 0;
    if (canceled) m->load_aborted = 1;
    else if (m->huge_mode) m->is_unsorted = 1;                         /* ls -f: file system order */
    else DirModel_sort(m);
}

static void load_reset(DirModel *m)
{
    close_stream_resources(m);
    m->flt_valid = m->is_loading = m->load_aborted = m->huge_mode = m->is_unsorted = m->stats_complete = 0;
    m->count = m->raw_count = m->name_used = m->total_bytes = 0;
    m->dir_count = m->file_count = m->has_dotdot = 0;
}

static void load_add_parent(DirModel *m)
{
    mem_copy(m->name_pool, "..", 3);
    m->name_used = 3;
    m->entries[0] = (FileEntry){.mode = S_IFDIR | 0755, .flags = FE_IS_DIR | FE_IS_PARENT | FE_STAT_READY, .name_len = 2, .disp_width = 2};
    m->order[0] = 0;
    m->raw_count = m->count = 1;
    m->has_dotdot = 1;
}

/* 0 (is_loading = 1 while more batches follow), or -errno */
int DirModel_reload(DirModel *m)
{
    load_reset(m);
    intptr_t fd = os_openat(AT_FDCWD, m->path, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (fd < 0) return (int)fd;
    m->load_dirfd = (int)fd;
    FileStat st;
    uint64_t ino = 0;                                                  /* unknown stamp: the listing is never cached */
    if (os_fstat((int)fd, &st) >= 0) {
        ino = st.ino;
        m->dir_dev = st.dev;
        m->dir_mtime = st.mtime;
        m->dir_mtime_ns = (int32_t)st.mtime_nsec;
    }
    m->dir_ino = ino;
    int r = -ENOMEM;
    char *buf = mem_alloc(DIRENTS_BUF_SIZE);
    if (!buf) goto fail;
    m->load_buf = buf;
    m->is_loading = 1;
    if (!(m->path[0] == '/' && !m->path[1])) {
        if ((r = ensure_capacity(m, 3)) < 0) goto fail;
        load_add_parent(m);
    }
    intptr_t s = DirModel_step_load(m, 0);
    if (s < 0) return (int)s;
    if (m->is_loading) m->is_unsorted = 1;                             /* no sort indicator until the end of the stream */
    (void)git_refresh(m);
    return 0;
fail:
    close_stream_resources(m);
    m->is_loading = 0;
    return r;
}
