/* src/fs/pkg_manager.c - package install, list and remove (freestanding C23; replaces pkg_manager.s, kept as
 * tests/harness/pkg_manager_reference.s).
 *
 * Packages live in <root>/<name>/ (root: $DUOP_PKG_DIR, else $XDG_CONFIG_HOME/duop/packages, else $HOME/.config/duop/packages):
 * the archive's files, manifest.ini, sha256 (of the archive), hashes.sha256 (of every file) and files.list (the *.lang /
 * *.layout files copied to <root>/../lang and <root>/../layouts, removed again with the package or before a reinstall). Every path that does not fit
 * fails the operation: nothing is written to a truncated or empty path. */
#include "duop_pkg.h"
#include "duop_config.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define PKM_LIST_CAP 8192          /* files.list and the hash list of an install (each half of one block) */
#define PKM_MANIFEST_MAX 4096
#define PKM_DIRBUF 16384
#define PKM_ACTIVATE_MAX 524288    /* a *.lang / *.layout file copied out of the package */

static const char pkm_manifest[] = "manifest.ini";
static const char pkm_dir_lang[] = "/../lang", pkm_dir_lay[] = "/../layouts";

/* the root, or "" when no variable is set or the result would not fit cap */
void pkg_get_root(char **envp, char *out, int cap)
{
    const char *v = cfg_getenv(envp, "DUOP_PKG_DIR="), *sub = "";
    if (!v && (v = cfg_getenv(envp, "XDG_CONFIG_HOME="))) sub = "/duop/packages";
    if (!v && (v = cfg_getenv(envp, "HOME="))) sub = "/.config/duop/packages";
    if (cap <= 0) return;
    out[0] = 0;
    if (!v || str_len(v) + str_len(sub) >= (size_t)cap) return;
    (void)str_copy(out, v, (size_t)cap);
    (void)str_cat(out, sub, (size_t)cap);
}

int pkm_safe_name(const char *s)
{
    if (!s || !s[0] || !str_cmp(s, ".") || !str_cmp(s, "..")) return 0;
    for (; *s; s++)
        if (*s == '/') return 0;
    return 1;
}

/* p without leading "./", or NULL when empty, absolute or containing ".." before a '/' or the end (anywhere, not only as a
 * whole component: "a../b" is refused too) */
const char *pkm_safe_relpath(const char *p)
{
    if (!p) return nullptr;
    while (p[0] == '.' && p[1] == '/') p += 2;
    if (!p[0] || p[0] == '/') return nullptr;
    for (const char *q = p; *q; q++)
        if (q[0] == '.' && q[1] == '.' && (!q[2] || q[2] == '/')) return nullptr;
    return p;
}

int pkg_list(char **envp, PkgEntry *out, int max)
{
    char *mem = mem_alloc(2 * PATH_MAX + PKM_DIRBUF + PKM_MANIFEST_MAX);   /* the manifest has its own buffer: the directory
                                                                               block is still being iterated */
    if (!mem) return 0;
    char *root = mem, *path = mem + PATH_MAX, *dents = mem + 2 * PATH_MAX, *man = dents + PKM_DIRBUF;
    int n = 0;
    pkg_get_root(envp, root, PATH_MAX);
    intptr_t fd = os_openat(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0);
    if (!os_is_err(fd)) {
        intptr_t got;
        while (n < max && (got = os_dir_read((int)fd, dents, PKM_DIRBUF)) > 0) {
            size_t pos = 0, len;
            uint8_t type;
            for (const char *name; n < max && (name = os_dir_next_ex(dents, (size_t)got, &pos, &type));) {
                if (!pkm_safe_name(name) || path_join(path, root, name, PATH_MAX) < 0 ||
                    path_join(path, path, pkm_manifest, PATH_MAX) < 0 || fs_read_file_head(path, man, PKM_MANIFEST_MAX, &len) < 0)
                    continue;
                pkg_parse_manifest(man, (int)len, &out[n]);
                if (out[n].name[0]) n++;
            }
        }
        (void)os_close((int)fd);
    }
    mem_free(mem);
    return n;
}

static bool pkm_ends_with(const char *s, const char *suf)
{
    size_t a = str_len(s), b = str_len(suf);
    return a >= b && !str_cmp(s + a - b, suf);
}

/* a *.lang / *.layout file of the package copied to <root>/../lang|layouts/<base>; its path appended to files (a whole line or
 * nothing: a cut line would name a different file for pkg_remove to delete) */
static void pkm_activate_file(const char *root, const char *src, const char *base, char *files, uint64_t *files_len)
{
    const char *sub = pkm_ends_with(base, ".lang") ? pkm_dir_lang : pkm_ends_with(base, ".layout") ? pkm_dir_lay : nullptr;
    if (!sub || str_len(root) + str_len(sub) >= PATH_MAX) return;
    char *mem = mem_alloc(2 * PATH_MAX);
    if (!mem) return;
    char *dir = mem, *dst = mem + PATH_MAX;
    (void)str_copy(dir, root, PATH_MAX);
    (void)str_cat(dir, sub, PATH_MAX);
    pkg_mkdir_p(dir);
    uint8_t *data = nullptr;
    size_t got;
    if (pkm_safe_name(base) && path_join(dst, dir, base, PATH_MAX) >= 0 && (data = mem_alloc(PKM_ACTIVATE_MAX)) &&
        fs_read_file_head(src, data, PKM_ACTIVATE_MAX, &got) >= 0 && pkg_write_file(dst, data, got) == 0) {
        size_t at = str_len(files), dl = str_len(dst);
        if (at + dl < PKM_LIST_CAP - 2) {
            mem_copy(files + at, dst, dl);
            files[at + dl] = '\n';
            files[at + dl + 1] = 0;
            *files_len = at + dl + 1;
        }
    }
    mem_free(data);
    mem_free(mem);
}

__attribute__((noinline)) static void pkm_ensure_parent(const char *path)   /* own frame: the PATH_MAX copy */
{
    char buf[PATH_MAX];
    size_t n = str_copy(buf, path, PATH_MAX), cut = 0;
    for (size_t i = 0; i < n; i++)
        if (buf[i] == '/') cut = i;
    if (!cut) return;
    buf[cut] = 0;
    pkg_mkdir_p(buf);
}

/* every safe file entry into pkg_dir; its hash and (for *.lang / *.layout) its activation recorded. lens: files.list, hashes. */
static void pkm_extract_all(ArcCtx *ctx, const char *pkg_dir, const char *root, char *lists, uint64_t lens[2], char *dst)
{
    for (uint32_t i = 0; i < ctx->count; i++) {
        ArcEntry *e = &ctx->entries[i];
        const char *rel = e->is_dir ? nullptr : pkm_safe_relpath(e->name);
        if (!rel || path_join(dst, pkg_dir, rel, PATH_MAX) < 0) continue;
        pkm_ensure_parent(dst);
        if (pkg_extract_entry_to(ctx, e, dst) != 0) continue;
        pkg_hashes_append(dst, lists + PKM_LIST_CAP, &lens[1]);
        pkm_activate_file(root, dst, path_basename(rel), lists, &lens[0]);
    }
}

/* the manifest entry (any depth) extracted, read and removed again: 0 with *pe filled, or -1 */
static int pkm_read_manifest(ArcCtx *ctx, const char *root, char *tmp, char *man, PkgEntry *pe)
{
    ArcEntry *mf = nullptr;
    for (uint32_t i = 0; i < ctx->count && !mf; i++)
        if (!str_cmp(path_basename(ctx->entries[i].name), pkm_manifest)) mf = &ctx->entries[i];
    size_t got;
    if (!mf || path_join(tmp, root, pkm_manifest, PATH_MAX) < 0 || pkg_extract_entry_to(ctx, mf, tmp) != 0) return -1;
    intptr_t r = fs_read_file_head(tmp, man, PKM_MANIFEST_MAX, &got);
    (void)os_unlinkat(AT_FDCWD, tmp, 0);
    if (r < 0) return -1;
    pkg_parse_manifest(man, (int)got, pe);
    return pkm_safe_name(pe->name) ? 0 : -1;
}

/* a files.list line that names <root>/../lang/<file> or <root>/../layouts/<file> */
static bool pkm_safe_unlink_entry(const char *root, const char *line)
{
    if (!root[0] || !str_starts_with(line, root)) return false;
    const char *p = line + str_len(root);
    if (str_starts_with(p, pkm_dir_lang)) p += sizeof pkm_dir_lang - 1;
    else if (str_starts_with(p, pkm_dir_lay)) p += sizeof pkm_dir_lay - 1;
    else return false;
    return *p == '/' && pkm_safe_name(p + 1);
}

/* the activated files recorded in <dir>/files.list deleted (complete lines only); buf: PKM_LIST_CAP bytes */
static void pkm_unlink_listed(const char *root, const char *dir, char *path, char *buf)
{
    size_t got;
    if (path_join(path, dir, "files.list", PATH_MAX) < 0 || fs_read_file_head(path, buf, PKM_LIST_CAP, &got) < 0) return;
    for (char *p = buf, *end = buf + got; p < end;) {
        char *nl = p;
        while (nl < end && *nl != '\n') nl++;
        if (nl == end) break;
        *nl = 0;
        if (pkm_safe_unlink_entry(root, p)) (void)os_unlinkat(AT_FDCWD, p, 0);
        p = nl + 1;
    }
}

/* the package of ctx installed: files, sha256, files.list and hashes.sha256 written; 0, or -1 when any of them failed */
static int pkm_install_from_ctx(char **envp, ArcCtx *ctx, const char *sha_hex)
{
    char *mem = mem_alloc(4 * PATH_MAX + PKM_MANIFEST_MAX + 2 * PKM_LIST_CAP);
    if (!mem) return -1;
    char *root = mem, *dir = mem + PATH_MAX, *path = mem + 2 * PATH_MAX, *dst = mem + 3 * PATH_MAX;
    char *man = mem + 4 * PATH_MAX, *lists = man + PKM_MANIFEST_MAX;
    PkgEntry pe;
    int r = -1;
    pkg_get_root(envp, root, PATH_MAX);
    if (!root[0]) goto out;                                             /* never a package relative to the working directory */
    pkg_mkdir_p(root);
    if (pkm_read_manifest(ctx, root, path, man, &pe) < 0 || path_join(dir, root, pe.name, PATH_MAX) < 0) goto out;
    pkm_unlink_listed(root, dir, path, lists);                         /* a reinstall: the old version's activations go first */
    pkg_mkdir_p(dir);
    lists[0] = 0;
    uint64_t lens[2] = {0, 0};
    pkm_extract_all(ctx, dir, root, lists, lens, dst);
    r = 0;
    if (path_join(path, dir, "sha256", PATH_MAX) < 0 || pkg_write_file(path, sha_hex, 64) != 0) r = -1;
    if (path_join(path, dir, "files.list", PATH_MAX) < 0 || pkg_write_file(path, lists, str_len(lists)) != 0) r = -1;
    if (pkg_hashes_write(dir, lists + PKM_LIST_CAP, lens[1]) != 0) r = -1;
out:
    mem_free(mem);
    return r;
}

/* the temp-file suffix of a download, so that its type is the one the URL names */
static const char *pkm_dl_suffix(const char *url)
{
    switch (arc_is_archive(url)) {
    case ARC_TAR: return ".tar";
    case ARC_ZIP: return ".zip";
    default: return ".tar.gz";
    }
}

int pkg_install_archive(char **envp, const char *path_or_url, const char *expected_sha256)
{
    char tmp[PATH_MAX], sha[80];
    bool dl = str_starts_with(path_or_url, "http://") || str_starts_with(path_or_url, "https://");
    int r = -1;
    if (dl) {
        if (tmp_make_path("pkg_dl", pkm_dl_suffix(path_or_url), tmp, PATH_MAX) < 0) return -1;
        if (pkg_fetch_url(envp, path_or_url, tmp) != 0) goto clean;      /* a failed download leaves no temp file either */
        path_or_url = tmp;
    }
    ArcCtx *ctx = pkg_load_archive_sha(path_or_url, sha);
    if (!ctx) goto clean;
    if (!expected_sha256 || !expected_sha256[0] || !str_casecmp(sha, expected_sha256)) r = pkm_install_from_ctx(envp, ctx, sha);
    pkg_free_archive(ctx);
clean:
    if (dl) (void)os_unlinkat(AT_FDCWD, tmp, 0);
    return r;
}

int pkg_remove(char **envp, const char *name)
{
    if (!pkm_safe_name(name)) return -1;
    char *mem = mem_alloc(3 * PATH_MAX + PKM_LIST_CAP);
    if (!mem) return -1;
    char *root = mem, *dir = mem + PATH_MAX, *path = mem + 2 * PATH_MAX, *buf = mem + 3 * PATH_MAX;
    int r = -1;
    pkg_get_root(envp, root, PATH_MAX);
    if (!root[0] || path_join(dir, root, name, PATH_MAX) < 0) goto out;
    pkm_unlink_listed(root, dir, path, buf);
    r = fs_delete_recursive(dir) < 0 ? -1 : 0;
out:
    mem_free(mem);
    return r;
}
