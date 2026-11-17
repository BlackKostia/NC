/* include/duop_fs.h - C view of the filesystem layer (the .c files under src/fs): the compact directory entry and the DirModel class.
 * Layouts mirror include/types.inc and classes.inc exactly; tests/test_abi_layouts.py compares every offset. */
#pragma once
#include "duop_config.h"
#include "duop_oop.h"

#define FILTER_MAX 64
#define DIRENTS_BUF_SIZE 1048576   /* 1 MiB getdents64 read buffer for DirModel streaming */
#define HUGE_DIR_THRESHOLD 50000   /* switch to ls -f unsorted mode above this threshold */

#define FE_IS_DIR 1
#define FE_IS_LINK 2
#define FE_IS_EXEC 4
#define FE_IS_HIDDEN 8
#define FE_SELECTED 16
#define FE_IS_PARENT 32
#define FE_LINK_DIR 64
#define FE_STAT_READY 128
#define FE_DT_UNKNOWN 256

/* 32 bytes: compact metadata; the name lives in DirModel.name_pool at name_off */
typedef struct FileEntry {
    int64_t size;
    int64_t mtime;
    uint32_t mode, flags, name_off;
    uint16_t name_len;
    uint8_t disp_width;            /* terminal columns of the name (clamped 0..255) */
    uint8_t ext_offset;            /* offset of '.' after index 0, or 0 */
} FileEntry;
_Static_assert(sizeof(FileEntry) == 32, "FileEntry is shared with assembly");

/* the assembler packs fields at 4 bytes: du_total .. path sit at offsets that are not multiples of 8 */
#pragma pack(push, 4)
typedef struct DirModel {
    Object base;
    FileEntry *entries;            /* compact array (raw_cap entries) */
    uint32_t *order;               /* visible / sorted indices into entries[] */
    char *name_pool;               /* contiguous NUL-terminated UTF-8 file names */
    uint64_t count;                /* visible (filtered) entries, i.e. elements of order[] */
    uint64_t raw_count;            /* loaded entries, i.e. elements of entries[] */
    uint64_t raw_cap, name_used, name_cap, total_bytes;
    char *load_buf;
    uint64_t load_pos, load_bytes;
    int32_t load_dirfd, is_loading, load_aborted, huge_mode, is_unsorted, stats_complete;
    int32_t dir_count, file_count, sort_mode, sort_desc, show_hidden, has_dotdot;
    uint64_t dir_dev, dir_ino;     /* identity + mtime of the listed directory at load (validates dir-cache snapshots) */
    int64_t dir_mtime;
    int32_t dir_mtime_ns, dir_pad;
    uint64_t flt_raw;              /* raw_count when order[] was last filtered */
    int32_t flt_lc_len, flt_valid, flt_hidden, virtual_mode, du_mode;
    uint64_t du_total;
    void *arc_ctx, *git_ctx;
    char path[PATH_MAX];
    char filter[FILTER_MAX];
    char flt_lc[FILTER_MAX];       /* ASCII-lowercased filter (SIMD needle) */
    char flt_applied[FILTER_MAX];  /* filter that produced the current order[] */
} DirModel;
#pragma pack(pop)
/* the assembler's class size has no tail padding: this is what Object_alloc is given (sizeof would add 4 unused bytes) */
#define DIRMODEL_SIZE (offsetof(DirModel, flt_applied) + FILTER_MAX)

int dir_diff_mark(DirModel *active, DirModel *other);   /* marks entries missing in / differing from `other`; their count */

/* ---- recursive search into a virtual panel (dir_search*.c) ---- */
int dir_search_run(DirModel *m, const char *root_path, const char *mask, const char *grep);   /* hits, or -errno when root cannot be opened */
int ds_match_mask(const char *name, const char *mask, int has_glob);   /* empty mask matches; has_glob: '*' '?' pattern, else case-insensitive substring */
int ds_glob_ci(const char *str, const char *pat);
int ds_grep_file(int dirfd, const char *name, const char *pat, size_t pat_len, char *buf);   /* 1 when pat occurs in the first 1 MiB */
int ds_ensure_model_cap(DirModel *m, size_t add_name_bytes);    /* room for one more entry and add_name_bytes of names: 0 / -1 */
int ds_append_entry(DirModel *m, const char *rel_name, const FileStat *st);   /* 0, or -1 when the model cannot grow */
int ds_append_parent(DirModel *m);                              /* ".." as the newest entry (FE_IS_PARENT); 0 or < 0 */
void ds_join_rel(char *dst, const char *prefix, const char *name);

/* ---- fuzzy finder backend (dir_fuzzy*.c, fs_write.c) ---- */
typedef struct FuzzyItem {
    const char *path;              /* NUL-terminated, relative to the collected root; lives in the caller's pool */
    int32_t is_dir, pad;
} FuzzyItem;
int fuzzy_score(const char *query, const char *cand, uint64_t *out_mask);   /* <0 no match, else score >= 1 (0: empty query); out_mask = matched candidate positions < 64 */
int dir_fuzzy_collect(const char *root, char *pool, int pool_cap, FuzzyItem *items, int max_items);   /* names collected (depth <= 8, no .git) */
int fs_write_file(const char *path, const void *buf, uint64_t len);        /* atomic write (tmp + fsync + rename) keeping the mode of a regular target: 0 / -1 */

/* ---- directory model methods still in assembly (dir_model*.s) ---- */
int DirModel_step_load(DirModel *m, size_t max_entries);        /* 1 more may follow, 0 done, -errno */
const char *DirModel_entry_name(const DirModel *m, const FileEntry *e);
int DirModel_reload(DirModel *m);

/* ---- lazy stat, selection and lookup (dir_model_stat.c, dir_model_select.c) ---- */
FileEntry *DirModel_get_entry(DirModel *m, intptr_t idx);      /* visible index -> entry through order[], or NULL */
void mark_link_dir(DirModel *m, FileEntry *e);                 /* symlink to a directory: counted as a dir once, FE_LINK_DIR */
void apply_stat_to_entry(DirModel *m, FileEntry *e, const FileStat *st, int dirfd);   /* dirfd -2: link targets left to the caller */
void DirModel_ensure_entry_stat(DirModel *m, FileEntry *e);
void DirModel_stat_range(DirModel *m, size_t view_start, size_t view_len);            /* the visible rows not stat'ed yet */
void DirModel_ensure_all_stats(DirModel *m);                   /* batched stat of every pending entry (sort by size / time) */
void DirModel_toggle_select(DirModel *m, intptr_t idx);
void DirModel_select_all_toggle(DirModel *m);                  /* select all visible, or clear when anything is selected */
size_t DirModel_count_selected(DirModel *m, int64_t *out_bytes);
intptr_t DirModel_find_by_name(DirModel *m, const char *name); /* view index or -1 */

/* ---- sorting of index slices (dir_sort.c, dir_sort_radix.c): dirs first, equal primary keys by name ascending ---- */
void DirModel_sort(DirModel *m);                               /* order[has_dotdot ..] -> [dirs][files], each sorted; is_unsorted = 0 */
int cmp_indices(uint32_t a, uint32_t b, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc);
uint64_t extract_radix_key(uint32_t idx, const FileEntry *entries, uint32_t mode, uint32_t desc);
uint64_t make_prefix_key(uint32_t idx, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc);
void insertion_sort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc);
void heapsort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc);
void introsort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc);
void radix_sort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc);

/* ---- trash (freedesktop.org Trash 1.0) and the 16-deep undo stack (trash_info.c, trash_dirs.c, trash_undo.c) ---- */
#define UNDO_MAX 16
#define UNDO_NONE 0
#define UNDO_RENAME 1
#define UNDO_MOVE 2
#define UNDO_TRASH 3
int tu_write_info(const char *info_path, const char *orig_path);        /* atomic <name>.trashinfo with the escaped original path and UTC date; 0 or -errno */
void tu_get_data_home(const char *const *envp, char *dst, size_t cap);  /* $XDG_DATA_HOME, else $HOME/.local/share, else /tmp */
void tu_mkdir_p_base(const char *data_home);                            /* creates data_home, Trash, Trash/files and Trash/info (0700), errors ignored */
int tu_pick_unique(const char *data_home, const char *base, char *out_files, char *out_info);   /* free "<base>[.N]" name in Trash/files: 0, or -EEXIST */
int trash_move_file(const char *src_path, const char *const *envp, char *out_trash_path, char *out_info_path);   /* 0, or -errno */
void undo_push(int kind, const char *orig_path, const char *cur_path, const char *info_path);   /* info_path may be NULL */
int undo_pop_and_apply(void);                                           /* 1 undone, 0 nothing to undo, -errno (-EEXIST keeps the entry) */

/* ---- file operations still in assembly (file_ops*.s) ---- */
intptr_t fs_rename_noreplace(const char *old_path, const char *new_path);   /* 0, or -errno (-EEXIST: target exists) */
void fs_progress_item(void);                                                /* one more item done in the running copy / delete */
int fs_copy_recursive(const char *src_path, const char *dst_path);          /* 0, or -errno */
int fs_delete_recursive(const char *path);                                  /* 0, or -errno */

/* ---- navigation state: tab history, bookmarks, frecency (nav_state.c, nav_persist.c) ---- */
#define NAV_TAB_MAX 8                  /* tabs per pane */
#define NAV_HIST_MAX 32                /* remembered paths per tab */
#define NAV_BM_MAX 64
#define NAV_FRE_MAX 128

typedef struct NavTab {                /* 4384 bytes; the pane code reads cursor and hist_len directly */
    char path[PATH_MAX];
    int32_t cursor, scroll, sort_mode, sort_desc, show_hidden;
    int32_t hist_pos, hist_len, hist_pad;
    char *hist[NAV_HIST_MAX];          /* heap strings, hist_len valid */
} NavTab;
#if UINTPTR_MAX == UINT64_MAX
_Static_assert(sizeof(NavTab) == 4384, "NavTab is shared with assembly");
#endif

char *nav_strdup(const char *s);                               /* heap copy, NULL when out of memory */
int nav_ci_contains(const char *hay, const char *needle);      /* ASCII case-insensitive substring; an empty needle matches */
NavTab *nav_tabs_alloc(const char *init_path);                 /* NAV_TAB_MAX zeroed tabs; tab 0 starts at init_path */
void nav_tabs_free(NavTab *tabs, int tab_count);
void nav_hist_push(NavTab *tab, const char *path);             /* new place: cuts the forward history, repeats are ignored */
const char *nav_hist_back(NavTab *tab);                        /* previous path or NULL */
const char *nav_hist_fwd(NavTab *tab);
void nav_state_init(const char *const *envp);                  /* once: data directory + bookmarks + frecency */
void nav_state_cleanup(void);
int nav_bookmarks_count(void);
const char *nav_bookmarks_get(int idx);
int nav_bookmarks_add(const char *path);                       /* 1 added, 0 duplicate / full */
void nav_bookmarks_remove(int idx);
void nav_frecency_record(const char *path);
int nav_frecency_count(void);
const char *nav_frecency_get(int idx);
int nav_frecency_score(int idx);
int nav_frecency_match(const char *substr, int *out_indices, int max_out);

/* ---- git status guard (git_trust.c) ---- */
int git_repo_trusted(const char *dotgit);                      /* "<worktree>/.git": 1 when `git status` may run there (plain dir, vetted local config), else 0 */

/* ---- directory change notifications (dir_watch.c) ---- */
int dirwatch_init(void);                                       /* 0, or -errno (the feature stays off) */
int dirwatch_fd(void);                                         /* pollable watch fd or -1 */
void dirwatch_set(int slot, const char *path);                 /* slot 0 / 1 = left / right pane directory */
uint32_t dirwatch_poll(void);                                  /* 1/2 = slot 0 structural/content, 4/8 = slot 1 */
void dirwatch_cleanup(void);

/* ---- whole-file helpers of the file operations (file_ops_read.c) ---- */
intptr_t fs_read_file_alloc(const char *path, size_t max_bytes, void **out_buf, size_t *out_len);   /* regular file -> NUL-terminated heap buffer: 0, or -errno */
intptr_t copy_link_at(int sdir, const char *sname, int ddir, const char *dname);                    /* copy a symlink as a symlink: 0, or -errno */

/* ---- crash-safe "Overwrite" (file_ops_overwrite.c): write a sibling temp file, then rename it over the target ---- */
typedef struct FoOpenResult { intptr_t fd; uint64_t used; } FoOpenResult;     /* rax:rdx: the fd or -errno; used = 1 when a temp file stands in */
DUOP_NODISCARD FoOpenResult fo_open_overwrite(int dfd, const char *name, uint32_t dst_mode, uint32_t new_mode, char *out_tmp);
DUOP_NODISCARD intptr_t fo_overwrite_open(int dfd, const char *name, uint32_t mode, char *out_tmp);            /* exclusive temp file next to `name`: fd or -errno */
DUOP_NODISCARD intptr_t fo_overwrite_commit(int dfd, const char *tmp, const char *name);                      /* renames the finished temp file over `name`: 0 or -errno */

/* ---- LRU directory cache (dir_cache.c): listings of recently left directories, handed back in O(1) on return ---- */
#define DC_SLOTS 16                                            /* snapshots kept at most (config.inc) */
#define DC_BUDGET 33554432                                     /* 32 MiB of entries / order / name pools at most (config.inc) */
extern uint64_t g_dc_bytes;                                    /* footprint of the snapshots held now */
int dircache_store(DirModel *m);                               /* 1: m's arrays donated (m left empty), 0: m keeps them */
int dircache_fetch(DirModel *m, const FileStat *dir_st);       /* 1: snapshot installed, order[] reusable; 2: installed, re-filter/sort; 0: miss/stale */
void dircache_invalidate(const char *path);                    /* drops the snapshot of path */

/* ---- git branch + `git status --porcelain=v1 -z` of a pane (git_status.c) ---- */
extern int g_git_defer;                                        /* 1 until the first frame is drawn: git_refresh does nothing */
int git_refresh(DirModel *dm);                                 /* runs git status for dm->path (trusted repositories only); returns 0 */
int git_lookup(DirModel *dm, const char *name);                /* status character of a top-level name, or 0 */
const char *git_branch(DirModel *dm);                          /* branch name, or "" */
void git_free_ctx(DirModel *dm);
int git_spawn_status(const char *dir, char *out_buf, int buf_cap);   /* bytes of output (NUL-terminated), or -1 */
void git_parse_branch(char *branch, const char **p_cur, const char *end);   /* "## <branch>..." record -> branch[64] */
