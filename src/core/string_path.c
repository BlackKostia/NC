/* src/core/string_path.c - path helpers (freestanding C23; replaces string_path.s). Quirks of the assembly version
 * are kept on purpose (callers were audited against them): path_basename("a/") is "", path_dirname("a//b") is "a/". */
#include "duop_string.h"

int64_t path_join(char *dst, const char *dir, const char *name, size_t cap)
{
    if (!cap) return -DUOP_ENAMETOOLONG;
    if (str_len(dir) >= cap) { dst[0] = 0; return -DUOP_ENAMETOOLONG; }
    size_t cur = str_copy(dst, dir, cap);
    if (cur && dst[cur - 1] != '/') {
        if (cur + 1 >= cap) { dst[0] = 0; return -DUOP_ENAMETOOLONG; }
        dst[cur++] = '/';
        dst[cur] = 0;
    }
    while (*name == '/') name++;
    size_t nlen = str_len(name);
    if (nlen >= cap - cur) { dst[0] = 0; return -DUOP_ENAMETOOLONG; }
    str_copy(dst + cur, name, cap - cur);
    return (int64_t)(cur + nlen);
}

void path_dirname(const char *path, char *dst, size_t cap)
{
    size_t n = str_copy(dst, path, cap);
    while (n > 1 && dst[n - 1] == '/') dst[--n] = 0;      /* trailing slashes, but never the root */
    size_t i = n;
    while (i > 0) {
        i--;
        if (dst[i] != '/') continue;
        if (i) dst[i] = 0;                                  /* cut at the last slash */
        else if (cap >= 2) dst[1] = 0;                      /* "/x" -> "/" */
        return;
    }
    if (cap >= 2) { dst[0] = '.'; dst[1] = 0; }             /* no slash at all (or empty) -> "." */
}

const char *path_basename(const char *path)
{
    const char *slash = str_rchr(path, '/');
    if (!slash) return path;
    const char *base = slash + 1;
    if (*base) return base;
    return path[1] == 0 ? path : base;                      /* "/" is its own basename; "a/" yields "" */
}

static bool feed(const char *p, char *out, size_t cap, size_t *len)
{
    for (;;) {
        while (*p == '/') p++;
        if (!*p) return true;
        size_t cl = 0;
        while (p[cl] && p[cl] != '/') cl++;
        if (cl == 1 && p[0] == '.') {
            /* "." */
        } else if (cl == 2 && p[0] == '.' && p[1] == '.') {
            if (*len > 1) {                                 /* ".." never climbs above "/" */
                size_t i = *len;
                do { i--; } while (out[i] != '/');
                *len = i ? i : 1;
            }
        } else {
            if (*len + cl + 2 > cap) return false;
            if (*len != 1) out[(*len)++] = '/';
            for (size_t k = 0; k < cl; k++) out[(*len)++] = p[k];
        }
        p += cl;
    }
}

size_t path_normalize(const char *base, const char *target, char *out, size_t cap)
{
    if (cap < 2) return 0;
    out[0] = '/';
    size_t len = 1;
    if (target[0] != '/' && !feed(base, out, cap, &len)) return 0;
    if (!feed(target, out, cap, &len)) return 0;
    out[len] = 0;
    return len;
}
