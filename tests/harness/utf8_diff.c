/* Differential harness: reference asm (symbols prefixed ref_) vs src/core/utf8.c. Prints OK or the first mismatch. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct { uint64_t cp, len; } Utf8Dec;
extern Utf8Dec ref_utf8_decode(const char *);
extern int ref_utf8_encode(uint32_t, char *);
extern int ref_utf8_char_width(uint32_t);
extern int ref_utf8_display_width(const char *);
extern Utf8Dec utf8_decode(const char *);
extern int utf8_encode(uint32_t, char *);
extern int utf8_char_width(uint32_t);
extern int utf8_display_width(const char *);

static uint64_t rs = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return (uint32_t)(rs >> 16); }

int main(void)
{
    long n = 0;
    for (uint32_t cp = 0; cp <= 0x110010; cp++) {
        char a[8] = {0}, b[8] = {0};
        int la = ref_utf8_encode(cp, a), lb = utf8_encode(cp, b);
        if (la != lb || memcmp(a, b, 4)) { printf("encode mismatch cp=%x\n", cp); return 1; }
        if (ref_utf8_char_width(cp) != utf8_char_width(cp)) { printf("width mismatch cp=%x\n", cp); return 1; }
        n++;
    }
    for (long i = 0; i < 6000000; i++) {   /* random 4-byte windows, biased towards lead/continuation bytes */
        char buf[8];
        for (int k = 0; k < 5; k++) {
            uint32_t r = rnd();
            buf[k] = (char)(r % 5 == 0 ? 0x80 | (r >> 8 & 0x3F) : r % 5 == 1 ? 0xC0 | (r >> 8 & 0x3F) : r % 7 == 2 ? 0 : (r >> 8));
        }
        buf[5] = 0;
        Utf8Dec x = ref_utf8_decode(buf), y = utf8_decode(buf);
        if (x.cp != y.cp || x.len != y.len) { printf("decode mismatch at iter %ld: %02x %02x %02x %02x -> %lx/%lu vs %lx/%lu\n", i, (uint8_t)buf[0], (uint8_t)buf[1], (uint8_t)buf[2], (uint8_t)buf[3], x.cp, x.len, y.cp, y.len); return 1; }
        if (ref_utf8_display_width(buf) != utf8_display_width(buf)) { printf("display_width mismatch iter %ld\n", i); return 1; }
    }
    if (utf8_display_width(NULL) != 0 || ref_utf8_display_width(NULL) != 0) { printf("NULL width mismatch\n"); return 1; }
    printf("OK %ld codepoints + 6000000 random windows identical\n", n);
    return 0;
}
