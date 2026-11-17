/* src/fs/fs_write.c - atomic whole-file write (freestanding C23; replaces fs_write_file of dir_fuzzy_walk.s): the data goes
 * to <path>.tmp.<hex>, is fsynced and renamed over path, so a crash leaves either the old or the new content. The mode of an
 * existing regular file is kept (0644 for a new one); symlinks, directories and special files are refused. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

int fs_write_file(const char *path, const void *buf, uint64_t len)
{
    FileStat st;
    char tmp[PATH_MAX];
    unsigned mode = 0644;
    int r = os_statat(AT_FDCWD, path, &st, 0);
    if (r >= 0) {
        if ((st.mode & S_IFMT) != S_IFREG) return -1;
        mode = st.mode & 0777;
    } else if (r != -ENOENT) {
        return -1;
    }
    intptr_t fd = tmp_open_atomic(path, tmp, (int)mode);
    if (fd < 0) return -1;
    intptr_t w = sys_write_all((int)fd, buf, len);
    int64_t rc = w < 0 ? w : (uint64_t)w == len ? 0 : -EIO;
    return tmp_commit_atomic((int)fd, tmp, path, rc) < 0 ? -1 : 0;
}
