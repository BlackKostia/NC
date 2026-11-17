/* Freestanding harness: reads stdin, feeds it in argv[1]-byte chunks to crc32/sha256, prints "<crc32 hex> <sha256 hex>". */
#include "duop_hash.h"

static uint8_t g_in[(4u << 20) + 16];

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)envp; (void)auxv;
    size_t chunk = 0;
    if (argc > 1) for (const char *s = argv[1]; *s; s++) chunk = chunk * 10 + (size_t)(*s - '0');
    if (!chunk) chunk = 1;
    size_t n = 0;
    for (;;) {
        intptr_t r = os_read(0, g_in + n, sizeof g_in - n);
        if (r <= 0) break;
        n += (size_t)r;
    }
    ShaCtx c;
    sha256_init(&c);
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t off = 0; off < n; off += chunk) {
        size_t k = n - off < chunk ? n - off : chunk;
        crc = crc32_update(crc, g_in + off, k);
        sha256_update(&c, g_in + off, k);
    }
    crc = ~crc;
    char out[8 + 1 + 65 + 1], *o = out;
    for (int sh = 28; sh >= 0; sh -= 4) *o++ = "0123456789abcdef"[(crc >> sh) & 15];
    *o++ = ' ';
    sha256_final_hex(&c, o);
    size_t len = 0;
    while (out[len]) len++;
    out[len++] = '\n';
    (void)os_write(1, out, len);
    return 0;
}
