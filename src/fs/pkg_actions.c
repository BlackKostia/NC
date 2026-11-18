/* src/fs/pkg_actions.c - declarative package actions: the [action] keys of a manifest, the scan of installed packages, the argv
 * of an action and the cached user-menu list (freestanding C23; replaces pkg_actions.s, kept as
 * tests/harness/pkg_actions_reference.s).
 *
 * An action runs <dir>/<exec> with the words of args; the words {dir} {other_dir} {file} {path} {marked_file} are replaced by the
 * caller's context. Nothing is ever cut to fit: a package directory longer than its slot is skipped, an argv that does not fit
 * its buffer or its array is refused, so an action never runs with a different path or argument than the manifest says. */
#include "duop_pkg.h"
#include "duop_pal.h"
#include "duop_string.h"

#define PKA_MENU_MAX 16
#define PKA_MANIFEST_MAX 4096
#define PKA_DIRBUF 16384

static const char pka_manifest[] = "manifest.ini";
static PkgAction pka_menu_cache[PKA_MENU_MAX];
static int pka_menu_cnt;

/* [s, e) without leading blanks and trailing blanks / CR, at most cap - 1 bytes, NUL-terminated */
static void pka_trim_copy(const char *s, const char *e, char *dst, int cap)
{
    while (s < e && (*s == ' ' || *s == '\t')) s++;
    while (e > s && (e[-1] == ' ' || e[-1] == '\t' || e[-1] == '\r')) e--;
    int n = 0;
    while (n < cap - 1 && s < e) dst[n++] = *s++;
    dst[n] = 0;
}

void pkg_action_parse(const char *buf, int len, PkgAction *out)
{
    static const struct { char key[8]; uint16_t off, cap; } keys[] = {
        {"name", offsetof(PkgAction, name), 64}, {"exec", offsetof(PkgAction, exec), 64}, {"menu", offsetof(PkgAction, menu), 64},
        {"args", offsetof(PkgAction, args), 128}, {"scope", offsetof(PkgAction, scope), 16}, {"mode", offsetof(PkgAction, mode), 16},
        {"ext", offsetof(PkgAction, ext), 64},
    };
    mem_zero(out, sizeof *out);
    const char *end = buf + len;
    for (const char *line = buf; line < end;) {
        const char *eol = line, *eq;
        while (eol < end && *eol != '\n') eol++;
        for (eq = line; eq < eol && *eq != '='; eq++) {}
        if (eq < eol) {
            char key[64];
            pka_trim_copy(line, eq, key, sizeof key);
            for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++)
                if (!str_cmp(key, keys[i].key)) {
                    pka_trim_copy(eq + 1, eol, (char *)out + keys[i].off, keys[i].cap);
                    break;
                }
        }
        line = eol + 1;
    }
}

static bool pka_safe_seg(const char *s)
{
    if (!s || !s[0] || !str_cmp(s, "..")) return false;
    for (; *s; s++)
        if (*s == '/') return false;
    return true;
}

/* <root>/<name>/manifest.ini into man (PKA_MANIFEST_MAX bytes); dir gets <root>/<name>. -1 when anything is missing or too long. */
static intptr_t pka_read_manifest(const char *root, const char *name, char *dir, char *path, char *man, size_t *len)
{
    if (!root[0] || path_join(dir, root, name, PATH_MAX) < 0 || path_join(path, dir, pka_manifest, PATH_MAX) < 0) return -1;
    return fs_read_file_head(path, man, PKA_MANIFEST_MAX, len) < 0 ? -1 : 0;
}

int pkg_action_find(char **envp, const char *name, PkgAction *out)
{
    if (!pka_safe_seg(name)) return -1;
    char *mem = mem_alloc(3 * PATH_MAX + PKA_MANIFEST_MAX);
    if (!mem) return -1;
    char *root = mem, *dir = mem + PATH_MAX, *path = mem + 2 * PATH_MAX, *man = mem + 3 * PATH_MAX;
    size_t len;
    int r = -1;
    pkg_get_root(envp, root, PATH_MAX);
    if (pka_read_manifest(root, name, dir, path, man, &len) == 0) {
        pkg_action_parse(man, (int)len, out);
        if (pkm_safe_relpath(out->exec) && str_len(dir) < sizeof out->dir) {
            (void)str_copy(out->dir, dir, sizeof out->dir);
            r = 0;
        }
    }
    mem_free(mem);
    return r;
}

int pkg_actions_scan(char **envp, PkgAction *out, int max)
{
    char *mem = mem_alloc(3 * PATH_MAX + PKA_DIRBUF + PKA_MANIFEST_MAX);
    if (!mem) return 0;
    char *root = mem, *dir = mem + PATH_MAX, *path = mem + 2 * PATH_MAX, *dents = mem + 3 * PATH_MAX, *man = dents + PKA_DIRBUF;
    int n = 0;
    pkg_get_root(envp, root, PATH_MAX);
    intptr_t fd = root[0] ? os_openat(AT_FDCWD, root, O_RDONLY | O_DIRECTORY | O_CLOEXEC, 0) : -ENOENT;
    if (!os_is_err(fd)) {
        intptr_t got;
        while (n < max && (got = os_dir_read((int)fd, dents, PKA_DIRBUF)) > 0) {
            size_t pos = 0, len;
            uint8_t type;
            for (const char *name; n < max && (name = os_dir_next_ex(dents, (size_t)got, &pos, &type));) {
                if (!pka_safe_seg(name) || pka_read_manifest(root, name, dir, path, man, &len) < 0) continue;
                pkg_action_parse(man, (int)len, &out[n]);
                if (!out[n].exec[0] || str_len(dir) >= sizeof out[n].dir) continue;     /* never a cut directory */
                (void)str_copy(out[n].dir, dir, sizeof out[n].dir);
                n++;
            }
        }
        (void)os_close((int)fd);
    }
    mem_free(mem);
    return n;
}

/* the context value a placeholder word stands for ("" when unset), or NULL for a literal word */
static const char *pka_resolve_tok(const char *tok, const char **ctx)
{
    static const char *const ph[] = {"{dir}", "{other_dir}", "{file}", "{path}", "{marked_file}"};
    for (int i = 0; i < 5; i++)
        if (!str_cmp(tok, ph[i])) return ctx[i] ? ctx[i] : "";
    return nullptr;
}

/* argv_out: <dir>/<exec> then the words of args (placeholders resolved), NULL-terminated; the strings live in str_buf.
 * The count, or -1 (argv_out[0] = NULL) when the executable is unsafe or anything does not fit buf_cap / max_args. */
int pkg_action_build_argv(PkgAction *act, const char **ctx, char *str_buf, int buf_cap, char **argv_out, int max_args)
{
    int n = 1;
    int64_t len;
    if (buf_cap < 2 || max_args < 2 || !pkm_safe_relpath(act->exec) || (len = path_join(str_buf, act->dir, act->exec, (size_t)buf_cap)) < 0)
        goto fail;
    argv_out[0] = str_buf;
    char *buf = str_buf + len + 1;
    int64_t cap = buf_cap - len - 1;
    for (const char *p = act->args;;) {
        while (*p == ' ' || *p == '\t') p++;
        if (!*p) break;
        int64_t k = 0;
        while (p[k] && p[k] != ' ' && p[k] != '\t') k++;
        if (n >= max_args - 1 || k >= cap) goto fail;                 /* refused, never cut */
        mem_copy(buf, p, (size_t)k);
        buf[k] = 0;
        p += k;
        const char *v = pka_resolve_tok(buf, ctx);
        argv_out[n++] = v ? (char *)v : buf;
        if (!v) { buf += k + 1; cap -= k + 1; }
    }
    argv_out[n] = nullptr;
    return n;
fail:
    argv_out[0] = nullptr;
    return -1;
}

int pkg_menu_refresh(char **envp)
{
    int n = pkg_actions_scan(envp, pka_menu_cache, PKA_MENU_MAX), k = 0;
    for (int i = 0; i < n; i++)
        if (pka_menu_cache[i].menu[0]) {
            if (i != k) pka_menu_cache[k] = pka_menu_cache[i];
            k++;
        }
    pka_menu_cnt = k;
    return k;
}

int pkg_menu_count(void)
{
    return pka_menu_cnt;
}

PkgAction *pkg_menu_get(int idx)
{
    return idx >= 0 && idx < pka_menu_cnt ? &pka_menu_cache[idx] : nullptr;
}
