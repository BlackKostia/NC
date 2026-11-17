/* src/fs/dir_search.c - recursive directory search into a DirModel virtual panel (freestanding C23; replaces
 * dir_search.s, dir_search_reset.s and dir_search_walk.s).
 *
 * dir_search_run() walks the tree below root (depth <= 16, at most 4096 hits), keeping the names that match the
 * mask (glob or substring) and - when a grep text is given - regular files whose first MiB contains it. Symlinks and
 * special files are skipped, directories are entered without following links. Results are appended to the model with
 * their path relative to root. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

#define SEARCH_MAX_DEPTH 16
#define SEARCH_MAX_HITS 4096
#define SEARCH_DENTS_SZ 16384
#define SEARCH_GREP_SZ 32768

int utf8_display_width(const char *s);
void DirModel_cancel_load(DirModel *m);                    /* still assembly (dir_model_stream.s) */

typedef struct {
    DirModel *model;
    const char *name_mask, *grep_pat;
    size_t grep_len;
    char *grep_buf;
    int32_t hits, has_glob;
} Search;

int ds_ensure_model_cap(DirModel *m, size_t add_name_bytes)
{
    if (m->raw_count >= m->raw_cap) {
        uint64_t cap = m->raw_cap * 2 < 128 ? 128 : m->raw_cap * 2;
        void *e = mem_realloc(m->entries, cap * sizeof(FileEntry));
        if (!e) return -1;
        m->entries = e;
        void *o = mem_realloc(m->order, cap * 4);
        if (!o) return -1;
        m->order = o;
        m->raw_cap = cap;
    }
    uint64_t need = m->name_used + add_name_bytes;
    if (need > m->name_cap) {
        uint64_t cap = m->name_cap;
        do { cap <<= 1; if (cap < 4096) cap = 4096; } while (cap < need);
        char *p = mem_realloc(m->name_pool, cap);
        if (!p) return -1;
        m->name_pool = p;
        m->name_cap = cap;
    }
    return 0;
}

/* 0, or -1 when the model cannot grow (asm callers test the sign) */
int ds_append_entry(DirModel *m, const char *rel_name, const FileStat *st)
{
    size_t len = str_len(rel_name);
    if (ds_ensure_model_cap(m, len + 1) < 0) return -1;
    uint64_t off = m->name_used;
    str_copy(m->name_pool + off, rel_name, len + 1);
    m->name_used = off + len + 1;
    uint64_t idx = m->raw_count;
    FileEntry *e = &m->entries[idx];
    e->size = st->size;
    e->mtime = st->mtime;
    e->mode = st->mode;
    e->name_off = (uint32_t)off;
    e->name_len = (uint16_t)len;
    e->ext_offset = 0;
    uint32_t flags = FE_STAT_READY;
    if ((st->mode & S_IFMT) == S_IFDIR) {
        flags |= FE_IS_DIR;
        m->dir_count++;
    } else {
        m->file_count++;
        m->total_bytes += (uint64_t)st->size;
        if (st->mode & 0111) flags |= FE_IS_EXEC;
    }
    e->flags = flags;
    int w = utf8_display_width(rel_name);
    e->disp_width = (uint8_t)(w > 255 ? 255 : w);
    m->order[m->count] = (uint32_t)idx;
    m->raw_count++;
    m->count++;
    return 0;
}

/* ".." as the newest entry the way the real directory loader adds it: FE_IS_PARENT (never hidden by the live filter, never
 * selectable), has_dotdot = 1 (sort keeps it first), not counted as a directory */
int ds_append_parent(DirModel *m)
{
    FileStat st = {.mode = S_IFDIR | 0755};
    if (ds_append_entry(m, "..", &st) < 0) return -1;
    m->entries[m->raw_count - 1].flags |= FE_IS_PARENT;
    m->has_dotdot = 1;
    m->dir_count--;
    return 0;
}

void ds_join_rel(char *dst, const char *prefix, const char *name)
{
    if (!*prefix) { str_copy(dst, name, PATH_MAX); return; }
    size_t n = str_copy(dst, prefix, PATH_MAX - 2);
    dst[n] = '/';
    str_copy(dst + n + 1, name, 256);
}

/* empties the model into a search result list: only ".." (unless the root is "/") */
static void ds_reset_model(DirModel *m, const char *root)
{
    DirModel_cancel_load(m);
    m->flt_valid = 0; m->is_loading = 0; m->load_aborted = 0; m->huge_mode = 0; m->is_unsorted = 0;
    m->stats_complete = 1;
    m->virtual_mode = 1;
    m->count = m->raw_count = m->name_used = m->total_bytes = 0;
    m->dir_count = m->file_count = m->has_dotdot = 0;
    if (root[0] == '/' && !root[1]) return;
    if (ds_ensure_model_cap(m, 3) < 0) return;
    m->name_pool[0] = '.'; m->name_pool[1] = '.'; m->name_pool[2] = 0;
    m->name_used = 3;
    m->entries[0] = (FileEntry){.mode = S_IFDIR | 0755, .flags = FE_IS_DIR | FE_IS_PARENT | FE_STAT_READY, .name_len = 2, .disp_width = 2};
    m->order[0] = 0;
    m->raw_count = m->count = 1;
    m->has_dotdot = 1;
}

static void ds_walk_dir(Search *s, int dirfd, const char *prefix, int depth);

static void ds_handle_dir(Search *s, int dirfd, const char *name, const char *rel, int depth)
{
    FileStat st;
    if (!s->grep_pat || !*s->grep_pat) {                                    /* name search also lists matching directories */
        if (ds_match_mask(name, s->name_mask, s->has_glob) && os_statat(dirfd, name, &st, 0) >= 0) {
            (void)ds_append_entry(s->model, rel, &st);
            s->hits++;
        }
    }
    if (depth >= SEARCH_MAX_DEPTH) return;
    intptr_t fd = os_openat(dirfd, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW, 0);
    if (os_is_err(fd)) return;
    ds_walk_dir(s, (int)fd, rel, depth + 1);
    os_close((int)fd);
}

static void ds_handle_reg(Search *s, int dirfd, const char *name, const char *rel, const FileStat *st)
{
    FileStat own;
    if (!st) {
        if (os_statat(dirfd, name, &own, 0) < 0) return;
        st = &own;
    }
    if (!ds_match_mask(name, s->name_mask, s->has_glob)) return;
    if (s->grep_pat && *s->grep_pat && !ds_grep_file(dirfd, name, s->grep_pat, s->grep_len, s->grep_buf)) return;
    (void)ds_append_entry(s->model, rel, st);
    s->hits++;
}

static void ds_walk_dir(Search *s, int dirfd, const char *prefix, int depth)
{
    char rel[PATH_MAX];
    FileStat st;
    char *dents = mem_alloc(SEARCH_DENTS_SZ);
    if (!dents) return;
    while (s->hits < SEARCH_MAX_HITS) {
        intptr_t n = os_dir_read(dirfd, dents, SEARCH_DENTS_SZ);
        if (n <= 0) break;
        size_t pos = 0;
        uint8_t type;
        const char *name;
        while (s->hits < SEARCH_MAX_HITS && (name = os_dir_next_ex(dents, (size_t)n, &pos, &type)) != nullptr) {
            if (name[0] == '.' && (!name[1] || (name[1] == '.' && !name[2]))) continue;
            ds_join_rel(rel, prefix, name);
            if (type == PAL_DT_DIR) { ds_handle_dir(s, dirfd, name, rel, depth); continue; }
            const FileStat *known = nullptr;
            if (type == PAL_DT_UNKNOWN) {                                       /* filesystems without d_type */
                if (os_statat(dirfd, name, &st, 0) < 0) continue;
                uint32_t kind = st.mode & S_IFMT;
                if (kind == S_IFDIR) { ds_handle_dir(s, dirfd, name, rel, depth); continue; }
                if (kind != S_IFREG) continue;
                known = &st;
            } else if (type != PAL_DT_REG) {
                continue;
            }
            ds_handle_reg(s, dirfd, name, rel, known);
        }
    }
    mem_free(dents);
}

int dir_search_run(DirModel *m, const char *root, const char *mask, const char *grep)
{
    ds_reset_model(m, root);
    Search s = {.model = m, .name_mask = mask, .grep_pat = grep};
    for (const char *p = mask; p && *p; p++)
        if (*p == '*' || *p == '?') { s.has_glob = 1; break; }
    if (grep && *grep) {
        s.grep_len = str_len(grep);
        s.grep_buf = mem_alloc(SEARCH_GREP_SZ);
    }
    int result;
    intptr_t fd = os_openat(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (os_is_err(fd)) {
        result = (int)fd;
    } else {
        ds_walk_dir(&s, (int)fd, "", 0);
        os_close((int)fd);
        result = s.hits;
    }
    mem_free(s.grep_buf);
    return result;
}
