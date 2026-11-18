/* src/fs/file_ops.c - the small file operations and the data path of the copy engine (freestanding C23; replaces file_ops.s, kept
 * as tests/harness/file_ops_reference.s).
 *
 * copy_data moves the bytes of one file: FICLONE reflink (O(1) copy-on-write on Btrfs / XFS / bcachefs), else copy_file_range in
 * 4 MiB steps, else read / write through ONE shared 256 KiB buffer (no allocation per file). It reports progress and honours a
 * cancel request through the fs_progress_* hooks (task.s), which do nothing outside a background worker. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"
#include "duop_tui.h"
#include "i18n_slots.h"

#define CFR_CHUNK 4194304
#define COPY_BUF_SIZE 262144
#define FS_ERR_SAME 9999           /* -9999: source and target are the same */

static uint8_t *g_copy_buf;       /* lazily allocated, reused for every file */

/* the localised message of a -errno result of the file operations (generic text for anything unexpected) */
const char *fs_errno_message(int neg_errno)
{
    const LangStrings *l = i18n_get();
    switch (-neg_errno) {
    case EACCES: return l->s[LS_err_perm];
    case EEXIST: return l->s[LS_err_exists];
    case ENOENT: return l->s[LS_err_noent];
    case ENOTEMPTY: return l->s[LS_err_notempty];
    case EISDIR: return l->s[LS_err_isdir];
    case ENOTDIR: return l->s[LS_err_notdir];
    case FS_ERR_SAME: return l->s[LS_err_same];
    case ECANCELED: return l->s[LS_err_canceled];
    case EBUSY: return l->s[LS_err_busy];
    case EOPNOTSUPP: return l->s[LS_err_special];
    default: return l->s[LS_err_generic];
    }
}

intptr_t fs_mkdir(const char *path) { return os_mkdirat(AT_FDCWD, path, 0755); }

/* creates an empty file; an existing one is an error (-EEXIST) */
intptr_t fs_touch(const char *path)
{
    intptr_t fd = os_openat(AT_FDCWD, path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0644);
    if (fd < 0) return fd;
    (void)os_close((int)fd);
    return 0;
}

intptr_t fs_rename(const char *old_path, const char *new_path)
{
    return os_renameat2(AT_FDCWD, old_path, AT_FDCWD, new_path, 0);   /* safe-overwrite: callers checked the target */
}

/* 0, or -errno (-EEXIST: the target exists). Without RENAME_NOREPLACE in the kernel or the file system the target is looked at
 * first (no-follow: a dangling symlink there counts as existing). */
intptr_t fs_rename_noreplace(const char *old_path, const char *new_path)
{
    intptr_t r = os_renameat2(AT_FDCWD, old_path, AT_FDCWD, new_path, RENAME_NOREPLACE);
    if (r != -EINVAL && r != -ENOSYS) return r;
    FileStat st;
    int s = os_statat(AT_FDCWD, new_path, &st, 0);
    if (s >= 0) return -EEXIST;
    if (s != -ENOENT) return s;
    return os_renameat2(AT_FDCWD, old_path, AT_FDCWD, new_path, 0);   /* safe-overwrite: the target was just verified absent */
}

/* 1 when dst is src (trailing '/' ignored) or lies strictly inside it */
int path_is_same_or_descendant(const char *src, const char *dst)
{
    size_t n = str_len(src);
    while (n > 1 && src[n - 1] == '/') n--;
    if (!n) return 0;
    for (size_t i = 0; i < n; i++)
        if (src[i] != dst[i]) return 0;
    if (n == 1 && src[0] == '/') return 1;
    return dst[n] == 0 || dst[n] == '/';
}

static intptr_t copy_rw(int sfd, int dfd)
{
    if (!g_copy_buf) g_copy_buf = mem_alloc(COPY_BUF_SIZE);
    if (!g_copy_buf) return -ENOMEM;
    for (;;) {
        intptr_t r = os_read(sfd, g_copy_buf, COPY_BUF_SIZE);
        if (r == -EINTR) {                                             /* SIGTERM of a cancel request breaks blocking reads */
            if (fs_progress_cancelled()) return -ECANCELED;
            continue;
        }
        if (r <= 0) return r;
        intptr_t w = sys_write_all(dfd, g_copy_buf, (size_t)r);
        if (w < 0) return w;
        fs_progress_bytes((uint64_t)w);
        if (fs_progress_cancelled()) return -ECANCELED;
    }
}

/* the data of sfd into dfd: 0, -errno or -ECANCELED */
intptr_t copy_data(int sfd, int dfd, int is_regular)
{
    if (!is_regular) return copy_rw(sfd, dfd);
    if (os_clone_file(sfd, dfd) == 0) {                                /* reflinked: account the whole size at once */
        FileStat st;
        if (os_fstat(sfd, &st) >= 0) fs_progress_bytes((uint64_t)st.size);
        return 0;
    }
    uint64_t moved = 0;
    for (;;) {
        intptr_t r = os_copy_file_range(sfd, dfd, CFR_CHUNK);
        if (r == 0) return 0;
        if (r > 0) {
            moved += (uint64_t)r;
            fs_progress_bytes((uint64_t)r);
            if (fs_progress_cancelled()) return -ECANCELED;
            continue;
        }
        if (r == -EINTR) {
            if (fs_progress_cancelled()) return -ECANCELED;
            continue;
        }
        if (moved) return r;                                           /* failure after progress: a genuine I/O error */
        if (r == -EXDEV || r == -EOPNOTSUPP || r == -EINVAL || r == -ENOSYS || r == -EBADF) return copy_rw(sfd, dfd);
        return r;
    }
}
