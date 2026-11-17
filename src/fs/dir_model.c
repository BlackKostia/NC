/* src/fs/dir_model.c - the DirModel class: vtable, construction and destruction, the environment overrides of the loader and the
 * helpers that reset cached state (freestanding C23; replaces dir_model.s, kept as tests/harness/dir_model_reference.s).
 *
 * A listing is a compact array of 32-byte FileEntry records, a uint32_t order[] of the visible indices and one contiguous name pool;
 * loading (dir_model_load.s / dir_model_stream.s) fills them from d_type alone, stat data arrives lazily (dir_model_stat.c). */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

#define INITIAL_FILE_CAP 512
#define INITIAL_NAME_CAP 65536       /* 64 KiB contiguous UTF-8 name pool */
#define STREAM_BATCH_BUDGET 4096     /* entries per incremental load batch in App_run */

uint64_t g_huge_threshold;           /* entries above which a listing stays unsorted (ls -f mode) */
uint64_t g_stream_batch;             /* entries loaded per event-loop step */

void DirModel_dtor(DirModel *m);

const ObjectVtbl DirModel_vtbl = {&Object_vtbl, "DirModel", DIRMODEL_SIZE, (void (*)(Object *))DirModel_dtor};

static uint64_t dm_parse_u64(const char *s)
{
    uint64_t v = 0;
    for (; (uint8_t)(*s - '0') <= 9; s++) v = v * 10 + (uint64_t)(*s - '0');
    return v;
}

/* DUOP_HUGE_THRESHOLD=<n> and DUOP_STREAM_BATCH=<n> (n > 0) override the defaults */
void DirModel_init_env(char **envp)
{
    g_huge_threshold = HUGE_DIR_THRESHOLD;
    g_stream_batch = STREAM_BATCH_BUDGET;
    for (; envp && *envp; envp++) {
        uint64_t v;
        if (str_starts_with(*envp, "DUOP_HUGE_THRESHOLD=")) {
            if ((v = dm_parse_u64(*envp + 20))) g_huge_threshold = v;
        } else if (str_starts_with(*envp, "DUOP_STREAM_BATCH=")) {
            if ((v = dm_parse_u64(*envp + 18))) g_stream_batch = v;
        }
    }
}

/* entries / order for INITIAL_FILE_CAP entries and the name pool: 0, or -ENOMEM with all three released */
int alloc_initial_arrays(DirModel *m)
{
    void *p = mem_alloc(INITIAL_FILE_CAP * sizeof(FileEntry));
    if (!p) goto fail;
    m->entries = p;
    if (!(p = mem_alloc(INITIAL_FILE_CAP * 4))) goto fail;
    m->order = p;
    m->raw_cap = INITIAL_FILE_CAP;
    if (!(p = mem_alloc(INITIAL_NAME_CAP))) goto fail;
    m->name_pool = p;
    m->name_cap = INITIAL_NAME_CAP;
    return 0;
fail:
    mem_free(m->entries);
    mem_free(m->order);
    mem_free(m->name_pool);
    m->entries = nullptr;
    m->order = nullptr;
    m->name_pool = nullptr;
    m->raw_cap = m->name_cap = 0;
    return -ENOMEM;
}

/* A model of initial_path (NULL: the working directory, "/" when even that fails), loaded; NULL on OOM. */
DirModel *DirModel_new(const char *initial_path)
{
    DirModel *m = Object_alloc(&DirModel_vtbl, DIRMODEL_SIZE);
    if (!m) return nullptr;
    m->load_dirfd = -1;
    m->show_hidden = 1;
    m->sort_mode = SORT_NAME;
    if (alloc_initial_arrays(m)) {
        Object_free(&m->base);                                      /* the asm released the arrays but leaked the object */
        return nullptr;
    }
    if (initial_path) (void)str_copy(m->path, initial_path, PATH_MAX);
    else if (os_getcwd(m->path, PATH_MAX) < 0) (void)str_copy(m->path, "/", PATH_MAX);
    (void)DirModel_reload(m);
    return m;
}

/* contents or attributes changed (watch event): cached stats are dropped, the visible rows re-stat lazily; selections stay */
void DirModel_invalidate_stats(DirModel *m)
{
    for (uint64_t i = (uint32_t)m->has_dotdot; i < m->raw_count; i++) m->entries[i].flags &= ~(uint32_t)FE_STAT_READY;
    m->total_bytes = 0;
    m->stats_complete = 0;
}

/* a cached listing was restored: stats and selections are forgotten, exactly like a fresh load */
void reset_entry_stats(DirModel *m)
{
    for (uint64_t i = (uint32_t)m->has_dotdot; i < m->raw_count; i++) m->entries[i].flags &= ~(uint32_t)(FE_STAT_READY | FE_SELECTED);
    m->total_bytes = 0;
    m->stats_complete = 0;
}

void close_stream_resources(DirModel *m)
{
    if (m->load_dirfd >= 0) {
        (void)os_close(m->load_dirfd);
        m->load_dirfd = -1;
    }
    if (m->load_buf) {
        mem_free(m->load_buf);
        m->load_buf = nullptr;
    }
    m->load_pos = 0;
    m->load_bytes = 0;
}

void DirModel_dtor(DirModel *m)
{
    close_stream_resources(m);
    git_free_ctx(m);
    mem_free(m->name_pool);
    mem_free(m->order);
    mem_free(m->entries);
    Object_dtor(&m->base);
}

const char *DirModel_entry_name(const DirModel *m, const FileEntry *e)
{
    return m && e ? m->name_pool + e->name_off : nullptr;
}
