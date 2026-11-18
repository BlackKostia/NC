/* src/fs/pkg_archive.c - archive and manifest helpers of the package manager (freestanding C23; replaces pkg_archive.s, kept as
 * tests/harness/pkg_archive_reference.s).
 *
 * A package archive is read whole (at most ARC_MAX_FILE bytes, hashed before gunzip) and indexed by archive_parse.c; entries are
 * written to plain files. The manifest is "key = value" lines with optional quotes; name / version / kind / description are kept. */
#include "duop_pkg.h"
#include "duop_arc.h"
#include "duop_hash.h"
#include "duop_inflate.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

/* every directory of path, then path itself (errors ignored: EEXIST is the normal case). A path of PATH_MAX bytes or more is not
 * truncated into a different one: nothing is created. */
void pkg_mkdir_p(const char *path)
{
    char buf[PATH_MAX];
    if (str_len(path) >= PATH_MAX) return;
    (void)str_copy(buf, path, PATH_MAX);
    for (size_t i = 1; buf[0] && buf[i]; i++) {
        if (buf[i] != '/') continue;
        buf[i] = 0;
        (void)os_mkdirat(AT_FDCWD, buf, 0755);
        buf[i] = '/';
    }
    (void)os_mkdirat(AT_FDCWD, buf, 0755);
}

int pkg_write_file(const char *path, const void *buf, uint64_t len)
{
    intptr_t fd = os_openat(AT_FDCWD, path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (os_is_err(fd)) return -1;
    intptr_t w = sys_write_all((int)fd, buf, (size_t)len);
    (void)os_close((int)fd);
    return w < 0 ? -1 : 0;
}

/* a regular file (a symlink is refused), made executable (0755) unless some x bit is already set: 0 / -1 */
int pkg_ensure_exec(const char *path)
{
    FileStat st;
    if (os_is_err(os_statat(AT_FDCWD, path, &st, 0)) || (st.mode & S_IFMT) != S_IFREG) return -1;
    if (st.mode & 0111) return 0;
    return os_is_err(os_fchmodat(AT_FDCWD, path, 0755)) ? -1 : 0;
}

static bool pka_lead(char c) { return c == ' ' || c == '\t' || c == '=' || c == '"'; }
static bool pka_trail(char c) { return c == ' ' || c == '\t' || c == '\r' || c == '"'; }

/* [p, end) without leading blanks / '=' / quotes and trailing blanks / CR / quotes, at most cap - 1 bytes, NUL-terminated */
static void pka_copy_val(const char *p, const char *end, char *dst, int cap)
{
    while (p < end && pka_lead(*p)) p++;
    while (end > p && pka_trail(end[-1])) end--;
    int n = 0;
    while (p < end && n < cap - 1) dst[n++] = *p++;
    dst[n] = 0;
}

void pkg_parse_manifest(const char *buf, int len, PkgEntry *out)
{
    static const struct { char key[12]; uint8_t off, cap; } fields[] = {
        {"name", offsetof(PkgEntry, name), 64}, {"version", offsetof(PkgEntry, version), 32},
        {"kind", offsetof(PkgEntry, kind), 16}, {"description", offsetof(PkgEntry, desc), 112},
    };
    mem_zero(out, sizeof *out);
    const char *end = buf + len;
    for (const char *line = buf; line < end;) {
        const char *eol = line, *eq;
        while (eol < end && *eol != '\n') eol++;
        for (eq = line; eq < eol && *eq != '='; eq++) {}
        if (eq < eol) {
            char key[64];
            pka_copy_val(line, eq, key, sizeof key);
            for (size_t i = 0; i < sizeof fields / sizeof fields[0]; i++)
                if (!str_cmp(key, fields[i].key)) {
                    pka_copy_val(eq + 1, eol, (char *)out + fields[i].off, fields[i].cap);
                    break;
                }
        }
        line = eol + 1;
    }
}

void pkg_free_archive(ArcCtx *ctx)
{
    if (!ctx) return;
    mem_free(ctx->raw);
    mem_free(ctx->entries);
    mem_free(ctx);
}

/* the archive at path, indexed; out_sha_hex65 (may be NULL) gets the SHA-256 of the bytes read. NULL when unreadable or OOM. */
ArcCtx *pkg_load_archive_sha(const char *path, char *out_sha_hex65)
{
    int type = arc_is_archive(path);
    if (!type) return nullptr;
    ArcCtx *ctx = mem_alloc(sizeof *ctx);
    if (!ctx) return nullptr;
    mem_zero(ctx, sizeof *ctx);
    ctx->type = (uint32_t)type;
    ctx->entries = mem_alloc(ARC_MAX_ENTRIES * sizeof(ArcEntry));
    ctx->raw = mem_alloc(ARC_MAX_FILE);
    size_t got = 0;
    if (!ctx->entries || !ctx->raw || fs_read_file_head(path, ctx->raw, ARC_MAX_FILE, &got) < 0) goto fail;
    ctx->raw_len = got;
    if (out_sha_hex65) {
        ShaCtx sha;
        sha256_init(&sha);
        sha256_update(&sha, ctx->raw, ctx->raw_len);
        sha256_final_hex(&sha, out_sha_hex65);
    }
    if (type == ARC_TGZ) {
        uint64_t n = 0;
        uint8_t *plain = arc_ungzip(ctx->raw, ctx->raw_len, &n);
        if (!plain) goto fail;
        mem_free(ctx->raw);
        ctx->raw = plain;
        ctx->raw_len = n;
    }
    if (type == ARC_ZIP) arc_parse_zip(ctx);
    else arc_parse_tar(ctx);
    return ctx;
fail:
    pkg_free_archive(ctx);
    return nullptr;
}

ArcCtx *pkg_load_archive(const char *path)
{
    return pkg_load_archive_sha(path, nullptr);
}

/* entry ent of ctx written to dest_path (stored, deflated or tar data): 0 / -1 */
int pkg_extract_entry_to(ArcCtx *ctx, ArcEntry *ent, const char *dest_path)
{
    uint64_t avail = ctx->raw_len;
    if (ent->off > avail) return -1;
    const uint8_t *p = ctx->raw + ent->off;
    avail -= ent->off;
    uint64_t comp = avail;
    if (ctx->type == ARC_ZIP) {
        if (avail < 30) return -1;
        uint64_t hdr = 30 + (uint64_t)load_le16(p + 26) + load_le16(p + 28);
        if (avail < hdr) return -1;
        p += hdr;
        avail -= hdr;
        comp = ent->comp_size < avail ? ent->comp_size : avail;
    }
    if (ent->method == 8) {
        if (ent->size > ARC_MAX_UNCOMP) return -1;
        uint8_t *out = mem_alloc(ent->size ? ent->size : 1);
        if (!out) return -1;
        int64_t n = inflate_raw(p, comp, out, ent->size);
        int r = n < 0 ? -1 : pkg_write_file(dest_path, out, (uint64_t)n);
        mem_free(out);
        return r;
    }
    if (ent->method) return -1;
    uint64_t len = ent->size < comp ? ent->size : comp;
    return pkg_write_file(dest_path, p, len < avail ? len : avail);
}
