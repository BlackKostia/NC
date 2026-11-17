/* src/fs/dir_model_stream.c - streaming a directory into a DirModel batch by batch (freestanding C23; replaces dir_model_stream.s,
 * kept as tests/harness/dir_model_stream_reference.s).
 *
 * Entries come from d_type alone (no stat): directory / symlink / regular, or FE_DT_UNKNOWN for file systems without d_type. Each
 * batch is filtered as it arrives, so the first frame already shows matching rows; from g_huge_threshold entries on the listing
 * stays in file system order (ls -f). */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

int utf8_display_width(const char *s);

#define STREAM_BATCH_BUDGET 4096

/* one directory entry appended (and shown when it passes the filter): 0 or -ENOMEM */
static int stream_append(DirModel *m, const char *name, uint8_t type, uint64_t huge)
{
    size_t len = 0;
    uint32_t last_dot = 0, hi = 0;
    uint32_t off = (uint32_t)m->name_used;
    bool copied = false;
    if (m->raw_count < m->raw_cap && m->name_used + 256 <= m->name_cap) {   /* room for any name (NAME_MAX 255): scan while copying */
        char *dst = m->name_pool + off;
        for (char c; len < 255 && (c = name[len]); len++) {
            dst[len] = c;
            hi |= (uint8_t)c;
            if (c == '.' && len) last_dot = (uint32_t)len;
        }
        dst[len] = 0;
        copied = !name[len];                                          /* a longer name (never from Linux) takes the slow path */
    }
    if (!copied) {
        len = 0;
        hi = last_dot = 0;
        for (; name[len]; len++) {
            hi |= (uint8_t)name[len];
            if (name[len] == '.' && len) last_dot = (uint32_t)len;
        }
        if (m->raw_count >= m->raw_cap || m->name_used + len + 1 > m->name_cap) {   /* growth is rare: the call only then */
            int r = ensure_capacity(m, len + 1);
            if (r < 0) return r;
        }
        mem_copy(m->name_pool + off, name, len + 1);
    }
    m->name_used = off + len + 1;
    uint32_t w = hi & 0x80 ? (uint32_t)utf8_display_width(name) : (uint32_t)(len > 255 ? 255 : len);
    uint32_t flags = name[0] == '.' ? FE_IS_HIDDEN : 0, mode;
    if (type == PAL_DT_DIR) { flags |= FE_IS_DIR; mode = S_IFDIR | 0755; }
    else if (type == PAL_DT_LNK) { flags |= FE_IS_LINK; mode = S_IFLNK | 0777; }
    else if (type == PAL_DT_UNKNOWN) { flags |= FE_DT_UNKNOWN; mode = 0; }
    else mode = S_IFREG | 0644;
    uint64_t idx = m->raw_count++;
    m->entries[idx] = (FileEntry){.mode = mode, .flags = flags, .name_off = off, .name_len = (uint16_t)len,
                                  .disp_width = (uint8_t)(w > 255 ? 255 : w), .ext_offset = (uint8_t)(last_dot > 255 ? 0 : last_dot)};
    if (m->raw_count >= huge) m->huge_mode = m->is_unsorted = 1;      /* ls -f mode from here on */
    bool shown = (!(flags & FE_IS_HIDDEN) || m->show_hidden) &&
                 (!m->flt_lc_len || os_str_contains_ci_fast(m->name_pool + off, m->flt_lc, (size_t)m->flt_lc_len));   /* entry_passes_filter */
    if (shown) {
        m->order[m->count++] = (uint32_t)idx;
        if (flags & (FE_IS_DIR | FE_LINK_DIR)) m->dir_count++;
        else m->file_count++;
    }
    return 0;
}

/* Reads and appends up to max_entries (0: g_stream_batch) entries. 1 when more may follow, 0 at the end, -errno on a read error
 * or OOM: then the load ends as well, and the partial listing is marked aborted, so the dir cache never takes it for complete. */
intptr_t DirModel_step_load(DirModel *m, size_t max_entries)
{
    if (!m->is_loading) return 0;
    m->flt_valid = 0;
    prepare_filter(m);
    size_t budget = max_entries ? max_entries : g_stream_batch ? g_stream_batch : STREAM_BATCH_BUDGET;
    uint64_t huge = g_huge_threshold ? g_huge_threshold : HUGE_DIR_THRESHOLD;
    intptr_t r = 0;
    for (size_t added = 0; added < budget;) {
        if (m->load_pos >= m->load_bytes) {                            /* refill the 1 MiB getdents64 buffer */
            r = os_dir_read(m->load_dirfd, m->load_buf, DIRENTS_BUF_SIZE);
            if (r <= 0) goto end;
            m->load_bytes = (uint64_t)r;
            m->load_pos = 0;
        }
        uint8_t type;
        const char *name = os_dir_next_ex(m->load_buf, m->load_bytes, &m->load_pos, &type);
        if (!name || (name[0] == '.' && (!name[1] || (name[1] == '.' && !name[2])))) continue;
        if ((r = stream_append(m, name, type, huge)) < 0) goto end;
        added++;
    }
    return 1;
end:
    finish_load_internal(m, 0);
    if (r < 0) m->load_aborted = 1;                                    /* incomplete: not a listing to cache */
    return r;
}

/* Esc: stops the stream, keeping the rows loaded so far */
void DirModel_cancel_load(DirModel *m)
{
    if (m->is_loading) finish_load_internal(m, 1);
}
