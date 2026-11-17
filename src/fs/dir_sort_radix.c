/* src/fs/dir_sort_radix.c - byte-skipping LSD radix sorts and DirModel_sort (freestanding C23; replaces dir_sort_radix.s +
 * dir_sort_prefix.s, kept as tests/harness/dir_sort_radix_reference.s and dir_sort_prefix_reference.s).
 *
 * SORT_SIZE / SORT_MTIME from RADIX_MIN_N entries: radix over the 64-bit key (byte lanes that never differ are skipped), then
 * equal-key runs by name. SORT_NAME / SORT_EXT from PREFIX_MIN_N entries: radix over an order-preserving 8-byte prefix key
 * (16-byte {key, idx} records, one sequential pass over the name pool), then the full comparator on equal-prefix runs only.
 * Without memory for the scratch arrays both fall back to introsort. */
#include "duop_fs.h"
#include "duop_string.h"

#define RADIX_MIN_N 64
#define PREFIX_MIN_N 512

typedef struct PrefixRec { uint64_t key; uint32_t idx, pad; } PrefixRec;

/* one counting pass of byte `shift / 8` from src to dst (n elements, the key of element i is key_of(i)) */
#define DS_RADIX_PASS(n, shift, keyexpr, place)                                   \
    do {                                                                          \
        size_t hist[256] = {0};                                                   \
        for (size_t i = 0; i < (n); i++) hist[(uint8_t)((keyexpr) >> (shift))]++; \
        size_t sum = 0;                                                           \
        for (int b = 0; b < 256; b++) { size_t t = hist[b]; hist[b] = sum; sum += t; } \
        for (size_t i = 0; i < (n); i++) {                                        \
            size_t at = hist[(uint8_t)((keyexpr) >> (shift))]++;                  \
            place;                                                                \
        }                                                                         \
    } while (0)

void radix_sort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    uint32_t *scratch = mem_alloc(len * 4);
    if (!scratch) {
        introsort_u32(arr, len, entries, pool, mode, desc);
        return;
    }
    uint64_t first = extract_radix_key(arr[0], entries, mode, desc), diff = 0;
    for (size_t i = 1; i < len; i++) diff |= extract_radix_key(arr[i], entries, mode, desc) ^ first;
    uint32_t *src = arr, *dst = scratch;
    for (unsigned shift = 0; shift < 64; shift += 8) {
        if (!(uint8_t)(diff >> shift)) continue;                      /* this byte lane is the same everywhere */
        DS_RADIX_PASS(len, shift, extract_radix_key(src[i], entries, mode, desc), dst[at] = src[i]);
        uint32_t *t = src;
        src = dst;
        dst = t;
    }
    if (src != arr) mem_copy(arr, src, len * 4);
    mem_free(scratch);
    for (size_t i = 0; i < len;) {                                    /* equal sizes / times: by name, ascending */
        uint64_t k = extract_radix_key(arr[i], entries, mode, desc);
        size_t j = i + 1;
        while (j < len && extract_radix_key(arr[j], entries, mode, desc) == k) j++;
        if (j - i >= 2) introsort_u32(arr + i, j - i, entries, pool, SORT_NAME, 0);
        i = j;
    }
}

uint64_t make_prefix_key(uint32_t idx, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    const FileEntry *e = &entries[idx];
    const uint8_t *s = (const uint8_t *)pool + e->name_off;
    uint64_t key = 0;
    unsigned take = 8;
    if (mode == SORT_EXT) {
        if (!e->ext_offset) return desc ? ~key : key;                 /* no extension: key 0 */
        s += e->ext_offset + 1;
        key = 1;                                                      /* has-extension flag above the 7 key bytes */
        take = 7;
    }
    for (unsigned c = 0; c < take; c++) {
        uint8_t b = *s;
        if (b) {
            s++;
            if (b >= 'A' && b <= 'Z') b += 32;
        }
        key = key << 8 | b;                                           /* NUL padded once the name ends */
    }
    return desc ? ~key : key;
}

static void prefix_sort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    PrefixRec *recs = mem_alloc(len * 32);                            /* two record arrays */
    if (!recs) {
        introsort_u32(arr, len, entries, pool, mode, desc);
        return;
    }
    uint64_t diff = 0;
    for (size_t i = 0; i < len; i++) {
        recs[i] = (PrefixRec){make_prefix_key(arr[i], entries, pool, mode, desc), arr[i], 0};
        diff |= recs[i].key ^ recs[0].key;
    }
    PrefixRec *src = recs, *dst = recs + len;
    for (unsigned shift = 0; shift < 64; shift += 8) {
        if (!(uint8_t)(diff >> shift)) continue;
        DS_RADIX_PASS(len, shift, src[i].key, dst[at] = src[i]);
        PrefixRec *t = src;
        src = dst;
        dst = t;
    }
    for (size_t i = 0; i < len; i++) arr[i] = src[i].idx;
    for (size_t i = 0; i < len;) {                                    /* equal prefixes: the full comparator */
        size_t j = i + 1;
        while (j < len && src[j].key == src[i].key) j++;
        if (j - i >= 2) introsort_u32(arr + i, j - i, entries, pool, mode, desc);
        i = j;
    }
    mem_free(recs);
}

static void sort_half(uint32_t *arr, size_t len, const DirModel *m)
{
    if (len < 2) return;
    uint32_t mode = (uint32_t)m->sort_mode, desc = (uint32_t)m->sort_desc;
    if (mode == SORT_SIZE || mode == SORT_MTIME) {
        if (len >= RADIX_MIN_N) radix_sort_u32(arr, len, m->entries, m->name_pool, mode, desc);
        else introsort_u32(arr, len, m->entries, m->name_pool, mode, desc);
    } else if (len >= PREFIX_MIN_N) {
        prefix_sort_u32(arr, len, m->entries, m->name_pool, mode, desc);
    } else {
        introsort_u32(arr, len, m->entries, m->name_pool, mode, desc);
    }
}

static bool ds_is_dir(const DirModel *m, uint32_t idx) { return m->entries[idx].flags & (FE_IS_DIR | FE_LINK_DIR); }

/* Partitions order[has_dotdot .. count - 1] into [directories][files] (two pointers, O(n)) and sorts each half. */
void DirModel_sort(DirModel *m)
{
    if ((m->sort_mode == SORT_SIZE || m->sort_mode == SORT_MTIME) && !m->stats_complete) DirModel_ensure_all_stats(m);
    int64_t n = (int64_t)(m->count - (uint32_t)m->has_dotdot);       /* -1 for an empty filtered view */
    if (n >= 2) {
        uint32_t *s = m->order + (uint32_t)m->has_dotdot;
        int64_t lo = 0, hi = n - 1;
        while (lo <= hi) {
            while (lo <= hi && ds_is_dir(m, s[lo])) lo++;
            if (lo > hi) break;
            while (lo < hi && !ds_is_dir(m, s[hi])) hi--;
            if (lo >= hi) break;
            uint32_t t = s[lo];
            s[lo++] = s[hi];
            s[hi--] = t;
        }
        sort_half(s, (size_t)lo, m);
        sort_half(s + lo, (size_t)(n - lo), m);
    }
    m->is_unsorted = 0;
}
