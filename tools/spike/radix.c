/* Spike (Етап 0.0): radix_sort_u32 з src/fs/dir_sort_radix.s у freestanding C23. */
#include <stdint.h>
#include <stddef.h>

typedef struct { int64_t size, mtime; uint32_t mode, flags, name_off; uint16_t name_len; uint8_t disp_width, ext_offset; } FileEntry;
_Static_assert(sizeof(FileEntry) == 32, "FileEntry ABI");

enum { SORT_NAME = 0, SORT_SIZE = 1, SORT_MTIME = 2, SORT_EXT = 3 };

extern void *mem_alloc(uint64_t n);
extern void mem_free(void *p);
extern void introsort_u32(uint32_t *a, uint64_t n, const FileEntry *e, const char *pool, uint32_t mode, uint32_t desc);

static inline uint64_t radix_key(uint32_t idx, const FileEntry *e, uint32_t mode, uint32_t desc)
{
    int64_t v = (mode == SORT_MTIME) ? e[idx].mtime : e[idx].size;
    uint64_t k = (uint64_t)v ^ 0x8000000000000000ull;
    return desc ? ~k : k;
}

void radix_sort_u32(uint32_t *arr, uint64_t len, const FileEntry *e, const char *pool, uint32_t mode, uint32_t desc)
{
    uint32_t *scratch = mem_alloc(len * 4);
    if (!scratch) { introsort_u32(arr, len, e, pool, mode, desc); return; }
    uint64_t first = radix_key(arr[0], e, mode, desc), diff = 0;
    for (uint64_t i = 1; i < len; i++) diff |= radix_key(arr[i], e, mode, desc) ^ first;
    uint32_t *src = arr, *dst = scratch;
    uint32_t parity = 0;
    uint64_t hist[256];
    for (uint32_t sh = 0; sh < 64; sh += 8) {
        if (!((diff >> sh) & 0xFF)) continue;
        for (int i = 0; i < 256; i++) hist[i] = 0;
        for (uint64_t i = 0; i < len; i++) hist[(radix_key(src[i], e, mode, desc) >> sh) & 0xFF]++;
        uint64_t sum = 0;
        for (int i = 0; i < 256; i++) { uint64_t c = hist[i]; hist[i] = sum; sum += c; }
        for (uint64_t i = 0; i < len; i++) {
            uint32_t v = src[i];
            dst[hist[(radix_key(v, e, mode, desc) >> sh) & 0xFF]++] = v;
        }
        uint32_t *t = src; src = dst; dst = t;
        parity ^= 1;
    }
    if (parity) for (uint64_t i = 0; i < len; i++) arr[i] = src[i];
    mem_free(scratch);
    for (uint64_t i = 0; i < len;) {
        uint64_t k = radix_key(arr[i], e, mode, desc), j = i + 1;
        while (j < len && radix_key(arr[j], e, mode, desc) == k) j++;
        if (j - i >= 2) introsort_u32(arr + i, j - i, e, pool, SORT_NAME, 0);
        i = j;
    }
}
