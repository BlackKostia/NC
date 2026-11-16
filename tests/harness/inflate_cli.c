/* Freestanding harness: stdin = [u32 mode (0 raw, 1 zlib)][u32 cap][stream]; prints "<ret>\n" then the output bytes. */
#include "duop_abi.h"

int64_t inflate_raw(const void *src, uint64_t src_len, void *dst, uint64_t dst_cap);
int64_t inflate_zlib(const void *src, uint64_t src_len, void *dst, uint64_t dst_cap);

static uint8_t g_in[(1u << 22)], g_out[(4u << 20) + 16];

int duop_main(int argc, char **argv, char **envp, const uintptr_t *auxv)
{
    (void)argc; (void)argv; (void)envp; (void)auxv;
    size_t n = 0;
    for (;;) {
        intptr_t r = os_read(0, g_in + n, sizeof g_in - n);
        if (r <= 0) break;
        n += (size_t)r;
    }
    if (n < 8) return 2;
    uint32_t mode = load_le32(g_in), cap = load_le32(g_in + 4);
    if (cap > 4u << 20) cap = 4u << 20;
    int64_t r = (mode ? inflate_zlib : inflate_raw)(g_in + 8, n - 8, g_out, cap);
    char head[24]; int k = 0; uint64_t u = r < 0 ? (uint64_t)-r : (uint64_t)r; char t[20]; int m = 0;
    do { t[m++] = (char)('0' + u % 10); u /= 10; } while (u);
    if (r < 0) head[k++] = '-';
    while (m) head[k++] = t[--m];
    head[k++] = '\n';
    (void)os_write(1, head, (size_t)k);
    if (r > 0) (void)os_write(1, g_out, (size_t)r);
    return 0;
}
