/* tools/abi_verify.c - C11 Compile-Time & Runtime Kernel ABI Verifier for Duop.
 * Verifies include/os/linux/x86_64/pal_target.inc constants against Linux UAPI headers.
 * Compiled standalone with gcc/clang during verification; never linked into duop.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/stat.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>

typedef struct {
    const char *name;
    long long expected;
} AbiEntry;

static const AbiEntry k_entries[] = {
    {"AT_FDCWD", AT_FDCWD},
    {"AT_SYMLINK_NOFOLLOW", AT_SYMLINK_NOFOLLOW},
    {"AT_REMOVEDIR", AT_REMOVEDIR},
    {"O_RDONLY", O_RDONLY},
    {"O_WRONLY", O_WRONLY},
    {"O_RDWR", O_RDWR},
    {"O_CREAT", O_CREAT},
    {"O_EXCL", O_EXCL},
    {"O_TRUNC", O_TRUNC},
    {"O_APPEND", O_APPEND},
    {"O_NONBLOCK", O_NONBLOCK},
    {"O_DIRECTORY", O_DIRECTORY},
    {"O_NOFOLLOW", O_NOFOLLOW},
    {"O_CLOEXEC", O_CLOEXEC},
    {"PROT_READ", PROT_READ},
    {"PROT_WRITE", PROT_WRITE},
    {"MAP_SHARED", MAP_SHARED},
    {"MAP_PRIVATE", MAP_PRIVATE},
    {"MAP_ANONYMOUS", MAP_ANONYMOUS},
    {"MAP_FIXED", MAP_FIXED},
    {"MREMAP_MAYMOVE", MREMAP_MAYMOVE},
    {"S_IFMT", S_IFMT},
    {"S_IFDIR", S_IFDIR},
    {"S_IFREG", S_IFREG},
    {"S_IFLNK", S_IFLNK},
    {"ENOENT", ENOENT},
    {"ESRCH", ESRCH},
    {"EINTR", EINTR},
    {"EIO", EIO},
    {"EBADF", EBADF},
    {"TIOCGWINSZ", TIOCGWINSZ},
    {"WINSIZE_ROW", (long long)offsetof(struct winsize, ws_row)},
    {"WINSIZE_COL", (long long)offsetof(struct winsize, ws_col)},
    {"POLLFD_FD", (long long)offsetof(struct pollfd, fd)},
    {"POLLFD_EVENTS", (long long)offsetof(struct pollfd, events)},
    {"POLLFD_REVENTS", (long long)offsetof(struct pollfd, revents)},
    {"POLLIN", POLLIN},
    {"CLOCK_MONOTONIC", CLOCK_MONOTONIC},
    {"TIMESPEC_SEC", (long long)offsetof(struct timespec, tv_sec)},
    {"TIMESPEC_NSEC", (long long)offsetof(struct timespec, tv_nsec)},
    {"SIGINT", SIGINT},
    {"SIGTERM", SIGTERM},
    {"SIGBUS", SIGBUS},
    {"SIGWINCH", SIGWINCH},
    {"KSTAT_SIZE", (long long)sizeof(struct stat)},
    {"KSTAT_DEV", (long long)offsetof(struct stat, st_dev)},
    {"KSTAT_INO", (long long)offsetof(struct stat, st_ino)},
    {"KSTAT_NLINK", (long long)offsetof(struct stat, st_nlink)},
    {"KSTAT_MODE", (long long)offsetof(struct stat, st_mode)},
    {"KSTAT_UID", (long long)offsetof(struct stat, st_uid)},
    {"KSTAT_GID", (long long)offsetof(struct stat, st_gid)},
    {"KSTAT_ST_SIZE", (long long)offsetof(struct stat, st_size)},
    {"KSTAT_MTIME", (long long)offsetof(struct stat, st_mtim)},
    {"KSTAT_MTIME_NSEC", (long long)offsetof(struct stat, st_mtim) + (long long)offsetof(struct timespec, tv_nsec)},
    {"KSTATX_SIZE", (long long)sizeof(struct statx)},
    {"KSTATX_MASK", (long long)offsetof(struct statx, stx_mask)},
    {"KSTATX_MODE", (long long)offsetof(struct statx, stx_mode)},
    {"KSTATX_INO", (long long)offsetof(struct statx, stx_ino)},
    {"KSTATX_ST_SIZE", (long long)offsetof(struct statx, stx_size)},
    {"KSTATX_MTIME", (long long)offsetof(struct statx, stx_mtime)},
    {"KSTATX_DEV_MAJOR", (long long)offsetof(struct statx, stx_dev_major)},
    {"KSTATX_DEV_MINOR", (long long)offsetof(struct statx, stx_dev_minor)},
    {"KDIRENT_INO", (long long)offsetof(struct dirent64, d_ino)},
    {"KDIRENT_RECLEN", (long long)offsetof(struct dirent64, d_reclen)},
    {"KDIRENT_TYPE", (long long)offsetof(struct dirent64, d_type)},
    {"KDIRENT_NAME", (long long)offsetof(struct dirent64, d_name)},
};

static int lookup_pal_equ(const char *path, const char *sym, long long *out) {
    FILE *fp = fopen(path, "r");
    if (!fp) return 0;
    char line[512];
    size_t slen = strlen(sym);
    int found = 0;
    while (fgets(line, sizeof(line), fp)) {
        const char *p = strstr(line, ".equ");
        if (!p) continue;
        p += 4;
        while (*p == ' ' || *p == '\t') p++;
        if (strncmp(p, sym, slen) != 0 || p[slen] != ',') continue;
        p += slen + 1;
        while (*p == ' ' || *p == '\t') p++;
        *out = strtoll(p, NULL, 0);
        found = 1;
        break;
    }
    fclose(fp);
    return found;
}

int main(int argc, char **argv) {
    const char *inc_path = argc > 1 ? argv[1] : "include/os/linux/x86_64/pal_target.inc";
    size_t n = sizeof(k_entries) / sizeof(k_entries[0]);
    int failures = 0;
    int checked = 0;
    for (size_t i = 0; i < n; i++) {
        long long actual = 0;
        if (!lookup_pal_equ(inc_path, k_entries[i].name, &actual)) {
            fprintf(stderr, "ABI MISSING: %s not found in %s\n", k_entries[i].name, inc_path);
            failures++;
            continue;
        }
        checked++;
        if (actual != k_entries[i].expected) {
            fprintf(stderr, "ABI MISMATCH: %s: pal_target.inc=%lld (0x%llx) vs kernel=%lld (0x%llx)\n",
                    k_entries[i].name, actual, (unsigned long long)actual,
                    k_entries[i].expected, (unsigned long long)k_entries[i].expected);
            failures++;
        }
    }
    if (failures > 0) return 1;
    printf("C11 KERNEL ABI AUDIT PASSED (%d constants verified against Linux headers)\n", checked);
    return 0;
}
