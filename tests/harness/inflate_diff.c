/* Differential harness: reference asm inflate (ref_ prefix) vs src/fs/inflate.c on a corpus file (argv[1]):
 * repeated records [u32 len][bytes]. Each record is inflated as raw deflate and as zlib with several output caps;
 * return values, produced bytes and the absence of out-of-bounds writes must match. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int64_t ref_inflate_raw(const void *, uint64_t, void *, uint64_t);
extern int64_t ref_inflate_zlib(const void *, uint64_t, void *, uint64_t);
extern int64_t inflate_raw(const void *, uint64_t, void *, uint64_t);
extern int64_t inflate_zlib(const void *, uint64_t, void *, uint64_t);
void *mem_alloc(uint64_t n) { return calloc(1, n); }
void mem_free(void *p) { free(p); }
void mem_zero(void *p, uint64_t n) { memset(p, 0, n); }

#define CANARY 64
static int one(int64_t (*fa)(const void *, uint64_t, void *, uint64_t), int64_t (*fb)(const void *, uint64_t, void *, uint64_t),
               const uint8_t *in, uint32_t n, uint64_t cap, long rec, const char *what)
{
    uint8_t *a = malloc(cap + 2 * CANARY), *b = malloc(cap + 2 * CANARY);
    memset(a, 0xA5, cap + 2 * CANARY); memset(b, 0xA5, cap + 2 * CANARY);
    int64_t ra = fa(in, n, a + CANARY, cap), rb = fb(in, n, b + CANARY, cap);
    int bad = 0;
    if (ra != rb) { printf("record %ld %s cap=%lu: ret %ld (asm) vs %ld (C)\n", rec, what, (unsigned long)cap, (long)ra, (long)rb); bad = 1; }
    else if (ra > 0 && memcmp(a + CANARY, b + CANARY, (size_t)ra)) { printf("record %ld %s cap=%lu: output differs\n", rec, what, (unsigned long)cap); bad = 1; }
    for (int i = 0; i < CANARY && !bad; i++)
        if (b[i] != 0xA5 || b[CANARY + cap + i] != 0xA5) { printf("record %ld %s: C wrote out of bounds\n", rec, what); bad = 1; }
    free(a); free(b);
    return bad;
}

int main(int argc, char **argv)
{
    if (argc < 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    uint32_t n; long rec = 0, ok = 0;
    while (fread(&n, 4, 1, f) == 1) {
        uint8_t *buf = malloc(n + 8);
        if (fread(buf, 1, n, f) != n) return 2;
        uint64_t caps[4] = {64, 4096, 1u << 16, 3u << 20};
        for (int c = 0; c < 4; c++) {
            if (one(ref_inflate_raw, inflate_raw, buf, n, caps[c], rec, "raw")) return 1;
            if (one(ref_inflate_zlib, inflate_zlib, buf, n, caps[c], rec, "zlib")) return 1;
        }
        free(buf); rec++; ok++;
    }
    printf("OK %ld records identical\n", ok);
    return 0;
}
