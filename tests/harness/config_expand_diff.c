/* Differential harness: reference asm config_expand_cmd (ref_ prefix) vs src/core/config_expand.c. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const char *cur_name, *cur_path, *selection, *active_dir, *inactive_dir; } Ctx;
extern int64_t ref_config_expand_cmd(const char *, char *, size_t, const Ctx *);
extern int64_t config_expand_cmd(const char *, char *, size_t, const Ctx *);

static uint64_t rs = 0xD1B54A32D192ED03ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 20); }
static void rstr(char *s, size_t max, const char *alpha)
{
    size_t n = rnd() % (max + 1), na = strlen(alpha);
    for (size_t i = 0; i < n; i++) s[i] = alpha[rnd() % na];
    s[n] = 0;
}

int main(void)
{
    static const char *tal[] = {"%fpdDFsx%\\'\" a$`", "ab %f %s '%p' \"%d\" \\%", "%%%f'\"\\x"};
    static const char *val_al[] = {"ab '\"\\$` x", "plain", "'''", "\"$`\\"};
    long n = 0;
    for (long it = 0; it < 1500000; it++) {
        char tmpl[96], names[120], cur[40], path[40], ad[40], id[40];
        rstr(tmpl, 40, tal[rnd() % 3]);
        rstr(cur, 12, val_al[rnd() % 4]); rstr(path, 12, val_al[rnd() % 4]); rstr(ad, 12, val_al[rnd() % 4]); rstr(id, 12, val_al[rnd() % 4]);
        size_t p = 0;
        for (int k = rnd() % 4; k > 0; k--) { char nm[16]; rstr(nm, 8, val_al[rnd() % 4]); if (!nm[0]) nm[0] = 'n', nm[1] = 0; size_t l = strlen(nm) + 1; memcpy(names + p, nm, l); p += l; }
        names[p++] = 0;
        Ctx c = {rnd() % 9 ? cur : NULL, rnd() % 9 ? path : NULL, rnd() % 9 ? names : NULL, rnd() % 9 ? ad : NULL, rnd() % 9 ? id : NULL};
        size_t cap = rnd() % 100;
        char o1[128], o2[128];
        memset(o1, 0x5A, sizeof o1); memset(o2, 0x5A, sizeof o2);
        int64_t r1 = ref_config_expand_cmd(tmpl, o1, cap, &c), r2 = config_expand_cmd(tmpl, o2, cap, &c);
        if (r1 != r2 || memcmp(o1, o2, sizeof o1)) {
            printf("MISMATCH tmpl=[%s] cap=%zu: ret %ld vs %ld out [%s] vs [%s]\n", tmpl, cap, (long)r1, (long)r2, o1, o2);
            return 1;
        }
        n++;
    }
    printf("OK %ld expansions identical\n", n);
    return 0;
}
