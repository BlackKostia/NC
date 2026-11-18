/* src/fs/pkg_registry.c - the package registry: fetching it, listing and finding entries, upgrading installed packages and
 * comparing versions (freestanding C23; replaces pkg_registry.s, kept as tests/harness/pkg_registry_reference.s).
 *
 * <root>/registry.tsv has one package per line: name, version, kind, sha256, url, description, tab-separated ('\r' ignored,
 * empty lines and '#' comments skipped). DUOP_PKG_REGISTRY names its source: an http(s) URL (downloaded) or a local file
 * (copied, at most 64 KiB). */
#include "duop_pkg.h"
#include "duop_config.h"
#include "duop_string.h"

#define PKR_FILE_CAP 65536
#define PKR_FIND_MAX 64            /* entries pkg_registry_find looks through */
#define PKR_UPGRADE_MAX 32         /* installed packages pkg_registry_upgrade looks at */

static const char pkr_reg_file[] = "registry.tsv";

/* one tab-separated field into dst (at most cap - 1 bytes kept, '\r' dropped): the position after the tab or the line end */
static const char *pkr_copy_field(const char *p, const char *end, char *dst, int cap)
{
    int n = 0;
    for (; p < end && *p != '\t'; p++)
        if (*p != '\r' && n < cap - 1) dst[n++] = *p;
    dst[n] = 0;
    return p < end ? p + 1 : p;
}

static void pkr_parse_line(const char *line, const char *end, PkgRegEntry *e)
{
    mem_zero(e, sizeof *e);
    line = pkr_copy_field(line, end, e->name, sizeof e->name);
    line = pkr_copy_field(line, end, e->version, sizeof e->version);
    line = pkr_copy_field(line, end, e->kind, sizeof e->kind);
    line = pkr_copy_field(line, end, e->sha256, sizeof e->sha256);
    line = pkr_copy_field(line, end, e->url, sizeof e->url);
    (void)pkr_copy_field(line, end, e->desc, sizeof e->desc);
}

/* a heap block: path buffer + the registry text */
typedef struct PkrBuf { char root[PATH_MAX], reg[PATH_MAX], text[PKR_FILE_CAP]; } PkrBuf;

int pkg_registry_update(char **envp)
{
    const char *src = cfg_getenv(envp, "DUOP_PKG_REGISTRY=");
    if (!src) return -1;
    PkrBuf *b = mem_alloc(sizeof *b);
    if (!b) return -1;
    pkg_get_root(envp, b->root, PATH_MAX);
    pkg_mkdir_p(b->root);
    (void)path_join(b->reg, b->root, pkr_reg_file, PATH_MAX);
    int r;
    size_t got;
    if (str_starts_with(src, "http://") || str_starts_with(src, "https://")) r = pkg_fetch_url(envp, src, b->reg);
    else if (fs_read_file_head(src, b->text, PKR_FILE_CAP, &got) < 0) r = -1;
    else r = pkg_write_file(b->reg, b->text, got);
    mem_free(b);
    return r;
}

int pkg_registry_list(char **envp, PkgRegEntry *out, int max)
{
    PkrBuf *b = mem_alloc(sizeof *b);
    if (!b) return 0;
    pkg_get_root(envp, b->root, PATH_MAX);
    (void)path_join(b->reg, b->root, pkr_reg_file, PATH_MAX);
    size_t got;
    int n = 0;
    if (fs_read_file_head(b->reg, b->text, PKR_FILE_CAP, &got) >= 0) {
        const char *p = b->text, *end = b->text + got;
        while (p < end && n < max) {
            const char *eol = p;
            while (eol < end && *eol != '\n') eol++;
            if (eol != p && *p != '#') {
                pkr_parse_line(p, eol, &out[n]);
                if (out[n].name[0]) n++;                               /* a line without a name takes no slot */
            }
            p = eol + 1;
        }
    }
    mem_free(b);
    return n;
}

int pkg_registry_find(char **envp, const char *name, PkgRegEntry *out)
{
    PkgRegEntry *list = mem_alloc(PKR_FIND_MAX * sizeof *list);
    if (!list) return -1;
    int n = pkg_registry_list(envp, list, PKR_FIND_MAX), r = -1;
    for (int i = 0; i < n; i++)
        if (!str_cmp(list[i].name, name)) {
            mem_copy(out, &list[i], sizeof *out);
            r = 0;
            break;
        }
    mem_free(list);
    return r;
}

/* every installed package with a newer registry version is installed again from its registry URL: 0, or -1 when any failed */
int pkg_registry_upgrade(char **envp)
{
    PkgEntry *inst = mem_alloc(PKR_UPGRADE_MAX * sizeof *inst);
    if (!inst) return -1;
    int n = pkg_list(envp, inst, PKR_UPGRADE_MAX), r = 0;
    PkgRegEntry reg;
    for (int i = 0; i < n; i++) {
        if (pkg_registry_find(envp, inst[i].name, &reg) != 0) continue;
        if (pkg_semver_cmp(inst[i].version, reg.version) >= 0) continue;
        if (pkg_install_archive(envp, reg.url, reg.sha256) != 0) r = -1;
    }
    mem_free(inst);
    return r;
}

/* one numeric part ("v" / "V" allowed in front, 32-bit wrap-around as before) and the position after it and its '.' */
static int32_t pkr_ver_part(const char **pp)
{
    const char *p = *pp;
    uint32_t v = 0;
    if (*p == 'v' || *p == 'V') p++;
    for (; *p >= '0' && *p <= '9'; p++) v = v * 10 + (uint32_t)(*p - '0');
    if (*p == '.') p++;
    *pp = p;
    return (int32_t)v;
}

/* -1 / 0 / 1 comparing major.minor.patch (missing parts are 0) */
int pkg_semver_cmp(const char *a, const char *b)
{
    for (int i = 0; i < 3; i++) {
        int32_t x = pkr_ver_part(&a), y = pkr_ver_part(&b);
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}
