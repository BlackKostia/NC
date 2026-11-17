/* Differential harness: reference asm string/path/format/datetime (ref_ prefix) vs the freestanding C modules.
 * Random inputs over alphabets that hit every branch; returns, output buffers and buffer tails must match. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DECL(ret, name, args) extern ret ref_##name args; extern ret name args;
DECL(size_t, str_len, (const char *))
DECL(size_t, str_copy, (char *, const char *, size_t))
DECL(size_t, str_cat, (char *, const char *, size_t))
DECL(int, str_cmp, (const char *, const char *))
DECL(int, str_casecmp, (const char *, const char *))
DECL(int, str_contains_ci, (const char *, const char *))
DECL(const char *, str_chr, (const char *, int))
DECL(const char *, str_rchr, (const char *, int))
DECL(int, str_starts_with, (const char *, const char *))
DECL(size_t, u64_to_dec, (uint64_t, char *))
DECL(size_t, u64_to_hex, (uint64_t, char *, int))
DECL(int64_t, path_join, (char *, const char *, const char *, size_t))
DECL(void, path_dirname, (const char *, char *, size_t))
DECL(const char *, path_basename, (const char *))
DECL(size_t, path_normalize, (const char *, const char *, char *, size_t))
DECL(size_t, format_size, (int64_t, char *))
DECL(void, format_perms, (uint32_t, char *))
DECL(void, format_datetime, (int64_t, char *))
DECL(void, format_datetime_raw, (int64_t, char *))

static uint64_t rs = 0x2545F4914F6CDD1Dull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 20); }
static long checks;
#define FAIL(...) do { printf(__VA_ARGS__); printf("\n"); exit(1); } while (0)
#define BUF 600
#define EXPECT(cond, ...) do { checks++; if (!(cond)) FAIL(__VA_ARGS__); } while (0)

static void rstr(char *s, size_t max, const char *alpha)
{
    size_t n = rnd() % (max + 1), na = strlen(alpha);
    for (size_t i = 0; i < n; i++) s[i] = alpha[rnd() % na];
    s[n] = 0;
}
static int sgn(int v) { return v < 0 ? -1 : v > 0; }

static void test_strings(void)
{
    static const char *alphas[] = {"abAB/.", "abcXYZ019 ._-", "aA\x80\xC3\xA9@[`{/"};
    char a[BUF], b[BUF], o1[BUF], o2[BUF];
    for (long it = 0; it < 400000; it++) {
        const char *al = alphas[rnd() % 3];
        rstr(a, rnd() % 5 ? 40 : 400, al); rstr(b, rnd() % 5 ? 20 : 300, al);
        EXPECT(ref_str_len(a) == str_len(a), "str_len %s", a);
        EXPECT(ref_str_cmp(a, b) == str_cmp(a, b), "str_cmp [%s] [%s]", a, b);
        EXPECT(ref_str_casecmp(a, b) == str_casecmp(a, b), "str_casecmp [%s] [%s] %d %d", a, b, ref_str_casecmp(a, b), str_casecmp(a, b));
        EXPECT(ref_str_contains_ci(a, b) == str_contains_ci(a, b), "contains_ci [%s] [%s]", a, b);
        EXPECT(ref_str_starts_with(a, b) == str_starts_with(a, b), "starts_with [%s] [%s]", a, b);
        int ch = rnd() % 7 == 0 ? 0 : (int)al[rnd() % strlen(al)];
        EXPECT(ref_str_chr(a, ch) == str_chr(a, ch), "str_chr [%s] %d", a, ch);
        EXPECT(ref_str_rchr(a, ch) == str_rchr(a, ch), "str_rchr [%s] %d", a, ch);
        size_t cap = rnd() % 60;
        memset(o1, 0x5A, 80); memset(o2, 0x5A, 80);
        EXPECT(ref_str_copy(o1, a, cap) == str_copy(o2, a, cap) && !memcmp(o1, o2, 80), "str_copy cap=%zu [%s]", cap, a);
        memset(o1, 0, 80); memset(o2, 0, 80);
        memcpy(o1, b, strlen(b) < 40 ? strlen(b) + 1 : 40); o1[39] = 0; memcpy(o2, o1, 80);
        EXPECT(ref_str_cat(o1, a, cap) == str_cat(o2, a, cap) && !memcmp(o1, o2, 80), "str_cat cap=%zu [%s]+[%s]", cap, o1, a);
    }
    EXPECT(ref_str_len(NULL) == 0 && str_len(NULL) == 0, "str_len(NULL)");
    for (long it = 0; it < 300000; it++) {
        uint64_t v = ((uint64_t)rnd() << 32 | rnd()) >> (rnd() % 64);
        EXPECT(ref_u64_to_dec(v, o1) == u64_to_dec(v, o2) && !strcmp(o1, o2), "u64_to_dec %lu", v);
        int md = (int)(rnd() % 32);
        EXPECT(ref_u64_to_hex(v, o1, md) == u64_to_hex(v, o2, md) && !strcmp(o1, o2), "u64_to_hex %lx %d", v, md);
    }
}

static void test_paths(void)
{
    static const char *alphas[] = {"/./ab", "//..a", "ab/"};
    char a[BUF], b[BUF], o1[BUF], o2[BUF];
    for (long it = 0; it < 600000; it++) {
        const char *al = alphas[rnd() % 3];
        rstr(a, rnd() % 4 ? 16 : 60, al); rstr(b, rnd() % 4 ? 16 : 60, al);
        size_t cap = rnd() % 70;
        memset(o1, 0x5A, 100); memset(o2, 0x5A, 100);
        int64_t r1 = ref_path_join(o1, a, b, cap), r2 = path_join(o2, a, b, cap);
        EXPECT(r1 == r2 && !memcmp(o1, o2, 100), "path_join [%s] [%s] cap=%zu: %ld vs %ld", a, b, cap, (long)r1, (long)r2);
        memset(o1, 0x5A, 100); memset(o2, 0x5A, 100);
        ref_path_dirname(a, o1, cap); path_dirname(a, o2, cap);
        EXPECT(!memcmp(o1, o2, 100), "path_dirname [%s] cap=%zu: [%s] vs [%s]", a, cap, o1, o2);
        const char *p1 = ref_path_basename(a), *p2 = path_basename(a);
        EXPECT(p1 - a == p2 - a, "path_basename [%s]", a);
        char base[BUF]; rstr(base, 30, "/ab.");
        base[0] = '/';
        memset(o1, 0x5A, 100); memset(o2, 0x5A, 100);
        size_t n1 = ref_path_normalize(base, a, o1, cap), n2 = path_normalize(base, a, o2, cap);
        EXPECT(n1 == n2 && (n1 == 0 || !memcmp(o1, o2, n1 + 1)), "path_normalize [%s] [%s] cap=%zu: %zu vs %zu [%s] [%s]", base, a, cap, n1, n2, o1, o2);
    }
}

static void test_format(void)
{
    char o1[64], o2[64];
    for (long it = 0; it < 500000; it++) {
        int64_t v = (int64_t)(((uint64_t)rnd() << 32 | rnd()) >> (rnd() % 64));
        if (rnd() % 9 == 0) v = -v;
        if (rnd() % 11 == 0) v = (int64_t)(1024ull << (10 * (rnd() % 6))) + (int64_t)(rnd() % 3) - 1;
        memset(o1, 0x5A, 64); memset(o2, 0x5A, 64);
        EXPECT(ref_format_size(v, o1) == format_size(v, o2) && !memcmp(o1, o2, 64), "format_size %ld: [%s] vs [%s]", (long)v, o1, o2);
        uint32_t mode = rnd();
        memset(o1, 0x5A, 64); memset(o2, 0x5A, 64);
        ref_format_perms(mode, o1); format_perms(mode, o2);
        EXPECT(!memcmp(o1, o2, 64), "format_perms %o: [%s] vs [%s]", mode, o1, o2);
        int64_t t = (int64_t)(((uint64_t)rnd() << 32 | rnd()) >> (rnd() % 40)) - (rnd() % 4 ? 0 : (int64_t)rnd() * 50);
        if (rnd() % 7 == 0) t = (int64_t)(rnd() % 4000000000u) - 2000000000;
        memset(o1, 0x5A, 64); memset(o2, 0x5A, 64);
        ref_format_datetime_raw(t, o1); format_datetime_raw(t, o2);
        EXPECT(!memcmp(o1, o2, 20), "datetime_raw %ld: [%s] vs [%s]", (long)t, o1, o2);
        memset(o2, 0x5A, 64);
        format_datetime(t, o2);                    /* cached path must equal the uncached reference */
        format_datetime(t, o2);
        EXPECT(!memcmp(o1, o2, 17), "datetime(cached) %ld: [%s] vs [%s]", (long)t, o1, o2);
    }
    for (int64_t t = -200; t < 200; t++) {         /* around 1970-01-01 and minute -1 (the asm cache returned "" here) */
        ref_format_datetime_raw(t, o1); format_datetime(t, o2);
        EXPECT(!memcmp(o1, o2, 17), "datetime near epoch %ld: [%s] vs [%s]", (long)t, o1, o2);
    }
}

int main(void)
{
    test_strings(); test_paths(); test_format();
    printf("OK %ld checks identical\n", checks);
    return 0;
}
