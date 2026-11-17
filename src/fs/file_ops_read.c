/* src/fs/file_ops_read.c - small whole-file helpers of the file operations (freestanding C23; replaces file_ops_read.s and
 * file_ops_copy_link.s): read a regular file into a NUL-terminated heap buffer, and copy a symbolic link as a link. */
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_sys.h"

/* Reads at most max_bytes of a regular file (opened O_NONBLOCK so that a FIFO cannot hang the UI; only regular files are
 * accepted) into a heap buffer of length + 1 bytes. 0, or -errno with *out_buf == NULL. */
intptr_t fs_read_file_alloc(const char *path, size_t max_bytes, void **out_buf, size_t *out_len)
{
    *out_buf = nullptr;
    *out_len = 0;
    intptr_t fd = os_openat(AT_FDCWD, path, O_RDONLY | O_NONBLOCK | O_CLOEXEC, 0);
    if (fd < 0) return fd;
    FileStat st;
    intptr_t err = os_fstat((int)fd, &st);
    if (err >= 0 && (st.mode & S_IFMT) != S_IFREG) err = -EINVAL;
    if (err < 0) { os_close((int)fd); return err; }
    size_t cap = st.size < 0 ? 0 : (size_t)st.size;
    if (cap > max_bytes) cap = max_bytes;
    char *buf = mem_alloc(cap + 1);
    if (!buf) { os_close((int)fd); return -ENOMEM; }
    size_t got = 0;
    while (got < cap) {
        intptr_t n = sys_read_retry((int)fd, buf + got, cap - got);
        if (n == 0) break;                                   /* the file shrank: what was read is the result */
        if (n < 0) { mem_free(buf); os_close((int)fd); return n; }
        got += (size_t)n;
    }
    buf[got] = 0;
    *out_buf = buf;
    *out_len = got;
    os_close((int)fd);
    return 0;
}

/* copies the link (sdir, sname) as a link to the same target at (ddir, dname): 0, or -errno */
intptr_t copy_link_at(int sdir, const char *sname, int ddir, const char *dname)
{
    char target[PATH_MAX];
    intptr_t n = os_readlinkat(sdir, sname, target, PATH_MAX - 1);
    if (n < 0) return n;
    target[n] = 0;
    intptr_t r = os_symlinkat(target, ddir, dname);
    if (r < 0) return r;
    fs_progress_item();
    return 0;
}
