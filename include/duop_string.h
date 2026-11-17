/* include/duop_string.h - core string, path and formatting API (src/core/string*.c). Freestanding C23. */
#pragma once
#include "duop_abi.h"

#define DUOP_ENAMETOOLONG 36

size_t      str_len(const char *s);                                   /* NULL-safe */
size_t      str_copy(char *dst, const char *src, size_t cap);         /* always NUL-terminates when cap > 0; returns chars written */
size_t      str_cat(char *dst, const char *src, size_t cap);
int         str_cmp(const char *a, const char *b);                    /* difference of the first differing bytes */
int         str_casecmp(const char *a, const char *b);                /* ASCII case-insensitive */
int         str_contains_ci(const char *hay, const char *needle);
const char *str_chr(const char *s, int ch);                           /* ch == 0 finds the terminator */
const char *str_rchr(const char *s, int ch);
int         str_starts_with(const char *s, const char *prefix);
size_t      u64_to_dec(uint64_t v, char *buf);                        /* buf >= 21 bytes; returns length */
size_t      u64_to_hex(uint64_t v, char *buf, int min_digits);        /* lower-case, zero-padded to min_digits (<= 32) */

int64_t     path_join(char *dst, const char *dir, const char *name, size_t cap);   /* length or -ENAMETOOLONG */
void        path_dirname(const char *path, char *dst, size_t cap);
const char *path_basename(const char *path);
size_t      path_normalize(const char *base, const char *target, char *out, size_t cap);  /* length, 0 if it does not fit */

size_t      format_size(int64_t bytes, char *buf);                    /* "512 B", "4.2 K", "128 M"; buf >= 16 */
void        format_perms(uint32_t mode, char *buf);                   /* "drwxr-xr-x" + NUL (11 bytes) */
void        format_datetime(int64_t epoch_sec, char *buf);            /* "YYYY-MM-DD HH:MM" UTC, minute-cached; buf >= 20 */
void        format_datetime_raw(int64_t epoch_sec, char *buf);        /* same, uncached */
