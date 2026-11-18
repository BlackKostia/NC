/* src/fs/pkg_popup.c - the package actions of the popup menu (menu actions whose scope / ext fit the entry under the cursor) and
 * the {marked_file} list of selected paths (freestanding C23; replaces pkg_popup.s, kept as tests/harness/pkg_popup_reference.s). */
#include "duop_pkg.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define PKP_SCAN_MAX 16
#define PKP_CACHE_MAX 8

static PkgAction pkp_scan_buf[PKP_SCAN_MAX];
static PkgAction pkp_cache[PKP_CACHE_MAX];
static int pkp_cnt;

static char pkp_lower(char c) { return c >= 'A' && c <= 'Z' ? (char)(c + 32) : c; }

/* an empty list matches everything; else one word of list (',' / ' ' separated, at most 63 bytes) ends name, case-insensitively */
static bool pkp_match_ext(const char *list, const char *name)
{
    if (!list[0]) return true;
    if (!name) return false;
    size_t nlen = str_len(name);
    while (*list) {
        if (*list == ',' || *list == ' ') { list++; continue; }
        size_t n = 0;
        while (n < 63 && list[n] && list[n] != ',' && list[n] != ' ') n++;
        bool same = n <= nlen;
        for (size_t i = 0; same && i < n; i++) same = pkp_lower(name[nlen - n + i]) == pkp_lower(list[i]);
        if (same) return true;
        list += n;
    }
    return false;
}

/* a menu action for this entry: scope "dir" needs a directory, "file" a file; an ext list needs a file whose name matches */
static bool pkp_match_entry(const PkgAction *a, int is_dir, const char *name)
{
    if (!a->menu[0]) return false;
    if (!str_cmp(a->scope, "dir") && !is_dir) return false;
    if (!str_cmp(a->scope, "file") && is_dir) return false;
    return !a->ext[0] || (!is_dir && pkp_match_ext(a->ext, name));
}

int pkg_popup_refresh(char **envp, int is_dir, const char *entry_name)
{
    int n = pkg_actions_scan(envp, pkp_scan_buf, PKP_SCAN_MAX), k = 0;
    for (int i = 0; i < n && k < PKP_CACHE_MAX; i++)
        if (pkp_match_entry(&pkp_scan_buf[i], is_dir, entry_name)) pkp_cache[k++] = pkp_scan_buf[i];
    pkp_cnt = k;
    return k;
}

int pkg_popup_count(void)
{
    return pkp_cnt;
}

PkgAction *pkg_popup_get(int idx)
{
    return idx >= 0 && idx < pkp_cnt ? &pkp_cache[idx] : nullptr;
}

const char *pkg_popup_label(int idx)
{
    PkgAction *a = pkg_popup_get(idx);
    return a ? a->menu : nullptr;
}

int pkg_action_has_marked(PkgAction *act)
{
    for (const char *p = act->args; *p; p++)
        if (str_starts_with(p, "{marked_file}")) return 1;
    return 0;
}

/* the selected entries' paths (or fallback_path when none is selected), one per line, in a new temp file: 0, or -1 with no file
 * left when a path does not fit or a write fails */
int pkg_write_marked_list(DirModel *model, const char *fallback_path, char *out_tmp_path, int cap)
{
    intptr_t fd = tmp_open_unique("marked", ".txt", out_tmp_path, cap);
    if (fd < 0) return -1;
    char line[PATH_MAX + 1];
    int marked = 0;
    bool ok = true;
    for (uint64_t i = 0; ok && i < model->count; i++) {
        FileEntry *e = DirModel_get_entry(model, (intptr_t)i);
        if (!e || !(e->flags & FE_SELECTED)) continue;
        int64_t n = path_join(line, model->path, DirModel_entry_name(model, e), PATH_MAX);
        if (n < 0) { ok = false; break; }
        line[n] = '\n';
        ok = sys_write_all((int)fd, line, (size_t)n + 1) >= 0;
        marked++;
    }
    if (ok && !marked && fallback_path && fallback_path[0])
        ok = sys_write_all((int)fd, fallback_path, str_len(fallback_path)) >= 0 && sys_write_all((int)fd, "\n", 1) >= 0;
    ok = !os_is_err(os_close((int)fd)) && ok;
    if (ok) return 0;
    (void)os_unlinkat(AT_FDCWD, out_tmp_path, 0);
    return -1;
}
