/* src/fs/git_trust.c - may `git status` run in this repository? (freestanding C23; replaces git_trust.s)
 *
 * `git status` runs programs named by the repository's own configuration: filter drivers (filter.<name>.clean / .process),
 * anything an [include] pulls in, core.fsmonitor (overridden on the command line by the caller). A repository that arrives from
 * elsewhere (archive, shared disk, download) must not run code just because somebody browsed it, so git_repo_trusted() only
 * accepts a plain <repo>/.git directory whose local config is a readable regular file, free of NUL bytes, not larger than
 * 32 KiB and naming no filter / include section. Everything unreadable or unexpected counts as untrusted; a missing config
 * file is fine (it cannot name a program). */
#include "duop_fs.h"
#include "duop_oop.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define GT_CFG_MAX 32768

/* bytes read (<= GT_CFG_MAX + 1, so that "too large" is detectable), or -errno */
static intptr_t gt_read_config(int fd, char *buf)
{
    size_t got = 0;
    while (got < GT_CFG_MAX + 1) {
        intptr_t n = sys_read_retry(fd, buf + got, GT_CFG_MAX + 1 - got);
        if (n < 0) return n;
        if (n == 0) break;
        got += (size_t)n;
    }
    return (intptr_t)got;
}

/* the text is NUL free and names no filter / include section */
static bool gt_config_clean(char *buf, size_t len)
{
    buf[len] = 0;
    if (str_len(buf) != len) return false;                        /* embedded NUL: git may parse more than we do */
    return !str_contains_ci(buf, "filter") && !str_contains_ci(buf, "include");
}

int git_repo_trusted(const char *dotgit)                         /* dotgit = "<worktree>/.git"; 1 trusted, 0 refuse */
{
    char cfg[PATH_MAX];
    FileStat st;
    if (str_len(dotgit) >= PATH_MAX - 16) return 0;               /* "/config" must fit without truncation */
    if (os_statat(AT_FDCWD, dotgit, &st, 0) < 0 || (st.mode & S_IFMT) != S_IFDIR) return 0;   /* no-follow: a symlinked .git is not trusted */
    str_copy(cfg, dotgit, PATH_MAX);
    str_cat(cfg, "/config", PATH_MAX);
    intptr_t fd = os_openat(AT_FDCWD, cfg, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0);
    if (fd == -ENOENT) return 1;                                  /* no local config: nothing can name a program */
    if (fd < 0) return 0;
    if (os_fstat((int)fd, &st) < 0 || (st.mode & S_IFMT) != S_IFREG) { os_close((int)fd); return 0; }
    char *buf = mem_alloc(GT_CFG_MAX + 2);
    if (!buf) { os_close((int)fd); return 0; }
    intptr_t n = gt_read_config((int)fd, buf);
    os_close((int)fd);
    int ok = n >= 0 && n <= GT_CFG_MAX && gt_config_clean(buf, (size_t)n);
    mem_free(buf);
    return ok;
}
