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

/* ---- directory model methods still in assembly (dir_model*.s, dir_sort*.s) ---- */
int DirModel_step_load(DirModel *m, size_t max_entries);        /* 1 more may follow, 0 done, -errno */
const char *DirModel_entry_name(const DirModel *m, const FileEntry *e);
void DirModel_sort(DirModel *m);
int DirModel_reload(DirModel *m);

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
int fs_copy_recursive(const char *src_path, const char *dst_path);          /* 0, or -errno */
int fs_delete_recursive(const char *path);                                  /* 0, or -errno */
