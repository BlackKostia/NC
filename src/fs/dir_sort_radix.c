/* src/fs/dir_sort_radix.c - single-extract, single-histogram-pass byte-skipping LSD radix sorts (numeric keys and
 * multi-stage 8-byte prefix keys) and DirModel_sort (freestanding C23).
 *
 * SORT_SIZE / SORT_MTIME from RADIX_MIN_N entries: one pass over FileEntry[] builds 16-byte {key, idx} records and
 * all 8 byte-lane histograms, skips constant lanes, scatters sequentially, and breaks large equal-key runs with
 * prefix radix (reusing the same buffer). SORT_NAME / SORT_EXT from PREFIX_MIN_N entries: multi-stage 8-byte prefix
 * radix (advancing offset on long shared prefixes, switching completed SORT_EXT runs straight to SORT_NAME ascending).
 * Without memory for the scratch buffer both fall back to pdqsort (introsort_u32). */
#include "duop_fs.h"
#include "duop_string.h"

#define RADIX_MIN_N 64
#define PREFIX_MIN_N 256
#define MAX_PREFIX_OFF 24u
#define HIST_BYTES (8u * 256u * sizeof(uint32_t))

typedef struct RadixRec { uint64_t key; uint32_t idx, pad; } RadixRec;

static inline void radix_hist_add(uint32_t hist[8][256], uint64_t k)
{
    hist[0][(uint8_t)(k)]++;
    hist[1][(uint8_t)(k >> 8)]++;
    hist[2][(uint8_t)(k >> 16)]++;
    hist[3][(uint8_t)(k >> 24)]++;
    hist[4][(uint8_t)(k >> 32)]++;
    hist[5][(uint8_t)(k >> 40)]++;
    hist[6][(uint8_t)(k >> 48)]++;
    hist[7][(uint8_t)(k >> 56)]++;
}

static void radix_reverse(RadixRec *a, size_t len)
{
    for (size_t lo = 0, hi = len - 1; lo < hi; lo++, hi--) {
        RadixRec t = a[lo];
        a[lo] = a[hi];
        a[hi] = t;
    }
}

/* Runs only non-constant byte lanes using precomputed histograms; returns the buffer holding the sorted records. */
static RadixRec *radix_pass_recs(RadixRec *src, RadixRec *dst, size_t len, uint32_t hist[8][256])
{
    for (unsigned p = 0; p < 8; p++) {
        uint32_t *h = hist[p];
        unsigned shift = p * 8;
        if ((size_t)h[(uint8_t)(src[0].key >> shift)] == len) continue;   /* byte lane identical everywhere */
        uint32_t sum = 0;
        for (int b = 0; b < 256; b++) { uint32_t t = h[b]; h[b] = sum; sum += t; }
        for (size_t i = 0; i < len; i++) {
            RadixRec r = src[i];
            dst[h[(uint8_t)(r.key >> shift)]++] = r;
        }
        RadixRec *t = src;
        src = dst;
        dst = t;
    }
    return src;
}

static void *radix_alloc(size_t len, RadixRec **out_a, RadixRec **out_b, uint32_t (**out_h)[256])
{
    if (len > (SIZE_MAX - HIST_BYTES) / (2u * sizeof(RadixRec))) return nullptr;
    void *buf = mem_alloc(len * 2u * sizeof(RadixRec) + HIST_BYTES);
    if (!buf) return nullptr;
    *out_a = (RadixRec *)buf;
    *out_b = *out_a + len;
    *out_h = (uint32_t (*)[256])(*out_b + len);
    return buf;
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
        uint8_t b = s[c];
        if (!b) { key <<= (take - c) * 8; break; }                    /* NUL padded once the name ends */
        if ((uint8_t)(b - 'A') <= 25) b += 32;
        key = (key << 8) | b;
    }
    return desc ? ~key : key;
}

/* Continuation 8-byte prefix key at byte offset `off > 0` (only called when previous chunk had no NUL). */
static uint64_t make_prefix_key_at(uint32_t idx, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc, unsigned off)
{
    const FileEntry *e = &entries[idx];
    const uint8_t *s = (const uint8_t *)pool + e->name_off + (mode == SORT_EXT ? (size_t)e->ext_offset + 1u : 0u) + off;
    uint64_t key = 0;
    for (unsigned c = 0; c < 8; c++) {
        uint8_t b = s[c];
        if (!b) { key <<= (8u - c) * 8; break; }
        if ((uint8_t)(b - 'A') <= 25) b += 32;
        key = (key << 8) | b;
    }
    return desc ? ~key : key;
}

static void prefix_sort_buf(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool,
                            uint32_t mode, uint32_t desc, unsigned off, RadixRec *a, RadixRec *b, uint32_t hist[8][256])
{
    mem_zero(hist, HIST_BYTES);
    bool asc = true, rev = true;
    uint64_t prev = 0;
    for (size_t i = 0; i < len; i++) {
        uint64_t k = off ? make_prefix_key_at(arr[i], entries, pool, mode, desc, off)
                         : make_prefix_key(arr[i], entries, pool, mode, desc);
        a[i] = (RadixRec){k, arr[i], 0};
        radix_hist_add(hist, k);
        if (i) { if (k < prev) asc = false; if (k > prev) rev = false; }
        prev = k;
    }
    RadixRec *res = asc ? a : rev ? (radix_reverse(a, len), a) : radix_pass_recs(a, b, len, hist);
    RadixRec *other = (res == a) ? b : a;
    if (!asc) for (size_t i = 0; i < len; i++) arr[i] = res[i].idx;
    size_t big_i = 0, big_len = 0;
    uint32_t big_mode = 0, big_desc = 0;
    unsigned big_off = 0;
    for (size_t i = 0; i < len;) {
        size_t j = i + 1;
        while (j < len && res[j].key == res[i].key) j++;
        size_t run = j - i;
        if (run >= 2) {
            uint64_t raw = desc ? ~res[i].key : res[i].key;
            uint32_t sm = mode, sd = desc;
            unsigned soff = 0;
            bool sub_radix = false;
            if (mode == SORT_EXT && !(raw & 0xFFu)) {
                sm = SORT_NAME; sd = 0; sub_radix = (run >= PREFIX_MIN_N);
            } else if ((raw & 0xFFu) && run >= PREFIX_MIN_N && off < MAX_PREFIX_OFF) {
                soff = (mode == SORT_EXT && !off) ? 7u : off + 8u;
                sub_radix = true;
            }
            if (!sub_radix) introsort_u32(arr + i, run, entries, pool, sm, sd);
            else if (run <= len / 2) prefix_sort_buf(arr + i, run, entries, pool, sm, sd, soff, other, other + run, hist);
            else { big_i = i; big_len = run; big_mode = sm; big_desc = sd; big_off = soff; }
        }
        i = j;
    }
    if (big_len) prefix_sort_buf(arr + big_i, big_len, entries, pool, big_mode, big_desc, big_off, a, b, hist);
}

void radix_sort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    if (len < 2) return;
    RadixRec *a, *b;
    uint32_t (*hist)[256];
    void *buf = radix_alloc(len, &a, &b, &hist);
    if (!buf) {
        introsort_u32(arr, len, entries, pool, mode, desc);
        return;
    }
    bool asc = true, rev = true;
    uint64_t prev = 0;
    for (size_t i = 0; i < len; i++) {
        uint64_t k = extract_radix_key(arr[i], entries, mode, desc);
        a[i] = (RadixRec){k, arr[i], 0};
        radix_hist_add(hist, k);
        if (i) { if (k < prev) asc = false; if (k > prev) rev = false; }
        prev = k;
    }
    RadixRec *res = asc ? a : rev ? (radix_reverse(a, len), a) : radix_pass_recs(a, b, len, hist);
    RadixRec *other = (res == a) ? b : a;
    if (!asc) for (size_t i = 0; i < len; i++) arr[i] = res[i].idx;
    size_t big_i = 0, big_len = 0;
    for (size_t i = 0; i < len;) {                                    /* equal sizes / times: by name, ascending */
        size_t j = i + 1;
        while (j < len && res[j].key == res[i].key) j++;
        size_t run = j - i;
        if (run >= 2) {
            if (run < PREFIX_MIN_N) introsort_u32(arr + i, run, entries, pool, SORT_NAME, 0);
            else if (run <= len / 2) prefix_sort_buf(arr + i, run, entries, pool, SORT_NAME, 0, 0, other, other + run, hist);
            else { big_i = i; big_len = run; }
        }
        i = j;
    }
    if (big_len) prefix_sort_buf(arr + big_i, big_len, entries, pool, SORT_NAME, 0, 0, a, b, hist);
    mem_free(buf);
}

static void prefix_sort_u32(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    RadixRec *a, *b;
    uint32_t (*hist)[256];
    void *buf = radix_alloc(len, &a, &b, &hist);
    if (!buf) {
        introsort_u32(arr, len, entries, pool, mode, desc);
        return;
    }
    prefix_sort_buf(arr, len, entries, pool, mode, desc, 0, a, b, hist);
    mem_free(buf);
}

/* O(1) expected on unsorted input, O(n) with zero allocation on already-sorted or reversed slices. */
static bool try_presorted(uint32_t *arr, size_t len, const FileEntry *entries, const char *pool, uint32_t mode, uint32_t desc)
{
    bool asc = true, rev = true;
    for (size_t i = 1; i < len && (asc || rev); i++) {
        int r = cmp_indices(arr[i - 1], arr[i], entries, pool, mode, desc);
        if (r > 0) asc = false;
        else if (r < 0) rev = false;
    }
    if (asc) return true;
    if (rev) {
        for (size_t lo = 0, hi = len - 1; lo < hi; lo++, hi--) {
            uint32_t t = arr[lo];
            arr[lo] = arr[hi];
            arr[hi] = t;
        }
        return true;
    }
    return false;
}

static void sort_half(uint32_t *arr, size_t len, const DirModel *m)
{
    if (len < 2) return;
    uint32_t mode = (uint32_t)m->sort_mode, desc = (uint32_t)m->sort_desc;
    if (len >= RADIX_MIN_N && try_presorted(arr, len, m->entries, m->name_pool, mode, desc)) return;
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
