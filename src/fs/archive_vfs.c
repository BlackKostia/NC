/* src/fs/archive_vfs.c - an archive shown as a virtual folder of a pane, and single entries extracted to temp files (freestanding
 * C23; replaces the rest of archive_vfs.s + archive_extract.s, kept as tests/harness/archive_vfs_reference.s and
 * archive_extract_reference.s).
 *
 * Entering an archive reads at most ARC_MAX_FILE bytes of it (gunzipped for .tar.gz) and indexes it; the pane then lists one level
 * of ctx->sub at a time (directories synthesised from the paths), ".." walks up and finally back to the real directory. The
 * parsers and the extraction run under the fault guard: a corrupt archive can never take the UI down. */
#include "duop_arc.h"
#include "duop_inflate.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

/* the listing of ctx->sub: one entry per first path component below it, de-duplicated; then filter and sort */
void arc_populate(DirModel *m)
{
    ArcCtx *ctx = m->arc_ctx;
    DirModel_cancel_load(m);
    m->raw_count = m->count = m->name_used = m->total_bytes = 0;
    m->dir_count = m->file_count = 0;
    m->virtual_mode = 2;
    m->stats_complete = 1;
    (void)str_copy(m->path, ctx->file, PATH_MAX);
    (void)ds_append_parent(m);
    size_t sub = str_len(ctx->sub);
    char name[PATH_MAX];
    for (uint32_t i = 0; i < ctx->count; i++) {
        const ArcEntry *e = &ctx->entries[i];
        if (sub && !str_starts_with(e->name, ctx->sub)) continue;
        if (!e->name[sub]) continue;
        (void)str_copy(name, e->name + sub, PATH_MAX);
        bool dir = false;
        for (char *p = name; *p; p++)
            if (*p == '/') { *p = 0; dir = true; break; }               /* a deeper path: its first component is a folder */
        if (!name[0] || DirModel_find_by_name(m, name) >= 0) continue;
        FileStat st = {0};
        if (dir || e->is_dir) st.mode = S_IFDIR | 0755;
        else {
            st.mode = S_IFREG | 0644;
            st.size = (int64_t)e->size;
        }
        (void)ds_append_entry(m, name, &st);
    }
    DirModel_apply_filter(m);
    DirModel_sort(m);
}

void arc_free_ctx(DirModel *m)
{
    ArcCtx *ctx = m->arc_ctx;
    if (!ctx) return;
    m->arc_ctx = nullptr;
    mem_free(ctx->raw);
    mem_free(ctx->entries);
    mem_free(ctx);
}

/* ".." inside an archive: one folder up, or out of the archive (the cursor lands on the archive file) */
int arc_nav_up_model(DirModel *m)
{
    if (m->virtual_mode != 2) return -1;
    ArcCtx *ctx = m->arc_ctx;
    size_t n = str_len(ctx->sub);
    if (n) {
        size_t i = n - 1;
        while (i && ctx->sub[i - 1] != '/') i--;
        ctx->sub[i] = 0;                                                /* "a/b/" -> "a/", "a/" -> "" */
        arc_populate(m);
        return 0;
    }
    char *mem = mem_alloc(2 * PATH_MAX);                               /* the directory and the archive name outlive ctx */
    if (!mem) return 0;
    (void)str_copy(mem, ctx->orig, PATH_MAX);
    (void)str_copy(mem + PATH_MAX, path_basename(ctx->file), PATH_MAX);
    m->virtual_mode = 0;
    arc_free_ctx(m);
    (void)DirModel_chdir(m, mem);
    intptr_t cur = DirModel_find_by_name(m, mem + PATH_MAX);
    mem_free(mem);
    return (int32_t)cur >= 0 ? (int)cur : 0;
}

/* raw data (gunzipped for ARC_TGZ) and the entry table of a fresh ctx: 0, or -1 with ctx released */
static int arc_load_raw_ctx(ArcCtx *ctx, const char *path)
{
    size_t got;
    ctx->entries = mem_alloc(ARC_MAX_ENTRIES * sizeof(ArcEntry));
    if (!ctx->entries) goto fail;
    ctx->raw = mem_alloc(ARC_MAX_FILE);
    if (!ctx->raw || fs_read_file_head(path, ctx->raw, ARC_MAX_FILE, &got) < 0 || (int64_t)got <= 0) goto fail;
    ctx->raw_len = got;
    if (ctx->type == ARC_TGZ) {
        uint64_t n;
        uint8_t *plain = arc_ungzip(ctx->raw, ctx->raw_len, &n);
        if (!plain) goto fail;
        mem_free(ctx->raw);
        ctx->raw = plain;
        ctx->raw_len = n;
    }
    return 0;
fail:
    mem_free(ctx->raw);
    mem_free(ctx->entries);
    mem_free(ctx);
    return -1;
}

static int arc_open(DirModel *m, const FileEntry *ent, const char *name)
{
    int type = arc_is_archive(name);
    const bool truncated = ent->size > ARC_MAX_FILE;                      /* read now: arc_populate reuses ent's row */
    char *path = mem_alloc(PATH_MAX);
    if (!type || !path || path_join(path, m->path, name, PATH_MAX) < 0) {   /* path-checked */
        mem_free(path);
        return 0;
    }
    arc_free_ctx(m);
    ArcCtx *ctx = mem_alloc(sizeof *ctx);
    if (!ctx) { mem_free(path); return 0; }
    mem_zero(ctx, sizeof *ctx);
    ctx->type = (uint32_t)type;
    if (arc_load_raw_ctx(ctx, path) < 0) { mem_free(path); return 0; }
    (void)str_copy(ctx->orig, m->path, PATH_MAX);
    (void)str_copy(ctx->file, path, PATH_MAX);
    mem_free(path);
    m->arc_ctx = ctx;
    TryFrame f;
    if (os_try_begin(&f) != 0) {                                       /* a fault while indexing: drop the archive */
        arc_free_ctx(m);
        return 0;
    }
    if (type == ARC_ZIP) arc_parse_zip(ctx);
    else arc_parse_tar(ctx);
    os_try_end(&f);
    arc_populate(m);
    return truncated ? 3 : 1;
}

int arc_enter_model(DirModel *m, const FileEntry *ent)
{
    if (!ent) return 0;
    const char *name = DirModel_entry_name(m, ent);
    if (m->virtual_mode != 2) {
        if (ent->flags & FE_IS_DIR) return 0;
        return arc_open(m, ent, name);
    }
    if (ent->flags & FE_IS_PARENT) return 2;
    if (!(ent->flags & FE_IS_DIR)) return 0;
    ArcCtx *ctx = m->arc_ctx;                                           /* one folder deeper */
    (void)str_cat(ctx->sub, name, PATH_MAX);
    size_t n = str_len(ctx->sub);
    if (n < PATH_MAX - 2) { ctx->sub[n] = '/'; ctx->sub[n + 1] = 0; }
    arc_populate(m);
    return 1;
}

/* the bytes of entry e: a pointer into the archive (stored) or an inflated block (*own set); NULL when corrupt */
static const uint8_t *arc_entry_data(const ArcCtx *ctx, const ArcEntry *e, uint64_t *len, uint8_t **own)
{
    uint64_t rl = ctx->raw_len;
    if (e->off > rl) return nullptr;
    const uint8_t *p = ctx->raw + e->off;
    uint64_t avail = rl - e->off, size = e->size;
    if (ctx->type == ARC_ZIP) {
        if (avail < 30) return nullptr;
        uint64_t hdr = 30 + (uint64_t)load_le16(p + 26) + load_le16(p + 28);
        if (avail < hdr) return nullptr;
        p += hdr;
        avail -= hdr;
        uint64_t comp = e->comp_size < avail ? e->comp_size : avail;
        if (e->method == 8) {
            if (size > ARC_MAX_UNCOMP) return nullptr;
            uint8_t *buf = mem_alloc(size ? size : 1);
            if (!buf) return nullptr;
            *own = buf;
            int64_t r = inflate_raw(p, comp, buf, size);
            if (r < 0) return nullptr;
            *len = (uint64_t)r;
            return buf;
        }
        if (e->method) return nullptr;
        if (size > comp) size = comp;
    }
    *len = size < avail ? size : avail;
    return p;
}

int arc_extract_entry(DirModel *m, const FileEntry *ent, char *out_tmp_path)
{
    if (m->virtual_mode != 2 || !ent || (ent->flags & FE_IS_DIR)) return -1;
    const ArcCtx *ctx = m->arc_ctx;
    char *full = mem_alloc(PATH_MAX);
    if (!full) return -1;
    (void)str_copy(full, ctx->sub, PATH_MAX);
    (void)str_cat(full, DirModel_entry_name(m, ent), PATH_MAX);
    const ArcEntry *e = nullptr;
    for (uint32_t i = 0; i < ctx->count && !e; i++)
        if (!str_cmp(ctx->entries[i].name, full)) e = &ctx->entries[i];
    mem_free(full);
    if (!e) return -1;
    uint8_t *volatile own = nullptr;
    volatile intptr_t fd = -1;
    volatile int rc = -1;
    TryFrame f;
    if (os_try_begin(&f) == 0) {
        uint64_t len = 0;
        uint8_t *buf = nullptr;
        const uint8_t *data = arc_entry_data(ctx, e, &len, &buf);
        own = buf;
        if (data && (fd = tmp_open_unique("arc_view", ".tmp", out_tmp_path, PATH_MAX)) >= 0 && sys_write_all((int)fd, data, len) >= 0) rc = 0;
        os_try_end(&f);
    }
    if (fd >= 0) (void)os_close((int)fd);
    mem_free(own);
    return rc;
}
