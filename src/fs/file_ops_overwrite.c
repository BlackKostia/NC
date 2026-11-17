/* src/fs/file_ops_overwrite.c - crash-safe "Overwrite": write a sibling temp file, then rename it over the target
 * (freestanding C23; replaces file_ops_overwrite.s, kept as tests/harness/file_ops_overwrite_reference.s).
 *
 * Opening the existing target with O_TRUNC destroys the old content before the new copy exists: a read error, ENOSPC, a cancel or a
 * power cut half-way would leave neither version. Here the data goes to a hidden temp file in the same directory; only when it is
 * complete (the caller fsyncs it) does rename(2) swap it in atomically, so the target is always the complete old file or the
 * complete new file. */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"

#define OVW_TRIES 8            /* temp names tried before giving up with -EEXIST */
#define OVW_NAME_ROOM 48       /* the temp name (27 bytes + NUL) must fit behind the directory prefix */

static const char fo_ovw_pfx[] = ".duop-ovw.";
static const char fo_ovw_hex[] = "0123456789abcdef";

static uint32_t g_fo_ovw_seq;  /* shared by every thread: each temp name takes the next number */

static char *fo_ovw_hex8(char *dst, uint32_t v)       /* 8 hex digits; returns dst + 8 */
{
    for (int i = 28; i >= 0; i -= 4) *dst++ = fo_ovw_hex[(v >> i) & 15];
    return dst;
}

/* ".duop-ovw.<pid hex>.<seq hex>", NUL ended */
static void fo_ovw_name(char *out, uint32_t pid, uint32_t seq)
{
    char *p = out + str_copy(out, fo_ovw_pfx, 32);
    p = fo_ovw_hex8(p, pid);
    *p++ = '.';
    p = fo_ovw_hex8(p, seq);
    *p = 0;
}

/* Creates an exclusive temp file in the directory of `name` (a plain name relative to dfd, or a path; same directory = same
 * filesystem). out_tmp (PATH_MAX bytes) receives the temp name/path. Returns the open fd, or -errno. */
intptr_t fo_overwrite_open(int dfd, const char *name, uint32_t mode, char *out_tmp)
{
    size_t prefix = 0;                                   /* length of the directory part, up to and including the last '/' */
    for (size_t i = 0; name[i];) {
        char c = name[i++];
        if (c == '/') prefix = i;
    }
    if (prefix > PATH_MAX - OVW_NAME_ROOM) return -ENAMETOOLONG;
    for (size_t i = 0; i < prefix; i++) out_tmp[i] = name[i];
    uint32_t pid = (uint32_t)os_getpid();
    intptr_t r = -EEXIST;
    for (unsigned tries = 0; tries < OVW_TRIES; tries++) {
        uint32_t seq = __atomic_add_fetch(&g_fo_ovw_seq, 1, __ATOMIC_SEQ_CST);
        fo_ovw_name(out_tmp + prefix, pid, seq);
        r = os_openat(dfd, out_tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode);
        if (r == -EEXIST) continue;
        break;
    }
    return r;
}

/* Atomically replaces `name` with the finished (and fsynced) temp file: 0, or -errno. */
intptr_t fo_overwrite_commit(int dfd, const char *tmp, const char *name)
{
    return os_renameat2(dfd, tmp, dfd, name, 0);
}

/* Opens the target of an "Overwrite" for writing. An existing regular file is replaced through a temp file (used = 1, out_tmp = its
 * name: fo_overwrite_commit it once it is complete and fsynced). Anything else -- and a directory the user cannot write into -- is
 * opened in place with O_TRUNC (used = 0). Returns the fd or -errno (no fallback on ENOSPC: truncating would destroy the old file
 * for nothing). The old code took the creation mode of the in-place open from a register its only caller happened to leave
 * behind; it is the new_mode argument here. */
FoOpenResult fo_open_overwrite(int dfd, const char *name, uint32_t dst_mode, uint32_t new_mode, char *out_tmp)
{
    if ((dst_mode & S_IFMT) == S_IFREG) {
        intptr_t r = fo_overwrite_open(dfd, name, new_mode, out_tmp);
        if (r >= 0) return (FoOpenResult){r, 1};
        bool in_place = r == -EACCES || r == -EPERM;
        if (!in_place) return (FoOpenResult){r, 0};
    }
    intptr_t r = os_openat(dfd, name, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, new_mode);
    return (FoOpenResult){r, 0};
}
