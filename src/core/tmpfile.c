/* src/core/tmpfile.c - private per-process temporary directory, exclusive temp files and atomic replace
 * (freestanding C23; replaces tmpfile.s). Everything is *at-relative with O_EXCL | O_NOFOLLOW, so a hostile /tmp
 * cannot redirect a write; atomic commit = fsync + rename + parent-directory fsync. */
#include "duop_config.h"
#include "duop_pal.h"
#include "duop_string.h"

#define TMP_TRIES 16

static char g_tmp_dir[128];
static int32_t g_tmp_dir_ok;
static int32_t g_tmp_seq;

static char *append_hex(char *dst, uint32_t v, int digits)
{
    while (digits--) {
        unsigned d = (v >> (4 * digits)) & 0xF;
        *dst++ = (char)(d < 10 ? '0' + d : 'a' + d - 10);
    }
    *dst = 0;
    return dst;
}

static char *append_dec(char *dst, uint32_t v)
{
    return dst + u64_to_dec(v, dst);
}

static bool dir_is_ours(const char *path, uint32_t uid)
{
    FileStat st;
    if (os_statat(AT_FDCWD, path, &st, 0) < 0) return false;
    return (st.mode & S_IFMT) == S_IFDIR && st.uid == uid && (st.mode & 0777) == 0700;
}

/* Creates (or re-validates) /tmp/duop-<uid>-<pid>[-n] with mode 0700; copies it to out_dir when given. */
int tmp_ensure_dir(char *out_dir, int cap)
{
    if (g_tmp_dir_ok != 1) {
        uint32_t uid = (uint32_t)os_getuid(), pid = (uint32_t)os_getpid();
        bool ok = false;
        for (uint32_t n = 0; n < TMP_TRIES && !ok; n++) {
            str_copy(g_tmp_dir, "/tmp/duop-", sizeof g_tmp_dir);
            char *p = append_dec(g_tmp_dir + str_len(g_tmp_dir), uid);
            *p++ = '-';
            p = append_dec(p, pid);
            if (n) { *p++ = '-'; append_dec(p, n); }
            intptr_t r = os_mkdirat(AT_FDCWD, g_tmp_dir, 0700);
            ok = r == 0 || (r == -EEXIST && dir_is_ours(g_tmp_dir, uid));
        }
        if (!ok) return -1;
        g_tmp_dir_ok = 1;
    }
    if (out_dir) str_copy(out_dir, g_tmp_dir, (uint32_t)cap);
    return 0;
}

/* Opens <tmpdir>/<prefix>_<8 hex>[suffix] exclusively (0600); returns the fd or -1 (full-width: asm callers compare rax). */
intptr_t tmp_open_unique(const char *prefix, const char *suffix, char *out_path, int cap)
{
    if (cap < 64 || tmp_ensure_dir(out_path, cap) < 0) return -1;
    for (int tries = 0; tries < TMP_TRIES; tries++) {
        size_t dlen = str_copy(out_path, g_tmp_dir, (uint32_t)cap);
        size_t plen = str_len(prefix), slen = str_len(suffix);
        if (dlen + plen + slen + 11 > (uint32_t)cap) return -1;
        char *p = out_path + dlen;
        *p++ = '/';
        for (size_t i = 0; i < plen; i++) *p++ = prefix[i];
        *p++ = '_';
        p = append_hex(p, (uint32_t)__atomic_add_fetch(&g_tmp_seq, 1, __ATOMIC_SEQ_CST), 8);
        for (size_t i = 0; i < slen; i++) *p++ = suffix[i];
        *p = 0;
        intptr_t fd = os_openat(AT_FDCWD, out_path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd >= 0) return fd;
        if (fd != -EEXIST) return -1;
    }
    return -1;
}

int tmp_make_path(const char *prefix, const char *suffix, char *out_path, int cap)
{
    intptr_t fd = tmp_open_unique(prefix, suffix, out_path, cap);
    if (fd < 0) return -1;
    (void)os_close((int)fd);
    return 0;
}

/* Opens <final_path>.tmp.<8 hex> exclusively with `mode`; the name is written to tmp_buf (PATH_MAX bytes).
 * Returns the fd, or -errno (-ENAMETOOLONG when the final path leaves no room for the suffix). */
intptr_t tmp_open_atomic(const char *final_path, char *tmp_buf, int mode)
{
    if (str_len(final_path) >= PATH_MAX - 14) return -ENAMETOOLONG;
    intptr_t fd = -EEXIST;
    for (int tries = 0; tries < TMP_TRIES && fd == -EEXIST; tries++) {
        str_copy(tmp_buf, final_path, PATH_MAX);
        str_cat(tmp_buf, ".tmp", PATH_MAX);
        char *p = tmp_buf + str_len(tmp_buf);
        *p++ = '.';
        append_hex(p, (uint32_t)__atomic_add_fetch(&g_tmp_seq, 1, __ATOMIC_SEQ_CST), 8);
        fd = os_openat(AT_FDCWD, tmp_buf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, (unsigned)mode);
    }
    return fd;
}

static intptr_t fsync_retry(int fd)
{
    intptr_t r;
    while ((r = os_fsync(fd)) == -EINTR) {}
    return r;
}

/* Best effort: make the rename itself durable by syncing the containing directory. */
static void fsync_parent_dir(const char *final_path)
{
    char dir[PATH_MAX];
    size_t n = str_len(final_path);
    while (n && final_path[n - 1] != '/') n--;                 /* n = index after the last slash (0 = none) */
    if (!n) { dir[0] = '.'; dir[1] = 0; }
    else if (n == 1) { dir[0] = '/'; dir[1] = 0; }
    else {
        if (n - 1 >= PATH_MAX - 1) return;
        for (size_t i = 0; i < n - 1; i++) dir[i] = final_path[i];
        dir[n - 1] = 0;
    }
    intptr_t fd = os_openat(AT_FDCWD, dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (fd < 0) return;
    (void)fsync_retry((int)fd);
    (void)os_close((int)fd);
}

/* Finishes an atomic write started by tmp_open_atomic: a failed write (write_rc < 0) or any later error removes the
 * temp file and returns the error; otherwise fsync + close + rename over final_path + directory fsync, returns 0. */
intptr_t tmp_commit_atomic(int fd, const char *tmp_buf, const char *final_path, int64_t write_rc)
{
    intptr_t rc = write_rc;
    if (rc >= 0) {
        intptr_t s = fsync_retry(fd);
        if (s < 0 && s != -EINVAL) {
            rc = s;
            (void)os_close(fd);
        } else {
            intptr_t c = os_close(fd);
            rc = c < 0 ? c : os_renameat2(AT_FDCWD, tmp_buf, AT_FDCWD, final_path, 0);
        }
        if (rc >= 0) {
            fsync_parent_dir(final_path);
            return 0;
        }
    } else {
        (void)os_close(fd);
    }
    (void)os_unlinkat(AT_FDCWD, tmp_buf, 0);
    return rc;
}
