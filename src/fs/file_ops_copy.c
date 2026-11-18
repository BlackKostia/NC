/* src/fs/file_ops_copy.c - the recursive copy engine (freestanding C23; replaces file_ops_copy.s + file_ops_copy_at.s, kept as
 * tests/harness/file_ops_copy_reference.s and file_ops_copy_at_reference.s).
 *
 * fd-relative traversal (children are reached with openat / mkdirat / unlinkat on the parent's fd: no PATH_MAX joins, no repeated
 * resolution from the root), d_type driven (an entry is stat'ed only when the kernel reports DT_UNKNOWN), depth bounded by
 * MAX_DIR_DEPTH, never descending into the destination root. An existing target goes through the conflict policy
 * (fo_resolve_eexist_open: skip, crash-safe overwrite through a temp file, ...); a failed or canceled copy removes what it created. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

#define MAX_DIR_DEPTH 512
#define DENTS_CAP 32752            /* 32 KiB slab block minus its 16-byte header */
#define FO_SAME_FILE (-9999)
#define FO_SKIP (-2)

extern void *g_fs_progress;        /* TaskShared of the background worker, NULL in the UI process (task.s) */
void fs_progress_begin(const char *path);
FoOpenResult fo_resolve_eexist_open(int dst_dfd, const char *dst_rel, const FileStat *src_st, char *out_ren);

static uint64_t g_copy_root_dev, g_copy_root_ino;   /* the destination root of the running copy */

/* data, fsync (EINVAL: not syncable, fine) and close of a fresh destination; the first error wins */
static intptr_t cra_fill(int sfd, int dfd, const char *sname, uint32_t mode)
{
    fs_progress_begin(sname);
    intptr_t rc = copy_data(sfd, dfd, (mode & S_IFMT) == S_IFREG);
    if (rc >= 0) {
        intptr_t s;
        while ((s = os_fsync(dfd)) == -EINTR) {}
        if (s < 0 && s != -EINVAL) rc = s;
    }
    intptr_t c = os_close(dfd);
    if (c < 0 && rc >= 0) rc = c;
    (void)os_close(sfd);                                               /* fault-checked: source fd read-only cleanup */
    return rc;
}

/* Copies one entry that is neither a directory nor a symlink. A destination that is the source itself (hard link / symlink to it)
 * is rejected with -9999 instead of being truncated; a FIFO is streamed only by the background worker; a canceled or failed copy
 * unlinks what it created. 0, or -errno. */
[[gnu::noinline]] intptr_t copy_reg_at(int sdir, const char *sname, int ddir, const char *dname)
{
    char created[PATH_MAX];                                            /* the name to remove on failure ("" = none) */
    FileStat st;
    int oflags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | (g_fs_progress ? 0 : O_NONBLOCK);   /* UI: a FIFO / device must never block */
    intptr_t sfd = os_openat(sdir, sname, oflags, 0);
    if (sfd < 0) return sfd;
    intptr_t r = os_fstat((int)sfd, &st);
    uint32_t type = st.mode & S_IFMT;
    if (r >= 0 && type != S_IFREG && !(type == S_IFIFO && g_fs_progress)) r = -EOPNOTSUPP;   /* devices, sockets: never read */
    if (r < 0) {
        (void)os_close((int)sfd);
        return r;
    }
    (void)str_copy(created, dname, PATH_MAX);
    int made = 1;                                                      /* 1: created, 2: temp file to rename over the target */
    intptr_t dfd = os_openat(ddir, dname, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, (st.mode & 0777) | 0600);
    if (dfd == -EEXIST) {
        made = 0;
        created[0] = 0;
        FoOpenResult o = fo_resolve_eexist_open(ddir, dname, &st, created);
        dfd = o.fd;
        if (dfd >= 0 && created[0]) made = (uint32_t)o.used == 1 ? 2 : 1;
        if (dfd == FO_SKIP) {
            fs_progress_item();
            (void)os_close((int)sfd);
            return 0;
        }
    }
    if (dfd < 0) {
        (void)os_close((int)sfd);
        return dfd;
    }
    r = cra_fill((int)sfd, (int)dfd, sname, st.mode);
    if (r >= 0 && made == 2) r = fo_overwrite_commit(ddir, created, dname);   /* swap the finished copy in atomically */
    if (r < 0) {
        if (made) (void)os_unlinkat(ddir, created, 0);                 /* fault-checked: the partial target / temp file */
        return r;
    }
    fs_progress_item();
    return 0;
}

/* one directory entry of copy_dir_fd */
static intptr_t cdf_entry(int sfd, int dfd, const char *name, uint8_t type, int depth)
{
    if (type == PAL_DT_UNKNOWN) {
        FileStat st;
        type = PAL_DT_REG;
        if (os_statat(sfd, name, &st, 0) >= 0) {
            if ((st.mode & S_IFMT) == S_IFDIR) type = PAL_DT_DIR;
            else if ((st.mode & S_IFMT) == S_IFLNK) type = PAL_DT_LNK;
        }
    }
    if (type == PAL_DT_DIR) return copy_subdir(sfd, name, dfd, depth + 1);
    if (type == PAL_DT_LNK) return copy_link_at(sfd, name, dfd, name);
    return copy_reg_at(sfd, name, dfd, name);
}

/* every entry of sfd into dfd: 0, -errno, -ECANCELED, -ENAMETOOLONG beyond MAX_DIR_DEPTH */
intptr_t copy_dir_fd(int sfd, int dfd, int depth)
{
    if ((unsigned)depth >= MAX_DIR_DEPTH) return -ENAMETOOLONG;
    char *buf = mem_alloc(DENTS_CAP);
    if (!buf) return -ENOMEM;
    intptr_t r;
    for (;;) {
        intptr_t n = os_dir_read(sfd, buf, DENTS_CAP);
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
            r = fs_progress_cancelled() ? -ECANCELED : cdf_entry(sfd, dfd, name, type, depth);
        }
        if (r < 0) break;
    }
    mem_free(buf);
    return r;
}

/* mkdir + recursive copy of the sub-directory name of sdir into ddir (an existing directory is merged into) */
intptr_t copy_subdir(int sdir, const char *name, int ddir, int depth)
{
    if ((unsigned)depth >= MAX_DIR_DEPTH) return -ENAMETOOLONG;
    intptr_t sfd = os_openat(sdir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
    if (sfd < 0) return sfd;
    FileStat st;
    intptr_t r = os_fstat((int)sfd, &st);
    if (r >= 0 && st.dev == g_copy_root_dev && st.ino == g_copy_root_ino) r = 0;   /* never recurse into the destination root */
    else if (r >= 0) {
        r = os_mkdirat(ddir, name, (st.mode & 0777) | 0700);
        if (r >= 0 || r == -EEXIST) {
            fs_progress_begin(name);
            fs_progress_item();
            intptr_t dfd = os_openat(ddir, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
            r = dfd;
            if (dfd >= 0) {
                r = copy_dir_fd((int)sfd, (int)dfd, depth);
                (void)os_close((int)dfd);
            }
        }
    }
    (void)os_close((int)sfd);
    return r;
}

intptr_t fs_copy_file(const char *src_path, const char *dst_path) { return copy_reg_at(AT_FDCWD, src_path, AT_FDCWD, dst_path); }

static intptr_t fcr_dir(const char *src, const char *dst, const FileStat *sst)
{
    FileStat dst_st;
    if (path_is_same_or_descendant(src, dst)) return FO_SAME_FILE;     /* a directory into itself / a descendant */
    if (os_statat(AT_FDCWD, dst, &dst_st, 1) >= 0 && dst_st.dev == sst->dev && dst_st.ino == sst->ino) return FO_SAME_FILE;
    intptr_t r = os_mkdirat(AT_FDCWD, dst, (sst->mode & 0777) | 0700);
    if (r < 0 && r != -EEXIST) return r;
    fs_progress_begin(src);
    fs_progress_item();
    intptr_t sfd = os_openat(AT_FDCWD, src, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
    if (sfd < 0) return sfd;
    intptr_t dfd = os_openat(AT_FDCWD, dst, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, 0);
    if (dfd >= 0) {
        FileStat root;
        bool ok = os_fstat((int)dfd, &root) >= 0;
        g_copy_root_dev = ok ? root.dev : UINT64_MAX;
        g_copy_root_ino = ok ? root.ino : UINT64_MAX;
        r = copy_dir_fd((int)sfd, (int)dfd, 0);
        (void)os_close((int)dfd);
    } else {
        r = dfd;
    }
    (void)os_close((int)sfd);
    return r;
}

/* Copies a file, a symlink (as a symlink) or a whole directory tree: 0, or -errno (-9999: the target is the source or inside it). */
intptr_t fs_copy_recursive(const char *src_path, const char *dst_path)
{
    if (!str_cmp(src_path, dst_path)) return FO_SAME_FILE;
    FileStat st;
    intptr_t r = os_statat(AT_FDCWD, src_path, &st, 0);
    if (r < 0) return r;
    if ((st.mode & S_IFMT) == S_IFDIR) return fcr_dir(src_path, dst_path, &st);
    if ((st.mode & S_IFMT) == S_IFLNK) return copy_link_at(AT_FDCWD, src_path, AT_FDCWD, dst_path);
    return copy_reg_at(AT_FDCWD, src_path, AT_FDCWD, dst_path);
}
