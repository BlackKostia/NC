/* src/core/string.c - NUL-terminated string primitives and integer formatting (freestanding C23; replaces string.s). */
#include "duop_string.h"

static inline uint8_t lower(uint8_t c) { return (uint8_t)((uint8_t)(c - 'A') <= 25 ? c + 32 : c); }

size_t str_len(const char *s)
{
    return s ? os_str_len_fast(s) : 0;
}

size_t str_copy(char *dst, const char *src, size_t cap)
{
    if (!cap) return 0;
    size_t i = 0;
    if (src)
        for (size_t max = cap - 1; i < max && src[i]; i++) dst[i] = src[i];
    dst[i] = 0;
    return i;
}

size_t str_cat(char *dst, const char *src, size_t cap)
{
    size_t n = str_len(dst);
    if (n >= cap) return n;
    return n + str_copy(dst + n, src, cap - n);
}

int str_cmp(const char *a, const char *b)
{
    const uint8_t *x = (const uint8_t *)a, *y = (const uint8_t *)b;
    while (*x && *x == *y) { x++; y++; }
    return (int)*x - (int)*y;
}

int str_casecmp(const char *a, const char *b)
{
    const uint8_t *x = (const uint8_t *)a, *y = (const uint8_t *)b;
    while (lower(*x) == lower(*y)) {
        if (!*x) return 0;
        x++; y++;
    }
    return (int)lower(*x) - (int)lower(*y);
}

/* Lower-case needles up to 255 bytes take the PAL SIMD scan; longer ones the plain nested loop. */
int str_contains_ci(const char *hay, const char *needle)
{
    if (!*needle) return 1;
    char lc[256];
    size_t n = 0;
    while (needle[n] && n < 255) { lc[n] = (char)lower((uint8_t)needle[n]); n++; }
    if (!needle[n]) return os_str_contains_ci_fast(hay, lc, n);
    for (; *hay; hay++) {
        size_t j = 0;
        while (needle[j] && hay[j] && lower((uint8_t)hay[j]) == lower((uint8_t)needle[j])) j++;
        if (!needle[j]) return 1;
        if (!hay[j]) return 0;
    }
    return 0;
}

const char *str_chr(const char *s, int ch)
{
    for (;; s++) {
        if ((int)(uint8_t)*s == ch) return s;
        if (!*s) return nullptr;
    }
}

const char *str_rchr(const char *s, int ch)
{
    const char *hit = nullptr;
    for (;; s++) {
        if ((int)(uint8_t)*s == ch) hit = s;
        if (!*s) return hit;
    }
}

int str_starts_with(const char *s, const char *prefix)
{
    while (*prefix) {
        if (*s++ != *prefix++) return 0;
    }
    return 1;
}

size_t u64_to_dec(uint64_t v, char *buf)
{
    char t[20];
    size_t n = 0;
    do { t[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    for (size_t i = 0; i < n; i++) buf[i] = t[n - 1 - i];
    buf[n] = 0;
    return n;
}

size_t u64_to_hex(uint64_t v, char *buf, int min_digits)
{
    static const char hex[] = "0123456789abcdef";
    char t[32];
    size_t n = 0;
    do { t[n++] = hex[v & 15]; v >>= 4; } while (v);
    if (min_digits > 32) min_digits = 32;       /* the assembly version overran its 32-byte scratch here */
    while ((int)n < min_digits) t[n++] = '0';
    for (size_t i = 0; i < n; i++) buf[i] = t[n - 1 - i];
    buf[n] = 0;
    return n;
}
