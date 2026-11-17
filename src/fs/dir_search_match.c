/* src/fs/dir_search_match.c - glob / substring name matching and file content grep (freestanding C23; replaces
 * dir_search_match.s). */
#include "duop_fs.h"
#include "duop_pal.h"
#include "duop_string.h"
#include "duop_sys.h"

#define SEARCH_GREP_SZ 32768
#define SEARCH_MAX_GREP 1048576

static uint8_t lc(uint8_t c) { return c >= 'A' && c <= 'Z' ? (uint8_t)(c + 32) : c; }

/* Case-insensitive glob with '*' and '?'; backtracks to the last '*' only. */
int ds_glob_ci(const char *str, const char *pat)
{
    const char *star_pat = nullptr, *star_str = nullptr;
    for (;;) {
        uint8_t c = (uint8_t)*pat, a = (uint8_t)*str;
        if (c == '*') {
            star_pat = ++pat;
            star_str = str;
            continue;
        }
        if (!a) break;
        if (c == '?' || lc(a) == lc(c)) { str++; pat++; continue; }
        if (!star_pat) return 0;
        str = ++star_str;
        pat = star_pat;
    }
    while (*pat == '*') pat++;
    return *pat == 0;
}

int ds_match_mask(const char *name, const char *mask, int has_glob)
{
    if (!mask || !*mask) return 1;
    return has_glob ? ds_glob_ci(name, mask) : str_contains_ci(name, mask);
}

/* The file is read in 32 KiB windows; the last pat_len - 1 bytes are carried over so a match may straddle windows. */
int ds_grep_file(int dirfd, const char *name, const char *pat, size_t pat_len, char *buf)
{
    intptr_t fd = os_openat(dirfd, name, O_RDONLY | O_CLOEXEC, 0);
    if (os_is_err(fd)) return 0;
    int found = 0;
    int32_t total = 0;
    size_t carry = 0;
    while (total < SEARCH_MAX_GREP && SEARCH_GREP_SZ - 1 > carry) {
        intptr_t n = sys_read_retry((int)fd, buf + carry, SEARCH_GREP_SZ - 1 - carry);
        if (n <= 0) break;
        total += (int32_t)n;
        size_t len = carry + (size_t)n;
        buf[len] = 0;
        if (str_contains_ci(buf, pat)) { found = 1; break; }
        carry = pat_len - 1 > len ? len : pat_len - 1;
        if (carry) for (size_t i = 0; i < carry; i++) buf[i] = buf[len - carry + i];
    }
    os_close((int)fd);
    return found;
}
