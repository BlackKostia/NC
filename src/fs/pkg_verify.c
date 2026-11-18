/* src/fs/pkg_verify.c - recording and checking the SHA-256 of every installed package file (freestanding C23; replaces
 * pkg_verify.s, kept as tests/harness/pkg_verify_reference.s).
 *
 * <root>/<name>/hashes.sha256 holds "<64 hex> <path>\n" per installed file (manifest.ini among them); <root>/<name>/sha256 the
 * hash of the archive. pkg_verify fails on anything unexpected: an unreadable or malformed list, a missing manifest entry, a file
 * whose content changed. */
#include "duop_pkg.h"
#include "duop_hash.h"
#include "duop_string.h"

#define PKG_HASHES_CAP 8192        /* the hash list buffer of the installer and of the check */

static const char pkv_hashes_file[] = "hashes.sha256";

/* "<sha256 hex> <file_path>\n" appended to buf (*len_ptr bytes used) when the file hashes and the line fits PKG_HASHES_CAP */
void pkg_hashes_append(const char *file_path, char *buf, uint64_t *len_ptr)
{
    uint32_t crc;
    char hex[72];
    if (hash_file(file_path, &crc, hex) < 0) return;
    size_t n = str_len(file_path);
    uint64_t at = *len_ptr;
    if (at + n + 66 >= PKG_HASHES_CAP) return;
    char *d = buf + at;
    mem_copy(d, hex, 64);
    d[64] = ' ';
    mem_copy(d + 65, file_path, n);
    d[65 + n] = '\n';
    *len_ptr = at + n + 66;
}

int pkg_hashes_write(const char *pkg_dir, const char *buf, uint64_t len)
{
    char path[PATH_MAX];
    (void)path_join(path, pkg_dir, pkv_hashes_file, PATH_MAX);
    return pkg_write_file(path, buf, len);
}

static bool pkv_is_hex64(const char *s)
{
    for (int i = 0; i < 64; i++) {
        uint8_t c = (uint8_t)s[i];
        if (c >= '0' && c <= '9') continue;
        c |= 0x20;
        if (c < 'a' || c > 'f') return false;
    }
    return true;
}

/* every line "<hex> <path>" must match the current content of path, and manifest.ini must be among them: 0, else -1 */
static int pkv_check_hashes_buf(char *buf, uint64_t len)
{
    char *p = buf, *end = buf + len;
    bool manifest = false;
    while (p < end) {
        char *nl = p;
        while (nl < end && *nl != '\n') nl++;
        if (nl >= end) return -1;                                        /* a line without its newline */
        *nl = 0;
        if (nl - p < 66 || !pkv_is_hex64(p) || p[64] != ' ') return -1;
        p[64] = 0;
        if (!str_cmp(path_basename(p + 65), "manifest.ini")) manifest = true;
        uint32_t crc;
        char hex[72];
        if (hash_file(p + 65, &crc, hex) < 0 || str_casecmp(p, hex)) return -1;
        p = nl + 1;
    }
    return manifest ? 0 : -1;
}

int pkg_verify(char **envp, const char *name)
{
    if (!pkm_safe_name(name)) return -1;
    char *mem = mem_alloc(2 * PATH_MAX + PKG_HASHES_CAP);           /* root / path, the package dir, the hash list */
    if (!mem) return -1;
    char *path = mem, *dir = mem + PATH_MAX, *buf = mem + 2 * PATH_MAX, sha[80];
    size_t got;
    int r = -1;
    pkg_get_root(envp, path, PATH_MAX);
    if (path_join(dir, path, name, PATH_MAX) < 0 || path_join(path, dir, "sha256", PATH_MAX) < 0) goto out;
    if (fs_read_file_head(path, sha, 72, &got) < 0 || (int64_t)got < 64 || !pkv_is_hex64(sha)) goto out;
    if (path_join(path, dir, pkv_hashes_file, PATH_MAX) < 0) goto out;
    if (fs_read_file_head(path, buf, PKG_HASHES_CAP, &got) >= 0 && got) r = pkv_check_hashes_buf(buf, got);
out:
    mem_free(mem);
    return r;
}
