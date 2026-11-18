/* src/fs/file_ops_delete.c - recursive delete, move (rename, or copy + delete across file systems) and the head of a file
 * (freestanding C23; replaces file_ops_delete.s, kept as tests/harness/file_ops_delete_reference.s).
 *
 * The delete is fd-relative and d_type driven like the copy engine; symlinks are removed, never followed (O_NOFOLLOW on every
 * directory open); depth is bounded by MAX_DIR_DEPTH. */
#include "duop_task.h"
#include "duop_pal.h"
#include "duop_sys.h"

#define MAX_DIR_DEPTH 512
#define DENTS_CAP 32752


/* one entry of dfd: a directory is emptied first, then removed */
static intptr_t ddf_entry(int dfd, const char *name, uint8_t type, int depth);

/* removes every entry below dfd (not dfd itself): 0, -errno, -ECANCELED, -ENAMETOOLONG beyond MAX_DIR_DEPTH */
static intptr_t delete_dir_fd(int dfd, int depth)
{
    if ((unsigned)depth >= MAX_DIR_DEPTH) return -ENAMETOOLONG;
    char *buf = mem_alloc(DENTS_CAP);
    if (!buf) return -ENOMEM;
    intptr_t r;
    for (;;) {
        intptr_t n = os_dir_read(dfd, buf, DENTS_CAP);
        if (n <= 0) {
            r = n;
            break;
        }
        size_t pos = 0;
        uint8_t type;
        const char *name;
        r = 0;
        while (r >= 0 && (name = os_dir_next_ex(buf, (size_t)n, &pos, &type))) {
            if (name[0] == '.' && (!name[1] || (name[1] == '.' && !name[2]))) continue;
            r = fs_progress_cancelled() ? -ECANCELED : ddf_entry(dfd, name, type, depth);
        }
        if (r < 0) break;
    }
    mem_free(buf);
    return r;
}

static intptr_t ddf_entry(int dfd, const char *name, uint8_t type, int depth)
{
    if (type == PAL_DT_UNKNOWN) {
        FileStat st;
        type = os_statat(dfd, name, &st, 0) >= 0 && (st.mode & S_IFMT) == S_IFDIR ? PAL_DT_DIR : PAL_DT_REG;
    }
    intptr_t r;
    if (type == PAL_DT_DIR) {
        intptr_t sub = os_openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
        if (sub < 0) return sub;
        r = delete_dir_fd((int)sub, depth + 1);
        (void)os_close((int)sub);
        if (r < 0) return r;
        r = os_unlinkat(dfd, name, AT_REMOVEDIR);
    } else {
        r = os_unlinkat(dfd, name, 0);
    }
    if (r < 0) return r;
    fs_progress_begin(name);
    fs_progress_item();
    return 0;
}

intptr_t fs_delete_recursive(const char *path)
{
    FileStat st;
    intptr_t r = os_statat(AT_FDCWD, path, &st, 0);
    if (r < 0) return r;
    fs_progress_begin(path);
    if ((st.mode & S_IFMT) != S_IFDIR) {
        r = os_unlinkat(AT_FDCWD, path, 0);
    } else {
        intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
        if (fd < 0) return fd;
        r = delete_dir_fd((int)fd, 0);
        (void)os_close((int)fd);
        if (r < 0) return r;
        r = os_unlinkat(AT_FDCWD, path, AT_REMOVEDIR);
    }
    if (r < 0) return r;
    fs_progress_item();
    return 0;
}

/* Moves by rename; across file systems (EXDEV) by copy, and only a copy that skipped nothing removes the source - as one step
 * (no cancel, no double counting), so a move never ends half-deleted. The background worker applies the conflict policy first. */
intptr_t fs_move_recursive(const char *src_path, const char *dst_path)
{
    char renamed[PATH_MAX];
    const char *dst = dst_path;
    if (g_fs_progress) {
        intptr_t act = fo_move_check_conflict(src_path, dst_path, renamed);
        if (act < 0) return act;
        if ((int)act == CONFLICT_ACT_SKIP) {
            fs_progress_item();
            return 0;
        }
        if ((int)act == CONFLICT_ACT_RENAME) dst = renamed;
    }
    intptr_t r = fs_rename(src_path, dst);
    if (r != -EXDEV) return r;
    g_copy_had_skip = 0;
    r = fs_copy_recursive(src_path, dst);
    if (r < 0 || g_copy_had_skip) return r;
    TaskShared *progress = g_fs_progress;
    g_fs_progress = nullptr;
    r = fs_delete_recursive(src_path);
    g_fs_progress = progress;
    return r;
}

/* up to max_bytes of the start of path into buf (O_NONBLOCK: a FIFO cannot hang the caller); a read error ends the head early.
 * 0 with *out_read set, or the -errno of the open. */
intptr_t fs_read_file_head(const char *path, void *buf, size_t max_bytes, size_t *out_read)
{
    if (out_read) *out_read = 0;
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
    if (fd < 0) return fd;
    size_t got = 0;
    while (got < max_bytes) {
        intptr_t n = sys_read_retry((int)fd, (uint8_t *)buf + got, max_bytes - got);
        if (n <= 0) break;
        got += (size_t)n;
    }
    if (out_read) *out_read = got;
    (void)os_close((int)fd);
    return 0;
}
